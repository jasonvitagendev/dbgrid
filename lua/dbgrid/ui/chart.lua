-- A horizontal bar chart of one numeric column of a result, labelled by
-- another column: the "top 10 by count" query, readable at a glance.
local util = require("dbgrid.util")

local M = {}

local BAR = "█"
local HALF = "▌"

---Is a value numeric (as the grid decides it)?
---@param v any
---@return boolean
local function numeric(v)
  if v == nil or v == vim.NIL then
    return false
  end
  return tonumber(v) ~= nil
end

---Pick the value and label columns of a set: `value` the column under the
---cursor when numeric, else the first numeric column; `label` the first
---non-numeric column that is not the value column (nil: the row number).
---@param columns string[]
---@param rows any[][]
---@param prefer? integer   column under the cursor
---@return integer? value, integer? label
function M.pick_columns(columns, rows, prefer)
  local is_num = {}
  for j = 1, #columns do
    local any, all = false, true
    for _, row in ipairs(rows) do
      local v = row[j]
      if v ~= nil and v ~= vim.NIL then
        any = true
        if not numeric(v) then
          all = false
          break
        end
      end
    end
    is_num[j] = any and all
  end
  local value
  if prefer and is_num[prefer] then
    value = prefer
  else
    for j = 1, #columns do
      if is_num[j] then
        value = j
        break
      end
    end
  end
  if not value then
    return nil, nil
  end
  local label
  for j = 1, #columns do
    if j ~= value and not is_num[j] then
      label = j
      break
    end
  end
  if not label then
    for j = 1, #columns do
      if j ~= value then
        label = j
        break
      end
    end
  end
  return value, label
end

---Format a number for the value column: integers with separators, others as given.
---@param v any
---@return string
local function fmt_value(v)
  if v == nil or v == vim.NIL then
    return "NULL"
  end
  local s = tostring(v)
  if s:match("^%-?%d+$") then
    local n = tonumber(s)
    if n and math.abs(n) < 1e15 then
      return (n < 0 and "-" or "") .. util.fmt_int(math.abs(n))
    end
  end
  return s
end

---Lines of the chart.
---@param opts { columns: string[], rows: any[][], value: integer, label?: integer, width: integer, title?: string }
---@return string[] lines, table<integer, table> line_hl, table<integer, integer> row_at  (lnum → row index)
function M.lines(opts)
  local columns, rows = opts.columns, opts.rows
  local lines, line_hl, row_at = {}, {}, {}
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      line_hl[#lines] = hl
    end
  end
  local labels, values, shown = {}, {}, {}
  local lw, vw = 0, 0
  local maxabs, sum, nonnull = 0, 0, 0
  for i, row in ipairs(rows) do
    local l = opts.label and row[opts.label] or tostring(i)
    if l == nil or l == vim.NIL then
      l = "NULL"
    end
    l = tostring(l):gsub("%s+", " ")
    l = util.truncate(l, 40)
    labels[i] = l
    lw = math.max(lw, util.width(l))
    local v = row[opts.value]
    local n = numeric(v) and tonumber(v) or nil
    values[i] = n
    shown[i] = fmt_value(v)
    vw = math.max(vw, util.width(shown[i]))
    if n then
      maxabs = math.max(maxabs, math.abs(n))
      sum = sum + n
      nonnull = nonnull + 1
    end
  end
  local title = opts.title
    or string.format(
      " %s by %s · %s %s · max %s · sum %s",
      columns[opts.value] or "?",
      opts.label and columns[opts.label] or "row",
      util.fmt_int(#rows),
      #rows == 1 and "row" or "rows",
      fmt_value(tostring(maxabs)),
      fmt_value(tostring(sum))
    )
  add(title, { { 0, #title, "DbgridSetTitle" } })
  add("")
  if #rows == 0 then
    add(" (no rows)", { { 0, 10, "DbgridStatusDim" } })
    return lines, line_hl, row_at
  end
  local bw = math.max(8, math.min(100, (opts.width or 80) - lw - vw - 6))
  for i = 1, #rows do
    local prefix = " " .. util.pad(labels[i], lw) .. " │ "
    local n = values[i]
    local bar = ""
    if n and maxabs > 0 then
      local len = math.abs(n) / maxabs * bw
      local full = math.floor(len)
      bar = string.rep(BAR, full)
      if len - full >= 0.5 then
        bar = bar .. HALF
      elseif full == 0 and n ~= 0 then
        bar = HALF
      end
    end
    local bar_w = util.width(bar)
    local line = prefix .. bar .. string.rep(" ", bw - bar_w + 1) .. util.pad(shown[i], vw, true)
    local hl = {
      { 1, #prefix - 3, "DbgridChartLabel" },
      { #prefix - 3, #prefix, "DbgridSeparator" },
    }
    if #bar > 0 then
      hl[#hl + 1] = { #prefix, #prefix + #bar, n < 0 and "DbgridChartBarNeg" or "DbgridChartBar" }
    end
    hl[#hl + 1] = { #line - #shown[i], #line, n and "DbgridNumber" or "DbgridNull" }
    add(line, hl)
    row_at[#lines] = i
  end
  return lines, line_hl, row_at
end

---Parse a `-- @chart [value [by label]]` directive against the columns.
---@param spec string|boolean
---@param columns string[]
---@param rows any[][]
---@return integer? value, integer? label
function M.from_directive(spec, columns, rows)
  if type(spec) ~= "string" then
    return M.pick_columns(columns, rows)
  end
  local pos = {}
  for j, c in ipairs(columns) do
    pos[c:lower()] = pos[c:lower()] or j
  end
  local v, l = spec:match('^%s*([%w_"]+)%s+by%s+([%w_"]+)%s*$')
  if not v then
    v = spec:match('^%s*([%w_"]+)%s*$')
  end
  local value = v and pos[v:gsub('"', ""):lower()]
  local label = l and pos[l:gsub('"', ""):lower()]
  if not value then
    return M.pick_columns(columns, rows)
  end
  if not label then
    local _, auto = M.pick_columns(columns, rows, value)
    label = auto
  end
  return value, label
end

return M
