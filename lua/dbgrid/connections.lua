-- Connection registry: setup() connections, saved connections (data dir),
-- and DATABASE_URL-style variables found in the project's .env files.
local util = require("dbgrid.util")
local config = require("dbgrid.config")
local project = require("dbgrid.project")
local adapters = require("dbgrid.adapters")

local M = {}

local function saved_path()
  return project.data_dir() .. "/connections.json"
end

---@return dbgrid.Connection[]
local function saved()
  local data = util.read_json(saved_path())
  return data and data.connections or {}
end

---@param list dbgrid.Connection[]
local function write_saved(list)
  util.write_json(saved_path(), { connections = list })
end

---Parse a dotenv file into a table.
---@param path string
---@return table<string,string>
function M.parse_env_file(path)
  local out = {}
  local text = util.read_file(path)
  if not text then
    return out
  end
  for _, line in ipairs(util.lines(text)) do
    line = line:gsub("^%s*export%s+", "")
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k and not line:match("^%s*#") then
      if v:match('^".*"$') then
        v = v:sub(2, -2):gsub("\\n", "\n")
      elseif v:match("^'.*'$") then
        v = v:sub(2, -2)
      else
        v = v:gsub("%s+#.*$", "")
      end
      out[k] = v
    end
  end
  return out
end

---Connections discovered from the environment and .env files.
---@param root string
---@return dbgrid.Connection[]
function M.discovered(root)
  local cfg = config.get()
  local out = {}
  local seen = {}
  for _, var in ipairs(cfg.env_vars or {}) do
    local v = os.getenv(var)
    if v and adapters.scheme(v) and not seen[v] then
      seen[v] = true
      out[#out + 1] = { name = var, url = v, source = "env" }
    end
  end
  for _, f in ipairs(cfg.env_files or {}) do
    local vars = M.parse_env_file(root .. "/" .. f)
    for _, var in ipairs(cfg.env_vars or {}) do
      local v = vars[var]
      if v then
        v = util.expand_env(v, vars)
        if adapters.scheme(v) and not seen[v] then
          seen[v] = true
          out[#out + 1] = { name = var .. " (" .. f .. ")", url = v, source = f }
        end
      end
    end
  end
  return out
end

---Every connection available to the project, in priority order.
---@param root? string
---@return dbgrid.Connection[]
function M.all(root)
  root = root or project.root()
  local out = {}
  local names = {}
  local function add(c, source)
    if c.name and c.url and not names[c.name] then
      local copy = vim.deepcopy(c)
      copy.url = util.expand_env(copy.url)
      copy.source = copy.source or source
      names[c.name] = true
      out[#out + 1] = copy
    end
  end
  for _, c in ipairs(config.get().connections or {}) do
    add(c, "setup")
  end
  for _, c in ipairs(saved()) do
    if not c.project or c.project == root then
      add(c, c.project and "project" or "saved")
    end
  end
  for _, c in ipairs(M.discovered(root)) do
    add(c, c.source)
  end
  return out
end

---@param name string
---@return dbgrid.Connection?
function M.get(name)
  if not name then
    return nil
  end
  for _, c in ipairs(M.all()) do
    if c.name == name then
      return c
    end
  end
end

---The connection new notebooks should use, if it can be decided without asking.
---@return dbgrid.Connection?
function M.default()
  local cfg = config.get()
  if cfg.default_connection then
    local c = M.get(cfg.default_connection)
    if c then
      return c
    end
  end
  local all = M.all()
  if #all == 1 then
    return all[1]
  end
  return nil
end

---Persist a connection (global, or bound to the current project).
---@param conn dbgrid.Connection
---@param scope "global"|"project"
function M.save(conn, scope)
  local list = saved()
  local copy = {
    name = conn.name,
    url = conn.url,
    readonly = conn.readonly or nil,
    index_check = conn.index_check,
    statement_timeout_ms = conn.statement_timeout_ms,
    password_cmd = conn.password_cmd,
    adapter = conn.adapter,
    project = scope == "project" and project.root() or nil,
  }
  for i, c in ipairs(list) do
    if c.name == conn.name and (c.project or "") == (copy.project or "") then
      list[i] = copy
      write_saved(list)
      return
    end
  end
  list[#list + 1] = copy
  write_saved(list)
end

---@param name string
---@return boolean removed
function M.remove(name)
  local list = saved()
  local out = {}
  local removed = false
  for _, c in ipairs(list) do
    if c.name == name then
      removed = true
    else
      out[#out + 1] = c
    end
  end
  if removed then
    write_saved(out)
  end
  return removed
end

---Interactive add: name, url, scope.
---@param cb? fun(conn?: dbgrid.Connection)
function M.add_interactive(cb)
  vim.ui.input({ prompt = "Connection name: " }, function(name)
    if not name or name == "" then
      return cb and cb(nil)
    end
    vim.ui.input({ prompt = "URL (postgres://user:pass@host:5432/db or $DATABASE_URL): " }, function(url)
      if not url or url == "" then
        return cb and cb(nil)
      end
      local conn = { name = name, url = url }
      local a, err = adapters.for_connection({ name = name, url = util.expand_env(url) })
      if not a then
        util.error(err or "unsupported url")
        return cb and cb(nil)
      end
      vim.ui.select({ "this project only", "everywhere", "read-only, this project only", "read-only, everywhere" }, {
        prompt = "Save connection",
      }, function(choice, idx)
        if not choice then
          return cb and cb(nil)
        end
        conn.readonly = idx >= 3 or nil
        M.save(conn, (idx == 1 or idx == 3) and "project" or "global")
        util.notify("saved connection " .. name)
        if cb then
          cb(M.get(name))
        end
      end)
    end)
  end)
end

---Test a connection.
---@param conn dbgrid.Connection
---@param cb fun(ok: boolean, message: string)
function M.test(conn, cb)
  local a, err = adapters.for_connection(conn)
  if not a then
    return cb(false, err or "no adapter")
  end
  a.test(conn, cb)
end

---One line describing a connection for pickers.
---@param conn dbgrid.Connection
function M.describe(conn)
  local parts = { conn.name }
  if conn.readonly then
    parts[#parts + 1] = "[ro]"
  end
  parts[#parts + 1] = util.redact_url(conn.url or "")
  if conn.source then
    parts[#parts + 1] = "(" .. conn.source .. ")"
  end
  return table.concat(parts, "  ")
end

return M
