local H = _G.H
local url = os.getenv("DBGRID_TEST_URL")
if not url then
  io.write("  skip ui integration (DBGRID_TEST_URL not set)\n")
  return
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("dbgrid").setup({
  storage = { data_dir = tmp .. "/data", mode = "data" },
  connections = { { name = "test", url = url } },
  default_connection = "test",
  query = { confirm_writes = false, limit = 5 },
  index_check = { mode = "warn", min_rows = 1000 },
})
local notebook = require("dbgrid.notebook")
local layout = require("dbgrid.ui.layout")
local runner = require("dbgrid.runner")
local cells = require("dbgrid.cells")
local query = require("dbgrid.ui.query")

local function results_lines(s)
  return vim.api.nvim_buf_get_lines(s.results_buf, 0, -1, false)
end

local function set_cells(s, lines)
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.b[s.buf].dbgrid_cells_cache = nil
end

local function run_and_wait(s, idx)
  local done
  local cell = cells.parse(s.buf)[idx]
  runner.run_cell(s, cell, {
    cb = function(r)
      done = r
    end,
  })
  H.truthy(
    H.wait(15000, function()
      return done ~= nil
    end),
    "run timed out"
  )
  return done
end

H.describe("notebook ui", function()
  local nb = notebook.create("ui test", { connection = "test" })
  local s = layout.open(nb)

  H.it("opens a tab with a query and a results window", function()
    H.truthy(s.results_win and vim.api.nvim_win_is_valid(s.results_win))
    H.truthy(s.query_win and vim.api.nvim_win_is_valid(s.query_win))
    H.eq(vim.api.nvim_get_current_win(), s.query_win)
    H.eq(vim.bo[s.buf].filetype, "sql")
    H.eq(vim.b[s.buf].dbgrid, nb.name)
    H.matches(table.concat(results_lines(s), "\n"), "not been run")
    H.matches(layout.winbar_query(s.buf), "test")
  end)

  H.it("runs a cell, renders the grid and caches the result", function()
    set_cells(s, {
      "-- %% [c1] first three",
      "select id, email, null::text as gone, balance from users where id <= 3 order by id",
      "",
      "-- %% [c2] update",
      "update users set note = note where id = 1",
      "",
      "-- %% [c3] broken",
      "select id,",
      "  nope",
      "from users",
    })
    vim.api.nvim_win_set_cursor(s.query_win, { 2, 0 })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(r.statements[1].limit_applied, 5)
    local lines = results_lines(s)
    local text = table.concat(lines, "\n")
    H.matches(text, "id │ email")
    H.matches(text, "user1@example%.com")
    H.matches(text, "NULL")
    H.matches(text, "3 rows")
    H.matches(text, "LIMIT 5 added")
    H.eq(s.active_cell, "c1")
    H.eq(nb.meta.cells.c1.row_count, 3)
    H.eq(nb.meta.cells.c1.status, "ok")
    -- header status extmark
    local marks = vim.api.nvim_buf_get_extmarks(s.buf, query.ns, 0, -1, { details = true })
    local found = false
    for _, m in ipairs(marks) do
      local vt = m[4].virt_text
      if vt then
        for _, chunk in ipairs(vt) do
          if chunk[1]:find("3 rows", 1, true) then
            found = true
          end
        end
      end
    end
    H.truthy(found, "expected a '3 rows' status on the header")
  end)

  H.it("shows the numeric column right-aligned and the cursor column", function()
    local rl = results_lines(s)
    local header_lnum
    for i, l in ipairs(rl) do
      if l:find("id │ email", 1, true) then
        header_lnum = i
      end
    end
    H.truthy(header_lnum)
    local row = rl[header_lnum + 2]
    H.matches(row, "^%s*1 │ user1@example%.com")
    vim.api.nvim_win_set_cursor(s.results_win, { header_lnum + 2, 0 })
    local results = require("dbgrid.ui.results")
    local c = results.cell_at_cursor(s)
    H.eq(c.column, "id")
    H.eq(c.value, "1")
    results.move_column(s, 1)
    c = results.cell_at_cursor(s)
    H.eq(c.column, "email")
    H.eq(c.value, "user1@example.com")
  end)

  H.it("switches results when the cursor moves to another cell", function()
    vim.api.nvim_win_set_cursor(s.query_win, { 5, 0 })
    query.on_cursor(s)
    H.eq(s.active_cell, "c2")
    H.matches(table.concat(results_lines(s), "\n"), "not been run")
    query.move(s, -1)
    H.eq(s.active_cell, "c1")
    H.eq(vim.api.nvim_win_get_cursor(s.query_win)[1], 2)
    query.move(s, 1)
    query.move(s, 1)
    H.eq(s.active_cell, "c3")
  end)

  H.it("runs writes and shows command tags", function()
    local r = run_and_wait(s, 2)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.matches(table.concat(results_lines(s), "\n"), "UPDATE 1")
  end)

  H.it("reports errors with a diagnostic on the right line", function()
    local r = run_and_wait(s, 3)
    H.eq(r.ok, false)
    H.matches(table.concat(results_lines(s), "\n"), 'column "nope" does not exist')
    local diags = vim.diagnostic.get(s.buf, { namespace = runner.diag_ns })
    H.eq(#diags, 1)
    H.eq(diags[1].lnum, 8) -- 0-based: "  nope" is line 9
    H.eq(nb.meta.cells.c3.status, "error")
  end)

  H.it("warns about sequential scans on big tables", function()
    set_cells(s, { "-- %% [c4] scan", "select * from users where balance > 5" })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, true)
    H.truthy(#r.warnings >= 1, "expected a seq scan warning")
    H.matches(r.warnings[1].message, "Seq Scan on users")
    H.matches(table.concat(results_lines(s), "\n"), "Seq Scan on users")
    H.truthy(r.statements[1].plan, "plan should be attached")
    require("dbgrid.ui.results").toggle_plan(s)
    H.matches(table.concat(results_lines(s), "\n"), "Seq Scan on users")
    require("dbgrid.ui.results").toggle_plan(s)
  end)

  H.it("marks a cell stale after editing", function()
    vim.api.nvim_buf_set_lines(s.buf, 1, 2, false, { "select * from users where balance > 6" })
    vim.b[s.buf].dbgrid_cells_cache = nil
    local cell = cells.parse(s.buf)[1]
    local chunks = query.status_chunks(s, cell)
    local joined = ""
    for _, c in ipairs(chunks) do
      joined = joined .. c[1]
    end
    H.matches(joined, "edited")
  end)

  H.it("record view, sort, filter and yanks", function()
    set_cells(s, { "-- %% [c5] few", "select id, email from users where id <= 4 order by id desc" })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, true)
    local results = require("dbgrid.ui.results")
    local rl = results_lines(s)
    local first_row
    for i, l in ipairs(rl) do
      if l:match("^%s*4 │") then
        first_row = i
      end
    end
    H.truthy(first_row)
    vim.api.nvim_win_set_cursor(s.results_win, { first_row, 0 })
    results.sort(s)
    H.matches(results_lines(s)[first_row], "^%s*1 │")
    results.sort(s)
    H.matches(results_lines(s)[first_row], "^%s*4 │")
    s.view.filter = "user2"
    results.render(s, true)
    H.matches(table.concat(results_lines(s), "\n"), "user2@example%.com")
    H.falsy(table.concat(results_lines(s), "\n"):find("user3@", 1, true))
    s.view.filter = nil
    results.render(s, true)
    vim.api.nvim_win_set_cursor(s.results_win, { first_row, 0 })
    results.toggle_record(s)
    H.matches(table.concat(results_lines(s), "\n"), "row 1 of 4")
    results.toggle_record(s)
    vim.api.nvim_win_set_cursor(s.results_win, { first_row, 0 })
    results.yank_row_json(s)
    H.matches(vim.fn.getreg('"'), '"email": "user4@example.com"')
    results.yank_insert(s)
    H.matches(vim.fn.getreg('"'), "^INSERT INTO users %(id, email%) VALUES %('4', 'user4@example.com'%);$")
    results.yank_csv(s)
    H.matches(vim.fn.getreg('"'), "^id,email\n4,user4@example.com\n")
  end)

  H.it("completes columns from the schema", function()
    local schema = require("dbgrid.schema")
    local conn = require("dbgrid.connections").get("test")
    local loaded
    schema.get(conn, function(sch)
      loaded = sch
    end)
    H.truthy(H.wait(15000, function()
      return loaded ~= nil
    end))
    set_cells(s, { "-- %% [c6]", "select u. from users u" })
    local items = require("dbgrid.completion").items(s.buf, 2, 9)
    local labels = vim.tbl_map(function(i)
      return i.label
    end, items)
    H.truthy(vim.tbl_contains(labels, "email"))
    H.truthy(vim.tbl_contains(labels, "balance"))
    H.falsy(vim.tbl_contains(labels, "select"))
    local items2 = require("dbgrid.completion").items(s.buf, 2, 6)
    local kinds = {}
    for _, i in ipairs(items2) do
      kinds[i.kind_name] = true
    end
    H.truthy(kinds.table and kinds.column and kinds.keyword)
  end)

  if os.getenv("DBGRID_TEST_AI") then
    H.it("generates SQL from a prompt with the real agent and runs it", function()
      set_cells(s, { "-- %% [ai1] generated", "-- ? number of users per plan, with the plan name, most users first" })
      local cell = cells.parse(s.buf)[1]
      require("dbgrid.ai").generate(s, cell)
      H.truthy(
        H.wait(170000, function()
          return s.runtime.ai1 and s.runtime.ai1.status == "generated"
        end),
        "generation timed out"
      )
      local fresh = cells.by_id(s.buf, "ai1")
      local body = cells.body_text(fresh)
      io.write("    generated:\n" .. body:gsub("\n", "\n      ") .. "\n")
      H.matches(body:lower(), "plans")
      H.matches(body, "^%-%- %? number of users per plan")
      local r = run_and_wait(s, 1)
      H.eq(r.ok, true, vim.inspect(r.error))
      H.truthy(r.statements[1].sets[1].row_count >= 1)
      H.eq(s.runtime.ai1.status, "ok")
    end)
  end

  H.it("closes the layout", function()
    local tabs = #vim.api.nvim_list_tabpages()
    layout.close(s)
    H.eq(#vim.api.nvim_list_tabpages(), tabs - 1)
  end)
end)
