---@diagnostic disable: undefined-field
-- Small helpers shared across dbgrid. No Neovim UI in here.
local M = {}

local uv = vim.uv or vim.loop

---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.INFO, { title = "dbgrid" })
  end)
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

---Read a whole file. Returns nil when it does not exist.
---@param path string
---@return string?
function M.read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and stat.size > 0 and uv.fs_read(fd, stat.size, 0) or ""
  uv.fs_close(fd)
  return data
end

---Write a file atomically (write to a temp file, then rename).
---@param path string
---@param data string
function M.write_file(path, data)
  M.mkdirp(vim.fs.dirname(path))
  local tmp = path .. ".tmp." .. tostring(uv.hrtime())
  local fd = assert(uv.fs_open(tmp, "w", 420), "dbgrid: cannot open " .. tmp)
  uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  assert(uv.fs_rename(tmp, path))
end

---@param dir string
function M.mkdirp(dir)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

---@param path string
---@return boolean
function M.exists(path)
  return uv.fs_stat(path) ~= nil
end

---@param path string
---@return table?
function M.read_json(path)
  local data = M.read_file(path)
  if not data or data == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok then
    return nil
  end
  return decoded
end

---@param path string
---@param tbl table
function M.write_json(path, tbl)
  M.write_file(path, vim.json.encode(tbl))
end

---Turn free text into a filesystem/tag friendly slug.
---@param s string
---@return string
function M.slug(s)
  s = s:lower():gsub("[^%w%-_]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):gsub("%-%-+", "-")
  if s == "" then
    s = "untitled"
  end
  return s
end

---Short, stable hash for strings (FNV-1a, 32 bit), as 8 hex chars.
---@param s string
---@return string
function M.hash(s)
  local h = 2166136261
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i))
    -- multiply modulo 2^32 without overflowing doubles: split into 16-bit halves
    local lo = bit.band(h, 0xffff)
    local hi = bit.rshift(h, 16)
    h = bit.band(lo * 16777619 + bit.lshift(bit.band(hi * 16777619, 0xffff), 16), 0xffffffff)
  end
  h = bit.band(h, 0xffffffff)
  if h < 0 then
    h = h + 4294967296 -- LuaJIT bit ops return signed 32-bit ints
  end
  return string.format("%08x", h)
end

