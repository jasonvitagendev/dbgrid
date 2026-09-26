local H = _G.H
local explain = require("dbgrid.explain")

local function node(t)
  return t
end

H.describe("explain.analyze_findings", function()
  local plan = {
    {
      Plan = node({
        ["Node Type"] = "Sort",
        ["Plan Rows"] = 5000,
        ["Actual Rows"] = 80,
        ["Actual Loops"] = 1,
        ["Actual Total Time"] = 120,
        ["Sort Key"] = { "x" },
        ["Sort Method"] = "external merge",
        ["Sort Space Type"] = "Disk",
        ["Sort Space Used"] = 4096,
        ["Temp Written Blocks"] = 12,
        Plans = {
          node({
            ["Node Type"] = "Nested Loop",
            ["Plan Rows"] = 100,
            ["Actual Rows"] = 120000,
            ["Actual Loops"] = 1,
            ["Actual Total Time"] = 100,
            Plans = {
              node({
                ["Node Type"] = "Index Scan",
                ["Relation Name"] = "plans",
                ["Plan Rows"] = 3,
                ["Actual Rows"] = 3,
                ["Actual Loops"] = 1,
                ["Actual Total Time"] = 0.1,
              }),
              node({
                ["Node Type"] = "Seq Scan",
                ["Relation Name"] = "users",
                Filter = "(balance > 5)",
                ["Rows Removed by Filter"] = 40000,
                ["Plan Rows"] = 400,
                ["Actual Rows"] = 40000,
                ["Actual Loops"] = 3,
                ["Actual Total Time"] = 30,
              }),
            },
          }),
        },
      }),
      ["Planning Time"] = 0.5,
      ["Execution Time"] = 121,
    },
  }
  H.it("reports estimate errors, disk sorts, nested loop scans and the hot node", function()
    local schema = {
      by_name = { users = { name = "users", schema = "public", columns = { { name = "id" }, { name = "balance" } } } },
    }
    local findings = explain.analyze_findings(plan, { min_rows = 100, schema = schema })
    local messages = table.concat(
      vim.tbl_map(function(f)
        return f.severity .. ": " .. f.message .. (f.suggestion and (" -> " .. f.suggestion) or "")
      end, findings),
      "\n"
    )
    H.matches(messages, "Sort: planner expected 5,000 rows, got 80 %(62× over%-estimated")
    H.matches(messages, "Sort spilled to disk %(4,096 kB%)")
    H.matches(messages, "Nested Loop: planner expected 100 rows, got 120,000")
    H.matches(messages, "Seq Scan on users: planner expected 400 rows, got 40,000 .*ANALYZE users;")
    H.falsy(messages:find("reads 240,000 rows", 1, true), "a filter that keeps half the rows is not a finding")
    H.matches(messages, "temp blocks written")
    H.matches(messages, "info: %d+%% of the time")
    H.falsy(messages:find("repeated 3 times"), "3 loops is not a nested-loop problem")
  end)
  H.it("renders actual rows and flags bad estimates in the plan text", function()
    local lines, marks = explain.to_lines(plan)
    H.matches(lines[1], "^Sort %(cost=.* rows=5000 .*%) %(actual time=.* rows=80 loops=1%) ⚠ 62× over%-estimated$")
    H.eq(marks[1], "DbgridWarn")
    H.matches(table.concat(lines, "\n"), "Sort Method: external merge  Disk: 4096kB")
    H.matches(table.concat(lines, "\n"), "Execution Time: 121.000 ms")
    H.matches(table.concat(lines, "\n"), "Rows Removed by Filter: 40000")
    H.eq(#explain.analyze_findings({ { Plan = { ["Node Type"] = "Seq Scan", ["Plan Rows"] = 1 } } }), 0)
  end)
end)

H.describe("explain sqlite plans", function()
  H.it("renders and warns about full scans", function()
    local plan = {
      sqlite = true,
      nodes = {
        { depth = 0, detail = "SCAN users" },
        { depth = 1, detail = "SEARCH plans USING INTEGER PRIMARY KEY (rowid=?)" },
      },
    }
    local lines, marks = explain.to_lines(plan)
    H.eq(lines, { "SCAN users", "  -> SEARCH plans USING INTEGER PRIMARY KEY (rowid=?)" })
    H.eq(marks[1], "DbgridWarn")
    local schema = {
      by_name = {
        users = { name = "users", schema = "main", rows = 5000, columns = { { name = "id" }, { name = "balance" } } },
      },
    }
    local w = explain.warnings(plan, schema, { min_rows = 1000, sql = "select * from users where balance > 5" })
    H.eq(#w, 1)
    H.eq(w[1].suggestion, "CREATE INDEX ON users (balance);")
    H.matches(w[1].message, "Full scan of users %(~5,000 rows%)")
    H.eq(#explain.warnings(plan, schema, { min_rows = 10000 }), 0)
    H.eq(
      #explain.warnings(
        { sqlite = true, nodes = { { depth = 0, detail = "SCAN users USING COVERING INDEX x" } } },
        schema,
        { min_rows = 1 }
      ),
      0
    )
    H.eq(explain.total_cost(plan), nil)
  end)
end)
