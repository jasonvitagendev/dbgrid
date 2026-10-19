-- Tests for the undo of writes: the SET-clause parser, the capture plan, the
-- typed literals and the reverse statements run against a hand-made schema;
-- the whole round trip (UPDATE / DELETE, undo cell, run it) against a SQLite
-- database when sqlite3 is on PATH.
local H = _G.H
local sqlmod = require("dbgrid.sql")
local undo = require("dbgrid.undo")

local function stmt(sql)
  return sqlmod.split(sql)[1]
end

local function fake_schema()
  local tables = {
    {
      schema = "public",
      name = "users",
      kind = "r",
      rows = 10,
      columns = {
        { name = "id", type = "integer", identity = "a" },
        { name = "email", type = "text" },
        { name = "plan_id", type = "integer" },
        { name = "zip", type = "text" },
        { name = "email_lower", type = "text", generated = "s" },
      },
      indexes = {},
      constraints = { { name = "users_pkey", type = "p", columns = { "id" } } },
    },
    {
      schema = "public",
      name = "invoices",
      kind = "r",
      rows = 5,
      columns = {
        { name = "id", type = "integer" },
        { name = "user_id", type = "integer" },
        { name = "amount", type = "numeric(10,2)" },
        { name = "paid", type = "boolean" },
      },
      indexes = {},
      constraints = { { name = "invoices_pkey", type = "p", columns = { "id" } } },
    },
    {
      schema = "public",
      name = "memberships",
      kind = "r",
      rows = 5,
      columns = { { name = "user_id", type = "integer" }, { name = "team_id", type = "integer" }, { name = "role", type = "text" } },
      indexes = {},
      constraints = { { name = "memberships_pkey", type = "p", columns = { "user_id", "team_id" } } },
    },
    { schema = "public", name = "logs", kind = "r", rows = 5, columns = { { name = "msg", type = "text" } }, indexes = {}, constraints = {} },
    { schema = "public", name = "user_view", kind = "v", rows = 0, columns = { { name = "id", type = "integer" } }, indexes = {}, constraints = {} },
  }
  local by_name = {}
  for _, t in ipairs(tables) do
    by_name[(t.schema .. "." .. t.name):lower()] = t
    by_name[t.name:lower()] = t
  end
  return { tables = tables, by_name = by_name, schemas = { "public" }, enums = {}, functions = {} }
end

H.describe("sql.set_columns", function()
  H.it("reads a plain SET list", function()
    H.eq(sqlmod.set_columns(stmt("update users set email = 'x', plan_id = 2 where id = 1")), { "email", "plan_id" })
  end)
  H.it("reads the row form and quoted names", function()
    H.eq(
      sqlmod.set_columns(stmt("update users u set (email, plan_id) = ('x', 2) from plans p where u.plan_id = p.id")),
      { "email", "plan_id" }
    )
    H.eq(sqlmod.set_columns(stmt('update users set "Weird Name" = 1, zip = \'02134\' where id = 1')), { '"Weird Name"', "zip" })
  end)
  H.it("skips over subqueries and function calls in the expressions", function()
    H.eq(
      sqlmod.set_columns(stmt("update users set email = (select max(email) from users where id > 1), plan_id = coalesce(plan_id, 1) where id = 1")),
      { "email", "plan_id" }
    )
  end)
  H.it("is nil for other statements and shapes it does not read", function()
    H.eq(sqlmod.set_columns(stmt("delete from users where id = 1")), nil)
    H.eq(sqlmod.set_columns(stmt("update users set = 1 where id = 1")), nil)
  end)
end)

H.describe("sql.preview_select", function()
  H.it("selects over the rows a DELETE ... USING touches, without RETURNING", function()
    H.eq(
      sqlmod.preview_select(stmt("delete from invoices i using users u where u.id = i.user_id and u.id = 1 returning *"), "i.id"),
      "SELECT i.id FROM invoices i, users u where u.id = i.user_id and u.id = 1"
    )
    H.eq(sqlmod.preview_count(stmt("update users set email = 'x' where id = 1")), "SELECT count(*) FROM users where id = 1")
    H.eq(sqlmod.preview_select(stmt("update users set email = 'x'"), "id"), nil)
  end)
end)

