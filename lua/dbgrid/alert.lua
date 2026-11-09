-- Alerts (`-- @alert lag_bytes > 1000000000, wal_status = lost`): conditions
-- on the columns of a cell's first result set. A run in which any row meets
-- any condition raises the alert: a warning when it starts, a note when it
-- clears, a marker on the cell while it lasts, and (for a recorded cell) a
-- line in the marks file so the report shows when it happened.
local util = require("dbgrid.util")
local cells = require("dbgrid.cells")

local M = {}

local OPS = {
  [">"] = function(a, b)
    return a > b
  end,
  [">="] = function(a, b)
    return a >= b
  end,
  ["<"] = function(a, b)
    return a < b
  end,
  ["<="] = function(a, b)
    return a <= b
  end,
}

---@class dbgrid.AlertCondition
---@field column string
---@field op string        one of > >= < <= = !=
---@field value string
---@field text string      the condition as written

---Parse the value of the directive.
---@param spec string
---@return dbgrid.AlertCondition[] conds, string[] bad   the parts that are no condition
function M.parse(spec)
  local conds, bad = {}, {}
  for _, part in ipairs(vim.split(spec, ",", { trimempty = true })) do
    local text = util.trim(part)
    local column, op, value = text:match("^([%w_%.]+)%s*([<>=!]+)%s*(.-)$")
    if op == "==" then
      op = "="
    elseif op == "<>" then
      op = "!="
    end
    if column and value ~= "" and (OPS[op] or op == "=" or op == "!=") then
      value = value:gsub("^'(.*)'$", "%1"):gsub('^"(.*)"$', "%1")
      conds[#conds + 1] = { column = column, op = op, value = value, text = text }
    elseif text ~= "" then
      bad[#bad + 1] = text
    end
  end
  return conds, bad
end

---Does a value meet a condition? Numbers compare as numbers; `=` and `!=`
---fall back to text, the ordering operators never match text or NULL.
---@param cond dbgrid.AlertCondition
---@param v any
---@return boolean
function M.test(cond, v)
  if v == nil or v == vim.NIL then
    return false
  end
  local a, b = tonumber(v), tonumber(cond.value)
  if cond.op == "=" or cond.op == "!=" then
    local same
    if a and b then
      same = a == b
    else
      same = tostring(v) == cond.value
    end
    return (cond.op == "=") == same
  end
  if not a or not b then
    return false
  end
  return OPS[cond.op](a, b)
end

---Rows of a set meeting any condition.
---@param conds dbgrid.AlertCondition[]
---@param set dbgrid.ResultSet
---@return { cond: dbgrid.AlertCondition, value: any, row: integer, key: string? }[] hits, string[] unknown
function M.hits(conds, set)
  local by_name = {}
  for i, c in ipairs(set.columns) do
    by_name[c:lower()] = by_name[c:lower()] or i
  end
  local hits, unknown = {}, {}
  for _, cond in ipairs(conds) do
    local col = by_name[cond.column:lower()]
    if not col then
      unknown[#unknown + 1] = cond.column
    else
      for r, row in ipairs(set.rows) do
        if M.test(cond, row[col]) then
          -- name the row by its first column when that is not the tested one and reads like a label
          local first = row[1]
          local key = (col ~= 1 and #set.rows > 1 and first ~= nil and first ~= vim.NIL and not tonumber(first))
              and tostring(first)
            or nil
          hits[#hits + 1] = { cond = cond, value = row[col], row = r, key = key }
        end
      end
    end
  end
  return hits, unknown
end

---One line saying what fired.
---@param hits table[]
---@return string
function M.describe(hits)
  local h = hits[1]
  local text = string.format("%s = %s (%s)", h.cond.column, tostring(h.value), h.cond.text)
  if h.key then
    text = text .. " on " .. h.key
  end
  if #hits > 1 then
    text = text .. " +" .. (#hits - 1) .. " more"
  end
  return text
end

---Check the result of a run against the cell's `-- @alert`.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param result table
---@return boolean? firing  nil when the cell has no alert
function M.check(state, cell, result)
  state.alerts = state.alerts or {}
  local spec = cells.directives(cell).alert
  if type(spec) ~= "string" then
    state.alerts[cell.id] = nil
    return nil
  end
  local before = state.alerts[cell.id] or {}
  if before.spec ~= spec then
    before = { spec = spec }
    local _, bad = M.parse(spec)
    if #bad > 0 then
      util.warn("@alert: cannot read '" .. table.concat(bad, "', '") .. "' (use column > 5, column = text)")
    end
  end
  if not result or not result.ok then
    state.alerts[cell.id] = before
    return before.firing or false
  end
  local set
  for _, st in ipairs(result.statements or {}) do
    set = st.sets and st.sets[1]
    if set then
      break
    end
  end
  local conds = M.parse(spec)
  local hits, unknown = M.hits(conds, set or { columns = {}, rows = {} })
  if #unknown > 0 and not before.warned then
    util.warn("@alert: no column " .. table.concat(unknown, ", ") .. " in " .. cells.label(cell, 30))
  end
  local label = cells.label(cell, 30)
  local now = {
    spec = spec,
    warned = before.warned or #unknown > 0,
    firing = #hits > 0,
    hits = hits,
    since = before.since,
    text = before.text,
  }
  local record = require("dbgrid.record")
  local function mark(text)
    if record.wanted(cell) then
      pcall(record.mark, state.nb, label .. ": " .. text, "alert", result.ran_at)
    end
  end
  if now.firing and not before.firing then
    now.since = result.ran_at or os.time()
    now.text = M.describe(hits)
    util.warn("alert · " .. label .. ": " .. now.text)
    mark(now.text)
  elseif before.firing and not now.firing then
    util.notify("alert cleared · " .. label .. " (" .. tostring(before.text) .. ")")
    mark("cleared")
    now.since, now.text = nil, nil
  elseif now.firing then
    now.text = M.describe(hits)
  end
  state.alerts[cell.id] = now
  return now.firing
end

return M
