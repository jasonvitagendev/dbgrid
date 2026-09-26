-- Turns a cell into the text that is sent to the database: other cells named
-- with `{{name}}` are inlined as subqueries and `:name` / `{{name}}`
-- parameters are replaced by their values (asked for when unknown).
local cells = require("dbgrid.cells")
local sqlmod = require("dbgrid.sql")
local util = require("dbgrid.util")
local notebook = require("dbgrid.notebook")

local M = {}

---@class dbgrid.Expansion
---@field text string                 SQL with cells inlined and parameters substituted
---@field params table<string,string> parameter values used (name -> SQL literal text)
---@field cells string[]              ids of the cells that were inlined
---@field param_source table<string,string> where each value came from ("cell", "notebook", "prompt")

---Inline `{{other cell}}` references into a cell's body, recursively.
---@param buf integer
---@param cell dbgrid.Cell
---@param stack? table<string, boolean>  ids being expanded (cycle detection)
---@return string text, string? err, string[] used_ids, table<string,string> declared_params
function M.inline_cells(buf, cell, stack)
  stack = stack or {}
  local list = cells.parse(buf)
  local text = cells.body_text(cell)
  local own = {}
  for _, p in ipairs(cells.params(cell)) do
    own[p.name] = p.value
  end
  local declared = {}
  for _, p in ipairs(cells.params(cell)) do
    if p.value ~= "" then
      declared[p.name] = p.value
    end
  end
  local used, err = {}, nil
  local inner_stack = vim.tbl_extend("force", stack, { [cell.id or ("idx" .. cell.index)] = true })
  local out = sqlmod.substitute(text, sqlmod.placeholders(text), function(r)
    if err or r.style ~= "{{" or own[r.name] ~= nil then
      return nil -- a parameter (or an error already happened)
    end
    local target = cells.find(list, r.name)
    if not target or target == cell or target.id == cell.id then
      return nil -- not a cell: it is a parameter
    end
    local key = target.id or ("idx" .. target.index)
    if inner_stack[key] then
      err = "cell reference cycle through {{" .. r.name .. "}}"
      return nil
    end
    local inner, e, inner_used, inner_declared = M.inline_cells(buf, target, inner_stack)
    if e then
      err = e
      return nil
    end
    local stmts = sqlmod.split(inner)
    if #stmts ~= 1 then
      err = "{{" .. r.name .. "}} must contain exactly one statement to be inlined (it has " .. #stmts .. ")"
      return nil
    end
    if stmts[1].class ~= "read" then
      err = "{{" .. r.name .. "}} is a " .. stmts[1].kind:upper() .. "; only read-only queries can be inlined"
      return nil
    end
    used[#used + 1] = target.id
    for _, id in ipairs(inner_used) do
      used[#used + 1] = id
    end
    for k, v in pairs(inner_declared) do
      if declared[k] == nil then
        declared[k] = v
      end
    end
    return "(" .. sqlmod.inline(stmts[1].sql) .. ")"
  end)
  return out, err, used, declared
end

---Parameter names a text still needs after cells were inlined.
---@param text string
---@return string[] names, dbgrid.Placeholder[] refs
function M.parameter_names(text)
  local refs = sqlmod.placeholders(text)
  local names, seen = {}, {}
  for _, r in ipairs(refs) do
    if not seen[r.name] then
      seen[r.name] = true
      names[#names + 1] = r.name
    end
  end
  return names, refs
end

---Prepare a cell for execution. Missing parameter values are asked for one
---by one (and remembered in the notebook); `opts.values` supplies them
---without asking.
---@param s dbgrid.State
---@param cell dbgrid.Cell
---@param opts? { values?: table<string,string>, silent?: boolean }
---@param cb fun(exp?: dbgrid.Expansion, err?: string)
function M.prepare(s, cell, opts, cb)
  opts = opts or {}
  local text, err, used, declared = M.inline_cells(s.buf, cell, {})
  if err then
    return cb(nil, err)
  end
  local names, refs = M.parameter_names(text)
  local values, source, missing = {}, {}, {}
  local meta_params = s.nb.meta.params or {}
  for _, name in ipairs(names) do
    local v = opts.values and opts.values[name]
    if v and v ~= "" then
      values[name], source[name] = v, "given"
    elseif declared[name] and declared[name] ~= "" then
      values[name], source[name] = declared[name], "cell"
    elseif meta_params[name] and meta_params[name] ~= "" and meta_params[name] ~= vim.NIL then
      values[name], source[name] = meta_params[name], "notebook"
    else
      missing[#missing + 1] = name
    end
  end
  local function finish()
    local out = sqlmod.substitute(text, refs, function(r)
      local v = values[r.name]
      return v and (v:gsub("\n", " ")) or nil
    end)
    cb({ text = out, params = values, cells = used, param_source = source })
  end
  if #missing == 0 then
    return finish()
  end
  if opts.silent then
    return cb(nil, "missing value for :" .. table.concat(missing, ", :"))
  end
  local i = 0
  local function ask()
    i = i + 1
    local name = missing[i]
    if not name then
      return finish()
    end
    local last = meta_params[name]
    vim.ui.input({
      prompt = string.format("Value for :%s (a SQL literal, e.g. 'text', 42, now()): ", name),
      default = type(last) == "string" and last or "",
    }, function(input)
      if input == nil then
        return cb(nil, "cancelled: no value for :" .. name)
      end
      input = util.trim(input)
      if input == "" then
        return cb(nil, "no value for :" .. name)
      end
      values[name], source[name] = input, "prompt"
      notebook.set_param(s.nb, name, input)
      ask()
    end)
  end
  ask()
end

---Every parameter name used anywhere in the notebook, with the value that
---would currently apply (nil when unknown).
---@param s dbgrid.State
---@return { name: string, value: string?, cells: string[] }[]
function M.notebook_params(s)
  local list = cells.parse(s.buf)
  local by_name, order = {}, {}
  local meta_params = s.nb.meta.params or {}
  for _, cell in ipairs(list) do
    local declared = {}
    for _, p in ipairs(cells.params(cell)) do
      declared[p.name] = p.value
      if not by_name[p.name] then
        by_name[p.name] = { name = p.name, cells = {} }
        order[#order + 1] = p.name
      end
    end
    local text = cells.body_text(cell)
    for _, r in ipairs(sqlmod.placeholders(text)) do
      local is_cell = r.style == "{{" and declared[r.name] == nil and cells.find(list, r.name) ~= nil
      if not is_cell then
        if not by_name[r.name] then
          by_name[r.name] = { name = r.name, cells = {} }
          order[#order + 1] = r.name
        end
        local entry = by_name[r.name]
        local label = cells.ref_name(cell)
        if not vim.tbl_contains(entry.cells, label) then
          entry.cells[#entry.cells + 1] = label
        end
        if declared[r.name] and declared[r.name] ~= "" then
          entry.value = declared[r.name]
          entry.source = "cell"
        end
      end
    end
  end
  local out = {}
  for _, name in ipairs(order) do
    local e = by_name[name]
    if e.value == nil and type(meta_params[name]) == "string" and meta_params[name] ~= "" then
      e.value = meta_params[name]
      e.source = "notebook"
    end
    out[#out + 1] = e
  end
  return out
end

return M
