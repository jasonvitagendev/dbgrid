local H = _G.H
local sq = require("dbgrid.adapters.sqlite")

H.describe("sqlite.parse", function()
  local FS, RS = sq.FS, sq.RS
  H.it("parses quote-mode blocks with timing and change counts", function()
    local block = "'id'"
      .. FS
      .. "'note'"
      .. RS
      .. "1"
      .. FS
      .. "'a\nb'"
      .. RS
      .. "2"
      .. FS
      .. "NULL"
      .. RS
      .. "Run Time: real 0.002 user 0.000100 sys 0.000000\nchanges: 0   total_changes: 3\n"
    local sets, changes, ms = sq._parse_block(block)
    H.eq(sets[1].columns, { "id", "note" })
    H.eq(sets[1].rows, { { "1", "a\nb" }, { "2", vim.NIL } })
    H.eq(sets[1].row_count, 2)
    H.eq(changes, 0)
    H.eq(ms, 2)
    local sets2, changes2 =
      sq._parse_block("Run Time: real 0.000 user 0.000000 sys 0.000000\nchanges: 5   total_changes: 8\n")
    H.eq(sets2, {})
    H.eq(changes2, 5)
  end)
  H.it("keeps blobs as hex and separators inside text intact", function()
    local records = sq._parse_records(
      "X'019fe0b0'"
        .. FS
        .. "'it''s "
        .. RS
        .. FS
        .. " ''NULL'''"
        .. FS
        .. "''"
        .. FS
        .. "-1.5e+20"
        .. RS
        .. [[replace(replace('a\nb\r','\r',char(13)),'\n',char(10))]]
        .. FS
        .. [[unistr('x\u000ay\\z')]]
        .. FS
        .. "NULL"
        .. RS
    )
    H.eq(records, {
      { "X'019fe0b0'", "it's " .. RS .. FS .. " 'NULL'", "", "-1.5e+20" },
      { "a\nb\r", "x\ny\\z", vim.NIL },
    })
  end)
  H.it("maps errors back to the statement, line and column", function()
    local statements = { { sql = "select 1", line = 1 }, { sql = "select id,\n  nope\nfrom users", line = 5 } }
    local ranges = { { first = 4, last = 4 }, { first = 6, last = 8 } }
    local _, err = sq._parse_stderr(
      "Parse error near line 6: no such column: nope\n  select id,   nope from users;\n               ^--- error here\n",
      ranges,
      statements
    )
    H.eq(err.stmt_index, 2)
    H.eq(err.line, 6)
    H.eq(err.col, 3)
    H.eq(err.message, "no such column: nope")
    local _, e2 = sq._parse_stderr(
      "Runtime error near line 4: UNIQUE constraint failed: plans.id (19)\n",
      { { first = 4, last = 4 } },
      { { sql = "x", line = 1 } }
    )
    H.eq(e2.message, "UNIQUE constraint failed: plans.id")
    local _, e3 = sq._parse_stderr('Error: unable to open database "x": unable to open database file\n', {}, {})
    H.matches(e3.message, "unable to open")
  end)
  H.it("parses query plans and database paths", function()
    local plan = sq.parse_plan(
      "QUERY PLAN\n|--SCAN u USING INDEX i\n`--SEARCH p USING INTEGER PRIMARY KEY (rowid=?)\n   `--USE TEMP B-TREE FOR ORDER BY\n"
    )
    H.eq(plan.sqlite, true)
    H.eq(plan.nodes, {
      { depth = 0, detail = "SCAN u USING INDEX i" },
      { depth = 0, detail = "SEARCH p USING INTEGER PRIMARY KEY (rowid=?)" },
      { depth = 1, detail = "USE TEMP B-TREE FOR ORDER BY" },
    })
    H.eq(sq.path({ url = "sqlite:///tmp/x.db" }), "/tmp/x.db")
    H.eq(sq.path({ url = "sqlite:/tmp/x.db" }), "/tmp/x.db")
    H.eq(sq.path({ url = "sqlite::memory:" }), ":memory:")
    H.matches(sq.path({ url = "storage/dev.sqlite3" }), "/storage/dev%.sqlite3$")
    H.eq(sq.path({ url = "~/a.db" }), vim.env.HOME .. "/a.db")
    local adapters = require("dbgrid.adapters")
    H.eq(adapters.for_connection({ url = "sqlite:/x.db" }).name, "sqlite")
    H.eq(adapters.for_connection({ url = "/x/y.sqlite3" }).name, "sqlite")
    H.eq(adapters.for_connection({ url = "postgres://x/y" }).name, "postgres")
  end)
end)

