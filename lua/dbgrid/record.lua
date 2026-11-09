-- Recordings (`-- @record`): every run of the cell appends its first result
-- set to a CSV next to the notebook, one line per row with the time of the run
-- in front. A live cell (`-- @every 5s`) recorded this way leaves the series
-- behind that its ticks otherwise only keep in memory.
--
--   <store>/recordings/<notebook>/<cell>.csv
--   ts,slot_name,active,lag_bytes
--   2026-11-10T09:15:05,sub_app,t,18432
local util = require("dbgrid.util")
local cells = require("dbgrid.cells")

local M = {}

local uv = vim.uv or vim.loop

-- path -> header line the file is known to start with
local headers = {}

---Directory the recordings of a notebook are written to.
---@param nb dbgrid.Notebook
---@return string
function M.dir(nb)
  return nb.dir .. "/recordings/" .. nb.name
end

---File a cell is recorded to: named by `-- @record <name>`, else after the
---cell's title, or its id when it has none.
---@param nb dbgrid.Notebook
---@param cell dbgrid.Cell
---@return string
function M.path(nb, cell)
  local given = cells.directives(cell).record
  local name = type(given) == "string" and util.slug((given:gsub("%.csv$", "")))
    or (cell.title and cell.title ~= "") and util.slug(cell.title)
    or (cell.id or "cell")
  return M.dir(nb) .. "/" .. name .. ".csv"
end

---@param vals any[]
---@return string
local function csv_line(vals)
  local out = {}
  for i, v in ipairs(vals) do
    out[i] = (v == nil or v == vim.NIL) and "" or util.csv_escape(tostring(v))
  end
  return table.concat(out, ",")
end

---First line of a file, nil when it does not exist or is empty.
---@param path string
---@return string?
local function first_line(path)
  local text = util.read_file(path)
  return text and text:match("^([^\r\n]+)") or nil
end

