-- Cells: a notebook buffer is plain SQL where `-- %% [id] title` lines start a
-- new cell. Everything up to the next marker belongs to that cell.
--
--   -- %% [k3x9] overdue invoices
--   -- ? users with invoices overdue more than 30 days      <- prompt for the agent
--   -- @nolimit                                              <- directive
--   select ...
local util = require("dbgrid.util")
local sql = require("dbgrid.sql")

local M = {}

M.HEADER = "^%s*%-%-%s*%%%%(.*)$"
M.PROMPT = "^%s*%-%-%s*%?%s?(.*)$"
M.DIRECTIVE = "^%s*%-%-%s*@([%w_]+)%s*(.-)%s*$"

---@class dbgrid.Cell
---@field index integer
---@field id string?        nil until ensure_ids ran
---@field title string
---@field header integer?   1-based line of the marker (nil for an implicit first cell)
---@field first integer     first body line (1-based)
---@field last integer      last body line (may be first-1 when the body is empty)
---@field lines string[]    body lines

---@param line string
---@return string? id, string? title, boolean is_header
function M.parse_header(line)
  local rest = line:match(M.HEADER)
  if not rest then
    return nil, nil, false
  end
  local id, title = rest:match("^%s*%[([%w_%-]+)%]%s*(.-)%s*$")
  if id then
    return id, title, true
  end
  return nil, util.trim(rest), true
end

---@param id string
---@param title? string
function M.header_line(id, title)
  local s = "-- %% [" .. id .. "]"
  if title and title ~= "" then
    s = s .. " " .. title
  end
  return s
end

