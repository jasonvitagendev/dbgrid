-- Query history: every statement run is appended to <store>/history.jsonl
-- (one JSON object per line) so "what did I run on prod yesterday" has an answer.
local util = require("dbgrid.util")
local config = require("dbgrid.config")
local project = require("dbgrid.project")

local M = {}

---@class dbgrid.HistoryEntry
---@field ts integer
---@field connection string
---@field notebook string
---@field cell string
---@field sql string
---@field ok boolean
---@field rows integer?
---@field elapsed_ms number?
---@field error string?

---@param root? string
function M.path(root)
  return project.store_dir(root) .. "/history.jsonl"
end

---@param entry dbgrid.HistoryEntry
function M.append(entry)
  local cfg = config.get().history or {}
  if cfg.enabled == false then
    return
  end
  local path = M.path()
  util.mkdirp(vim.fs.dirname(path))
  project.ensure_ignores()
  local uv = vim.uv or vim.loop
  local fd = uv.fs_open(path, "a", 420)
  if not fd then
    return
  end
  uv.fs_write(fd, vim.json.encode(entry) .. "\n", -1)
  uv.fs_close(fd)
  M.trim(path, cfg.max_entries or 2000)
end

---Keep the file at `max` entries (rewritten once it is 25% over).
---@param path string
---@param max integer
function M.trim(path, max)
  local text = util.read_file(path)
  if not text then
    return
  end
  local lines = vim.split(text, "\n", { trimempty = true })
  if #lines <= max * 1.25 then
    return
  end
  util.write_file(path, table.concat(vim.list_slice(lines, #lines - max + 1, #lines), "\n") .. "\n")
end

---Entries, newest first.
---@param n? integer
---@param root? string
---@return dbgrid.HistoryEntry[]
function M.list(n, root)
  local text = util.read_file(M.path(root))
  if not text then
    return {}
  end
  local lines = vim.split(text, "\n", { trimempty = true })
  local out = {}
  for i = #lines, math.max(1, #lines - (n or 200) + 1), -1 do
    local ok, e = pcall(vim.json.decode, lines[i])
    if ok and type(e) == "table" then
      out[#out + 1] = e
    end
  end
  return out
end

---Pick an entry.
---@param cb fun(entry?: dbgrid.HistoryEntry, action?: "insert"|"run"|"yank")
function M.pick(cb)
  local entries = M.list(300)
  if #entries == 0 then
    util.notify("no history yet")
    return cb(nil)
  end
  local items = {}
  for _, e in ipairs(entries) do
    local first = (e.sql or ""):gsub("^%s*%-%-[^\n]*\n", ""):gsub("%s+", " ")
    items[#items + 1] = {
      text = string.format(
        "%s  %s  %s  %s  %s",
        os.date("%Y-%m-%d %H:%M", e.ts or 0),
        e.ok and "✓" or "✗",
        util.pad(tostring(e.connection or "?"), 12),
        e.rows and (util.fmt_int(e.rows) .. " rows") or (e.error and util.truncate(e.error, 30) or ""),
        util.truncate(first, 70)
      ),
      preview = util.lines(e.sql or ""),
      preview_ft = "sql",
      data = e,
    }
  end
  require("dbgrid.ui.picker").pick(items, {
    prompt = "History (Enter: new cell · <C-y>: yank)",
    on_select = function(item)
      cb(item and item.data or nil, "insert")
    end,
    actions = {
      ["<C-y>"] = function(item)
        cb(item.data, "yank")
      end,
    },
  })
end

return M