---Random short id made of lowercase letters and digits.
---@param n? integer
---@return string
function M.short_id(n)
  n = n or 4
  local alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
  local out = {}
  for _ = 1, n do
    local i = math.random(1, #alphabet)
    out[#out + 1] = alphabet:sub(i, i)
  end
  return table.concat(out)
end

---@param s string
---@return string
function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Split a string into lines without dropping empty ones.
---@param s string
---@return string[]
function M.lines(s)
  return vim.split(s, "\n", { plain = true })
end

---Debounce a function on a per-key basis.
---@param ms integer
---@param fn fun(...)
---@return fun(...)
function M.debounce(ms, fn)
  local timer
  return function(...)
    local args = { ... }
    if timer then
      timer:stop()
      timer:close()
    end
    timer = uv.new_timer()
    timer:start(ms, 0, function()
      timer:stop()
      timer:close()
      timer = nil
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
end

---@return number seconds with sub-second precision
function M.now()
  return uv.hrtime() / 1e9
end

---@return integer epoch seconds
function M.epoch()
  return os.time()
end

---Human readable "3m ago".
---@param epoch integer
---@return string
function M.ago(epoch)
  if not epoch then
    return ""
  end
  local d = os.time() - epoch
  if d < 5 then
    return "just now"
  elseif d < 60 then
    return d .. "s ago"
  elseif d < 3600 then
    return math.floor(d / 60) .. "m ago"
  elseif d < 86400 then
    return math.floor(d / 3600) .. "h ago"
  end
  return os.date("%Y-%m-%d", epoch) --[[@as string]]
end

---@param ms number
---@return string
function M.fmt_ms(ms)
  if not ms then
    return ""
  end
  if ms < 1000 then
    return string.format("%d ms", math.floor(ms + 0.5))
  end
  return string.format("%.2f s", ms / 1000)
end

---Thousands separator.
---@param n number
---@return string
function M.fmt_int(n)
  local s = tostring(math.floor(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

---Display width that never errors on odd bytes.
---@param s string
---@return integer
function M.width(s)
  local ok, w = pcall(vim.fn.strdisplaywidth, s)
  return ok and w or #s
end

---Truncate to a display width, adding an ellipsis.
---@param s string
---@param max integer
---@return string
function M.truncate(s, max)
  if M.width(s) <= max then
    return s
  end
  local out = ""
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if M.width(out .. ch) > max - 1 then
      break
    end
    out = out .. ch
  end
  return out .. "…"
end

---Pad a string to width `w` (left aligned unless `right`).
---@param s string
---@param w integer
---@param right? boolean
function M.pad(s, w, right)
  local fill = w - M.width(s)
  if fill <= 0 then
    return s
  end
  if right then
    return string.rep(" ", fill) .. s
  end
  return s .. string.rep(" ", fill)
end

---Expand `$VAR` and `${VAR}` from the environment (and an optional table).
---@param s string
---@param extra? table<string,string>
---@return string
function M.expand_env(s, extra)
  return (
    s:gsub("%${([%w_]+)}", function(k)
      return (extra and extra[k]) or os.getenv(k) or ""
    end):gsub("%$([%w_]+)", function(k)
      return (extra and extra[k]) or os.getenv(k) or ""
    end)
  )
end

---Strip the password from a database URL for display.
---@param url string
---@return string
function M.redact_url(url)
  return (url:gsub("(://[^:/@]+):[^@]*@", "%1:***@"))
end

---Pretty print JSON text; returns the input untouched when it is not JSON.
---@param text string
---@return string, boolean
function M.pretty_json(text)
  local ok, value = pcall(vim.json.decode, text)
  if not ok or type(value) ~= "table" then
    return text, false
  end
  local buf = {}
  local function enc(v, indent)
    local t = type(v)
    if v == vim.NIL or v == nil then
      buf[#buf + 1] = "null"
    elseif t == "string" then
      buf[#buf + 1] = vim.json.encode(v)
    elseif t == "number" or t == "boolean" then
      buf[#buf + 1] = tostring(v)
    elseif t == "table" then
      local is_list = vim.islist(v) or (next(v) == nil and getmetatable(v) ~= nil)
      if vim.tbl_isempty(v) then
        buf[#buf + 1] = is_list and "[]" or "{}"
        return
      end
      local pad = string.rep("  ", indent + 1)
      if is_list then
        buf[#buf + 1] = "[\n"
        for i, item in ipairs(v) do
          buf[#buf + 1] = pad
          enc(item, indent + 1)
          buf[#buf + 1] = i < #v and ",\n" or "\n"
        end
        buf[#buf + 1] = string.rep("  ", indent) .. "]"
      else
        local keys = vim.tbl_keys(v)
        table.sort(keys, function(a, b)
          return tostring(a) < tostring(b)
        end)
        buf[#buf + 1] = "{\n"
        for i, k in ipairs(keys) do
          buf[#buf + 1] = pad .. vim.json.encode(tostring(k)) .. ": "
          enc(v[k], indent + 1)
          buf[#buf + 1] = i < #keys and ",\n" or "\n"
        end
        buf[#buf + 1] = string.rep("  ", indent) .. "}"
      end
    else
      buf[#buf + 1] = vim.json.encode(tostring(v))
    end
  end
  enc(value, 0)
  return table.concat(buf), true
end

---Does the string look like a JSON object/array?
---@param s string
function M.looks_json(s)
  local first = s:match("^%s*(.)")
  return first == "{" or first == "["
end

---@param tbl table
---@param fn fun(v:any):boolean
---@return any?
function M.find(tbl, fn)
  for _, v in ipairs(tbl) do
    if fn(v) then
      return v
    end
  end
end

---Ordered unique.
---@param list any[]
---@return any[]
function M.uniq(list)
  local seen, out = {}, {}
  for _, v in ipairs(list) do
    if not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  return out
end

---Escape a value for CSV.
---@param v string
function M.csv_escape(v)
  if v:find('[",\n\r]') then
    return '"' .. v:gsub('"', '""') .. '"'
  end
  return v
end

---SQL literal quoting for INSERT export.
---@param v string|nil
function M.sql_literal(v)
  if v == nil or v == vim.NIL then
    return "NULL"
  end
  return "'" .. tostring(v):gsub("'", "''") .. "'"
end

---Make keymap hint plugins pick up buffer-local keymaps set after the buffer
---was entered. which-key caches a buffer's keymaps on BufEnter and only
---rescans on BufNew/BufReadPost/LspAttach, so without this `<localleader>`
---shows no popup in a notebook until the buffer is reloaded.
---@param buf integer
function M.refresh_keymap_hints(buf)
  if package.loaded["which-key"] then
    pcall(function()
      require("which-key.buf").clear({ buf = buf })
    end)
  end
end

---A run error as lines: message, position, detail, hint, context.
---@param e dbgrid.RunError
---@return string[]
function M.error_lines(e)
  local out = { "ERROR: " .. tostring(e.message) }
  if e.line then
    out[#out + 1] = "at line " .. e.line .. (e.col and (", column " .. e.col) or "") .. " of the statement"
  end
  if e.detail then
    out[#out + 1] = "DETAIL: " .. e.detail
  end
  if e.hint then
    out[#out + 1] = "HINT: " .. e.hint
  end
  if e.context then
    out[#out + 1] = "CONTEXT: " .. e.context
  end
  return out
end

return M
