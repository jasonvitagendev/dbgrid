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

---@param plan table   decoded EXPLAIN JSON (an array with one {Plan=...} element)
---@param schema? table  schema cache (dbgrid.schema.Data) for row counts and columns
---@param opts { min_rows: integer }
---@return dbgrid.PlanWarning[]
function M.warnings(plan, schema, opts)
  opts = opts or { min_rows = 10000 }
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
      or (table_info and table_info.schema ~= "public" and (table_info.schema .. "."))
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

---Root node and top-level element (times, triggers) of a decoded plan.
---@param plan table
---@return table? root, table? top
local function root_of(plan)
  if type(plan) ~= "table" then
    return nil, nil
  end
  local top = plan[1] or plan
  if type(top) ~= "table" or type(top.Plan) ~= "table" then
    return nil, nil
  end
  return top.Plan, top
end

---`users`, or `other_schema.users`, for a scan node; nil for the rest.
---@param node table
---@return string?
local function relation_of(node)
  local rel = node["Relation Name"]
  if not rel then
    return nil
  end
  if node.Schema and node.Schema ~= "public" then
    return node.Schema .. "." .. rel
  end
  return rel
end

---`Seq Scan on users` / `Hash Join`.
---@param node table
---@return string
local function node_label(node)
  local rel = relation_of(node)
  return tostring(node["Node Type"]) .. (rel and (" on " .. rel) or "")
end

---Relations a plan touches, unique by schema and name, in tree order.
---@param plan table
---@return { name: string, schema?: string, alias?: string }[]
function M.relations(plan)
  local root = root_of(plan)
  local out, seen = {}, {}
  walk(root, function(node)
    local name = node["Relation Name"]
    if name then
      local key = tostring(node.Schema) .. "." .. name
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = { name = name, schema = node.Schema, alias = node.Alias }
      end
    end
  end)
  return out
end

---@class dbgrid.PlanSummary
---@field execution_ms number?
---@field planning_ms number?
---@field total_cost number?
---@field analyzed boolean   true for EXPLAIN ANALYZE plans (nodes carry actual rows and times)

---@param plan table
---@return dbgrid.PlanSummary
function M.summary(plan)
  local root, top = root_of(plan)
  return {
    execution_ms = top and top["Execution Time"] or nil,
    planning_ms = top and top["Planning Time"] or nil,
    total_cost = root and root["Total Cost"] or nil,
    analyzed = root ~= nil and (root["Actual Rows"] ~= nil or root["Actual Total Time"] ~= nil),
  }
end

---@class dbgrid.PlanFinding
---@field kind "estimate"|"spill"|"hot"|"filter"
---@field message string
---@field node table
---@field relation string?
---@field severity "warn"|"info"

---Time a node spent over all of its loops, or nil without ANALYZE.
---@param node table
---@return number?
local function node_ms(node)
  local t = node["Actual Total Time"]
  if type(t) ~= "number" then
    return nil
  end
  return t * (node["Actual Loops"] or 1)
end