H.describe("undo.plan", function()
  local sch = fake_schema()
  H.it("keeps the key and the assigned columns of an UPDATE", function()
    local plans, skipped = undo.plan(sch, sqlmod.split("update users set email = 'x' where id <= 2"), { max_rows = 1000 })
    H.eq(skipped, {})
    H.eq(#plans, 1)
    H.eq(plans[1].kind, "update")
    H.eq(vim.tbl_map(function(c) return c.name end, plans[1].columns), { "id", "email" })
    H.eq(plans[1].key, { 1 })
    H.eq(plans[1].sql, "SELECT users.id, users.email FROM users where id <= 2 LIMIT 1001")
  end)
  H.it("keeps every column of a DELETE except generated ones, through the alias", function()
    local plans = undo.plan(sch, sqlmod.split("delete from users u where u.plan_id = 2"), {})
    H.eq(vim.tbl_map(function(c) return c.name end, plans[1].columns), { "id", "email", "plan_id", "zip" })
    H.eq(plans[1].sql, "SELECT u.id, u.email, u.plan_id, u.zip FROM users u where u.plan_id = 2")
  end)
  H.it("falls back to every column when the SET clause is unreadable, and flags key changes", function()
    local plans = undo.plan(sch, sqlmod.split("update users set = 1 where id = 1"), {})
    H.eq(#plans[1].columns, 4)
    local plans2 = undo.plan(sch, sqlmod.split("update users set id = id + 100, email = 'x' where id = 1"), {})
    H.eq(plans2[1].key_changed, true)
    H.eq(vim.tbl_map(function(c) return c.name end, plans2[1].columns), { "id", "email" })
  end)
  H.it("handles composite keys", function()
    local plans = undo.plan(sch, sqlmod.split("update memberships set role = 'admin' where team_id = 3"), {})
    H.eq(vim.tbl_map(function(c) return c.name end, plans[1].columns), { "user_id", "team_id", "role" })
    H.eq(plans[1].key, { 1, 2 })
  end)
  H.it("says why a statement cannot be undone", function()
    local _, skipped = undo.plan(
      sch,
      sqlmod.split(table.concat({
        "update users set email = 'x'",
        "delete from logs where msg = 'a'",
        "delete from user_view where id = 1",
        "delete from nowhere where id = 1",
        "insert into users (email) values ('x')",
      }, ";\n")),
      {}
    )
    H.eq(skipped, {
      "UPDATE has no WHERE clause",
      "logs has no primary key",
      "user_view is not a plain table",
      "nowhere is not in the schema cache",
    })
    local _, skipped2 = undo.plan(nil, sqlmod.split("delete from users where id = 1"), {})
    H.eq(skipped2, { "users is not in the schema cache" })
  end)
end)

H.describe("undo.literal", function()
  H.it("quotes by the column type, not by the look of the value", function()
    H.eq(undo.literal("00123", "text"), "'00123'")
    H.eq(undo.literal("42", "integer"), "42")
    H.eq(undo.literal("-1.50", "numeric(10,2)"), "-1.50")
    H.eq(undo.literal("10.0", "real"), "10.0")
    H.eq(undo.literal("abc", "integer"), "'abc'")
    H.eq(undo.literal("t", "boolean"), "true")
    H.eq(undo.literal("false", "bool"), "false")
    H.eq(undo.literal("it's", "text"), "'it''s'")
    H.eq(undo.literal(vim.NIL, "text"), "NULL")
    H.eq(undo.literal(nil, "integer"), "NULL")
    H.eq(undo.literal("2026-01-01 10:00:00+00", "timestamptz"), "'2026-01-01 10:00:00+00'")
  end)
end)

H.describe("undo.capture and reverse", function()
  local sch = fake_schema()
  local conn = { name = "fake", url = "postgres://x/y" }
  local function fake_adapter(sets, err)
    return {
      run = function(_, stmts, _, cb)
        local statements = {}
        for i = 1, #stmts do
          statements[i] = { sets = sets[i] and { sets[i] } or {}, tags = {} }
        end
        cb({ ok = err == nil, statements = statements, error = err, notices = {} })
      end,
    }
  end
  local function capture(sql, sets, err, max_rows)
    require("dbgrid.config").get().query.undo_rows = max_rows or 1000
    local got, note
    undo.capture(conn, fake_adapter(sets, err), sch, sqlmod.split(sql), function(entries, n)
      got, note = entries or false, n
    end)
    require("dbgrid.config").get().query.undo_rows = 1000
    return got, note
  end

  H.it("re-inserts deleted rows with OVERRIDING SYSTEM VALUE for an identity column", function()
    local entries, note = capture("delete from users where plan_id = 2", {
      {
        columns = { "id", "email", "plan_id", "zip" },
        rows = { { "1", "a@x", "2", "02134" }, { "2", "it's", vim.NIL, vim.NIL } },
      },
    })
    H.eq(note, nil)
    H.eq(#entries, 1)
    H.eq(entries[1].overriding, true)
    H.eq(entries[1].table, "users")
    H.eq(undo.reverse_lines(entries[1]), {
      "INSERT INTO users (id, email, plan_id, zip)",
      "OVERRIDING SYSTEM VALUE",
      "VALUES",
      "  (1, 'a@x', 2, '02134'),",
      "  (2, 'it''s', NULL, NULL);",
    })
  end)

  H.it("restores updated columns row by row, keyed by the primary key", function()
    local entries = capture("update invoices set amount = 0, paid = true where user_id = 1", {
      { columns = { "id", "amount", "paid" }, rows = { { "7", "10.50", "f" }, { "9", "3.00", vim.NIL } } },
    })
    H.eq(entries[1].kind, "update")
    H.eq(entries[1].overriding, nil)
    H.eq(undo.reverse_lines(entries[1]), {
      "UPDATE invoices SET amount = 10.50, paid = false WHERE id = 7;",
      "UPDATE invoices SET amount = 3.00, paid = NULL WHERE id = 9;",
    })
  end)

  H.it("deduplicates rows a join repeated and handles composite keys", function()
    local entries = capture("update memberships m set role = 'x' from users u where u.id = m.user_id", {
      { columns = { "user_id", "team_id", "role" }, rows = { { "1", "2", "admin" }, { "1", "2", "admin" }, { "1", "3", "member" } } },
    })
    H.eq(#entries[1].rows, 2)
    H.eq(undo.reverse_lines(entries[1]), {
      "UPDATE memberships SET role = 'admin' WHERE user_id = 1 AND team_id = 2;",
      "UPDATE memberships SET role = 'member' WHERE user_id = 1 AND team_id = 3;",
    })
  end)

  H.it("keeps nothing when the rows exceed the cap or cannot be read", function()
    local entries, note = capture("delete from users where id < 10", {
      { columns = { "id", "email", "plan_id", "zip" }, rows = { { "1", "a", "1", "x" }, { "2", "b", "1", "y" } } },
    }, nil, 1)
    H.eq(entries, false)
    H.matches(note, "DELETE on users touches more than 1 rows")
    local entries2, note2 = capture("delete from users where id < 10", {}, { message = "boom" })
    H.eq(entries2, false)
    H.matches(note2, "DELETE on users: boom")
    -- nothing applies: no entries, a note only when something was skipped
    local entries3, note3 = capture("insert into users (email) values ('x')", {})
    H.eq(entries3, false)
    H.eq(note3, nil)
    local entries4, note4 = capture("delete from users", {})
    H.eq(entries4, false)
    H.eq(note4, "no undo: DELETE has no WHERE clause")
  end)

  H.it("keeps only the statements that ran after a failure outside a transaction", function()
    local entries = { { stmt_index = 1, rows = {} }, { stmt_index = 3, rows = {} } }
    H.eq(undo.applied(entries, { ok = true }, true), entries)
    H.eq(undo.applied(entries, { ok = false, error = { stmt_index = 3 } }, true), nil)
    H.eq(undo.applied(entries, { ok = false, error = { stmt_index = 3 } }, false), { entries[1] })
    H.eq(undo.applied(entries, { ok = false, error = { stmt_index = 1 } }, false), nil)
    H.eq(undo.applied(nil, { ok = true }, false), nil)
  end)

  H.it("writes the undo cell last statement first, with the connection when it differs", function()
    local result = {
      ran_at = os.time({ year = 2026, month = 1, day = 2, hour = 3, min = 4, sec = 5 }),
      connection = "prod/writer",
      undo = {
        {
          stmt_index = 1,
          kind = "update",
          table = "users",
          ref = "users",
          columns = { "id", "email" },
          types = { "integer", "text" },
          key = { 1 },
          rows = { { "1", "old@x" } },
        },
        {
          stmt_index = 2,
          kind = "delete",
          table = "invoices",
          ref = "invoices",
          columns = { "id", "amount" },
          types = { "integer", "numeric" },
          key = { 1 },
          rows = { { "7", "1.00" } },
        },
      },
    }
    local body = undo.cell_body(result, { conn = "prod/writer", label = '"fix emails"' })
    H.eq(body[1], "-- @conn prod/writer")
    H.matches(body[2], '^%-%- undo of "fix emails", run at 2026%-01%-02 03:04:05 on prod/writer')
    H.eq(vim.list_slice(body, 3), {
      "-- re-inserts 1 row deleted from invoices",
      "INSERT INTO invoices (id, amount)",
      "VALUES",
      "  (7, 1.00);",
      "-- restores 1 row of users changed by the UPDATE",
      "UPDATE users SET email = 'old@x' WHERE id = 1;",
    })
    local none, err = undo.cell_body({ undo = {} })
    H.eq(none, nil)
    H.matches(err, "no rows were kept")
    H.matches(undo.footer(result, "\\u"), "1 row of users, 1 row of invoices kept before the UPDATE; \\u writes the undo as a cell")
    local skipped, warn = undo.footer({ undo_skipped = "no undo: logs has no primary key" }, "\\u")
    H.matches(skipped, "no undo: logs has no primary key")
    H.eq(warn, true)
  end)
end)

if vim.fn.executable("sqlite3") ~= 1 then
  io.write("  skip undo integration (sqlite3 not on PATH)\n")
  return
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db = tmp .. "/undo.db"
vim
  .system({
    "sqlite3",
    db,
    table.concat({
      "create table plans(id integer primary key, name text not null);",
      "insert into plans(name) values ('free'),('pro'),('team');",
      "create table users(id integer primary key, email text not null, plan_id int references plans(id), zip text);",
      "insert into users(email, plan_id, zip) select 'user'||value||'@example.com', (value % 3)+1, '0'||value from generate_series(1,6);",
      "create table invoices(id integer primary key, user_id int not null references users(id), amount real, note text);",
      "insert into invoices(user_id, amount, note) values (1, 10, 'a'), (1, 20.5, null), (2, 5, 'c');",
      "create table logs(msg text);",
      "insert into logs values ('a');",
    }, " "),
  })
  :wait()
local function sqlite(sql)
  return vim.trim(vim.system({ "sqlite3", db, sql }):wait().stdout or "")
end

H.describe("undo against sqlite", function()
  require("dbgrid").setup({
    storage = { data_dir = tmp .. "/data", mode = "data" },
    connections = { { name = "sqlite-undo", url = "sqlite:" .. db }, { name = "sqlite-undo-2", url = "sqlite:" .. db } },
    default_connection = "sqlite-undo",
    query = { confirm_writes = false, limit = 5 },
    index_check = { mode = "off" },
  })
  local notebook = require("dbgrid.notebook")
  local layout = require("dbgrid.ui.layout")
  local runner = require("dbgrid.runner")
  local cells = require("dbgrid.cells")
  local nb = notebook.create("sqlite undo", { connection = "sqlite-undo" })
  local s = layout.open(nb)
  local function set_cells(lines)
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
    vim.b[s.buf].dbgrid_cells_cache = nil
  end
  local function results_text()
    return table.concat(vim.api.nvim_buf_get_lines(s.results_buf, 0, -1, false), "\n")
  end
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

  H.it("keeps the rows an UPDATE changes and restores them through the undo cell", function()
    set_cells({ "-- %% [u1] fix emails", "update users set email = 'changed', zip = '9' where id <= 2" })
    local r = run_and_wait(1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(sqlite("select count(*) from users where email = 'changed'"), "2")
    H.eq(#r.undo, 1)
    H.eq(r.undo[1].kind, "update")
    H.eq(r.undo[1].columns, { "id", "email", "zip" })
    H.eq(r.undo[1].rows, { { "1", "user1@example.com", "01" }, { "2", "user2@example.com", "02" } })
    H.matches(results_text(), "2 rows of users kept before the UPDATE")
    -- the cache keeps it
    H.eq(#notebook.result_of(nb, "u1").undo[1].rows, 2)
    -- write the undo cell below and run it
    local id = undo.write_cell(s, cells.by_id(s.buf, "u1"))
    H.truthy(id)
    local list = cells.parse(s.buf)
    H.eq(#list, 2)
    H.eq(list[2].title, "undo fix emails")
    local body = table.concat(list[2].lines, "\n")
    H.matches(body, "UPDATE users SET email = 'user1@example.com', zip = '01' WHERE id = 1;")
    H.matches(body, "UPDATE users SET email = 'user2@example.com', zip = '02' WHERE id = 2;")
    H.falsy(body:find("@conn", 1, true))
    local r2 = run_and_wait(2)
    H.eq(r2.ok, true, vim.inspect(r2.error))
    H.eq(sqlite("select email || '/' || zip from users where id <= 2 order by id"), "user1@example.com/01\nuser2@example.com/02")
    -- the undo cell itself kept rows too (one entry per UPDATE statement), so it can be undone again
    H.eq(#r2.undo, 2)
    H.eq(r2.undo[1].rows, { { "1", "changed", "9" } })
    H.eq(r2.undo[2].rows, { { "2", "changed", "9" } })
  end)

  H.it("re-inserts deleted rows with their types intact", function()
    set_cells({ "-- %% [d1] drop invoices", "delete from invoices where user_id = 1" })
    local r = run_and_wait(1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(sqlite("select count(*) from invoices"), "1")
    H.eq(r.undo[1].kind, "delete")
    H.eq(r.undo[1].columns, { "id", "user_id", "amount", "note" })
    H.matches(results_text(), "2 rows of invoices kept before the DELETE")
    undo.write_cell(s, cells.by_id(s.buf, "d1"))
    local body = table.concat(cells.parse(s.buf)[2].lines, "\n")
    H.matches(body, "INSERT INTO invoices %(id, user_id, amount, note%)")
    H.matches(body, "%(1, 1, 10.0, 'a'%),")
    H.matches(body, "%(2, 1, 20.5, NULL%);")
    local r2 = run_and_wait(2)
    H.eq(r2.ok, true, vim.inspect(r2.error))
    H.eq(sqlite("select id || ':' || typeof(amount) || ':' || amount || ':' || coalesce(note, 'null') from invoices order by id"), "1:real:10.0:a\n2:real:20.5:null\n3:real:5.0:c")
  end)

  H.it("says why there is no undo, and skips dry runs", function()
    set_cells({ "-- %% [n1] no key", "delete from logs where msg = 'a'" })
    local r = run_and_wait(1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(r.undo, nil)
    H.eq(r.undo_skipped, "no undo: logs has no primary key")
    H.matches(results_text(), "no undo: logs has no primary key")
    H.eq(undo.write_cell(s, cells.by_id(s.buf, "n1")), nil)
    H.eq(#cells.parse(s.buf), 1)
    sqlite("insert into logs values ('a')")
    -- over the cap
    require("dbgrid.config").get().query.undo_rows = 1
    set_cells({ "-- %% [c1] cap", "update users set zip = zip where id <= 2" })
    local r2 = run_and_wait(1)
    H.eq(r2.ok, true, vim.inspect(r2.error))
    H.eq(r2.undo, nil)
    H.matches(r2.undo_skipped, "UPDATE on users touches more than 1 rows")
    require("dbgrid.config").get().query.undo_rows = 1000
    -- a dry run changes nothing, so nothing is kept
    set_cells({ "-- %% [dr] dry", "-- @dryrun", "update users set zip = 'x' where id = 1" })
    local r3 = run_and_wait(1)
    H.eq(r3.ok, true, vim.inspect(r3.error))
    H.eq(r3.undo, nil)
    H.eq(r3.undo_skipped, nil)
    -- capture off
    require("dbgrid.config").get().query.undo_rows = 0
    set_cells({ "-- %% [off] off", "update users set zip = zip where id = 1" })
    local r4 = run_and_wait(1)
    H.eq(r4.undo, nil)
    H.eq(r4.undo_skipped, nil)
    require("dbgrid.config").get().query.undo_rows = 1000
  end)

  H.it("pins the undo cell to the connection the write ran on", function()
    set_cells({ "-- %% [o1] other conn", "-- @conn sqlite-undo-2", "update users set zip = 'z' where id = 3" })
    local r = run_and_wait(1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(r.connection, "sqlite-undo-2")
    undo.write_cell(s, cells.by_id(s.buf, "o1"))
    local lines = cells.parse(s.buf)[2].lines
    H.eq(lines[1], "-- @conn sqlite-undo-2")
    H.matches(lines[2], '^%-%- undo of "other conn", run at .* on sqlite%-undo%-2')
    local r2 = run_and_wait(2)
    H.eq(r2.ok, true, vim.inspect(r2.error))
    H.eq(sqlite("select zip from users where id = 3"), "03")
  end)

  H.it("keeps the rows of a multi-statement cell and writes them back in reverse order", function()
    set_cells({
      "-- %% [m1] two writes",
      "update users set zip = 'a' where id = 4;",
      "delete from invoices where id = 3;",
    })
    local r = run_and_wait(1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(#r.undo, 2)
    H.eq(r.undo[1].stmt_index, 1)
    H.eq(r.undo[2].stmt_index, 2)
    undo.write_cell(s, cells.by_id(s.buf, "m1"))
    local body = table.concat(cells.parse(s.buf)[2].lines, "\n")
    local ins, upd = body:find("INSERT INTO invoices", 1, true), body:find("UPDATE users", 1, true)
    H.truthy(ins and upd and ins < upd, "the DELETE should be undone before the UPDATE")
    local r2 = run_and_wait(2)
    H.eq(r2.ok, true, vim.inspect(r2.error))
    H.eq(sqlite("select zip from users where id = 4"), "04")
    H.eq(sqlite("select count(*) from invoices where id = 3"), "1")
    layout.close(s)
  end)
end)