---Append the first result set of a run to the cell's recording. A run without
---rows still leaves a line with only the time, so a gap in the file is a run
---that failed or never happened. When the columns differ from the ones the
---file was started with, the old file is renamed aside and a new one begins.
---@param nb dbgrid.Notebook
---@param cell dbgrid.Cell
---@param result table   a stored result (ok, ran_at, statements)
---@return string? path  the file written, nil when nothing was recorded
---@return boolean? created  true when this run started the file
function M.append(nb, cell, result)
  if not result or not result.ok then
    return nil
  end
  local set
  for _, st in ipairs(result.statements or {}) do
    set = st.sets and st.sets[1]
    if set then
      break
    end
  end
  if not set or not set.columns or #set.columns == 0 then
    return nil
  end
  local path = M.path(nb, cell)
  local header = csv_line(vim.list_extend({ "ts" }, set.columns))
  local created = false
  if headers[path] ~= header or not util.exists(path) then
    local existing = first_line(path)
    if existing and existing ~= header then
      local stat = uv.fs_stat(path)
      local stamp = os.date("%Y%m%d-%H%M%S", stat and stat.mtime.sec or os.time())
      uv.fs_rename(path, (path:gsub("%.csv$", "")) .. "." .. stamp .. ".csv")
      existing = nil
    end
    created = existing == nil
    headers[path] = header
  end
  local ts = os.date("%Y-%m-%dT%H:%M:%S", result.ran_at or os.time())
  local lines = created and { header } or {}
  for _, row in ipairs(set.rows or {}) do
    local vals = { ts }
    for j = 1, #set.columns do
      vals[j + 1] = row[j] == nil and vim.NIL or row[j]
    end
    lines[#lines + 1] = csv_line(vals)
  end
  if #(set.rows or {}) == 0 then
    lines[#lines + 1] = ts
  end
  util.mkdirp(vim.fs.dirname(path))
  require("dbgrid.project").ensure_ignores(nb.root)
  local fd = uv.fs_open(path, "a", 420)
  if not fd then
    return nil
  end
  uv.fs_write(fd, table.concat(lines, "\n") .. "\n")
  uv.fs_close(fd)
  return path, created
end

---Recordings of a notebook, newest first.
---@param nb dbgrid.Notebook
---@return { path: string, name: string, lines: integer, mtime: integer }[]
function M.list(nb)
  local out = {}
  for _, path in ipairs(vim.fn.glob(M.dir(nb) .. "/*.csv", false, true)) do
    if vim.fn.fnamemodify(path, ":t") ~= M.MARKS then
      local stat = uv.fs_stat(path)
      local text = util.read_file(path) or ""
      local _, n = text:gsub("\n", "")
      out[#out + 1] = {
        path = path,
        name = vim.fn.fnamemodify(path, ":t:r"),
        lines = math.max(n - 1, 0),
        mtime = stat and stat.mtime.sec or 0,
      }
    end
  end
  table.sort(out, function(x, y)
    return x.mtime > y.mtime
  end)
  return out
end

-- Marks ------------------------------------------------------------------------

---File the marks of a notebook are kept in, next to its recordings.
M.MARKS = "marks.csv"

---Note a moment of the run ("subscription created"): a line in
---`<recordings>/marks.csv` the report splits the recordings on. Alerts are
---written the same way with kind "alert" and do not split anything.
---@param nb dbgrid.Notebook
---@param text string
---@param kind? "mark"|"alert"
---@param at? integer   epoch seconds (default: now)
---@return string path
function M.mark(nb, text, kind, at)
  local path = M.dir(nb) .. "/" .. M.MARKS
  local lines = {}
  if not util.exists(path) then
    lines[1] = "ts,kind,text"
  end
  lines[#lines + 1] = csv_line({ os.date("%Y-%m-%dT%H:%M:%S", at or os.time()), kind or "mark", text })
  util.mkdirp(vim.fs.dirname(path))
  require("dbgrid.project").ensure_ignores(nb.root)
  local fd = assert(uv.fs_open(path, "a", 420), "cannot open " .. path)
  uv.fs_write(fd, table.concat(lines, "\n") .. "\n")
  uv.fs_close(fd)
  return path
end

---Parse CSV text: quoted fields, doubled quotes and line breaks inside quotes.
---@param text string
---@return string[][] records
function M.parse_csv(text)
  local records, rec, field = {}, {}, {}
  local i, n, quoted = 1, #text, false
  local function end_field()
    rec[#rec + 1] = table.concat(field)
    field = {}
  end
  local function end_record()
    end_field()
    records[#records + 1] = rec
    rec = {}
  end
  while i <= n do
    local c = text:sub(i, i)
    if quoted then
      if c == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 1
        else
          quoted = false
        end
      else
        field[#field + 1] = c
      end
    elseif c == '"' then
      quoted = true
    elseif c == "," then
      end_field()
    elseif c == "\n" then
      end_record()
    elseif c ~= "\r" then
      field[#field + 1] = c
    end
    i = i + 1
  end
  if #field > 0 or #rec > 0 then
    end_record()
  end
  return records
end

---A recording as columns and rows; the time of each row is its first value.
---@param path string
---@return { columns: string[], rows: string[][] }?
function M.read(path)
  local text = util.read_file(path)
  if not text or text == "" then
    return nil
  end
  local records = M.parse_csv(text)
  local columns = table.remove(records, 1)
  return { columns = columns, rows = records }
end

---Marks and alerts of a notebook, oldest first.
---@param nb dbgrid.Notebook
---@return { ts: string, kind: string, text: string }[]
function M.marks(nb)
  local data = M.read(M.dir(nb) .. "/" .. M.MARKS)
  local out = {}
  for _, r in ipairs(data and data.rows or {}) do
    if r[1] and r[1] ~= "" then
      out[#out + 1] = { ts = r[1], kind = r[2] or "mark", text = r[3] or "" }
    end
  end
  table.sort(out, function(a, b)
    return a.ts < b.ts
  end)
  return out
end

---Whether a cell asks to be recorded.
---@param cell dbgrid.Cell
---@return boolean
function M.wanted(cell)
  return cells.directives(cell).record ~= nil
end

return M
