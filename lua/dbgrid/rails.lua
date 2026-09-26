-- Rails awareness: connections read from config/database.yml, so a Rails
-- project needs no dbgrid configuration to reach its development and test
-- databases. Only the subset of YAML that database.yml uses is understood
-- (nested mappings, scalars, `&default` anchors, `<<: *default` merges) and
-- the usual ERB snippets are evaluated against the environment.
local util = require("dbgrid.util")

local M = {}

---Evaluate the ERB that database.yml files use: ENV lookups with optional
---defaults. Anything else becomes an empty string.
---@param text string
---@return string
function M.strip_erb(text)
  local function env(name, default)
    local v = os.getenv(name)
    if v == nil or v == "" then
      return default or ""
    end
    return v
  end
  local function unquote(s)
    return (s:gsub("^%s*[\"'](.-)[\"']%s*$", "%1"))
  end
  -- statement tags (<% if ... %>) carry no value; drop the tag
  text = text:gsub("<%%[^=].-%%>", "")
  return (
    text:gsub("<%%=(.-)%%>", function(code)
      code = util.trim(code)
      local name, default = code:match("^ENV%.fetch%(%s*([\"'][^\"']+[\"'])%s*,%s*(.-)%s*%)%s*$")
      if name then
        return env(unquote(name), unquote(default))
      end
      name, default = code:match("^ENV%.fetch%(%s*([\"'][^\"']+[\"'])%s*%)%s*{%s*(.-)%s*}%s*$")
      if name then
        return env(unquote(name), unquote(default))
      end
      name = code:match("^ENV%.fetch%(%s*([\"'][^\"']+[\"'])%s*%)%s*$")
      if name then
        return env(unquote(name))
      end
      name, default = code:match("^ENV%[%s*([\"'][^\"']+[\"'])%s*%]%s*||%s*(.-)%s*$")
      if name then
        return env(unquote(name), unquote(default))
      end
      name = code:match("^ENV%[%s*([\"'][^\"']+[\"'])%s*%]%s*$")
      if name then
        return env(unquote(name))
      end
      return ""
    end)
  )
end

---@param v string
local function scalar(v)
  v = util.trim(v)
  -- strip a trailing comment
  if not v:match("^[\"']") then
    v = v:gsub("%s*#.*$", "")
  end
  if v:match('^".*"$') or v:match("^'.*'$") then
    v = v:sub(2, -2)
  end
  if v == "~" or v == "null" then
    return nil
  end
  return v
end

