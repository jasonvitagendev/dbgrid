-- Adapter registry. An adapter turns SQL into results for one database family.
-- See lua/dbgrid/adapters/postgres.lua for the reference implementation and
-- the README for the interface every adapter must provide.
local M = {}

---@class dbgrid.Adapter
---@field name string
---@field schemes table<string, boolean>              url schemes this adapter handles
---@field executable string                           client binary that must be on PATH
---@field run fun(conn: dbgrid.Connection, statements: dbgrid.RunStatement[], opts: table, cb: fun(result: dbgrid.RunResult)): dbgrid.Job
---@field explain fun(conn: dbgrid.Connection, statements: dbgrid.RunStatement[], cb: fun(plans: table[], err?: string)): dbgrid.Job
---@field explain_text fun(conn: dbgrid.Connection, sql: string, analyze: boolean, cb: fun(lines: string[], err?: string)): dbgrid.Job
---@field schema fun(conn: dbgrid.Connection, cb: fun(schema?: table, err?: string)): dbgrid.Job
---@field test fun(conn: dbgrid.Connection, cb: fun(ok: boolean, message: string)): dbgrid.Job
---@field cancel fun(job: dbgrid.Job)
---@field keywords string[]
---@field functions string[]

---@class dbgrid.Job
---@field kill fun(self: dbgrid.Job, signal?: integer|string)
---@field pid integer?

local registry = {}

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

---@param url string
---@return string? scheme
function M.scheme(url)
  return url and url:match("^([%w+]+)://")
end

---Adapter for a connection, by explicit `adapter` or url scheme.
---@param conn dbgrid.Connection
---@return dbgrid.Adapter?, string? error
function M.for_connection(conn)
  if conn.adapter then
    local a = M.get(conn.adapter)
    return a, a == nil and ("unknown adapter '" .. conn.adapter .. "'") or nil
  end
  if conn.aws and not conn.url then
    return M.get("postgres")
  end
  local scheme = M.scheme(conn.url or "")
  if not scheme then
    return nil, "connection url has no scheme: " .. tostring(conn.url)
  end
  if scheme == "aws" then
    return M.get("postgres")
  end
  -- built-in adapters are probed lazily by name
  for _, name in ipairs({ "postgres" }) do
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
  M.get("postgres")
  return vim.tbl_keys(registry)
end

return M
