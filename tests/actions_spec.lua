-- Tests for the actions on a result: following foreign keys, loading the
-- next page, editing a value into an UPDATE, backend signals, hidden
-- columns, the bar chart and CSV import. The pure parts run against a
-- hand-made schema; the rest against a SQLite database when sqlite3 is on
-- PATH.
local H = _G.H
local util = require("dbgrid.util")
local sqlmod = require("dbgrid.sql")
local follow = require("dbgrid.follow")
local chart = require("dbgrid.ui.chart")
local import = require("dbgrid.import")

local function fake_schema()
  local tables = {
    {
      schema = "public",
      name = "users",
      kind = "r",
      rows = 10,
      columns = {
        { name = "id", type = "integer" },
        { name = "email", type = "text" },
        { name = "plan_id", type = "integer" },
      },
      indexes = {},
      constraints = {
        { name = "users_pkey", type = "p", columns = { "id" } },
        {
          name = "users_plan_fk",
          type = "f",
          columns = { "plan_id" },
          ref_table = "public.plans",
          ref_columns = { "id" },
        },
      },
    },
    {
      schema = "public",
      name = "plans",
      kind = "r",
      rows = 3,
      columns = { { name = "id", type = "integer" }, { name = "name", type = "text" } },
      indexes = {},
      constraints = { { name = "plans_pkey", type = "p", columns = { "id" } } },
    },
    {
      schema = "public",
      name = "invoices",
      kind = "r",
      rows = 5,
      columns = {
        { name = "id", type = "integer" },
        { name = "user_id", type = "integer" },
        { name = "amount", type = "numeric" },
      },
      indexes = {},
      constraints = {
        { name = "invoices_pkey", type = "p", columns = { "id" } },
        {
          name = "invoices_user_fk",
          type = "f",
          columns = { "user_id" },
          ref_table = "public.users",
          ref_columns = { "id" },
        },
      },
    },
    -- no constraints at all: naming conventions only
    {
      schema = "public",
      name = "comments",
      kind = "r",
      rows = 5,
      columns = {
        { name = "id", type = "integer" },
        { name = "user_id", type = "integer" },
        { name = "body", type = "text" },
      },
      indexes = {},
      constraints = {},
    },
    {
      schema = "public",
      name = "active_users",
      kind = "v",
      rows = 0,
      columns = { { name = "id", type = "integer" }, { name = "email", type = "text" } },
      indexes = {},
      constraints = {},
    },
  }
  local by_name = {}
  for _, t in ipairs(tables) do
    by_name[(t.schema .. "." .. t.name):lower()] = t
    by_name[t.name:lower()] = t
  end
  return { version = "x", schemas = { "public" }, tables = tables, enums = {}, functions = {}, by_name = by_name }
end

H.describe("sql helpers", function()
  H.it("quotes identifiers only when needed", function()
    H.eq(util.sql_ident("users"), "users")
    H.eq(util.sql_ident("Users"), '"Users"')
    H.eq(util.sql_ident("user"), '"user"')
    H.eq(util.sql_ident("order"), '"order"')
    H.eq(util.sql_ident('we"ird'), '"we""ird"')
  end)
  H.it("pages a limited statement and strips the added limit", function()
    local st = sqlmod.split("select * from users order by id")[1]
    local sql, applied = sqlmod.ensure_limit(st, 5, 10)
    H.truthy(applied)
    H.eq(sql, "select * from users order by id\nLIMIT 5 OFFSET 10")
    local limited = sqlmod.ensure_limit(st, 5)
    H.eq(sqlmod.strip_limit(limited, 5), "select * from users order by id")
    local locking = sqlmod.split("select * from users for update")[1]
    local lsql = sqlmod.ensure_limit(locking, 5)
    H.eq(sqlmod.strip_limit(lsql, 5), "select * from users for update")
    H.eq(sqlmod.strip_limit("select 1", 5), nil)
  end)
end)