if vim.fn.executable("sqlite3") ~= 1 then
  io.write("  skip sqlite integration (sqlite3 not on PATH)\n")
  return
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db = tmp .. "/test.db"
vim
  .system({
    "sqlite3",
    db,
    table.concat({
      "create table plans(id integer primary key, name text not null);",
      "insert into plans(name) values ('free'),('pro'),('team');",
      "create table users(id integer primary key, email text not null unique, plan_id int references plans(id), balance real, created_at text default current_timestamp, note text);",
      "insert into users(email, plan_id, balance) select 'user'||value||'@example.com', (value % 3)+1, value*1.5 from generate_series(1,5000);",
      "create index users_created_at_idx on users(created_at);",
      "create view active_users as select * from users where balance > 5;",
    }, " "),
  })
  :wait()
local conn = { name = "sqlite-test", url = "sqlite:" .. db }

H.describe("sqlite integration", function()
  H.it("runs statements and returns rows, tags and timing", function()
    local result
    sq.run(conn, {
      {
        sql = "select id, email, null as b from users where id <= 2 order by id",
        kind = "select",
        class = "read",
        line = 1,
      },
      { sql = "create temp table dbgrid_t(a int)", kind = "create", class = "ddl", line = 2 },
      { sql = "insert into dbgrid_t values (1),(2)", kind = "insert", class = "write", line = 3 },
      { sql = "select count(*) from dbgrid_t", kind = "select", class = "read", line = 4 },
      { sql = "select id from users where id < 0", kind = "select", class = "read", line = 5 },
      {
        sql = "select x'1e1f00ff' as b, 'a' || char(30, 31) || 'b' as t, 42 as n",
        kind = "select",
        class = "read",
        line = 6,
      },
    }, {}, function(r)
      result = r
    end)
    H.truthy(H.wait(10000, function()
      return result ~= nil
    end))
    H.eq(result.ok, true, vim.inspect(result.error))
    H.eq(result.statements[1].sets[1].columns, { "id", "email", "b" })
    H.eq(
      result.statements[1].sets[1].rows,
      { { "1", "user1@example.com", vim.NIL }, { "2", "user2@example.com", vim.NIL } }
    )
    H.eq(result.statements[2].tags, { "CREATE TEMP" })
    H.eq(result.statements[3].tags, { "INSERT 2" })
    H.eq(result.statements[4].sets[1].rows, { { "2" } })
    H.eq(result.statements[5].sets, {})
    H.eq(result.statements[5].tags, {})
    H.eq(result.statements[6].sets[1].rows, { { "X'1e1f00ff'", "a\30\31b", "42" } })
    H.truthy(result.elapsed_ms > 0)
  end)

  H.it("reports errors with statement, line and column; later statements do not run", function()
    local result
    sq.run(conn, {
      { sql = "select 1", kind = "select", class = "read", line = 1 },
      { sql = "select id,\n  nope\nfrom users", kind = "select", class = "read", line = 3 },
      { sql = "select 2", kind = "select", class = "read", line = 7 },
    }, {}, function(r)
      result = r
    end)
    H.truthy(H.wait(10000, function()
      return result ~= nil
    end))
    H.eq(result.ok, false)
    H.eq(result.error.stmt_index, 2)
    H.eq(result.error.line, 4)
    H.eq(result.error.col, 3)
    H.eq(result.statements[1].ran, true)
    H.eq(result.statements[3].ran, false)
  end)

  H.it("rejects writes on read-only connections", function()
    local result
    sq.run(
      vim.tbl_extend("force", conn, { readonly = true }),
      { { sql = "insert into plans(name) values ('x')", kind = "insert", class = "write", line = 1 } },
      {},
      function(r)
        result = r
      end
    )
    H.truthy(H.wait(10000, function()
      return result ~= nil
    end))
    H.eq(result.ok, false)
    H.matches(result.error.message, "readonly")
  end)

  H.it("explains, describes the schema and counts rows", function()
    local plans
    sq.explain(conn, {
      { sql = "select * from users where balance > 5", kind = "select", class = "read", line = 1 },
      { sql = "select * from nope", kind = "select", class = "read", line = 2 },
      { sql = "select * from users where id = 3", kind = "select", class = "read", line = 3 },
    }, function(p)
      plans = p
    end)
    H.truthy(H.wait(10000, function()
      return plans ~= nil
    end))
    H.eq(plans[1].nodes[1].detail, "SCAN users")
    H.eq(plans[2], nil)
    H.matches(plans[3].nodes[1].detail, "^SEARCH users USING INTEGER PRIMARY KEY")
    local schema, err
    sq.schema(conn, function(s, e)
      schema, err = s, e
    end)
    H.truthy(H.wait(20000, function()
      return schema ~= nil or err ~= nil
    end))
    H.eq(err, nil)
    local users
    for _, t in ipairs(schema.tables) do
      if t.name == "users" then
        users = t
      end
    end
    H.truthy(users)
    H.eq(users.rows, 5000)
    H.eq(users.columns[2].name, "email")
    H.eq(users.columns[2].notnull, true)
    H.eq(users.indexes[1].primary, true)
    H.eq(#users.indexes, 3)
    H.eq(users.constraints[2].type, "f")
    H.eq(users.constraints[2].ref_table, "main.plans")
    local view = schema.by_name and schema.by_name["active_users"]
    H.eq(view, nil) -- raw document, normalised by dbgrid.schema
    local normalised = require("dbgrid.schema")
    H.eq(normalised.find_table({ by_name = { users = users } }, "USERS"), users)
    local ok, msg
    sq.test(conn, function(o, m)
      ok, msg = o, m
    end)
    H.truthy(H.wait(10000, function()
      return ok ~= nil
    end))
    H.eq(ok, true)
    H.matches(msg, "^SQLite %d")
  end)
end)

H.describe("sqlite notebook", function()
  require("dbgrid").setup({
    storage = { data_dir = tmp .. "/data", mode = "data" },
    connections = { conn },
    default_connection = "sqlite-test",
    query = { confirm_writes = false, limit = 5 },
    index_check = { mode = "warn", min_rows = 1000 },
  })
  local notebook = require("dbgrid.notebook")
  local layout = require("dbgrid.ui.layout")
  local runner = require("dbgrid.runner")
  local cells = require("dbgrid.cells")
  local nb = notebook.create("sqlite ui", { connection = "sqlite-test" })
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
  H.it("runs cells against sqlite with the index check and completion", function()
    local schema = require("dbgrid.schema")
    local loaded
    schema.get(conn, function(sch)
      loaded = sch
    end)
    H.truthy(H.wait(20000, function()
      return loaded ~= nil
    end))
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, {
      "-- %% [s1] scan",
      "select id, email from users where balance > :min order by id",
      "",
      "-- %% [s2] plans",
      "select * from plans",
    })
    vim.b[s.buf].dbgrid_cells_cache = nil
    notebook.set_param(nb, "min", "7000")
    local r = run_and_wait(1)
    H.eq(r.ok, true, vim.inspect(r.error))
    H.eq(r.statements[1].limit_applied, 5)
    H.truthy(#r.warnings >= 1, "expected a full scan warning")
    H.matches(r.warnings[1].message, "Full scan of users %(~5,000 rows%)")
    H.eq(r.warnings[1].suggestion, "CREATE INDEX ON users (balance);")
    local text = table.concat(vim.api.nvim_buf_get_lines(s.results_buf, 0, -1, false), "\n")
    H.matches(text, "user4668@example%.com")
    H.matches(text, "with :min = 7000")
    H.matches(text, "LIMIT 5 added")
    local items = require("dbgrid.completion").items(s.buf, 2, 6)
    local labels = {}
    for _, it in ipairs(items) do
      labels[it.label] = it.kind_name
    end
    H.eq(labels["group_concat"], "function")
    H.eq(labels["users"], "table")
    H.eq(labels["array_agg"], nil)
    runner.explain_cell(s, cells.parse(s.buf)[2], true)
    H.truthy(H.wait(10000, function()
      return s.runtime.s2 and s.runtime.s2.plan_text ~= nil
    end))
    H.eq(s.runtime.s2.plan_kind, "EXPLAIN")
    H.matches(table.concat(s.runtime.s2.plan_text, "\n"), "SCAN plans")
    layout.close(s)
  end)
end)
