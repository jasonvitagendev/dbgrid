local H = _G.H
local pg = require("dbgrid.adapters.postgres")

H.describe("postgres.parse_block", function()
  local FS, RS = pg.FS, pg.RS
  H.it("parses a result set with nulls, newlines and a footer", function()
    local block = "id"
      .. FS
      .. "note"
      .. RS
      .. "1"
      .. FS
      .. "a\nb"
      .. RS
      .. "2"
      .. FS
      .. pg.NULL
      .. RS
      .. "(2 rows)\nTime: 1.500 ms\n"
    local sets, tags, ms = pg._parse_block(block)
    H.eq(#sets, 1)
    H.eq(sets[1].columns, { "id", "note" })
    H.eq(sets[1].rows, { { "1", "a\nb" }, { "2", vim.NIL } })
    H.eq(sets[1].row_count, 2)
    H.eq(tags, {})
    H.eq(ms, 1.5)
  end)
  H.it("parses command tags", function()
    local sets, tags, ms = pg._parse_block("UPDATE 5\nTime: 0.900 ms\n")
    H.eq(sets, {})
    H.eq(tags, { "UPDATE 5" })
    H.eq(ms, 0.9)
  end)
  H.it("parses an empty result and a single column", function()
    local sets = pg._parse_block("?column?" .. RS .. "(0 rows)\n")
    H.eq(sets[1].columns, { "?column?" })
    H.eq(sets[1].rows, {})
    sets = pg._parse_block("x" .. RS .. "1" .. RS .. "(1 row)\n")
    H.eq(sets[1].rows, { { "1" } })
  end)
end)

H.describe("postgres.parse_stderr", function()
  H.it("maps errors back to statements and lines", function()
    local statements = { { sql = "select 1", line = 1 }, { sql = "select id,\n  emial\nfrom users", line = 5 } }
    local ranges = { { first = 3, last = 3 }, { first = 5, last = 7 } }
    local stderr =
      'psql:<stdin>:7: ERROR:  column "emial" does not exist\nLINE 2:   emial\n          ^\nHINT:  Perhaps you meant "email".\n'
    local notices, err = pg._parse_stderr(stderr, ranges, statements)
    H.eq(notices, {})
    H.eq(err.stmt_index, 2)
    H.eq(err.line, 6)
    H.eq(err.col, 3)
    H.matches(err.message, "emial")
    H.matches(err.hint, "email")
  end)
  H.it("collects notices", function()
    local notices, err = pg._parse_stderr("NOTICE:  hello\nWARNING:  careful\nDETAIL:  more\n", {}, {})
    H.eq(err, nil)
    H.eq(#notices, 3)
  end)
end)

local url = os.getenv("DBGRID_TEST_URL")
if not url then
  io.write("  skip postgres integration (DBGRID_TEST_URL not set)\n")
  return
end

local conn = { name = "test", url = url }

H.describe("postgres.connection_failed", function()
  local function res(message, ran)
    return { error = message and { message = message } or nil, statements = { { ran = ran } } }
  end
  H.it("recognises libpq connection errors before any statement ran", function()
    H.eq(
      pg.connection_failed(res('connection to server at "127.0.0.1", port 15122 failed: timeout expired', false)),
      true
    )
    H.eq(pg.connection_failed(res("could not connect to server: Connection refused", false)), true)
    H.eq(pg.connection_failed(res("server closed the connection unexpectedly", false)), true)
  end)
  H.it("leaves other failures alone", function()
    H.eq(pg.connection_failed(res('relation "x" does not exist', false)), false)
    H.eq(pg.connection_failed(res("server closed the connection unexpectedly", true)), false)
    H.eq(pg.connection_failed(res(nil, true)), false)
  end)
end)

H.describe("postgres integration", function()
  H.it("runs statements and returns rows, tags and timing", function()
    local result
    pg.run(conn, {
      { sql = "select 1 as a, null as b, E'x\\ny' as c", kind = "select", class = "read", line = 1 },
      { sql = "create temp table dbgrid_t(a int)", kind = "create", class = "ddl", line = 2 },
      { sql = "insert into dbgrid_t values (1),(2)", kind = "insert", class = "write", line = 3 },
      { sql = "select count(*) from dbgrid_t", kind = "select", class = "read", line = 4 },
    }, {}, function(r)
      result = r
    end)
    H.truthy(
      H.wait(10000, function()
        return result ~= nil
      end),
      "timed out"
    )
    H.eq(result.ok, true, vim.inspect(result.error))
    H.eq(result.statements[1].sets[1].columns, { "a", "b", "c" })
    H.eq(result.statements[1].sets[1].rows, { { "1", vim.NIL, "x\ny" } })
    H.eq(result.statements[2].tags, { "CREATE TABLE" })
    H.eq(result.statements[3].tags, { "INSERT 0 2" })
    H.eq(result.statements[4].sets[1].rows, { { "2" } })
    H.truthy(result.server_ms > 0)
    H.truthy(result.elapsed_ms > 0)
  end)

  H.it("reports errors with statement and line", function()
    local result
    pg.run(conn, {
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
    H.matches(result.error.message, "nope")
    H.eq(result.statements[3].ran, false)
  end)

  H.it("explains and fetches the schema", function()
    local plans
    pg.explain(conn, {
      { sql = "select * from users where balance > 5", kind = "select", class = "read", line = 1 },
      { sql = "select * from nope_table", kind = "select", class = "read", line = 2 },
    }, function(p)
      plans = p
    end)
    H.truthy(H.wait(10000, function()
      return plans ~= nil
    end))
    H.eq(plans[1][1].Plan["Node Type"], "Seq Scan")
    H.eq(plans[2], nil)

    local schema, err
    pg.schema(conn, function(s, e)
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
    H.eq(users.columns[2].name, "email")
    H.truthy(#users.indexes >= 2)
    H.eq(users.indexes[1].columns, { "id" })
  end)

  H.it("produces text plans, including analyze inside a rolled back tx", function()
    local lines, err
    pg.explain_text(conn, "delete from users where id = -1", true, function(l, e)
      lines, err = l, e
    end)
    H.truthy(H.wait(10000, function()
      return lines ~= nil
    end))
    H.eq(err, nil)
    H.matches(table.concat(lines, "\n"), "Delete on users")
  end)
end)

H.describe("explain.warnings", function()
  local explain = require("dbgrid.explain")
  H.it("flags seq scans on big tables and suggests an index", function()
    local schema = require("dbgrid.schema")
    local data = {
      tables = {
        {
          schema = "public",
          name = "users",
          rows = 1000000,
          columns = { { name = "id" }, { name = "email" } },
          indexes = {},
          constraints = {},
        },
      },
    }
    data.by_name = { users = data.tables[1], ["public.users"] = data.tables[1] }
    local plan = {
      {
        Plan = {
          ["Node Type"] = "Seq Scan",
          ["Relation Name"] = "users",
          Filter = "(email = 'x'::text)",
          ["Plan Rows"] = 1,
        },
      },
    }
    local w = explain.warnings(plan, data, { min_rows = 10000 })
    H.eq(#w, 1)
    H.matches(w[1].message, "Seq Scan on users")
    H.eq(w[1].suggestion, "CREATE INDEX ON users (email);")
    H.eq(#explain.warnings(plan, data, { min_rows = 10000000 }), 0)
    H.truthy(schema.find_table(data, "USERS"))
    -- an index scan that only serves ORDER BY still filters every row
    local ordered = {
      {
        Plan = {
          ["Node Type"] = "Index Scan",
          ["Index Name"] = "users_created_at_idx",
          ["Relation Name"] = "users",
          Filter = "(balance > 5)",
          ["Plan Rows"] = 19000,
        },
      },
    }
    data.tables[1].columns[3] = { name = "balance" }
    local w2 = explain.warnings(ordered, data, { min_rows = 10000 })
    H.eq(#w2, 1)
    H.matches(w2[1].message, "only orders rows")
    H.eq(w2[1].suggestion, "CREATE INDEX ON users (balance);")
    -- aggregates over a whole table are not a missing index
    local aggregate = {
      {
        Plan = {
          ["Node Type"] = "Aggregate",
          Plans = { { ["Node Type"] = "Seq Scan", ["Relation Name"] = "users", ["Plan Rows"] = 1000000 } },
        },
      },
    }
    H.eq(#explain.warnings(aggregate, data, { min_rows = 10000 }), 0)
    -- ... but a seq scan repeated inside a nested loop is
    local loop = {
      {
        Plan = {
          ["Node Type"] = "Nested Loop",
          Plans = {
            { ["Node Type"] = "Seq Scan", ["Relation Name"] = "plans", ["Plan Rows"] = 3 },
            { ["Node Type"] = "Seq Scan", ["Relation Name"] = "users", ["Plan Rows"] = 1000000 },
          },
        },
      },
    }
    local w3 = explain.warnings(loop, data, { min_rows = 10000 })
    H.eq(#w3, 1)
    H.matches(w3[1].message, "nested loop")
    local covered = {
      {
        Plan = {
          ["Node Type"] = "Index Scan",
          ["Index Name"] = "x",
          ["Relation Name"] = "users",
          ["Index Cond"] = "(id = 1)",
          Filter = "(balance > 5)",
          ["Plan Rows"] = 1,
        },
      },
    }
    H.eq(#explain.warnings(covered, data, { min_rows = 10000 }), 0)
  end)
end)