H.describe("follow", function()
  local sch = fake_schema()
  H.it("follows an outgoing foreign key", function()
    local targets = follow.targets(
      sch,
      "select id, user_id, amount from invoices",
      { "id", "user_id", "amount" },
      { "7", "42", "9.5" },
      2
    )
    H.eq(#targets, 1)
    H.eq(targets[1].direction, "→")
    H.eq(targets[1].table.name, "users")
    H.eq(targets[1].sql, "SELECT *\nFROM users\nWHERE id = '42'")
    H.matches(targets[1].label, "→ users where id = 42")
  end)
  H.it("follows incoming foreign keys from a primary key", function()
    local targets = follow.targets(sch, "select * from users u", { "id", "email", "plan_id" }, { "1", "a@x", "2" }, 1)
    H.eq(#targets, 1)
    H.eq(targets[1].direction, "←")
    H.eq(targets[1].table.name, "invoices")
    H.eq(targets[1].sql, "SELECT *\nFROM invoices\nWHERE user_id = '1'")
    -- plan_id on users is an outgoing key
    local out = follow.targets(sch, "select * from users", { "id", "email", "plan_id" }, { "1", "a@x", "2" }, 3)
    H.eq(out[1].table.name, "plans")
    H.eq(out[1].where, { { column = "id", value = "2" } })
  end)
  H.it("falls back to naming conventions and refuses NULL", function()
    local targets = follow.targets(sch, "select * from comments", { "id", "user_id", "body" }, { "1", "3", "hi" }, 2)
    H.eq(#targets, 1)
    H.eq(targets[1].table.name, "users")
    H.eq(targets[1].via, "name")
    -- users.id ← comments.user_id is only known by name (invoices by constraint)
    local back = follow.targets(sch, "select * from users", { "id" }, { "3" }, 1)
    H.eq(#back, 1)
    H.eq(back[1].table.name, "invoices")
    local none, reason = follow.targets(sch, "select * from comments", { "id", "user_id" }, { "1", vim.NIL }, 2)
    H.eq(none, {})
    H.matches(reason, "NULL")
    local nothing, why = follow.targets(
      sch,
      "select * from comments",
      { "id", "user_id", "body" },
      { "1", "3", "hi" },
      3
    )
    H.eq(nothing, {})
    H.matches(why, "no foreign key")
  end)
  H.it("builds an UPDATE keyed by the primary key", function()
    local sql = follow.update_sql(
      sch,
      "select u.id, u.email from users u",
      { "id", "email" },
      { "4", "old" },
      2,
      "'new'"
    )
    H.eq(sql, "UPDATE users\nSET email = 'new'\nWHERE id = '4';")
    local _, err = follow.update_sql(sch, "select email from users", { "email" }, { "old" }, 1, "'x'")
    H.matches(err, "primary key")
    local _, verr = follow.update_sql(sch, "select * from active_users", { "id", "email" }, { "1", "x" }, 2, "'x'")
    H.matches(verr, "not a plain table")
    H.eq(follow.literal_default("12"), "12")
    H.eq(follow.literal_default("t"), "true")
    H.eq(follow.literal_default(vim.NIL), "NULL")
    H.eq(follow.literal_default("it's"), "'it''s'")
  end)
end)

H.describe("chart", function()
  H.it("picks the columns and draws bars", function()
    local columns = { "plan", "users", "note" }
    local rows = { { "free", "40", "x" }, { "pro", "20", vim.NIL }, { "team", vim.NIL, "y" }, { "neg", "-10", "z" } }
    local value, label = chart.pick_columns(columns, rows)
    H.eq({ value, label }, { 2, 1 })
    local lines, hl, row_at = chart.lines({ columns = columns, rows = rows, value = value, label = label, width = 60 })
    H.matches(lines[1], "users by plan · 4 rows · max 40 · sum 50")
    local function bar_len(line)
      return util.width(line:match("│ (%S*)") or "")
    end
    H.truthy(lines[3]:find(" free │ █", 1, true))
    H.matches(lines[3], " 40$")
    H.truthy(lines[4]:find(" pro  │ █", 1, true))
    H.matches(lines[4], " 20$")
    H.matches(lines[5], "^ team │ +NULL$")
    H.truthy(lines[6]:find(" neg  │ █", 1, true))
    H.matches(lines[6], " %-10$")
    H.eq(row_at[3], 1)
    H.eq(row_at[6], 4)
    H.truthy(bar_len(lines[3]) > bar_len(lines[4]), "the larger value gets the longer bar")
    H.truthy(bar_len(lines[4]) > bar_len(lines[6]), "20 beats 10")
    H.eq(hl[6][3][3], "DbgridChartBarNeg")
    H.eq(chart.from_directive("users by plan", columns, rows), 2)
    local v2, l2 = chart.from_directive("users", columns, rows)
    H.eq({ v2, l2 }, { 2, 1 })
    H.eq(chart.from_directive("nope", columns, rows), 2)
  end)
end)

H.describe("import file inspection", function()
  H.it("splits quoted header lines and detects the delimiter", function()
    H.eq(import.split_line('a,"b,c","d ""q"""', ","), { "a", "b,c", 'd "q"' })
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local csv = dir .. "/people.csv"
    util.write_file(csv, "\239\187\191id;Name;note\n1;ann;x\n2;bob;y\n")
    local info = import.inspect(csv)
    H.eq(info.columns, { "id", "Name", "note" })
    H.eq(info.delimiter, ";")
    H.eq(info.lines, 3)
    H.eq(info.sample, "1;ann;x")
    local tsv = dir .. "/t.tsv"
    util.write_file(tsv, "a\tb\n1\t2")
    H.eq(import.inspect(tsv).delimiter, "\t")
    H.eq(import.inspect(tsv).lines, 2)
    local tbl = { columns = { { name = "id" }, { name = "name" } } }
    local matched, missing = import.match_columns({ "ID", "Name", "note" }, tbl)
    H.eq(matched, { "id", "name" })
    H.eq(missing, { "note" })
    H.eq(import.create_sql("people", { "id", "Name" }), 'CREATE TABLE people (\n  id text,\n  "Name" text\n);')
  end)
end)

-- Results pane behaviour that needs no database: injected results.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("dbgrid").setup({ storage = { data_dir = tmp .. "/data", mode = "data", cache_rows = 3 } })
local notebook = require("dbgrid.notebook")
local layout = require("dbgrid.ui.layout")
local results = require("dbgrid.ui.results")
local cells = require("dbgrid.cells")

local function set_cells(s, lines)
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.b[s.buf].dbgrid_cells_cache = nil
end

local function results_text(s)
  return table.concat(vim.api.nvim_buf_get_lines(s.results_buf, 0, -1, false), "\n")
end

local function fake_result(columns, rows, extra)
  return vim.tbl_extend("force", {
    ok = true,
    ran_at = os.time(),
    elapsed_ms = 3,
    sql_hash = "x",
    statements = {
      {
        sql = "select plan, users, note from stats",
        kind = "select",
        class = "read",
        sets = { { columns = columns, rows = rows, row_count = #rows } },
        tags = {},
      },
    },
    notices = {},
    warnings = {},
  }, extra or {})
end

H.describe("results pane actions", function()
  local nb = notebook.create("actions test")
  local s = layout.open(nb)
  set_cells(s, { "-- %% [c1] stats", "select plan, users, note from stats", "", "-- %% [c2] other", "select 2" })
  local c1 = cells.by_id(s.buf, "c1")
  local rows = { { "free", "40", "x" }, { "pro", "20", vim.NIL }, { "team", "5", "y" } }
  notebook.set_result(nb, c1, fake_result({ "plan", "users", "note" }, rows))

  H.it("hides and shows columns, remembered per cell", function()
    results.show(s, "c1")
    local header = vim.api.nvim_buf_get_lines(s.results_buf, 0, 1, false)[1]
    H.matches(header, "users")
    -- cursor on the "users" column of the first row
    local lnum
    for l in pairs(s.view.rows_layout) do
      lnum = lnum and math.min(lnum, l) or l
    end
    local start = s.view.rows_layout[lnum].starts[2]
    vim.api.nvim_win_set_cursor(s.results_win, { lnum, start })
    local c = results.cell_at_cursor(s)
    H.eq({ c.col, c.vcol, c.column }, { 2, 2, "users" })
    results.hide_column(s)
    header = vim.api.nvim_buf_get_lines(s.results_buf, 0, 1, false)[1]
    H.falsy(header:find("users", 1, true), "hidden column is gone from the header")
    H.matches(header, "note")
    H.matches(results.winbar(s), "1 column hidden")
    -- the slot now holds "note", which maps back to set column 3
    c = results.cell_at_cursor(s)
    H.eq({ c.col, c.vcol, c.column }, { 3, 2, "note" })
    results.yank_csv(s)
    H.eq(vim.fn.getreg('"'), "plan,note\nfree,x\npro,\nteam,y\n")
    -- switching cells and back keeps the hidden set
    results.show(s, "c2")
    results.show(s, "c1")
    H.truthy(s.view.hidden and s.view.hidden[1] and s.view.hidden[1].users)
    results.show_columns(s, "all")
    H.matches(vim.api.nvim_buf_get_lines(s.results_buf, 0, 1, false)[1], "users")
    H.eq(s.view.hidden, nil)
  end)

  H.it("draws the chart of the shown result and toggles back", function()
    results.show(s, "c1")
    results.toggle_chart(s)
    H.eq(s.view.mode, "chart")
    local text = results_text(s)
    H.matches(text, "users by plan · 3 rows · max 40")
    H.truthy(text:find(" free │ █", 1, true))
    H.matches(text, "3 rows · ")
    -- the chart rows are inspectable
    local lnum
    for l in pairs(s.view.rows_layout) do
      lnum = lnum and math.min(lnum, l) or l
    end
    vim.api.nvim_win_set_cursor(s.results_win, { lnum, 0 })
    local c = results.cell_at_cursor(s)
    H.eq({ c.column, c.value }, { "users", "40" })
    results.toggle_chart(s)
    H.eq(s.view.mode, "grid")
    results.toggle_chart(s, "users by note")
    H.matches(results_text(s), "users by note")
    H.eq(s.view.chart.label, 3)
    results.toggle_chart(s)
  end)

  H.it("charts a cell with an @chart directive when it runs", function()
    set_cells(s, { "-- %% [c1] stats", "-- @chart users by plan", "select plan, users, note from stats" })
    results.show(s, "c1", { ran = true })
    H.eq(s.view.mode, "chart")
    H.eq({ s.view.chart.value, s.view.chart.label }, { 2, 1 })
    set_cells(s, { "-- %% [c1] stats", "select plan, users, note from stats", "", "-- %% [c2] other", "select 2" })
    results.show(s, "c1", { view = "grid" })
  end)

  H.it("tells how to load more rows and keeps every row in memory", function()
    local many = {}
    for i = 1, 5 do
      many[i] = { "p" .. i, tostring(i), "n" }
    end
    local r = fake_result({ "plan", "users", "note" }, many, { truncated = true })
    r.statements[1].limit_applied = 5
    r.statements[1].more = true
    r.statements[1].unlimited = "select plan, users, note from stats"
    notebook.set_result(nb, c1, r)
    results.show(s, "c1")
    local text = results_text(s)
    H.matches(text, "only the first 5 rows were fetched %(LIMIT 5 was added%); \\m loads 5 more")
    H.matches(text, "p5")
    -- cache_rows = 3: the pane keeps all five, the disk copy three
    H.eq(#notebook.result_of(nb, "c1").statements[1].sets[1].rows, 5)
    vim.wait(1500, function()
      return util.exists(nb.cache_path)
    end)
    local disk = util.read_json(nb.cache_path)
    H.eq(#disk.c1.statements[1].sets[1].rows, 3)
    H.eq(disk.c1.statements[1].sets[1].evicted, true)
    H.eq(disk.c1.statements[1].unlimited, "select plan, users, note from stats")
  end)

  H.it("shows a result that belongs to no cell under its title", function()
    local r = fake_result({ "id", "email" }, { { "1", "a@x" } }, { title = "→ users where id = 1" })
    results.show_result(s, "__follow", r)
    H.eq(s.view.cell_id, "__follow")
    H.matches(results_text(s), "a@x")
    H.matches(results.winbar(s), "→ users where id = 1")
    H.matches(results.winbar(s), "gF keeps it")
    H.matches(results.winbar(s), "1 rows")
    -- keeping it makes a cell with the SQL and the result
    H.truthy(results.keep_result(s))
    local kept = cells.by_id(s.buf, s.view.cell_id)
    H.truthy(kept, "a cell was inserted")
    H.eq(kept.lines[1], "select plan, users, note from stats")
    H.eq(notebook.result_of(nb, kept.id).statements[1].sets[1].rows[1][2], "a@x")
  end)

  H.it("finds the pid column for a backend signal", function()
    local r = fake_result({ "pid", "usename", "query" }, { { "4242", "app", "select 1" } }, { title = "activity" })
    results.show_result(s, "__rows", r)
    local signalled
    package.loaded["dbgrid.runner"].signal_backend = function(_, pid, action, _, cb)
      signalled = { pid = pid, action = action }
      cb(true, "done")
    end
    results.signal_backend(s, { action = "cancel" })
    H.truthy(H.wait(2000, function()
      return signalled ~= nil
    end))
    H.eq(signalled, { pid = 4242, action = "cancel" })
    package.loaded["dbgrid.runner"] = nil
    layout.close(s)
  end)
end)

if vim.fn.executable("sqlite3") ~= 1 then
  io.write("  skip actions integration (sqlite3 not on PATH)\n")
  return
end

local db = tmp .. "/actions.db"
vim
  .system({
    "sqlite3",
    db,
    table.concat({
      "create table plans(id integer primary key, name text not null);",
      "insert into plans(name) values ('free'),('pro'),('team');",
      "create table users(id integer primary key, email text not null, plan_id int references plans(id));",
      "insert into users(email, plan_id) select 'user'||value||'@example.com', (value % 3)+1 from generate_series(1,12);",
      "create table invoices(id integer primary key, user_id int not null references users(id), amount real);",
      "insert into invoices(user_id, amount) values (1, 10), (1, 20), (2, 5);",
    }, " "),
  })
  :wait()
local conn = { name = "sqlite-actions", url = "sqlite:" .. db }

H.describe("actions against sqlite", function()
  require("dbgrid").setup({
    storage = { data_dir = tmp .. "/data2", mode = "data" },
    connections = { conn },
    default_connection = "sqlite-actions",
    query = { confirm_writes = false, limit = 5 },
    index_check = { mode = "off" },
  })
  local runner = require("dbgrid.runner")
  local nb = notebook.create("sqlite actions", { connection = "sqlite-actions" })
  local s = layout.open(nb)
  local function run_and_wait(idx)
    local done
    runner.run_cell(s, cells.parse(s.buf)[idx], {
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
  local function first_row_lnum()
    local lnum
    for l in pairs(s.view.rows_layout) do
      lnum = lnum and math.min(lnum, l) or l
    end
    return lnum
  end

  H.it("loads the next page of a limited result", function()
    set_cells(s, {
      "-- %% [p1] users",
      "select id, email, plan_id from users order by id",
      "",
      "-- %% [p2] invoices",
      "select id, user_id, amount from invoices order by id",
    })
    local r = run_and_wait(1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(#r.statements[1].sets[1].rows, 5)
    H.eq(r.statements[1].more, true)
    H.eq(r.statements[1].unlimited, "select id, email, plan_id from users order by id")
    local done
    runner.load_more(s, "p1", nil, function(res, err)
      done = { res = res, err = err }
    end)
    H.truthy(H.wait(15000, function()
      return done ~= nil
    end))
    H.eq(done.err, nil)
    local set = notebook.result_of(nb, "p1").statements[1].sets[1]
    H.eq(#set.rows, 10)
    H.eq(set.rows[6][1], "6")
    H.eq(set.rows[10][2], "user10@example.com")
    H.eq(notebook.result_of(nb, "p1").statements[1].pages, 2)
    H.eq(nb.meta.cells.p1.row_count, 10)
    local text = results_text(s)
    H.matches(text, "10 rows")
    H.matches(text, "LIMIT 5 · 2 pages")
    H.matches(text, "user10@example%.com")
    -- the third page is the last one (12 users): two rows, then nothing more
    done = nil
    runner.load_more(s, "p1", nil, function(res, err)
      done = { res = res, err = err }
    end)
    H.truthy(H.wait(15000, function()
      return done ~= nil
    end))
    H.eq(#notebook.result_of(nb, "p1").statements[1].sets[1].rows, 12)
    H.eq(notebook.result_of(nb, "p1").truncated, false)
    H.falsy(results_text(s):find("only the first", 1, true))
  end)

  H.it("follows a foreign key from a result and keeps it as a cell", function()
    local r = run_and_wait(2)
    H.eq(r.ok, true, vim.inspect(r.error))
    local lnum = first_row_lnum()
    vim.api.nvim_win_set_cursor(s.results_win, { lnum, s.view.rows_layout[lnum].starts[2] })
    H.eq(results.cell_at_cursor(s).column, "user_id")
    results.follow(s)
    H.truthy(
      H.wait(15000, function()
        return s.view.cell_id == "__follow" and notebook.result_of(nb, "__follow") ~= nil
      end),
      "the followed result did not show"
    )
    local shown = notebook.result_of(nb, "__follow")
    H.eq(shown.ok, true, vim.inspect(shown.error))
    H.eq(shown.statements[1].sets[1].rows, { { "1", "user1@example.com", "2" } })
    H.matches(results.winbar(s), "→ users where id = 1")
    -- from the user row, the primary key leads back to the invoices
    lnum = first_row_lnum()
    vim.api.nvim_win_set_cursor(s.results_win, { lnum, 0 })
    H.eq(results.cell_at_cursor(s).column, "id")
    local targets = follow.targets(
      require("dbgrid.schema").loaded(conn),
      shown.statements[1].sql,
      shown.statements[1].sets[1].columns,
      shown.statements[1].sets[1].rows[1],
      1
    )
    H.eq(#targets, 1)
    H.eq(targets[1].direction, "←")
    H.eq(targets[1].table.name, "invoices")
    results.follow(s)
    H.truthy(
      H.wait(15000, function()
        local cur = notebook.result_of(nb, "__follow")
        return cur and cur.title and cur.title:find("invoices", 1, true) ~= nil
      end),
      "the second hop did not show"
    )
    H.eq(#notebook.result_of(nb, "__follow").statements[1].sets[1].rows, 2)
    H.truthy(results.keep_result(s))
    local kept = cells.by_id(s.buf, s.view.cell_id)
    H.eq(kept.lines[1], "SELECT *")
    H.eq(kept.lines[3], "WHERE user_id = '1'")
  end)

  H.it("writes an UPDATE cell for the value under the cursor", function()
    results.show(s, "p1")
    local lnum = first_row_lnum()
    vim.api.nvim_win_set_cursor(s.results_win, { lnum, s.view.rows_layout[lnum].starts[2] })
    local prompt
    local saved = vim.ui.input
    vim.ui.input = function(opts, cb)
      prompt = opts
      cb("'changed@example.com'")
    end
    results.edit_value(s)
    H.truthy(H.wait(15000, function()
      return prompt ~= nil
    end))
    vim.ui.input = saved
    H.eq(prompt.prompt, "SET email = ")
    H.eq(prompt.default, "'user1@example.com'")
    local found
    for _, c in ipairs(cells.parse(s.buf)) do
      if c.title == "update users" then
        found = c
      end
    end
    H.truthy(found, "an update cell was inserted")
    H.eq(found.lines, { "UPDATE users", "SET email = 'changed@example.com'", "WHERE id = '1';" })
    local r = run_and_wait(found.index)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(r.statements[1].tags, { "UPDATE 1" })
  end)

  H.it("refuses backend signals outside PostgreSQL", function()
    local got
    runner.signal_backend(s, 1, "cancel", {}, function(ok, msg)
      got = { ok = ok, msg = msg }
    end)
    H.truthy(H.wait(5000, function()
      return got ~= nil
    end))
    H.eq(got.ok, false)
    H.matches(got.msg, "PostgreSQL")
  end)

  H.it("imports a CSV into an existing table and into a new one", function()
    local csv = tmp .. "/plans.csv"
    util.write_file(csv, 'name,id\n"enterprise",9\n"starter",10\n')
    local done
    import.run({ path = csv, table = "plans", state = s, confirm = false }, function(ok, msg, rows)
      done = { ok = ok, msg = msg, rows = rows }
    end)
    H.truthy(H.wait(20000, function()
      return done ~= nil
    end))
    H.eq(done.ok, true, tostring(done.msg))
    H.eq(done.rows, 2)
    local out = vim
      .system({ "sqlite3", db, "select name from plans where id in (9,10) order by id" }, { text = true })
      :wait()
    H.eq(vim.trim(out.stdout), "enterprise\nstarter")
    H.truthy(
      H.wait(15000, function()
        return s.view.cell_id == "__import" and notebook.result_of(nb, "__import") ~= nil
      end),
      "the import peek did not show"
    )
    H.matches(results.winbar(s), "imported into plans")
    -- a header column the table lacks is an error, not a silent skip
    util.write_file(csv, "name,colour\nx,red\n")
    done = nil
    import.run({ path = csv, table = "plans", state = s, confirm = false }, function(ok, msg)
      done = { ok = ok, msg = msg }
    end)
    H.truthy(H.wait(5000, function()
      return done ~= nil
    end))
    H.eq(done.ok, false)
    H.matches(done.msg, "colour")
    -- a new table from the header
    local cities = tmp .. "/cities.csv"
    util.write_file(cities, "city;country\nLisbon;PT\nOslo;NO\nBern;CH\n")
    done = nil
    import.run({ path = cities, table = "cities", state = s, confirm = false }, function(ok, msg, rows)
      done = { ok = ok, msg = msg, rows = rows }
    end)
    H.truthy(H.wait(20000, function()
      return done ~= nil
    end))
    H.eq(done.ok, true, tostring(done.msg))
    H.eq(done.rows, 3)
    out = vim.system({ "sqlite3", db, "select country from cities order by city" }, { text = true }):wait()
    H.eq(vim.trim(out.stdout), "CH\nPT\nNO")
    layout.close(s)
  end)
end)
