local H = _G.H
local explain = require("dbgrid.explain")

-- Plans recorded from the seed database (tests/seed.sql) with
--   psql -At -c "EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT JSON) <query>"

-- select * from users where balance > 5 order by email
local FILTERED = vim.json.decode([[
[
  {
    "Plan": {
      "Node Type": "Sort",
      "Parallel Aware": false,
      "Async Capable": false,
      "Startup Cost": 416.49,
      "Total Cost": 428.98,
      "Plan Rows": 4997,
      "Plan Width": 74,
      "Actual Startup Time": 1.589,
      "Actual Total Time": 1.799,
      "Actual Rows": 4997,
      "Actual Loops": 1,
      "Output": ["id", "email", "plan_id", "balance", "created_at", "note"],
      "Sort Key": ["users.email"],
      "Sort Method": "quicksort",
      "Sort Space Used": 544,
      "Sort Space Type": "Memory",
      "Shared Hit Blocks": 50,
      "Shared Read Blocks": 0,
      "Shared Dirtied Blocks": 0,
      "Shared Written Blocks": 0,
      "Local Hit Blocks": 0,
      "Local Read Blocks": 0,
      "Local Dirtied Blocks": 0,
      "Local Written Blocks": 0,
      "Temp Read Blocks": 0,
      "Temp Written Blocks": 0,
      "Plans": [
        {
          "Node Type": "Seq Scan",
          "Parent Relationship": "Outer",
          "Parallel Aware": false,
          "Async Capable": false,
          "Relation Name": "users",
          "Schema": "public",
          "Alias": "users",
          "Startup Cost": 0.00,
          "Total Cost": 109.50,
          "Plan Rows": 4997,
          "Plan Width": 74,
          "Actual Startup Time": 0.006,
          "Actual Total Time": 0.627,
          "Actual Rows": 4997,
          "Actual Loops": 1,
          "Output": ["id", "email", "plan_id", "balance", "created_at", "note"],
          "Filter": "(users.balance > '5'::numeric)",
          "Rows Removed by Filter": 3,
          "Shared Hit Blocks": 47,
          "Shared Read Blocks": 0,
          "Shared Dirtied Blocks": 0,
          "Shared Written Blocks": 0,
          "Local Hit Blocks": 0,
          "Local Read Blocks": 0,
          "Local Dirtied Blocks": 0,
          "Local Written Blocks": 0,
          "Temp Read Blocks": 0,
          "Temp Written Blocks": 0
        }
      ]
    },
    "Query Identifier": 1562840960959172348,
    "Planning": {
      "Shared Hit Blocks": 122,
      "Shared Read Blocks": 0,
      "Shared Dirtied Blocks": 0,
      "Shared Written Blocks": 0,
      "Local Hit Blocks": 0,
      "Local Read Blocks": 0,
      "Local Dirtied Blocks": 0,
      "Local Written Blocks": 0,
      "Temp Read Blocks": 0,
      "Temp Written Blocks": 0
    },
    "Planning Time": 0.312,
    "Triggers": [
    ],
    "Execution Time": 2.012
  }
]
]])

