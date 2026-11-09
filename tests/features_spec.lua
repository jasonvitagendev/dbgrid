-- Integration tests for the debugging features: templates, parameters, dry
-- runs, write previews, DDL warnings, live cells, history, export, analyze,
-- diffs and tunnelled connections. Needs DBGRID_TEST_URL.
local H = _G.H
local url = os.getenv("DBGRID_TEST_URL")
if not url then
  io.write("  skip features integration (DBGRID_TEST_URL not set)\n")
  return
end

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("dbgrid").setup({
  storage = { data_dir = tmp .. "/data", mode = "data" },
  connections = {
    { name = "test", url = url },
    { name = "test-ro", url = url, readonly = true },
    { name = "with-pass", url = url, password_cmd = "echo sekrit" },
  },
  default_connection = "test",
  query = { confirm_writes = false, limit = 5 },
  index_check = { mode = "warn", min_rows = 1000 },
  live = { min_interval_ms = 300 },
  ai = {
    agent = "fake",
    agents = { fake = { cmd = { root .. "/tests/fixtures/fake-agent" }, stdin = true } },
    timeout_ms = 20000,
  },
})
local notebook = require("dbgrid.notebook")
local layout = require("dbgrid.ui.layout")
local runner = require("dbgrid.runner")
local cells = require("dbgrid.cells")
local connections = require("dbgrid.connections")
local results_ui = require("dbgrid.ui.results")

local function set_cells(s, lines)
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.b[s.buf].dbgrid_cells_cache = nil
end

local function results_text(s)
  return table.concat(vim.api.nvim_buf_get_lines(s.results_buf, 0, -1, false), "\n")
end

local function run_and_wait(s, idx, opts)
  local done
  local cell = cells.parse(s.buf)[idx]
  opts = opts or {}
  opts.cb = function(r)
    done = r
  end
  runner.run_cell(s, cell, opts)
  H.truthy(
    H.wait(20000, function()
      return done ~= nil
    end),
    "run timed out"
  )
  return done
end

local function psql(sql)
  local out = vim.system({ "psql", url, "-X", "-A", "-t", "-c", sql }, { text = true }):wait()
  return vim.trim(out.stdout or ""), out.code
end

H.describe("connections.resolve", function()
  H.it("parses and rewrites urls", function()
    local user, pass, host, port, db, query =
      connections.parse_url("postgres://u:p%40ss@db.internal:5439/app?sslmode=require")
    H.eq({ user, pass, host, port, db, query }, { "u", "p@ss", "db.internal", "5439", "app", "sslmode=require" })
    H.eq(
      connections.tunnelled_url(
        "postgres://u@db.internal:5432/app",
        15432,
        { ssl = "verify-full", sslrootcert = "/ca.pem" }
      ),
      "postgres://u@db.internal:5432/app?hostaddr=127.0.0.1&port=15432&sslmode=verify-full&sslrootcert=/ca.pem"
    )
    H.eq(
      connections.tunnelled_url("postgres://u@h/app?sslmode=disable&application_name=x", 1),
      "postgres://u@h/app?application_name=x&hostaddr=127.0.0.1&port=1&sslmode=disable"
    )
  end)
  H.it("resolves a plain connection and runs password_cmd asynchronously", function()
    local eff
    connections.resolve(connections.get("test"), function(c)
      eff = c
    end)
    H.truthy(H.wait(2000, function()
      return eff ~= nil
    end))
    H.eq(eff._resolved, true)
    H.eq(eff.url, url)
    local pw
    connections.resolve(connections.get("with-pass"), function(c)
      pw = c
    end)
    H.truthy(H.wait(5000, function()
      return pw ~= nil
    end))
    H.eq(pw.env.PGPASSWORD, "sekrit")
    -- cached: the second resolve answers synchronously with the same table
    local again
    connections.resolve(connections.get("with-pass"), function(c)
      again = c
    end)
    H.eq(again, pw)
    connections.forget("with-pass")
  end)
  H.it("runs a query through a cmd tunnel", function()
    local port = url:match(":(%d+)/") or "5432"
    local conn = {
      name = "tunnelled",
      url = url:gsub("127%.0%.0%.1", "localhost"),
      tunnel = { kind = "cmd", cmd = { "python3", root .. "/tests/fixtures/forwarder.py", "{port}", port } },
      ssl = "disable",
    }
    local ok, msg
    connections.test(conn, function(good, m)
      ok, msg = good, m
    end)
    H.truthy(H.wait(20000, function()
      return ok ~= nil
    end))
    H.eq(ok, true, tostring(msg))
    H.matches(msg, "PostgreSQL")
    require("dbgrid.tunnel").kill_all()
  end)
end)