---Findings from an EXPLAIN ANALYZE plan: the hot node, bad row estimates,
---sorts and hashes that spilled to disk, filters that discard most rows.
---Empty for an estimate-only plan.
---@param plan table
---@param opts? { estimate_ratio?: number, min_rows?: integer }
---@return dbgrid.PlanFinding[]
function M.analyze_findings(plan, opts)
  opts = opts or {}
  local ratio_limit = opts.estimate_ratio or 10
  local min_rows = opts.min_rows or 1000
  local root, top = root_of(plan)
  if not root or root["Actual Rows"] == nil then
    return {}
  end
  local out = {}
  local function push(kind, node, severity, message)
    out[#out + 1] = { kind = kind, message = message, node = node, relation = relation_of(node), severity = severity }
  end

  -- hot: the node with the most exclusive time (its time minus its children's)
  local total_ms = top["Execution Time"] or node_ms(root) or 0
  if total_ms >= 1 then
    local hot, hot_ms = nil, -1
    walk(root, function(node)
      local own = node_ms(node)
      if own then
        for _, child in ipairs(node.Plans or {}) do
          own = own - (node_ms(child) or 0)
        end
        if own > hot_ms then
          hot, hot_ms = node, own
        end
      end
    end)
    if hot then
      local pct = math.min(100, math.floor(hot_ms / total_ms * 100 + 0.5))
      push(
        "hot",
        hot,
        "info",
        string.format("Most time (%.1f ms of %.1f ms, %d%%) is spent in %s", hot_ms, total_ms, pct, node_label(hot))
      )
    end
  end

  -- estimate: planned versus actual rows, both per loop
  walk(root, function(node)
    local planned, actual = node["Plan Rows"], node["Actual Rows"]
    if type(planned) == "number" and type(actual) == "number" then
      local ratio = math.max(actual, 1) / math.max(planned, 1)
      if (ratio >= ratio_limit or ratio <= 1 / ratio_limit) and math.max(actual, planned) >= min_rows then
        local rel = relation_of(node)
        local msg = string.format(
          "Planner expected %s rows and got %s on %s",
          util.fmt_int(planned),
          util.fmt_int(actual),
          node_label(node)
        )
        if rel then
          msg = msg .. string.format("; run ANALYZE %s to refresh statistics", rel)
        end
        push("estimate", node, "warn", msg)
      end
    end
  end)

  -- spill: work_mem was too small
  walk(root, function(node)
    local ntype = node["Node Type"]
    local method = node["Sort Method"]
    local external = type(method) == "string" and method:find("external", 1, true) ~= nil
    if ntype == "Sort" and (node["Sort Space Type"] == "Disk" or external) then
      push(
        "spill",
        node,
        "warn",
        string.format(
          "Sort of %s rows spilled to disk (%s kB); raise work_mem for this query",
          util.fmt_int(node["Actual Rows"] or 0),
          tostring(node["Sort Space Used"] or "?")
        )
      )
    elseif ntype == "Hash" and (node["Hash Batches"] or 1) > 1 then
      push(
        "spill",
        node,
        "warn",
        string.format("Hash join used %s batches (spilled to disk); raise work_mem", tostring(node["Hash Batches"]))
      )
    elseif ntype == "Aggregate" and ((node["HashAgg Batches"] or 1) > 1 or (node["Disk Usage"] or 0) > 0) then
      push(
        "spill",
        node,
        "warn",
        string.format("HashAggregate spilled to disk (%s kB); raise work_mem", tostring(node["Disk Usage"] or "?"))
      )
    end
  end)

  -- filter: rows read and thrown away
  walk(root, function(node)
    local actual = node["Actual Rows"] or 0
    local removed = node["Rows Removed by Filter"]
    if type(removed) == "number" and removed >= min_rows and removed > actual then
      push(
        "filter",
        node,
        "warn",
        string.format(
          "%s read %s rows to keep %s; the filter %s discards most of them "
            .. "(an index on the filtered columns would avoid the read)",
          node_label(node),
          util.fmt_int(removed + actual),
          util.fmt_int(actual),
          tostring(node.Filter)
        )
      )
    end
    local rechecked = node["Rows Removed by Index Recheck"]
    if type(rechecked) == "number" and rechecked >= min_rows and rechecked > actual then
      push(
        "filter",
        node,
        "info",
        string.format(
          "%s rechecked %s rows to keep %s; the bitmap was lossy (Rows Removed by Index Recheck), "
            .. "raise work_mem so it fits in memory",
          node_label(node),
          util.fmt_int(rechecked + actual),
          util.fmt_int(actual)
        )
      )
    end
  end)
  return out
end

local REMOVED_KEYS = { "Rows Removed by Filter", "Rows Removed by Index Recheck", "Rows Removed by Join Filter" }

---Buffer usage of a node as one line, or nil when no counter is above zero.
---@param node table
---@return string?
local function buffers_line(node)
  local hit, read = node["Shared Hit Blocks"] or 0, node["Shared Read Blocks"] or 0
  local dirtied, written = node["Shared Dirtied Blocks"] or 0, node["Shared Written Blocks"] or 0
  local temp_read, temp_written = node["Temp Read Blocks"] or 0, node["Temp Written Blocks"] or 0
  if hit + read + dirtied + written + temp_read + temp_written <= 0 then
    return nil
  end
  local s = string.format("Buffers: shared hit=%s read=%s", tostring(hit), tostring(read))
  if dirtied > 0 then
    s = s .. " dirtied=" .. tostring(dirtied)
  end
  if written > 0 then
    s = s .. " written=" .. tostring(written)
  end
  if temp_read > 0 or temp_written > 0 then
    s = s .. string.format(", temp read=%s written=%s", tostring(temp_read), tostring(temp_written))
  end
  return s
end

---Render the JSON plan as indented text (one node per line). Analyzed plans
---also show actual times, rows removed, sort methods, buffers and the totals.
---@param plan table
---@param opts? { actual?: boolean }   `actual = false` renders only the estimates
---@return string[]
function M.to_lines(plan, opts)
  local actual = not (opts and (opts.actual == false or opts.analyze == false))
  local root = type(plan) == "table" and plan[1] and plan[1].Plan
  local lines = {}
  if not root then
    return lines
  end
  local function fmt(node, depth)
    local parts = { node["Node Type"] }
    if node["Relation Name"] then
      parts[#parts + 1] = "on "
        .. node["Relation Name"]
        .. (node.Alias and node.Alias ~= node["Relation Name"] and (" " .. node.Alias) or "")
    end
    if node["Index Name"] then
      parts[#parts + 1] = "using " .. node["Index Name"]
    end
    if node["Join Type"] then
      parts[#parts + 1] = "(" .. node["Join Type"] .. ")"
    end
    parts[#parts + 1] = string.format(
      "(cost=%.2f..%.2f rows=%s width=%s)",
      node["Startup Cost"] or 0,
      node["Total Cost"] or 0,
      tostring(node["Plan Rows"]),
      tostring(node["Plan Width"])
    )
    if actual and node["Actual Total Time"] ~= nil then
      parts[#parts + 1] = string.format(
        "(actual time=%.3f..%.3f rows=%s loops=%s)",
        node["Actual Startup Time"] or 0,
        node["Actual Total Time"],
        tostring(node["Actual Rows"]),
        tostring(node["Actual Loops"])
      )
    end
    lines[#lines + 1] = string.rep("  ", depth) .. (depth > 0 and "-> " or "") .. table.concat(parts, " ")
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
    }) do
      if node[k] then
        local v = node[k]
        if type(v) == "table" then
          v = table.concat(v, ", ")
        end
        lines[#lines + 1] = pad .. k .. ": " .. tostring(v)
      end
    end
    if actual then
      for _, k in ipairs(REMOVED_KEYS) do
        if node[k] ~= nil then
          lines[#lines + 1] = pad .. k .. ": " .. tostring(node[k])
        end
      end
      if node["Sort Method"] then
        lines[#lines + 1] = pad
          .. string.format(
            "Sort Method: %s  %s: %skB",
            node["Sort Method"],
            node["Sort Space Type"] or "Memory",
            tostring(node["Sort Space Used"] or 0)
          )
      end
      if (node["Hash Batches"] or 1) > 1 then
        lines[#lines + 1] = pad .. "Hash Batches: " .. tostring(node["Hash Batches"])
      end
      local buffers = buffers_line(node)
      if buffers then
        lines[#lines + 1] = pad .. buffers
      end
    end
    for _, child in ipairs(node.Plans or {}) do
      fmt(child, depth + 1)
    end
  end
  fmt(root, 0)
  if actual then
    local top = plan[1]
    if type(top["Planning Time"]) == "number" then
      lines[#lines + 1] = string.format("Planning Time: %.3f ms", top["Planning Time"])
    end
    if type(top["Execution Time"]) == "number" then
      lines[#lines + 1] = string.format("Execution Time: %.3f ms", top["Execution Time"])
    end
  end
  return lines
end

---Statements that try an index hypothetically (hypopg) and explain the query
---with it; they must run in one session.
---@param index_sql string   `CREATE INDEX ...`
---@param explain_sql string   the query to explain
---@return string[]
function M.hypopg_script(index_sql, explain_sql)
  local stripped = require("dbgrid.sql").strip_semicolon(index_sql)
  return {
    "select hypopg_reset()",
    "select indexrelid, indexname from hypopg_create_index(" .. util.sql_literal(stripped) .. ")",
    "EXPLAIN (FORMAT JSON) " .. explain_sql,
  }
end

---@class dbgrid.CostDelta
---@field before number
---@field after number
---@field pct number   percent change of the total cost (negative means cheaper)
---@field used boolean   a hypothetical index (`<oid>name`) appears in the plan after

---Total cost before and after a hypothetical index.
---@param before_plan table
---@param after_plan table
---@return dbgrid.CostDelta
function M.cost_delta(before_plan, after_plan)
  local before = M.total_cost(before_plan) or 0
  local after = M.total_cost(after_plan) or 0
  local used = false
  walk((root_of(after_plan)), function(node)
    local name = node["Index Name"]
    if type(name) == "string" and name:sub(1, 1) == "<" then
      used = true
    end
  end)
  local pct = before > 0 and (after - before) / before * 100 or 0
  return { before = before, after = after, pct = pct, used = used }
end

return M