---Parse the YAML subset used by database.yml.
---@param text string
---@return table
function M.parse_yaml(text)
  local root = {}
  local anchors = {}
  local stack = { { indent = -1, node = root } }
  local all = {}
  for _, raw in ipairs(util.lines(M.strip_erb(text))) do
    local line = raw:gsub("\t", "  ")
    if not (line:match("^%s*#") or not line:match("%S") or line:match("^%-%-%-")) then
      all[#all + 1] = line
    end
  end
  for li, line in ipairs(all) do
    local indent = #line:match("^(%s*)")
    local next_indent = all[li + 1] and #all[li + 1]:match("^(%s*)") or -1
    while #stack > 1 and indent <= stack[#stack].indent do
      stack[#stack] = nil
    end
    local parent = stack[#stack].node
    local key, rest = line:match("^%s*([%w_%-%.<]+)%s*:%s*(.-)%s*$")
    if key then
      if key == "<<" then
        local anchor = rest:match("^%*([%w_%-]+)")
        local src = anchor and anchors[anchor]
        if type(src) == "table" then
          for k, v in pairs(src) do
            if parent[k] == nil then
              parent[k] = type(v) == "table" and vim.deepcopy(v) or v
            end
          end
        end
      else
        local anchor = rest:match("^&([%w_%-]+)")
        if anchor then
          rest = util.trim(rest:sub(#anchor + 2))
        end
        local alias = rest:match("^%*([%w_%-]+)$")
        if alias then
          parent[key] = anchors[alias] and vim.deepcopy(anchors[alias]) or nil
        elseif (rest == "" or rest:match("^#")) and next_indent > indent then
          local node = {}
          parent[key] = node
          stack[#stack + 1] = { indent = indent, node = node }
          if anchor then
            anchors[anchor] = node
          end
        else
          parent[key] = scalar(rest)
          if anchor then
            anchors[anchor] = parent[key]
          end
        end
      end
    end
  end
  return root
end

---Does a mapping look like one database config (rather than a group of them)?
---@param node table
local function is_db_config(node)
  return type(node) == "table" and (node.adapter ~= nil or node.database ~= nil or node.url ~= nil)
end

---@param cfg table    one database configuration
---@param root string  project root, for relative sqlite paths
---@return string? url, string? adapter
function M.url_for(cfg, root)
  if type(cfg.url) == "string" and cfg.url ~= "" then
    return cfg.url, cfg.adapter
  end
  local adapter = (cfg.adapter or ""):lower()
  local db = cfg.database
  if adapter == "sqlite3" or adapter == "sqlite" then
    if not db or db == "" or db == ":memory:" then
      return nil
    end
    if not db:match("^/") then
      db = root .. "/" .. db
    end
    return "sqlite:" .. db, "sqlite"
  end
  if adapter == "postgresql" or adapter == "postgres" or adapter == "postgis" then
    if not db then
      return nil
    end
    local auth = ""
    if cfg.username and cfg.username ~= "" then
      auth = cfg.username
      if cfg.password and cfg.password ~= "" then
        auth = auth .. ":" .. cfg.password
      end
      auth = auth .. "@"
    end
    local host = cfg.host or ""
    if cfg.port and cfg.port ~= "" and host ~= "" then
      host = host .. ":" .. cfg.port
    end
    return string.format("postgres://%s%s/%s", auth, host, db), "postgres"
  end
  return nil
end

---Connections found in <root>/config/database.yml for the wanted environments.
---@param root string
---@param environments? string[]
---@return dbgrid.Connection[]
function M.connections(root, environments)
  local path = root .. "/config/database.yml"
  local text = util.read_file(path)
  if not text then
    return {}
  end
  local ok, doc = pcall(M.parse_yaml, text)
  if not ok or type(doc) ~= "table" then
    return {}
  end
  local out = {}
  for _, env in ipairs(environments or { "development", "test" }) do
    local node = doc[env]
    if type(node) == "table" then
      local configs = {}
      if is_db_config(node) then
        configs[#configs + 1] = { name = "rails:" .. env, cfg = node }
      else
        local names = vim.tbl_keys(node)
        table.sort(names)
        for _, name in ipairs(names) do
          if is_db_config(node[name]) and not node[name].replica then
            local label = name == "primary" and ("rails:" .. env) or ("rails:" .. env .. "." .. name)
            configs[#configs + 1] = { name = label, cfg = node[name] }
          end
        end
      end
      for _, c in ipairs(configs) do
        local url = M.url_for(c.cfg, root)
        if url then
          out[#out + 1] =
            { name = c.name, url = url, source = "config/database.yml", readonly = env == "production" or nil }
        end
      end
    end
  end
  return out
end

---Is this project a Rails application?
---@param root string
---@return boolean
function M.is_rails(root)
  if not util.exists(root .. "/config/database.yml") then
    return false
  end
  if util.exists(root .. "/bin/rails") or util.exists(root .. "/config/application.rb") then
    return true
  end
  local gemfile = util.read_file(root .. "/Gemfile")
  return gemfile ~= nil and gemfile:find("rails", 1, true) ~= nil
end

---Bookkeeping tables Rails creates; not interesting for the agent.
M.SYSTEM_TABLES = { schema_migrations = true, ar_internal_metadata = true }

---Extra guidance for the agent when the schema follows Rails conventions.
M.AGENT_HINT = "The database belongs to a Ruby on Rails application: tables are plural snake_case with an integer `id` "
  .. "primary key, `created_at`/`updated_at` timestamps and `<singular>_id` foreign keys; a `type` column means "
  .. "single-table inheritance; `schema_migrations` and `ar_internal_metadata` are Rails bookkeeping, not app data."

return M