-- select count(*) from users u join plans p on p.id = u.plan_id
local JOIN = vim.json.decode([[
[
  {
    "Plan": {
      "Node Type": "Aggregate",
      "Strategy": "Plain",
      "Partial Mode": "Simple",
      "Parallel Aware": false,
      "Async Capable": false,
      "Startup Cost": 142.24,
      "Total Cost": 142.25,
      "Plan Rows": 1,
      "Plan Width": 8,
      "Actual Startup Time": 1.406,
      "Actual Total Time": 1.408,
      "Actual Rows": 1,
      "Actual Loops": 1,
      "Output": ["count(*)"],
      "Shared Hit Blocks": 48,
      "Shared Read Blocks": 0,
      "Shared Dirtied Blocks": 0,
      "Shared Written Blocks": 0,
      "Local Hit Blocks": 0,
      "Local Read Blocks": 0,
      "Local Dirtied Blocks": 0,
      "Local Written Blocks": 0,
      "Temp Read Blocks": 0,
      "Temp Written Blocks": 0,
      "Plans": [
        {
          "Node Type": "Hash Join",
          "Parent Relationship": "Outer",
          "Parallel Aware": false,
          "Async Capable": false,
          "Join Type": "Inner",
          "Startup Cost": 1.07,
          "Total Cost": 129.74,
          "Plan Rows": 5000,
          "Plan Width": 0,
          "Actual Startup Time": 0.033,
          "Actual Total Time": 1.111,
          "Actual Rows": 5000,
          "Actual Loops": 1,
          "Inner Unique": true,
          "Hash Cond": "(u.plan_id = p.id)",
          "Shared Hit Blocks": 48,
          "Shared Read Blocks": 0,
          "Shared Dirtied Blocks": 0,
          "Shared Written Blocks": 0,
          "Local Hit Blocks": 0,
          "Local Read Blocks": 0,
          "Local Dirtied Blocks": 0,
          "Local Written Blocks": 0,
          "Temp Read Blocks": 0,
          "Temp Written Blocks": 0,
          "Plans": [
            {
              "Node Type": "Seq Scan",
              "Parent Relationship": "Outer",
              "Parallel Aware": false,
              "Async Capable": false,
              "Relation Name": "users",
              "Schema": "public",
              "Alias": "u",
              "Startup Cost": 0.00,
              "Total Cost": 97.00,
              "Plan Rows": 5000,
              "Plan Width": 4,
              "Actual Startup Time": 0.003,
              "Actual Total Time": 0.331,
              "Actual Rows": 5000,
              "Actual Loops": 1,
              "Output": ["u.id", "u.email", "u.plan_id", "u.balance", "u.created_at", "u.note"],
              "Shared Hit Blocks": 47,
              "Shared Read Blocks": 0,
              "Shared Dirtied Blocks": 0,
              "Shared Written Blocks": 0,
              "Local Hit Blocks": 0,
              "Local Read Blocks": 0,
              "Local Dirtied Blocks": 0,
              "Local Written Blocks": 0,
              "Temp Read Blocks": 0,
              "Temp Written Blocks": 0
            },
            {
              "Node Type": "Hash",
              "Parent Relationship": "Inner",
              "Parallel Aware": false,
              "Async Capable": false,
              "Startup Cost": 1.03,
              "Total Cost": 1.03,
              "Plan Rows": 3,
              "Plan Width": 4,
              "Actual Startup Time": 0.012,
              "Actual Total Time": 0.012,
              "Actual Rows": 3,
              "Actual Loops": 1,
              "Output": ["p.id"],
              "Hash Buckets": 1024,
              "Original Hash Buckets": 1024,
              "Hash Batches": 1,
              "Original Hash Batches": 1,
              "Peak Memory Usage": 9,
              "Shared Hit Blocks": 1,
              "Shared Read Blocks": 0,
              "Shared Dirtied Blocks": 0,
              "Shared Written Blocks": 0,
              "Local Hit Blocks": 0,
              "Local Read Blocks": 0,
              "Local Dirtied Blocks": 0,
              "Local Written Blocks": 0,
              "Temp Read Blocks": 0,
              "Temp Written Blocks": 0,
              "Plans": [
                {
                  "Node Type": "Seq Scan",
                  "Parent Relationship": "Outer",
                  "Parallel Aware": false,
                  "Async Capable": false,
                  "Relation Name": "plans",
                  "Schema": "public",
                  "Alias": "p",
                  "Startup Cost": 0.00,
                  "Total Cost": 1.03,
                  "Plan Rows": 3,
                  "Plan Width": 4,
                  "Actual Startup Time": 0.002,
                  "Actual Total Time": 0.003,
                  "Actual Rows": 3,
                  "Actual Loops": 1,
                  "Output": ["p.id"],
                  "Shared Hit Blocks": 1,
                  "Shared Read Blocks": 0,
                  "Shared Dirtied Blocks": 0,
                  "Shared Written Blocks": 0,
                  "Local Hit Blocks": 0,
                  "Local Read Blocks": 0,
                  "Local Dirtied Blocks": 0,
                  "Local Written Blocks": 0,
                  "Temp Read Blocks": 0,
                  "Temp Written Blocks": 0
                }
              ]
            }
          ]
        }
      ]
    },
    "Query Identifier": -3340438645186105747,
    "Planning": {
      "Shared Hit Blocks": 229,
      "Shared Read Blocks": 0,
      "Shared Dirtied Blocks": 0,
      "Shared Written Blocks": 0,
      "Local Hit Blocks": 0,
      "Local Read Blocks": 0,
      "Local Dirtied Blocks": 0,
      "Local Written Blocks": 0,
      "Temp Read Blocks": 0,
      "Temp Written Blocks": 0
    },
    "Planning Time": 0.592,
    "Triggers": [
    ],
    "Execution Time": 1.494
  }
]
]])

