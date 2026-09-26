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

---Render the JSON plan as indented text (one node per line).
---@param plan table
---@return string[]
function M.to_lines(plan)
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
    for _, child in ipairs(node.Plans or {}) do
      fmt(child, depth + 1)
    end
  end
  fmt(root, 0)
  return lines
end

return M
