-- Plan analysis: turn EXPLAIN (FORMAT JSON) output into human warnings about
-- missing indexes.
local util = require("dbgrid.util")

local M = {}

---@class dbgrid.PlanWarning
---@field message string
---@field relation string
---@field rows integer?
---@field filter string?
---@field suggestion string?
---@field node table

---Walk every node of a plan tree.
---@param node table
---@param fn fun(node: table, parent?: table)
---@param parent? table
local function walk(node, fn, parent)
  if type(node) ~= "table" then
    return
  end
  fn(node, parent)
  for _, child in ipairs(node.Plans or {}) do
    walk(child, fn, node)
  end
end

---Column names (of `columns`) that appear in a filter expression.
---@param filter string
---@param columns string[]
---@return string[]
local function filter_columns(filter, columns)
  local set = {}
  for _, c in ipairs(columns) do
    set[c:lower()] = c
  end
  local found = {}
  for word in filter:gmatch("[%a_][%w_]*") do
    local col = set[word:lower()]
    if col and not vim.tbl_contains(found, col) then
      found[#found + 1] = col
    end
  end
  return found
end

---@param plan table   decoded EXPLAIN JSON (an array with one {Plan=...} element), or a SQLite plan
---@param schema? table  schema cache (dbgrid.schema.Data) for row counts and columns
---@param opts { min_rows: integer, sql?: string }
---@return dbgrid.PlanWarning[]
function M.warnings(plan, schema, opts)
  opts = opts or { min_rows = 10000 }
  if type(plan) == "table" and plan.sqlite then
    return M.sqlite_warnings(plan, schema, opts)
  end
  local root = type(plan) == "table" and plan[1] and plan[1].Plan or (plan and plan.Plan)
  if not root then
    return {}
  end
  local out = {}
  local seen = {}
  walk(root, function(node, parent)
    local ntype = node["Node Type"]
    local rel = node["Relation Name"]
    if not rel then
      return
    end
    -- an index scan without an index condition only walks the index for
    -- ordering; the filter is still applied to every row
    local index_only_orders = (ntype == "Index Scan" or ntype == "Index Only Scan")
      and node.Filter
      and not node["Index Cond"]
    if ntype ~= "Seq Scan" and not index_only_orders then
      return
    end
    -- a seq scan without a filter is inherent to the query (aggregate over the
    -- whole table, hash join build side) unless it sits inside a nested loop,
    -- where it is repeated for every outer row: that is a missing join index
    local in_nested_loop = parent and parent["Node Type"] == "Nested Loop"
    if ntype == "Seq Scan" and not node.Filter and not in_nested_loop then
      return
    end
    local key = rel .. "|" .. tostring(node.Filter)
    if seen[key] then
      return
    end
    seen[key] = true
    local table_info = schema and require("dbgrid.schema").find_table(schema, rel, node.Schema)
    local rows = table_info and table_info.rows or node["Plan Rows"] or 0
    -- a seq scan with no filter is a full-table read; only worth a warning when big
    if rows < (opts.min_rows or 0) then
      return
    end
    local name = (
      node.Schema and (node.Schema .. ".")
      or (table_info and not require("dbgrid.schema").is_default_schema(table_info.schema) and (table_info.schema .. "."))
      or ""
    ) .. rel
    local cols = {}
    if node.Filter and table_info then
      cols = filter_columns(
        node.Filter,
        vim.tbl_map(function(c)
          return c.name
        end, table_info.columns or {})
      )
    end
    local msg
    local suggestion
    if #cols > 0 then
      suggestion = string.format("CREATE INDEX ON %s (%s);", name, table.concat(cols, ", "))
    end
    if index_only_orders then
      msg = string.format(
        "Index Scan on %s using %s (~%s rows) only orders rows; filter %s has no index",
        name,
        tostring(node["Index Name"]),
        util.fmt_int(rows),
        node.Filter
      )
      if suggestion then
        msg = msg .. " — consider " .. suggestion
      end
    else
      msg = string.format("Seq Scan on %s (~%s rows)", name, util.fmt_int(rows))
      if node.Filter then
        msg = msg .. " filter " .. node.Filter
      end
      if suggestion then
        msg = msg .. " — no index used; consider " .. suggestion
      elseif node.Filter then
        msg = msg .. " — no index used for this filter"
      else
        msg = msg .. " — repeated for every row of the nested loop; the join column has no usable index"
      end
    end
    out[#out + 1] = {
      message = msg,
      relation = name,
      rows = rows,
      filter = node.Filter,
      suggestion = suggestion,
      node = node,
    }
  end)
  return out
end

---Total estimated cost of a plan.
---@param plan table
---@return number?
function M.total_cost(plan)
  local root = type(plan) == "table" and plan[1] and plan[1].Plan
  return root and root["Total Cost"] or nil
end

---Warnings for a SQLite `EXPLAIN QUERY PLAN` tree: a full table scan
---("SCAN t" without an index) on a big table that the statement filters.
---@param plan { sqlite: boolean, nodes: { depth: integer, detail: string }[] }
---@param schema? table
---@param opts { min_rows: integer, sql?: string }
---@return dbgrid.PlanWarning[]
function M.sqlite_warnings(plan, schema, opts)
  local out, seen = {}, {}
  for _, node in ipairs(plan.nodes or {}) do
    local rel = node.detail:match('^SCAN ([%w_"]+)$') or node.detail:match('^SCAN ([%w_"]+) AS')
    if rel and not node.detail:find("USING", 1, true) and not seen[rel] then
      seen[rel] = true
      local table_info = schema and require("dbgrid.schema").find_table(schema, rel)
      local rows = table_info and table_info.rows or 0
      if rows >= (opts.min_rows or 0) then
        local cols = {}
        if opts.sql and table_info then
          cols = require("dbgrid.sql").where_columns(
            opts.sql,
            vim.tbl_map(function(c)
              return c.name
            end, table_info.columns or {})
          )
        end
        local name = table_info and table_info.name or rel
        local suggestion = #cols > 0 and string.format("CREATE INDEX ON %s (%s);", name, table.concat(cols, ", "))
          or nil
        local msg = string.format("Full scan of %s (~%s rows) — no index used", name, util.fmt_int(rows))
        if suggestion then
          msg = msg .. "; consider " .. suggestion
        end
        out[#out + 1] = { message = msg, relation = name, rows = rows, suggestion = suggestion, node = node }
      end
    end
  end
  return out
end

---@class dbgrid.PlanFinding
---@field message string
---@field severity "warn"|"info"
---@field suggestion string?
---@field node table?

local function fmt_num(n)
  if n == nil then
    return "?"
  end
  if n >= 100 then
    return util.fmt_int(n)
  end
  return tostring(n)
end

---Short label for a node ("Seq Scan on users", "Hash Join").
---@param node table
local function node_label(node)
  local ntype = node["Node Type"] or "?"
  if ntype == "ModifyTable" then
    ntype = tostring(node.Operation or "Modify")
  end
  if node["Relation Name"] then
    return ntype .. " on " .. node["Relation Name"]
  end
  if node["Index Name"] and not node["Relation Name"] then
    return ntype .. " using " .. node["Index Name"]
  end
  return ntype
end

---What an EXPLAIN ANALYZE plan reveals: row estimates that were far off,
---sorts and hashes that spilled to disk, filters that discard almost
---everything, nested loops repeating a scan, and where the time went.
---@param plan table   decoded EXPLAIN (ANALYZE, FORMAT JSON)
---@param opts? { estimate_ratio?: number, min_rows?: integer, schema?: table }
---@return dbgrid.PlanFinding[]
function M.analyze_findings(plan, opts)
  opts = opts or {}
  local function index_suggestion(node)
    if not node["Relation Name"] or not node.Filter then
      return nil
    end
    local tbl = opts.schema and require("dbgrid.schema").find_table(opts.schema, node["Relation Name"], node.Schema)
    local cols = tbl
        and filter_columns(
          node.Filter,
          vim.tbl_map(function(c)
            return c.name
          end, tbl.columns or {})
        )
      or {}
    if #cols == 0 then
      return "CREATE INDEX ON " .. node["Relation Name"] .. " (<filter columns>);"
    end
    return string.format("CREATE INDEX ON %s (%s);", node["Relation Name"], table.concat(cols, ", "))
  end
  local ratio_limit = opts.estimate_ratio or 10
  local min_rows = opts.min_rows or 1000
  local root = type(plan) == "table" and plan[1] and plan[1].Plan
  if not root or root["Actual Rows"] == nil then
    return {}
  end
  local out = {}
  local function add(severity, message, node, suggestion)
    out[#out + 1] = { severity = severity, message = message, node = node, suggestion = suggestion }
  end
  local total = (root["Actual Total Time"] or 0) * (root["Actual Loops"] or 1)
  local hot -- { node, self_ms }
  walk(root, function(node, parent)
    local loops = node["Actual Loops"] or 1
    local est, act = node["Plan Rows"], node["Actual Rows"]
    if est and act and loops > 0 then
      local big = math.max(est, act)
      if big >= min_rows then
        local r = (act + 1) / (est + 1)
        if r >= ratio_limit or r <= 1 / ratio_limit then
          local factor = r >= 1 and r or 1 / r
          local dir = r >= 1 and "under" or "over"
          local suggestion
          if node["Relation Name"] then
            suggestion = string.format("ANALYZE %s;", node["Relation Name"])
          end
          add(
            "warn",
            string.format(
              "%s: planner expected %s rows, got %s (%d× %s-estimated%s)",
              node_label(node),
              fmt_num(est),
              fmt_num(act),
              math.floor(factor + 0.5),
              dir,
              node["Relation Name"] and "; statistics may be stale" or "; join or filter selectivity misjudged"
            ),
            node,
            suggestion or "CREATE STATISTICS on the correlated columns, or rewrite the join"
          )
        end
      end
    end
    if node["Sort Space Type"] == "Disk" then
      add(
        "warn",
        string.format(
          "%s spilled to disk (%s kB); raise work_mem or add an index on %s",
          node_label(node),
          fmt_num(node["Sort Space Used"] or 0),
          type(node["Sort Key"]) == "table" and table.concat(node["Sort Key"], ", ") or "the sort key"
        ),
        node,
        "SET work_mem = '64MB';"
      )
    end
    if (node["Hash Batches"] or 1) > 1 then
      add(
        "warn",
        string.format(
          "%s used %d batches: the hash table did not fit in work_mem",
          node_label(node),
          node["Hash Batches"]
        ),
        node,
        "SET work_mem = '64MB';"
      )
    end
    if (node["HashAgg Batches"] or 1) > 1 or (node["Disk Usage"] or 0) > 0 then
      add(
        "warn",
        string.format("%s spilled to disk (%s kB)", node_label(node), fmt_num(node["Disk Usage"] or 0)),
        node,
        "SET work_mem = '64MB';"
      )
    end
    local removed = node["Rows Removed by Filter"]
    if removed and removed >= min_rows and act then
      local read = removed + act
      if removed / read >= 0.9 then
        add(
          "warn",
          string.format(
            "%s reads %s rows to keep %s (%d%% discarded by filter %s)",
            node_label(node),
            fmt_num(read * loops),
            fmt_num(act * loops),
            math.floor(removed / read * 100 + 0.5),
            tostring(node.Filter or "")
          ),
          node,
          index_suggestion(node)
        )
      end
    end
    if parent and parent["Node Type"] == "Nested Loop" and loops >= 100 and node["Node Type"] == "Seq Scan" then
      add(
        "warn",
        string.format(
          "%s repeated %s times inside a nested loop; the join column has no usable index",
          node_label(node),
          fmt_num(loops)
        ),
        node,
        node["Relation Name"] and ("CREATE INDEX ON " .. node["Relation Name"] .. " (<join column>);") or nil
      )
    end
    -- time spent in this node alone
    local own = (node["Actual Total Time"] or 0) * loops
    for _, child in ipairs(node.Plans or {}) do
      own = own - (child["Actual Total Time"] or 0) * (child["Actual Loops"] or 1)
    end
    if not hot or own > hot.self_ms then
      hot = { node = node, self_ms = own }
    end
  end)
  if hot and total >= 10 and hot.self_ms / total >= 0.5 then
    add(
      "info",
      string.format(
        "%d%% of the time (%s) is spent in %s",
        math.floor(hot.self_ms / total * 100 + 0.5),
        util.fmt_ms(hot.self_ms),
        node_label(hot.node)
      ),
      hot.node
    )
  end
  local temp = (root["Temp Written Blocks"] or 0)
  if temp > 0 then
    add("info", string.format("%s temp blocks written (work_mem overflow somewhere in the plan)", fmt_num(temp)), root)
  end
  return out
end

---Render a plan as indented text (one node per line). For EXPLAIN ANALYZE
---plans the actual rows and time are added and estimates that were far off
---are called out. The second value maps line numbers to highlight groups.
---@param plan table   Postgres JSON plan or SQLite plan
---@param opts? { estimate_ratio?: number }
---@return string[] lines, table<integer, string> marks
function M.to_lines(plan, opts)
  opts = opts or {}
  local lines, marks = {}, {}
  if type(plan) == "table" and plan.sqlite then
    for _, node in ipairs(plan.nodes or {}) do
      lines[#lines + 1] = string.rep("  ", node.depth or 0) .. ((node.depth or 0) > 0 and "-> " or "") .. node.detail
      if node.detail:match("^SCAN ") and not node.detail:find("USING", 1, true) then
        marks[#lines] = "DbgridWarn"
      end
    end
    return lines, marks
  end
  local root = type(plan) == "table" and plan[1] and plan[1].Plan
  if not root then
    return lines, marks
  end
  local ratio_limit = opts.estimate_ratio or 10
  local function fmt(node, depth)
    local parts = { node_label(node) }
    if node["Relation Name"] and node.Alias and node.Alias ~= node["Relation Name"] then
      parts[#parts + 1] = node.Alias
    end
    if node["Index Name"] and node["Relation Name"] then
      parts[#parts + 1] = "using " .. node["Index Name"]
    end
    if node["Join Type"] then
      parts[#parts + 1] = "(" .. node["Join Type"] .. ")"
    end
    if node.Strategy and node["Node Type"] == "Aggregate" then
      parts[#parts + 1] = "(" .. tostring(node.Strategy) .. ")"
    end
    parts[#parts + 1] = string.format(
      "(cost=%.2f..%.2f rows=%s width=%s)",
      node["Startup Cost"] or 0,
      node["Total Cost"] or 0,
      tostring(node["Plan Rows"]),
      tostring(node["Plan Width"])
    )
    local hl
    if node["Actual Rows"] ~= nil then
      parts[#parts + 1] = string.format(
        "(actual time=%.3f..%.3f rows=%s loops=%s)",
        node["Actual Startup Time"] or 0,
        node["Actual Total Time"] or 0,
        tostring(node["Actual Rows"]),
        tostring(node["Actual Loops"] or 1)
      )
      local est, act = node["Plan Rows"] or 0, node["Actual Rows"] or 0
      if math.max(est, act) >= 1000 then
        local r = (act + 1) / (est + 1)
        if r >= ratio_limit then
          parts[#parts + 1] = string.format("⚠ %d× under-estimated", math.floor(r + 0.5))
          hl = "DbgridWarn"
        elseif r <= 1 / ratio_limit then
          parts[#parts + 1] = string.format("⚠ %d× over-estimated", math.floor(1 / r + 0.5))
          hl = "DbgridWarn"
        end
      end
    end
    lines[#lines + 1] = string.rep("  ", depth) .. (depth > 0 and "-> " or "") .. table.concat(parts, " ")
    if not hl and node["Node Type"] == "Seq Scan" then
      hl = "DbgridWarn"
    end
    if hl then
      marks[#lines] = hl
    end
    local pad = string.rep("  ", depth) .. (depth > 0 and "   " or "")
    for _, k in ipairs({
      "Filter",
      "Index Cond",
      "Recheck Cond",
      "Hash Cond",
      "Merge Cond",
      "Join Filter",
      "Sort Key",
      "Group Key",
      "Rows Removed by Filter",
      "Rows Removed by Join Filter",
      "Sort Method",
      "Hash Batches",
    }) do
      if node[k] ~= nil then
        local v = node[k]
        if type(v) == "table" then
          v = table.concat(v, ", ")
        end
        if k == "Sort Method" then
          v = tostring(v)
            .. "  "
            .. tostring(node["Sort Space Type"] or "")
            .. ": "
            .. tostring(node["Sort Space Used"] or "?")
            .. "kB"
          if node["Sort Space Type"] == "Disk" then
            marks[#lines + 1] = "DbgridWarn"
          end
        elseif k == "Hash Batches" then
          if v == 1 then
            v = nil
          else
            marks[#lines + 1] = "DbgridWarn"
          end
        end
        if v ~= nil then
          lines[#lines + 1] = pad .. k .. ": " .. tostring(v)
        end
      end
    end
    for _, child in ipairs(node.Plans or {}) do
      fmt(child, depth + 1)
    end
  end
  fmt(root, 0)
  local top = plan[1]
  if top["Planning Time"] or top["Execution Time"] then
    lines[#lines + 1] = ""
    if top["Planning Time"] then
      lines[#lines + 1] = string.format("Planning Time: %.3f ms", top["Planning Time"])
    end
    if top["Execution Time"] then
      lines[#lines + 1] = string.format("Execution Time: %.3f ms", top["Execution Time"])
    end
  end
  return lines, marks
end

return M
