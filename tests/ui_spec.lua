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

  H.it("asks the agent about the query and the result", function()
    local util = require("dbgrid.util")
    local ai = require("dbgrid.ai")
    local review = require("dbgrid.ui.review")
    -- a fake agent: keeps the prompt it was given, answers with two lines
    local script, captured = tmp .. "/agent.sh", tmp .. "/prompt.txt"
    util.write_file(
      script,
      "#!/bin/sh\ncat > '" .. captured .. "'\necho 'The scan is fine.'\necho 'Add an index on balance.'\n"
    )
    vim.fn.setfperm(script, "rwxr-xr-x")
    local cfg = require("dbgrid.config").get()
    cfg.ai.agents.fake = { cmd = { script }, stdin = true }
    cfg.ai.agent = "fake"
    local cell = cells.parse(s.buf)[1]
    ai.review(s, cell, "is this query ok?")
    H.truthy(s.running.c4, "a review job should be running")
    H.truthy(
      H.wait(10000, function()
        return s.runtime.c4 and s.runtime.c4.review ~= nil
      end),
      "answer timed out"
    )
    H.eq(s.running.c4, nil)
    local turns = s.runtime.c4.review.turns
    H.eq(#turns, 1)
    H.eq(turns[1].question, "is this query ok?")
    H.eq(turns[1].answer, "The scan is fine.\nAdd an index on balance.")
    local prompt = util.read_file(captured)
    H.matches(prompt, "## Question\nis this query ok%?")
    H.matches(prompt, "## Query %(cell q1 scan%)\nselect %* from users where balance > 5%s+LIMIT 5;")
    H.matches(prompt, "on connection test")
    H.matches(prompt, "The notebook added LIMIT 5 to this statement, and it was hit")
    H.matches(prompt, "5 rows:\nid | email | plan_id | balance | created_at | note\n%d+ | user%d+@example%.com")
    H.matches(prompt, "Index check before the run warned:\n%- Seq Scan on users")
    H.matches(prompt, "## Plan %(estimated.-\n%s*%-> Seq Scan on users")
    H.falsy(prompt:find("Earlier questions", 1, true))
    -- the answer float is open and focused on the transcript
    H.truthy(s.review_win and vim.api.nvim_win_is_valid(s.review_win), "the answer float should be open")
    H.eq(vim.api.nvim_get_current_win(), s.review_win)
    local fbuf = vim.api.nvim_win_get_buf(s.review_win)
    H.eq(vim.bo[fbuf].filetype, "markdown")
    local flines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
    H.eq(flines[1], "**Q:** is this query ok?")
    H.matches(table.concat(flines, "\n"), "Add an index on balance%.")
    review.close(s)
    H.eq(s.review_win, nil)
    -- a follow-up carries the earlier exchange
    ai.review(s, cell, "which index?")
    H.truthy(
      H.wait(10000, function()
        return #s.runtime.c4.review.turns == 2
      end),
      "follow-up timed out"
    )
    prompt = util.read_file(captured)
    H.matches(prompt, "## Earlier questions about this same result\nQ: is this query ok%?\nA: The scan is fine%.")
    flines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(s.review_win), 0, -1, false)
    H.matches(table.concat(flines, "\n"), "%*%*Q:%*%* is this query ok%?.*\n%-%-%-\n.*%*%*Q:%*%* which index%?")
    review.close(s)
    cfg.ai.agent = "claude"
    cfg.ai.agents.fake = nil
    vim.api.nvim_set_current_win(s.query_win)
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

  H.it("substitutes parameters and remembers prompted values", function()
    set_cells(s, {
      "-- %% [pp1] params",
      "-- @param min = 7000",
      "select id, email from users where balance > :min and id < {{max}} order by id",
    })
    local orig = vim.ui.input
    local asked = 0
    vim.ui.input = function(_, cb)
      asked = asked + 1
      cb("4700")
    end
    local r = run_and_wait(s, 1)
    vim.ui.input = orig
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(asked, 1)
    H.eq(r.params, { min = "7000", max = "4700" })
    H.eq(nb.meta.params.max, "4700")
    local text = table.concat(results_lines(s), "\n")
    H.matches(text, "with :max = 4700, :min = 7000")
    H.matches(text, "user4668@example%.com")
    H.falsy(text:find("user4700@", 1, true))
    -- the remembered value is reused without asking
    asked = 0
    vim.ui.input = function(_, cb)
      asked = asked + 1
      cb("1")
    end
    r = run_and_wait(s, 1)
    vim.ui.input = orig
    H.eq(asked, 0)
    H.eq(r.params.max, "4700")
    -- completion knows the parameters and the cells
    local items = require("dbgrid.completion").items(s.buf, 3, 61)
    local kinds = {}
    for _, it in ipairs(items) do
      kinds[it.label] = it.kind_name
    end
    H.eq(kinds.min, "parameter")
    H.eq(kinds.max, "parameter")
    H.eq(kinds.params, nil, "a cell does not reference itself")
  end)

  H.it("inlines referenced cells and runs dependencies first", function()
    set_cells(s, {
      "-- %% [r1] rich users",
      "select id, email from users where balance > 7000",
      "",
      "-- %% [r2] count rich",
      "select count(*) as n from {{rich-users}} r where r.id > 0",
      "",
      "-- %% [r3] setup",
      "update users set note = 'seen' where id = 1",
      "",
      "-- %% [r4] after setup",
      "-- @depends setup",
      "select note from users where id = 1",
    })
    local r = run_and_wait(s, 2)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(r.statements[1].sets[1].rows[1][1], "334")
    H.eq(r.refs, { "r1" })
    H.matches(table.concat(results_lines(s), "\n"), "inlines rich%-users")
    H.eq(nb.meta.cells.r1, nil, "an inlined cell is not run on its own")
    local items = require("dbgrid.completion").items(s.buf, 5, 28)
    local labels = vim.tbl_map(function(i)
      return i.label
    end, items)
    H.truthy(vim.tbl_contains(labels, "rich-users"))
    H.truthy(vim.tbl_contains(labels, "setup"))
    H.falsy(vim.tbl_contains(labels, "count-rich"))
    -- dependencies: r3 has not run, so running r4 runs it first
    r = run_and_wait(s, 4)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(r.statements[1].sets[1].rows[1][1], "seen")
    H.eq(nb.meta.cells.r3.status, "ok")
    local ran_at = nb.meta.cells.r3.ran_at
    -- a fresh dependency is not run again
    local deps = runner.pending_dependencies(s, cells.parse(s.buf)[4])
    H.eq(deps, {})
    local order = runner.run_order(s)
    H.eq(
      vim.tbl_map(function(c)
        return c.id
      end, order),
      { "r1", "r2", "r3", "r4" }
    )
    H.eq(nb.meta.cells.r3.ran_at, ran_at)
    -- a cycle is reported, not run
    set_cells(s, { "-- %% [x1] a", "-- @depends b", "select 1", "-- %% [x2] b", "-- @depends a", "select 2" })
    local _, err = runner.pending_dependencies(s, cells.parse(s.buf)[1])
    H.matches(err, "cycle")
  end)

  H.it("explain analyze reports findings in the plan view", function()
    set_cells(s, { "-- %% [ea1] filtered", "select * from users where balance > 7000" })
    runner.explain_cell(s, cells.parse(s.buf)[1], true)
    H.truthy(H.wait(15000, function()
      return s.runtime.ea1 and s.runtime.ea1.plan_text ~= nil
    end))
    local rt = s.runtime.ea1
    H.eq(rt.plan_kind, "EXPLAIN ANALYZE")
    H.truthy(rt.plan_info and rt.plan_info.plan)
    H.matches(table.concat(rt.plan_text, "\n"), "actual time=")
    H.matches(table.concat(rt.plan_text, "\n"), "Execution Time:")
    local findings = rt.plan_info.findings
    H.truthy(#findings >= 1, "expected a filter finding")
    H.matches(findings[1].message, "Seq Scan on users reads 5,000 rows to keep 334")
    H.eq(findings[1].suggestion, "CREATE INDEX ON users (balance);")
    local text = table.concat(results_lines(s), "\n")
    H.matches(text, "EXPLAIN ANALYZE")
    H.matches(text, "reads 5,000 rows")
    H.matches(text, "→ CREATE INDEX ON users %(balance%);")
    H.eq(s.view.mode, "plan")
  end)

  H.it("restores the plan view when the cursor leaves and returns to the cell", function()
    set_cells(s, {
      "-- %% [pa1] filtered",
      "select * from users where balance > 7000",
      "",
      "-- %% [pa2] other",
      "select 1",
    })
    runner.explain_cell(s, cells.parse(s.buf)[1], true)
    H.truthy(H.wait(15000, function()
      return s.runtime.pa1 and s.runtime.pa1.plan_text ~= nil
    end))
    H.eq(s.view.mode, "plan")
    -- moving to another cell shows its grid
    vim.api.nvim_win_set_cursor(s.query_win, { 5, 0 })
    query.on_cursor(s)
    H.eq(s.active_cell, "pa2")
    H.eq(s.view.mode, "grid")
    -- coming back restores the plan instead of the grid
    vim.api.nvim_win_set_cursor(s.query_win, { 2, 0 })
    query.on_cursor(s)
    H.eq(s.active_cell, "pa1")
    H.eq(s.view.mode, "plan")
    H.matches(table.concat(results_lines(s), "\n"), "EXPLAIN ANALYZE")
  end)

  H.it("shows the schema as a foldable document with indexes", function()
    set_cells(s, { "-- %% [sv1]", "select * from users u" })
    query.on_cursor(s, true)
    local results = require("dbgrid.ui.results")
    results.toggle_schema(s)
    H.eq(s.view.mode, "schema")
    local rl = results_lines(s)
    local text = table.concat(rl, "\n")
    H.matches(text, "▤ users  ~5,000 rows · 6 cols · 3 indexes")
    H.matches(text, "⌗ users_created_at_idx  %(created_at%)")
    H.matches(text, "⌗ users_pkey  %(id%)  PRIMARY KEY")
    H.matches(text, "plan_id%s+integer  → plans%(id%)")
    H.matches(text, "▤ invoices")
    H.matches(text, "People with an account")
    H.eq(vim.wo[s.results_win].foldmethod, "expr")
    local users_lnum, plans_lnum
    for i, l in ipairs(rl) do
      if l:match("^▤ users ") then
        users_lnum = i
      elseif l:match("^▤ plans ") then
        plans_lnum = i
      end
    end
    H.truthy(users_lnum and plans_lnum)
    vim.api.nvim_win_call(s.results_win, function()
      H.eq(vim.fn.foldclosed(users_lnum), -1, "the table used by the cell starts unfolded")
      H.eq(vim.fn.foldclosed(plans_lnum), plans_lnum, "other tables start folded")
    end)
    H.eq(vim.api.nvim_win_get_cursor(s.results_win)[1], users_lnum)
    -- moving to another cell keeps the document
    vim.api.nvim_win_set_cursor(s.query_win, { 1, 0 })
    query.on_cursor(s, true)
    H.eq(s.view.mode, "schema")
    -- <CR> toggles a fold, K describes, Tab jumps between tables
    vim.api.nvim_win_set_cursor(s.results_win, { plans_lnum, 0 })
    results.inspect(s, "<CR>")
    vim.api.nvim_win_call(s.results_win, function()
      H.eq(vim.fn.foldclosed(plans_lnum), -1)
    end)
    results.move_column(s, 1)
    H.truthy(vim.api.nvim_win_get_cursor(s.results_win)[1] > plans_lnum)
    results.yank_cell(s)
    H.matches(vim.fn.getreg('"'), "^%a+$")
    H.matches(layout.winbar_results(s.buf), "schema")
    results.toggle_schema(s)
    H.eq(s.view.mode, "grid")
    H.eq(vim.wo[s.results_win].foldmethod, "manual")
    -- running a cell replaces the document with its result
    results.toggle_schema(s)
    H.eq(s.view.mode, "schema")
    vim.api.nvim_win_set_cursor(s.query_win, { 2, 0 })
    query.on_cursor(s, true)
    H.eq(s.view.mode, "schema")
    run_and_wait(s, 1)
    H.eq(s.view.mode, "grid")
    H.eq(vim.wo[s.results_win].foldmethod, "manual")
    H.matches(table.concat(results_lines(s), "\n"), "@example%.com.*\n.* 5 rows")
  end)

  H.it("cancels a running query, client side and server side", function()
    set_cells(s, { "-- %% [cx1] slow", "select pg_sleep(20)" })
    local done
    runner.run_cell(s, cells.parse(s.buf)[1], {
      cb = function(r)
        done = r
      end,
    })
    H.truthy(H.wait(5000, function()
      return s.running.cx1 and s.running.cx1.kind == "run" and s.running.cx1.job ~= nil
    end))
    H.truthy(s.running.cx1.job.appname:match("^dbgrid%.nvim:%w+$"))
    local started = require("dbgrid.util").now()
    runner.cancel(s, cells.parse(s.buf)[1])
    H.truthy(
      H.wait(10000, function()
        return done ~= nil
      end),
      "cancel timed out"
    )
    H.eq(done.ok, false)
    H.matches(done.error.message, "cancel")
    H.truthy(require("dbgrid.util").now() - started < 8)
    -- the server-side path on its own
    local pg = require("dbgrid.adapters.postgres")
    local conn = require("dbgrid.connections").get("test")
    local result
    local job = pg.run(
      conn,
      { { sql = "select pg_sleep(20)", kind = "select", class = "read", line = 1 } },
      {},
      function(r)
        result = r
      end
    )
    vim.wait(500)
    local ok, msg
    pg.server_cancel(conn, job.appname, function(o, m)
      ok, msg = o, m
    end)
    H.truthy(
      H.wait(10000, function()
        return result ~= nil
      end),
      "server cancel timed out"
    )
    H.eq(ok, true)
    H.matches(msg, "^1 backend")
    H.matches(result.error.message, "canceling statement")
  end)

  H.it("switches the coding agent per notebook and per cell", function()
    local ai = require("dbgrid.ai")
    H.eq(ai.agent_name(s), "claude")
    H.eq(ai.set_agent(s, "nope"), false)
    H.eq(ai.set_agent(s, "kimi"), true)
    H.eq(ai.agent_name(s), "kimi")
    H.eq(notebook.load(nb.name).meta.agent, "kimi")
    H.matches(layout.winbar_query(s.buf), "kimi")
    set_cells(s, { "-- %% [ag1]", "-- @agent codex", "-- ? things" })
    H.eq(ai.agent_name(s, cells.parse(s.buf)[1]), "codex")
    ai.set_agent(s, nil)
    H.eq(ai.agent_name(s), "claude")
    local names = vim.tbl_map(function(a)
      return a.name
    end, ai.agents())
    H.eq(names, { "claude", "codex", "kimi" })
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

  H.it("hides the results pane while another file is shown and restores it", function()
    vim.api.nvim_set_current_win(s.query_win)
    local other = vim.fn.tempname() .. ".txt"
    vim.cmd("edit " .. vim.fn.fnameescape(other))
    H.truthy(
      H.wait(1000, function()
        return s.results_win == nil
      end),
      "results pane still open"
    )
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
    vim.cmd("buffer " .. s.buf)
    H.truthy(s.results_win and vim.api.nvim_win_is_valid(s.results_win))
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    H.eq(vim.api.nvim_get_current_win(), s.query_win)
  end)

  H.it("keeps the results pane while the notebook is still visible in a split", function()
    vim.api.nvim_set_current_win(s.query_win)
    vim.cmd("split")
    vim.cmd("enew")
    vim.wait(50)
    H.truthy(s.results_win and vim.api.nvim_win_is_valid(s.results_win))
    vim.cmd("close")
    vim.api.nvim_set_current_win(s.query_win)
  end)

  H.it("opens the results pane for a notebook opened by hand", function()
    -- `nvim -l` skips plugin/, which holds the BufReadPost hook under test
    vim.cmd("runtime plugin/dbgrid.lua")
    local nb2 = notebook.create("ui adopt", { connection = "test" })
    vim.cmd("tabnew")
    vim.cmd("edit " .. vim.fn.fnameescape(nb2.path))
    local s2
    H.truthy(
      H.wait(1000, function()
        s2 = require("dbgrid.state").get(vim.api.nvim_get_current_buf())
        return s2 ~= nil and s2.results_win ~= nil
      end),
      "notebook not attached"
    )
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    H.eq(vim.api.nvim_get_current_win(), s2.query_win)
    layout.close(s2)
    vim.api.nvim_set_current_win(s.query_win)
  end)

  H.it("closes the layout", function()
    local tabs = #vim.api.nvim_list_tabpages()
    layout.close(s)
    H.eq(#vim.api.nvim_list_tabpages(), tabs - 1)
  end)
end)