-- set work_mem = '64kB'; explain (analyze, buffers, format json) select * from users order by email
local SPILL = vim.json.decode([[
[
  {
    "Plan": {
      "Node Type": "Sort",
      "Parallel Aware": false,
      "Async Capable": false,
      "Startup Cost": 852.19,
      "Total Cost": 864.69,
      "Plan Rows": 5000,
      "Plan Width": 74,
      "Actual Startup Time": 1.918,
      "Actual Total Time": 2.308,
      "Actual Rows": 5000,
      "Actual Loops": 1,
      "Sort Key": ["email"],
      "Sort Method": "external merge",
      "Sort Space Used": 328,
      "Sort Space Type": "Disk",
      "Shared Hit Blocks": 50,
      "Shared Read Blocks": 0,
      "Shared Dirtied Blocks": 0,
      "Shared Written Blocks": 0,
      "Local Hit Blocks": 0,
      "Local Read Blocks": 0,
      "Local Dirtied Blocks": 0,
      "Local Written Blocks": 0,
      "Temp Read Blocks": 78,
      "Temp Written Blocks": 86,
      "Plans": [
        {
          "Node Type": "Seq Scan",
          "Parent Relationship": "Outer",
          "Parallel Aware": false,
          "Async Capable": false,
          "Relation Name": "users",
          "Alias": "users",
          "Startup Cost": 0.00,
          "Total Cost": 97.00,
          "Plan Rows": 5000,
          "Plan Width": 74,
          "Actual Startup Time": 0.003,
          "Actual Total Time": 0.318,
          "Actual Rows": 5000,
          "Actual Loops": 1,
          "Shared Hit Blocks": 47,
          "Shared Read Blocks": 0,
          "Shared Dirtied Blocks": 0,
          "Shared Written Blocks": 0,
          "Local Hit Blocks": 0,
          "Local Read Blocks": 0,
          "Local Dirtied Blocks": 0,
          "Local Written Blocks": 0,
          "Temp Read Blocks": 0,
          "Temp Written Blocks": 0
        }
      ]
    },
    "Planning": {
      "Shared Hit Blocks": 115,
      "Shared Read Blocks": 0,
      "Shared Dirtied Blocks": 0,
      "Shared Written Blocks": 0,
      "Local Hit Blocks": 0,
      "Local Read Blocks": 0,
      "Local Dirtied Blocks": 0,
      "Local Written Blocks": 0,
      "Temp Read Blocks": 0,
      "Temp Written Blocks": 0
    },
    "Planning Time": 0.360,
    "Triggers": [
    ],
    "Execution Time": 2.619
  }
]
]])

