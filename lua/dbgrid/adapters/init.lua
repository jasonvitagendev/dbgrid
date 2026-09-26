-- Adapter registry. An adapter turns SQL into results for one database family.
-- See lua/dbgrid/adapters/postgres.lua for the reference implementation and
-- the README for the interface every adapter must provide.
local M = {}

---@class dbgrid.Adapter
---@field name string
---@field schemes table<string, boolean>              url schemes this adapter handles
---@field executable string                           client binary that must be on PATH
---@field dialect? string                             human name ("PostgreSQL", "SQLite")
---@field analyze? boolean                            whether explain_text supports analyze
---@field run fun(conn: dbgrid.Connection, statements: dbgrid.RunStatement[], opts: table, cb: fun(result: dbgrid.RunResult)): dbgrid.Job
---@field explain fun(conn: dbgrid.Connection, statements: dbgrid.RunStatement[], cb: fun(plans: table[], err?: string)): dbgrid.Job
---@field explain_text fun(conn: dbgrid.Connection, sql: string, analyze: boolean, cb: fun(lines: string[], err?: string, info?: table)): dbgrid.Job
---@field schema fun(conn: dbgrid.Connection, cb: fun(schema?: table, err?: string)): dbgrid.Job
---@field test fun(conn: dbgrid.Connection, cb: fun(ok: boolean, message: string)): dbgrid.Job
---@field cancel fun(job: dbgrid.Job, conn?: dbgrid.Connection)
---@field keywords string[]
---@field functions string[]

---@class dbgrid.Job
---@field kill fun(self: dbgrid.Job, signal?: integer|string)
---@field pid integer?
---@field is_done? fun(): boolean
---@field appname? string

local registry = {}

-- Adapters that ship with dbgrid, probed lazily by name.
M.BUILTIN = { "postgres", "sqlite" }

---@param adapter dbgrid.Adapter
function M.register(adapter)
  registry[adapter.name] = adapter
  return adapter
end

---@param name string
---@return dbgrid.Adapter?
function M.get(name)
  if not registry[name] then
    local ok, mod = pcall(require, "dbgrid.adapters." .. name)
    if ok and type(mod) == "table" then
      registry[name] = mod
    end
  end
  return registry[name]
end

---Scheme of a connection url. Besides `scheme://...`, SQLite databases can
---be written as `sqlite:path`, `sqlite:///abs/path` or as a bare file path
---ending in .sqlite3 / .sqlite / .db.
---@param url string
---@return string? scheme
function M.scheme(url)
  if type(url) ~= "string" then
    return nil
  end
  local s = url:match("^([%w+]+)://")
  if s then
    return s
  end
  if url:match("^sqlite3?:") then
    return "sqlite"
  end
  if url:match("%.sqlite3?$") or url:match("%.db$") then
    return "sqlite"
  end
  return nil
end

---Adapter for a connection, by explicit `adapter` or url scheme.
---@param conn dbgrid.Connection
---@return dbgrid.Adapter?, string? error
function M.for_connection(conn)
  if conn.adapter then
    local a = M.get(conn.adapter)
    return a, a == nil and ("unknown adapter '" .. conn.adapter .. "'") or nil
  end
  local scheme = M.scheme(conn.url or "")
  if not scheme then
    return nil, "connection url has no scheme: " .. tostring(conn.url)
  end
  for _, name in ipairs(M.BUILTIN) do
    local a = M.get(name)
    if a and a.schemes[scheme] then
      return a
    end
  end
  for _, a in pairs(registry) do
    if a.schemes[scheme] then
      return a
    end
  end
  return nil, "no adapter for url scheme '" .. scheme .. "'"
end

---@return string[]
function M.names()
  for _, name in ipairs(M.BUILTIN) do
    M.get(name)
  end
  local names = vim.tbl_keys(registry)
  table.sort(names)
  return names
end

return M
