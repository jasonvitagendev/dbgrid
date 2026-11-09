-- Rates (`-- @rate`): counters that only grow (pg_stat_database, LSNs, byte
-- totals) say little as they are. `-- @rate xact_commit, rows_written` adds a
-- `<column>_per_s` column next to each named one: the difference to the
-- previous run of the cell divided by the seconds between the two. A bare
-- `-- @rate` does it for every numeric column. The first run has nothing to
-- compare with, and a counter that went down was reset: both give NULL.
local util = require("dbgrid.util")
local cells = require("dbgrid.cells")

local M = {}

M.SUFFIX = "_per_s"

---@param v any
---@return number?
local function num(v)
  if v == nil or v == vim.NIL then
    return nil
  end
  return tonumber(v)
end

---@param r number
---@return string
function M.format(r)
  if r == math.floor(r) then
    return string.format("%d", r)
  elseif math.abs(r) >= 100 then
    return string.format("%.1f", r)
  end
  return string.format("%.2f", r)
end

---Indexes of the columns a spec asks rates for.
---@param spec string|boolean  the directive's value
---@param set dbgrid.ResultSet
---@return integer[] wanted, string[] unknown
function M.columns(spec, set)
  local wanted, unknown = {}, {}
  if type(spec) == "string" then
    local by_name = {}
    for i, c in ipairs(set.columns) do
      by_name[c:lower()] = by_name[c:lower()] or i
    end
    for _, name in ipairs(vim.split(spec, "[,%s]+", { trimempty = true })) do
      local i = by_name[name:lower()]
      if i then
        wanted[#wanted + 1] = i
      else
        unknown[#unknown + 1] = name
      end
    end
    table.sort(wanted)
  else
    for i = 1, #set.columns do
      local all = #set.rows > 0
      for _, row in ipairs(set.rows) do
        if num(row[i]) == nil then
          all = false
          break
        end
      end
      if all then
        wanted[#wanted + 1] = i
      end
    end
  end
  return wanted, unknown
end

---Key of every row: the value of the first column that gets no rate when the
---set has several rows and that value is unique, else the position.
---@param set dbgrid.ResultSet
---@param is_rate table<integer, boolean>
---@return string[]
local function row_keys(set, is_rate)
  local keys = {}
  for r = 1, #set.rows do
    keys[r] = tostring(r)
  end
  if #set.rows < 2 then
    return keys
  end
  local key_col
  for i = 1, #set.columns do
    if not is_rate[i] then
      key_col = i
      break
    end
  end
  if not key_col then
    return keys
  end
  local named, seen = {}, {}
  for r, row in ipairs(set.rows) do
    local k = tostring(row[key_col])
    if seen[k] then
      return keys
    end
    seen[k] = true
    named[r] = "=" .. k
  end
  return named
end

---Add the rate columns to the first result set of a run, in place.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param result table
---@param now? number   seconds, for tests
function M.apply(state, cell, result, now)
  local spec = cells.directives(cell).rate
  if spec == nil or not result or not result.ok then
    return
  end
  local set
  for _, st in ipairs(result.statements or {}) do
    set = st.sets and st.sets[1]
    if set then
      break
    end
  end
  if not set or not set.columns or #set.columns == 0 then
    return
  end
  state.rates = state.rates or {}
  local prev = state.rates[cell.id]
  local wanted, unknown = M.columns(spec, set)
  if #unknown > 0 and not (prev and prev.warned) then
    util.warn("@rate: no column " .. table.concat(unknown, ", ") .. " in " .. cells.label(cell, 30))
  end
  now = now or util.now()
  local is_rate = {}
  for _, i in ipairs(wanted) do
    is_rate[i] = true
  end
  local keys = row_keys(set, is_rate)
  local dt = prev and (now - prev.t) or nil
  local values = {}
  local columns, rows = {}, {}
  for i, c in ipairs(set.columns) do
    columns[#columns + 1] = c
    if is_rate[i] then
      columns[#columns + 1] = c .. M.SUFFIX
    end
  end
  for r, row in ipairs(set.rows) do
    local before = prev and prev.values[keys[r]]
    local kept, out = {}, {}
    for i, c in ipairs(set.columns) do
      local v = row[i]
      out[#out + 1] = v == nil and vim.NIL or v
      if is_rate[i] then
        local cur, was = num(v), before and before[c]
        kept[c] = cur
        local rate = vim.NIL
        if cur and was and dt and dt > 0 and cur >= was then
          rate = M.format((cur - was) / dt)
        end
        out[#out + 1] = rate
      end
    end
    values[keys[r]] = kept
    rows[r] = out
  end
  state.rates[cell.id] = { t = now, values = values, warned = #unknown > 0 }
  set.columns, set.rows = columns, rows
end

return M