H.describe("templates", function()
  local templates = require("dbgrid.templates")
  H.it("lists the bundled templates and strips the header", function()
    local names = vim.tbl_map(function(t)
      return t.name
    end, templates.list())
    H.truthy(vim.tbl_contains(names, "diagnostics"))
    H.truthy(vim.tbl_contains(names, "blue-green"))
    local bg = templates.get("blue-green")
    H.eq(bg.connections, { "blue", "green" })
    local meta, body = templates.parse("-- template-name: X\n-- template-tags: a, b\n\n-- %% first\nselect 1\n")
    H.eq(meta.name, "X")
    H.eq(meta.tags, { "a", "b" })
    H.matches(body, "^%-%- %%%% first")
  end)
  H.it("instantiates with bound connections", function()
    local bg = templates.get("blue-green")
    local nb = templates.instantiate(bg, { bindings = { blue = "test", green = "test-ro" } })
    local text = require("dbgrid.util").read_file(nb.path)
    H.falsy(text:find("-- @conn blue", 1, true))
    H.truthy(text:find("-- @conn test-ro", 1, true))
    H.truthy(text:find("-- @conn test\n", 1, true))
    H.falsy(text:find("template-name", 1, true))
    H.eq(nb.meta.template, "blue-green")
    H.truthy(vim.tbl_contains(nb.meta.tags, "blue-green") or #nb.meta.tags > 0)
    local lr = templates.get("logical-replication")
    H.eq(lr.connections, { "source", "target" })
    local lnb = templates.instantiate(lr, { bindings = { source = "test", target = "test-ro" } })
    local ltext = require("dbgrid.util").read_file(lnb.path)
    H.falsy(ltext:find("-- @conn source", 1, true))
    H.falsy(ltext:find("-- @conn target", 1, true))
    H.truthy(ltext:find("-- @conn test-ro\n-- @every 10s\n-- @record", 1, true))
    local diag = templates.instantiate(templates.get("diagnostics"), {})
    local b = vim.api.nvim_create_buf(false, true)
    local u = require("dbgrid.util")
    vim.api.nvim_buf_set_lines(b, 0, -1, false, u.lines(u.read_file(diag.path)))
    H.truthy(#cells.parse(b) >= 20)
  end)
end)

H.describe("running features", function()
  local nb = notebook.create("features", { connection = "test" })
  local s = layout.open(nb)

  H.it("substitutes declared and remembered parameters", function()
    set_cells(s, {
      "-- %% [p1] declared",
      "-- @param n = 3",
      "select id from users where id <= :n order by id",
      "",
      "-- %% [p2] prompted",
      "select id from users where id <= :top order by id",
    })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(#r.statements[1].sets[1].rows, 3)
    H.eq(r.params, { n = "3" })
    H.matches(results_text(s), ":n = 3")
    local asked = 0
    local orig = vim.ui.input
    vim.ui.input = function(opts, cb)
      asked = asked + 1
      H.matches(opts.prompt, ":top")
      cb("2")
    end
    local r2 = run_and_wait(s, 2)
    vim.ui.input = orig
    H.eq(r2.ok, true, vim.inspect(r2.error))
    H.eq(#r2.statements[1].sets[1].rows, 2)
    H.eq(asked, 1)
    H.eq(notebook.params(nb).top, "2")
    -- remembered: no prompt the second time
    vim.ui.input = function()
      error("should not prompt")
    end
    local r3 = run_and_wait(s, 2)
    vim.ui.input = orig
    H.eq(#r3.statements[1].sets[1].rows, 2)
  end)

  H.it("dry-runs writes with RETURNING and rolls back", function()
    psql("update users set note = null where id <= 2")
    set_cells(s, { "-- %% [d1] dry", "-- @dryrun", "update users set note = 'dry' where id = 1" })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(r.dry_run, true)
    H.eq(r.statements[1].sets[1].rows[1][6], "dry")
    H.matches(results_text(s), "dry run, rolled back")
    H.eq(psql("select coalesce(note, 'null') from users where id = 1"), "null")
    -- a dry run is allowed on a read-only connection
    set_cells(s, { "-- %% [d2] dry ro", "-- @dryrun", "-- @conn test-ro", "delete from invoices where id = 1" })
    local r2 = run_and_wait(s, 1)
    H.eq(r2.ok, true, vim.inspect(r2.error))
    H.eq(psql("select count(*) from invoices where id = 1"), "1")
  end)

  H.it("previews the rows a write touches and warns about DDL locks", function()
    require("dbgrid.config").get().query.confirm_writes = true
    local messages, answer = {}, 1
    local orig = vim.fn.confirm
    vim.fn.confirm = function(msg)
      messages[#messages + 1] = msg
      return answer
    end
    set_cells(s, { "-- %% [w1] write", "update users set note = 'seen' where id <= 2" })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.matches(messages[#messages], "UPDATE touches 2 rows")
    H.eq(psql("select count(*) from users where note = 'seen'"), "2")
    psql("update users set note = null where id <= 2")
    -- DDL: warned and cancelled (with warnings present, Cancel is the first button)
    psql("drop index if exists users_balance_tmp")
    answer = 1
    set_cells(s, { "-- %% [w2] ddl", "create index users_balance_tmp on users (balance)" })
    local cell = cells.parse(s.buf)[1]
    runner.run_cell(s, cell)
    vim.wait(500)
    H.matches(messages[#messages], "CONCURRENTLY")
    H.eq(psql("select count(*) from pg_indexes where indexname = 'users_balance_tmp'"), "0")
    vim.fn.confirm = orig
    require("dbgrid.config").get().query.confirm_writes = false
  end)

  H.it("keeps the rows a write touches and writes the undo as a cell", function()
    local undo = require("dbgrid.undo")
    psql("update users set note = null where id <= 2")
    set_cells(s, { "-- %% [un1] note", "update users set note = 'undone?' where id <= 2" })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(#r.undo, 1)
    H.eq(r.undo[1].columns, { "id", "note" })
    local rows = vim.deepcopy(r.undo[1].rows)
    table.sort(rows, function(a, b)
      return tonumber(a[1]) < tonumber(b[1])
    end)
    H.eq(rows, { { "1", vim.NIL }, { "2", vim.NIL } })
    H.matches(results_text(s), "2 rows of users kept before the UPDATE")
    undo.write_cell(s, cells.by_id(s.buf, "un1"))
    local body = table.concat(cells.parse(s.buf)[2].lines, "\n")
    H.matches(body, "UPDATE users SET note = NULL WHERE id = 1;")
    H.matches(body, "UPDATE users SET note = NULL WHERE id = 2;")
    local r2 = run_and_wait(s, 2)
    H.eq(r2.ok, true, vim.inspect(r2.error))
    H.eq(psql("select count(*) from users where note is not null and id <= 2"), "0")
    -- a deleted row comes back with its id and typed literals
    set_cells(s, { "-- %% [un2] drop session", "delete from sessions where id = 1" })
    local r3 = run_and_wait(s, 1)
    H.eq(r3.ok, true, vim.inspect(r3.error))
    H.eq(r3.undo[1].kind, "delete")
    H.eq(r3.undo[1].columns, { "id", "user_id", "token" })
    H.eq(psql("select count(*) from sessions where id = 1"), "0")
    undo.write_cell(s, cells.by_id(s.buf, "un2"))
    H.matches(table.concat(cells.parse(s.buf)[2].lines, "\n"), "INSERT INTO sessions %(id, user_id, token%)")
    local r4 = run_and_wait(s, 2)
    H.eq(r4.ok, true, vim.inspect(r4.error))
    H.eq(psql("select user_id || ':' || token from sessions where id = 1"), "1:" .. psql("select md5('1')"))
    -- the schema carries the identity / generated flags the undo relies on
    local sch = require("dbgrid.schema").loaded(connections.get("test"))
    local users = sch and require("dbgrid.schema").find_table(sch, "users")
    H.truthy(users, "schema cache should hold users")
    local id = require("dbgrid.schema").find_column(users, "id")
    H.falsy(id.identity == "a", "a serial column is not an identity column")
  end)

  H.it("keeps a live cell ticking and stops it on edit", function()
    set_cells(s, { "-- %% [l1] live", "-- @every 300ms", "select count(*) as n, now() as t from users" })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.truthy(s.live.l1, "live loop should start after the first run")
    H.truthy(
      H.wait(5000, function()
        return (s.live.l1 and s.live.l1.ticks or 0) >= 2
      end),
      "expected at least two ticks"
    )
    H.truthy(s.live.l1.changed_count and s.live.l1.changed_count >= 1, "now() should change every tick")
    H.truthy(#s.live.l1.history >= 2)
    H.matches(results_text(s), "live every")
    vim.api.nvim_win_set_cursor(s.results_win, { 3, 0 })
    -- sparkline over the numeric column
    local shown
    local orig_preview = vim.lsp.util.open_floating_preview
    vim.lsp.util.open_floating_preview = function(lines)
      shown = lines
      return 0, 0
    end
    results_ui.sparkline(s)
    vim.lsp.util.open_floating_preview = orig_preview
    H.truthy(shown and shown[2]:find("ticks", 1, true), vim.inspect(shown))
    -- editing the cell stops the loop
    vim.api.nvim_buf_set_lines(s.buf, 2, 3, false, { "select count(*) as n from users" })
    vim.b[s.buf].dbgrid_cells_cache = nil
    runner.on_cell_edited(s, cells.parse(s.buf)[1])
    H.eq(s.live.l1, nil)
    -- a write cell refuses @every
    set_cells(s, { "-- %% [l2] bad", "-- @every 1s", "update users set note = null where id = 1" })
    local cell = cells.parse(s.buf)[1]
    runner.run_cell(s, cell)
    vim.wait(300)
    H.eq(s.live.l2, nil)
  end)

  H.it("logs history and exports markdown", function()
    local entries = require("dbgrid.history").list()
    H.truthy(#entries >= 3)
    H.eq(entries[1].connection, "test")
    H.truthy(entries[1].sql:find("select", 1, true) or entries[1].sql:find("update", 1, true))
    set_cells(s, { "-- %% [e1] export me", "select id, email from users where id <= 2 order by id" })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, true)
    local md = require("dbgrid.export").markdown(s)
    H.matches(md, "^# features\n")
    H.matches(md, "## export me")
    H.matches(md, "```sql\nselect id, email")
    H.matches(md, "| id | email |")
    H.matches(md, "| 1 | user1@example.com |")
  end)

  H.it("analyzes a plan with the agent and inserts its SQL", function()
    set_cells(s, { "-- %% [a1] slow", "select * from users where balance > 5 order by email" })
    local text, err
    runner.analyze_cell(s, cells.parse(s.buf)[1], {
      silent = true,
      cb = function(t, e)
        text, err = t, e
      end,
    })
    H.truthy(H.wait(30000, function()
      return text ~= nil or err ~= nil
    end))
    H.eq(err, nil)
    H.matches(text, "## Fix")
    local cached = notebook.result_of(nb, "a1")
    H.matches(cached.analysis.text, "CREATE INDEX")
    H.eq(cached.analysis.kind, "EXPLAIN ANALYZE")
    H.truthy(s.analysis_buf and vim.api.nvim_buf_is_valid(s.analysis_buf))
    H.eq(require("dbgrid.ai").sql_blocks(text), { "CREATE INDEX CONCURRENTLY users_balance_idx ON users (balance);" })
    require("dbgrid.ui.analysis").insert_sql(s)
    local list = cells.parse(s.buf)
    H.eq(#list, 2)
    H.matches(cells.body_text(list[2]), "CREATE INDEX CONCURRENTLY")
    -- the plan view shows the stored analysis
    results_ui.show(s, "a1", { view = "plan" })
    H.matches(results_text(s), "analysis %(EXPLAIN ANALYZE")
    require("dbgrid.ui.analysis").close(s)
  end)

  H.it("builds analyze and error prompts with redaction", function()
    local ai = require("dbgrid.ai")
    require("dbgrid.config").get().ai.redact_literals = true
    local p = ai.build_analyze_prompt({
      sql = "select * from users where email = 'a@b.c' and id > 42",
      plan_lines = { "Seq Scan on users", "  Filter: (email = 'a@b.c'::text)" },
      findings = { "Seq Scan on users (~5,000 rows)" },
      analyzed = true,
      version = "PostgreSQL 16.3 on x86_64",
    })
    require("dbgrid.config").get().ai.redact_literals = false
    H.matches(p, "PostgreSQL 16.3 performance expert")
    H.falsy(p:find("a@b.c", 1, true), "literal should be redacted")
    H.matches(p, "id > %?")
    H.matches(p, "## Rule%-based findings")
    local e = ai.build_error_prompt({
      sql = "select nope from users",
      error = { message = 'column "nope" does not exist', line = 1, col = 8, hint = "maybe email" },
    })
    H.matches(e, '## Error\nERROR: column "nope" does not exist')
    H.matches(e, "HINT: maybe email")
    local g = ai.build_prompt({
      prompt = "only active ones",
      existing_sql = "select nope from users",
      error = { message = 'column "nope" does not exist' },
    })
    H.matches(g, '## Last error.-\nERROR: column "nope" does not exist')
    H.falsy(ai.build_prompt({ prompt = "x", error = { message = "y" } }):find("Last error", 1, true))
  end)

  H.it("clones a cell and shows its last error without the agent", function()
    local query = require("dbgrid.ui.query")
    set_cells(s, { "-- %% [cl1] broken", "-- @nolimit", "select nope from users" })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, false)
    vim.api.nvim_set_current_win(s.query_win)
    vim.api.nvim_win_set_cursor(s.query_win, { 3, 0 })
    local win = query.show_error(s)
    H.truthy(win and vim.api.nvim_win_is_valid(win))
    local shown = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    H.matches(shown, '^ERROR: column "nope" does not exist')
    H.matches(shown, "at line 2, column 8 of the statement")
    H.matches(shown, "\nHINT: ")
    vim.api.nvim_win_close(win, true)
    local lines = query.error_lines({ error = { message = "boom", raw = "boom" }, statements = {} })
    H.eq(lines, { "ERROR: boom" })
    vim.api.nvim_win_set_cursor(s.query_win, { 3, 0 })
    local copy = query.clone_cell(s)
    local list = cells.parse(s.buf)
    H.eq(#list, 2)
    H.eq(list[1].id, "cl1")
    H.eq(list[2].id, copy.id)
    H.truthy(copy.id ~= "cl1")
    H.eq(list[2].title, "broken")
    H.eq((cells.body_text(list[2]):gsub("%s+$", "")), "-- @nolimit\nselect nope from users")
    H.eq(s.active_cell, copy.id)
    H.eq(vim.api.nvim_win_get_cursor(s.query_win)[1], list[2].first)
    H.eq(notebook.result_of(nb, copy.id), nil, "the copy has no result of its own")
    H.eq(query.show_error(s), nil)
  end)

  H.it("lets the agent investigate through the dbgrid-query helper", function()
    require("dbgrid.config").get().ai.investigate = true
    local text, err
    require("dbgrid.ai").ask_text("## Tool\nplease", function(t, e)
      text, err = t, e
    end, { connection = connections.get("test") })
    H.truthy(H.wait(30000, function()
      return text ~= nil or err ~= nil
    end))
    require("dbgrid.config").get().ai.investigate = false
    H.eq(err, nil)
    H.matches(text, "helper said:.-5000")
  end)

  H.it("diffs two runs of a cell and a run on another connection", function()
    set_cells(s, { "-- %% [f1] diffme", "select id, email, note from users where id <= 3 order by id" })
    local r1 = run_and_wait(s, 1)
    H.eq(r1.ok, true)
    psql("update users set note = 'changed' where id = 2")
    local r2 = run_and_wait(s, 1)
    H.eq(r2.ok, true)
    H.truthy(s.previous.f1, "previous result should be kept")
    results_ui.diff_previous(s)
    H.eq(s.view.mode, "diff")
    local d = s.view.diff.result
    H.eq(#d.changed, 1)
    H.eq(#d.added + #d.removed, 0)
    H.matches(results_text(s), "changed")
    results_ui.diff_previous(s)
    H.eq(s.view.mode, "grid")
    psql("update users set note = null where id = 2")
    local res
    runner.diff_on(s, cells.parse(s.buf)[1], "test-ro", function(x)
      res = x
    end)
    H.truthy(H.wait(20000, function()
      return res ~= nil
    end))
    H.eq(s.view.mode, "diff")
    H.eq(#s.view.diff.result.changed, 1) -- the note went back to null on the other side
  end)

  H.it("reports a missing hypopg extension clearly", function()
    set_cells(s, { "-- %% [h1] scan", "select * from users where balance > 5" })
    local delta, err
    runner.try_index(s, cells.parse(s.buf)[1], "create index on users (balance)", {
      cb = function(d, e)
        delta, err = d, e
      end,
    })
    H.truthy(H.wait(20000, function()
      return delta ~= nil or err ~= nil
    end))
    local has = psql("select count(*) from pg_available_extensions where name = 'hypopg'")
    if has == "0" then
      H.matches(err, "hypopg")
    else
      H.truthy(delta and delta.after)
    end
  end)

  H.it("compares schemas and settings of two connections", function()
    local d
    require("dbgrid.compare").schema(connections.get("test"), connections.get("test-ro"), function(x)
      d = x
    end)
    H.truthy(H.wait(30000, function()
      return d ~= nil
    end))
    H.matches(d.lines[1], "match")
    pcall(vim.api.nvim_win_close, 0, true)
    local sd
    require("dbgrid.compare").settings(connections.get("test"), connections.get("with-pass"), function(x)
      sd = x
    end)
    H.truthy(H.wait(30000, function()
      return sd ~= nil
    end))
    H.truthy(sd.lines[1]:find("match") or sd.lines[1]:find("0 differences"), sd.lines[1])
    pcall(vim.api.nvim_win_close, 0, true)
  end)

  H.it("shows arbitrary rows in the results pane", function()
    local rows = { columns = { "item", "last" }, rows = { { "status", "available" } } }
    results_ui.show_rows(s, rows, { title = "aws status" })
    H.matches(results_text(s), "status │ available")
  end)

  H.it("keeps temp tables across runs in a persistent session", function()
    local conn = vim.deepcopy(connections.get("test"))
    conn.name = "sess"
    conn.session = true
    local pg = require("dbgrid.adapters.postgres")
    local function run(stmts)
      local out
      pg.run(conn, stmts, {}, function(r)
        out = r
      end)
      H.truthy(H.wait(20000, function()
        return out ~= nil
      end))
      return out
    end
    local r1 = run({ { sql = "create temp table dbgrid_sess(a int)", kind = "create", class = "ddl", line = 1 } })
    H.eq(r1.ok, true, vim.inspect(r1.error))
    local r2 = run({ { sql = "insert into dbgrid_sess values (1), (2)", kind = "insert", class = "write", line = 1 } })
    H.eq(r2.ok, true, vim.inspect(r2.error))
    H.eq(r2.statements[1].tags, { "INSERT 0 2" })
    local r3 = run({ { sql = "select count(*) from dbgrid_sess", kind = "select", class = "read", line = 1 } })
    H.eq(r3.ok, true, vim.inspect(r3.error))
    H.eq(r3.statements[1].sets[1].rows, { { "2" } })
    -- an error is reported with the right line and the session survives
    local r4 = run({
      { sql = "select 1", kind = "select", class = "read", line = 1 },
      { sql = "select id,\n  nope\nfrom users", kind = "select", class = "read", line = 3 },
    })
    H.eq(r4.ok, false)
    H.eq(r4.error.stmt_index, 2)
    H.eq(r4.error.line, 4)
    local r5 = run({ { sql = "select count(*) from dbgrid_sess", kind = "select", class = "read", line = 1 } })
    H.eq(r5.ok, true, vim.inspect(r5.error))
    H.eq(#pg.sessions(), 1)
    -- explain analyze (rolled back) and the schema go through the same session
    local plan
    pg.explain_json(conn, "select * from dbgrid_sess", { analyze = true }, function(pl)
      plan = pl
    end)
    H.truthy(H.wait(20000, function()
      return plan ~= nil
    end))
    H.truthy(plan[1].Plan["Actual Rows"] ~= nil)
    pg.close_session(conn)
    H.eq(#pg.sessions(), 0)
    local r6 = run({ { sql = "select 1", kind = "select", class = "read", line = 1 } })
    H.eq(r6.ok, true)
    pg.close_session()
  end)

  H.it("closes the layout and stops live loops", function()
    set_cells(s, { "-- %% [z1] live", "-- @every 300ms", "select 1" })
    local r = run_and_wait(s, 1)
    H.eq(r.ok, true)
    H.truthy(s.live.z1)
    layout.close(s)
    runner.stop_all_live(s, "closed")
    H.eq(next(s.live), nil)
  end)
end)