---Parse the cells of a buffer (cached per changedtick).
---@param buf integer
---@return dbgrid.Cell[]
function M.parse(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cache = vim.b[buf].dbgrid_cells_cache
  if cache and cache.tick == tick then
    return cache.cells
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cells = {}
  local current
  for lnum, line in ipairs(lines) do
    local id, title, is_header = M.parse_header(line)
    if is_header then
      current = { id = id, title = title or "", header = lnum, first = lnum + 1, last = lnum, lines = {} }
      cells[#cells + 1] = current
    else
      if not current then
        -- text before the first marker: an implicit cell
        current = { id = nil, title = "", header = nil, first = 1, last = 0, lines = {} }
        cells[#cells + 1] = current
      end
      current.lines[#current.lines + 1] = line
      current.last = lnum
    end
  end
  -- drop an implicit first cell that is only whitespace
  if cells[1] and cells[1].header == nil then
    local blank = true
    for _, l in ipairs(cells[1].lines) do
      if l:match("%S") then
        blank = false
        break
      end
    end
    if blank then
      table.remove(cells, 1)
    end
  end
  for i, c in ipairs(cells) do
    c.index = i
  end
  vim.b[buf].dbgrid_cells_cache = { tick = tick, cells = cells }
  return cells
end

local function cells_first_index(cells, id)
  for i, c in ipairs(cells) do
    if c.id == id then
      return i
    end
  end
end

---Give every cell a unique id, inserting a marker for an implicit first cell.
---@param buf integer
---@return boolean changed
function M.ensure_ids(buf)
  local cells = M.parse(buf)
  local seen, changed = {}, false
  -- first pass (top-down): decide which cells need a new id; the first of two
  -- duplicates (a pasted cell) keeps its id
  local new_ids = {}
  for _, c in ipairs(cells) do
    if c.id and not seen[c.id] then
      seen[c.id] = true
    end
  end
  for i, c in ipairs(cells) do
    if not c.id or new_ids[c.id] or (c.id and cells_first_index(cells, c.id) ~= i) then
      local id
      repeat
        id = util.short_id(4)
      until not seen[id]
      seen[id] = true
      new_ids[i] = id
    end
  end
  -- second pass (bottom-up) so inserted lines do not shift what is still to be edited
  for i = #cells, 1, -1 do
    local c = cells[i]
    local id = new_ids[i]
    if id then
      if c.header then
        vim.api.nvim_buf_set_lines(buf, c.header - 1, c.header, false, { M.header_line(id, c.title) })
      else
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { M.header_line(id) })
      end
      changed = true
    end
  end
  return changed
end

---@param buf integer
---@param lnum integer 1-based
---@return dbgrid.Cell?, integer?
function M.cell_at(buf, lnum)
  local cells = M.parse(buf)
  for i = #cells, 1, -1 do
    local c = cells[i]
    if lnum >= (c.header or c.first) then
      return c, i
    end
  end
  return nil, nil
end

---@param buf integer
---@param id string
---@return dbgrid.Cell?
function M.by_id(buf, id)
  for _, c in ipairs(M.parse(buf)) do
    if c.id == id then
      return c
    end
  end
end

---@param cell dbgrid.Cell
function M.body_text(cell)
  return table.concat(cell.lines, "\n")
end

---The SQL to run: the body without prompt lines (comments would be harmless,
---but keeping prompts out of the executed text keeps error line numbers honest
---... they are kept, so line numbers map 1:1 to the buffer).
---@param cell dbgrid.Cell
function M.sql_text(cell)
  return M.body_text(cell)
end

---@param cell dbgrid.Cell
---@return boolean
function M.has_sql(cell)
  return sql.has_statements(M.body_text(cell))
end

---Prompt lines (`-- ? ...`) joined with newlines, or nil.
---@param cell dbgrid.Cell
---@return string?, integer? last_prompt_lnum
function M.prompt(cell)
  local parts, last = {}, nil
  for i, l in ipairs(cell.lines) do
    local p = l:match(M.PROMPT)
    if p then
      parts[#parts + 1] = p
      last = cell.first + i - 1
    end
  end
  if #parts == 0 then
    return nil, nil
  end
  return util.trim(table.concat(parts, "\n")), last
end

---`-- @name value` directives.
---@param cell dbgrid.Cell
---@return table<string, string|boolean>
function M.directives(cell)
  local out = {}
  for _, l in ipairs(cell.lines) do
    local k, v = l:match(M.DIRECTIVE)
    if k then
      out[k:lower()] = (v ~= "" and v) or true
    end
  end
  return out
end

---Stable hash of what a run depends on: the SQL (whitespace, comment and
---keyword-case insensitive, so formatting never marks a cell as edited) plus
---the directive lines that change how it runs.
---@param cell dbgrid.Cell
function M.hash(cell)
  local parts = { sql.normalize(M.body_text(cell)) }
  for _, l in ipairs(cell.lines) do
    local k, v = l:match(M.DIRECTIVE)
    if k then
      parts[#parts + 1] = "@" .. k:lower() .. " " .. v
    end
  end
  return util.hash(table.concat(parts, "\n"))
end

---`-- @param name = value` declarations, in order. An empty value declares a
---parameter that is asked for when the cell runs.
---@param cell dbgrid.Cell
---@return { name: string, value: string }[]
function M.params(cell)
  local out = {}
  for _, l in ipairs(cell.lines) do
    local k, v = l:match(M.DIRECTIVE)
    if k and k:lower() == "param" then
      local name, value = v:match("^([%w_]+)%s*=?%s*(.-)%s*$")
      if name then
        out[#out + 1] = { name = name, value = value or "" }
      end
    end
  end
  return out
end

---Parse an `@every` interval ("5s", "2m", "500ms", "1h") into milliseconds.
---@param value string|boolean|nil
---@return integer? ms
function M.interval_ms(value)
  if type(value) ~= "string" then
    return nil
  end
  local n, unit = value:match("^%s*(%d+%.?%d*)%s*(%a*)%s*$")
  if not n then
    return nil
  end
  local mult = ({ [""] = 1000, s = 1000, sec = 1000, ms = 1, m = 60000, min = 60000, h = 3600000 })[unit:lower()]
  if not mult then
    return nil
  end
  return math.floor(tonumber(n) * mult)
end

---Names listed by `-- @depends a, b` lines.
---@param cell dbgrid.Cell
---@return string[]
function M.depends(cell)
  local out = {}
  for _, l in ipairs(cell.lines) do
    local k, v = l:match(M.DIRECTIVE)
    if k and k:lower() == "depends" then
      for name in v:gmatch("[^,%s]+") do
        out[#out + 1] = name
      end
    end
  end
  return out
end

---Resolve a cell reference: an id, `q<index>`, a title (case-insensitive) or
---the slug of a title (`overdue-invoices` for "Overdue invoices").
---@param list dbgrid.Cell[]
---@param ref string
---@return dbgrid.Cell?
function M.find(list, ref)
  if not ref or ref == "" then
    return nil
  end
  local want = ref:lower()
  for _, c in ipairs(list) do
    if c.id and c.id:lower() == want then
      return c
    end
  end
  local idx = want:match("^q(%d+)$")
  if idx and list[tonumber(idx)] then
    return list[tonumber(idx)]
  end
  for _, c in ipairs(list) do
    if c.title ~= "" and c.title:lower() == want then
      return c
    end
  end
  for _, c in ipairs(list) do
    if c.title ~= "" and util.slug(c.title) == util.slug(ref) then
      return c
    end
  end
  return nil
end

---Name other cells can use to reference this one (`{{name}}`, `-- @depends name`).
---@param cell dbgrid.Cell
---@return string
function M.ref_name(cell)
  if cell.title and cell.title ~= "" then
    local slug = util.slug(cell.title)
    if slug ~= "untitled" then
      return slug
    end
  end
  return cell.id or ("q" .. cell.index)
end

---Short label: title, else the first non-comment line, else "cell".
---@param cell dbgrid.Cell
---@param max? integer
function M.label(cell, max)
  max = max or 40
  if cell.title and cell.title ~= "" then
    return util.truncate(cell.title, max)
  end
  for _, l in ipairs(cell.lines) do
    if l:match("%S") and not l:match("^%s*%-%-") then
      return util.truncate(util.trim(l):gsub("%s+", " "), max)
    end
  end
  local p = M.prompt(cell)
  if p then
    return util.truncate("? " .. p:gsub("%s+", " "), max)
  end
  return "(empty)"
end

---Insert a new cell. Returns the id and the line of the new marker.
---@param buf integer
---@param where "end"|"below"|"above"
---@param cell? dbgrid.Cell reference cell for below/above
---@param title? string
---@return string id, integer lnum
function M.insert(buf, where, cell, title)
  M.ensure_ids(buf)
  local cells = M.parse(buf)
  local seen = {}
  for _, c in ipairs(cells) do
    seen[c.id] = true
  end
  local id
  repeat
    id = util.short_id(4)
  until not seen[id]
  local header = M.header_line(id, title)
  local at -- 0-based insertion index
  if where == "end" or not cell then
    local n = vim.api.nvim_buf_line_count(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, math.max(0, n - 1), n, false)
    at = n
    if n == 1 and (lines[1] or "") == "" then
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { header, "" })
      return id, 1
    end
    if lines[1] and lines[1]:match("%S") then
      vim.api.nvim_buf_set_lines(buf, at, at, false, { "", header, "" })
      return id, at + 2
    end
    vim.api.nvim_buf_set_lines(buf, at, at, false, { header, "" })
    return id, at + 1
  elseif where == "above" then
    at = (cell.header or cell.first) - 1
    vim.api.nvim_buf_set_lines(buf, at, at, false, { header, "", "" })
    return id, at + 1
  else -- below
    at = cell.last
    vim.api.nvim_buf_set_lines(buf, at, at, false, { "", header, "" })
    return id, at + 2
  end
end

---Delete a cell (marker and body).
---@param buf integer
---@param cell dbgrid.Cell
function M.delete(buf, cell)
  local s = (cell.header or cell.first) - 1
  vim.api.nvim_buf_set_lines(buf, s, cell.last, false, {})
  if vim.api.nvim_buf_line_count(buf) == 0 then
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "" })
  end
end

---Range for text objects.
---@param cell dbgrid.Cell
---@param inner boolean
---@return integer first, integer last  (1-based, inclusive)
function M.range(cell, inner)
  local first = inner and cell.first or (cell.header or cell.first)
  local last = cell.last
  if inner then
    -- trim trailing blank lines from the inner object
    for i = #cell.lines, 1, -1 do
      if cell.lines[i]:match("%S") then
        break
      end
      last = last - 1
    end
  end
  if last < first then
    last = first
  end
  return first, last
end

return M