-- explain (analyze, buffers, format json) select * from users where balance > 7000
-- (balance > 5 keeps 4,997 of 5,000 rows, so the filter rule needs a selective filter)
local SELECTIVE = vim.json.decode([[
[
  {
    "Plan": {
      "Node Type": "Seq Scan",
      "Parallel Aware": false,
      "Async Capable": false,
      "Relation Name": "users",
      "Alias": "users",
      "Startup Cost": 0.00,
      "Total Cost": 109.50,
      "Plan Rows": 333,
      "Plan Width": 74,
      "Actual Startup Time": 0.477,
      "Actual Total Time": 0.518,
      "Actual Rows": 334,
      "Actual Loops": 1,
      "Filter": "(balance > '7000'::numeric)",
      "Rows Removed by Filter": 4666,
      "Shared Hit Blocks": 47,
      "Shared Read Blocks": 0,
      "Shared Dirtied Blocks": 0,
      "Shared Written Blocks": 0,
      "Local Hit Blocks": 0,
      "Local Read Blocks": 0,
      "Local Dirtied Blocks": 0,
      "Local Written Blocks": 0,
      "Temp Read Blocks": 0,
      "Temp Written Blocks": 0
    },
    "Planning": {
      "Shared Hit Blocks": 92,
      "Shared Read Blocks": 0,
      "Shared Dirtied Blocks": 0,
      "Shared Written Blocks": 0,
      "Local Hit Blocks": 0,
      "Local Read Blocks": 0,
      "Local Dirtied Blocks": 0,
      "Local Written Blocks": 0,
      "Temp Read Blocks": 0,
      "Temp Written Blocks": 0
    },
    "Planning Time": 0.346,
    "Triggers": [
    ],
    "Execution Time": 0.553
  }
]
]])

-- EXPLAIN (FORMAT JSON) select * from users where balance > 5 order by email
local ESTIMATE = vim.json.decode([[
[
  {
    "Plan": {
      "Node Type": "Sort",
      "Parallel Aware": false,
      "Async Capable": false,
      "Startup Cost": 416.49,
      "Total Cost": 428.98,
      "Plan Rows": 4997,
      "Plan Width": 74,
      "Sort Key": ["email"],
      "Plans": [
        {
          "Node Type": "Seq Scan",
          "Parent Relationship": "Outer",
          "Parallel Aware": false,
          "Async Capable": false,
          "Relation Name": "users",
          "Alias": "users",
          "Startup Cost": 0.00,
          "Total Cost": 109.50,
          "Plan Rows": 4997,
          "Plan Width": 74,
          "Filter": "(balance > '5'::numeric)"
        }
      ]
    }
  }
]
]])

local function kinds(findings)
  return vim.tbl_map(function(f)
    return f.kind
  end, findings)
end

H.describe("explain.relations / summary", function()
  H.it("lists relations once, in tree order", function()
    H.eq(explain.relations(JOIN), {
      { name = "users", schema = "public", alias = "u" },
      { name = "plans", schema = "public", alias = "p" },
    })
    H.eq(explain.relations(ESTIMATE), { { name = "users", alias = "users" } })
    H.eq(explain.relations({}), {})
    H.eq(explain.relations(nil), {})
  end)
  H.it("summarises times and cost", function()
    H.eq(explain.summary(FILTERED), { analyzed = true, execution_ms = 2.012, planning_ms = 0.312, total_cost = 428.98 })
    H.eq(explain.summary(ESTIMATE), { analyzed = false, total_cost = 428.98 })
    H.eq(explain.summary({}), { analyzed = false })
  end)
end)

H.describe("explain.hypopg", function()
  H.it("builds the script and measures the cost change", function()
    H.eq(explain.hypopg_script("create index on users (email);", "select * from users where email = 'x'"), {
      "select hypopg_reset()",
      "select indexrelid, indexname from hypopg_create_index('create index on users (email)')",
      "EXPLAIN (FORMAT JSON) select * from users where email = 'x'",
    })
    H.matches(explain.hypopg_script("create index on t (a) where b = 'it''s'", "select 1")[2], "'it''''s'")
    local after = vim.deepcopy(ESTIMATE)
    after[1].Plan["Total Cost"] = 214.49
    after[1].Plan.Plans[1]["Node Type"] = "Index Scan"
    after[1].Plan.Plans[1]["Index Name"] = "<13543>btree_users_balance"
    local d = explain.cost_delta(ESTIMATE, after)
    H.eq(d.before, 428.98)
    H.eq(d.after, 214.49)
    H.eq(d.used, true)
    H.eq(math.floor(d.pct + 0.5), -50)
    local unused = explain.cost_delta(ESTIMATE, ESTIMATE)
    H.eq(unused, { before = 428.98, after = 428.98, pct = 0, used = false })
    H.eq(explain.cost_delta({}, {}), { before = 0, after = 0, pct = 0, used = false })
  end)
end)
