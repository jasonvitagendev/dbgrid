-- `-- @secret name = <spec>` lines: a parameter whose value is read from AWS
-- Secrets Manager when the cell runs, through the connection's aws block. The
-- value is never remembered in the notebook, written to history, or shown in
-- an error; the spec is what the notebook keeps.
--
--   -- @secret pw = prod/db                  the secret's `password` key, as a SQL string
--   -- @secret token = prod/api#api_key      another key
--   -- @secret conn = conninfo:prod/db       a libpq connection string built from the
--                                            secret's host, port, dbname, username and
--                                            password (sslmode=require unless given):
--   -- @secret conn = conninfo:prod/db sslmode=verify-full application_name=migration
local cells = require("dbgrid.cells")
local util = require("dbgrid.util")

local M = {}

---@class dbgrid.SecretSpec
---@field id string                secret id or ARN
---@field key string               JSON key to read (default "password")
---@field conninfo boolean         build a libpq connection string instead of one key
---@field extras { k: string, v: string }[]  extra conninfo keywords, in order

---Parse the text after `-- @secret name =`.
---@param spec string
---@return dbgrid.SecretSpec? spec, string? err
function M.parse(spec)
  spec = util.trim(spec or "")
  if spec == "" then
    return nil, "no secret id"
  end
  local out = { conninfo = false, extras = {}, key = "password" }
  local rest = spec:match("^conninfo:%s*(.+)$")
  if rest then
    out.conninfo = true
    local words = vim.split(rest, "%s+", { trimempty = true })
    out.id = table.remove(words, 1)
    for _, w in ipairs(words) do
      local k, v = w:match("^([%w_]+)=(.+)$")
      if not k then
        return nil, "bad conninfo option '" .. w .. "' (expected key=value)"
      end
      out.extras[#out.extras + 1] = { k = k, v = v }
    end
  else
    local id, key = spec:match("^(.-)#([%w_%-%.]+)$")
    out.id = id or spec
    out.key = key or "password"
  end
  if not out.id or out.id == "" or out.id:find("%s") then
    return nil, "bad secret id in '" .. spec .. "'"
  end
  return out
end

---`-- @secret name = spec` declarations of a cell, in order.
---@param cell dbgrid.Cell
---@return { name: string, spec: string }[]
function M.declared(cell)
  local out = {}
  for _, l in ipairs(cell.lines) do
    local k, v = l:match(cells.DIRECTIVE)
    if k and k:lower() == "secret" then
      local name, spec = v:match("^([%w_]+)%s*=%s*(.-)%s*$")
      if name then
        out[#out + 1] = { name = name, spec = spec }
      end
    end
  end
  return out
end

---A SQL string literal (standard_conforming_strings: only the quote is doubled).
---@param s string
---@return string
function M.sql_literal(s)
  return "'" .. tostring(s):gsub("'", "''") .. "'"
end

---A libpq conninfo value: quoted when it has spaces, quotes or is empty.
---@param v string
---@return string
function M.conninfo_value(v)
  v = tostring(v)
  if v ~= "" and not v:find("[%s'\\]") then
    return v
  end
  return "'" .. v:gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

---Build `host=... port=... dbname=... user=... password=...` from a secret in
---the RDS shape (hand-written variants: db / database, hostWrite).
---@param secret table   decoded SecretString
---@param extras { k: string, v: string }[]
---@return string? conninfo, string? err
function M.conninfo(secret, extras)
  local function nz(v)
    if v == nil or v == vim.NIL or v == "" then
      return nil
    end
    return tostring(v)
  end
  local parts = {}
  local given = {}
  for _, e in ipairs(extras or {}) do
    given[e.k] = true
  end
  local fields = {
    { "host", nz(secret.host) or nz(secret.hostWrite) or nz(secret.hostname) },
    { "port", nz(secret.port) },
    { "dbname", nz(secret.dbname) or nz(secret.db) or nz(secret.database) or nz(secret.dbName) },
    { "user", nz(secret.username) or nz(secret.user) },
    { "password", nz(secret.password) },
  }
  for _, f in ipairs(fields) do
    if f[2] and not given[f[1]] then
      parts[#parts + 1] = f[1] .. "=" .. M.conninfo_value(f[2])
    end
  end
  if #parts == 0 then
    return nil, "the secret has none of host, port, dbname, username, password"
  end
  for _, e in ipairs(extras or {}) do
    parts[#parts + 1] = e.k .. "=" .. M.conninfo_value(e.v)
  end
  if not given.sslmode then
    parts[#parts + 1] = "sslmode=require"
  end
  return table.concat(parts, " ")
end

---Value of one declaration from its decoded secret.
---@param spec dbgrid.SecretSpec
---@param secret table   decoded SecretString (`{ value = "..." }` when it was not JSON)
---@return string? raw, string? err
function M.value(spec, secret)
  if spec.conninfo then
    return M.conninfo(secret, spec.extras)
  end
  local v = secret[spec.key]
  if (v == nil or v == vim.NIL) and spec.key == "password" and secret.value then
    v = secret.value -- a plain-text secret
  end
  if v == nil or v == vim.NIL then
    return nil, "the secret has no '" .. spec.key .. "' key"
  end
  return tostring(v)
end

---Resolve every declaration of a cell through the connection's aws block.
---@param conn dbgrid.Connection
---@param declared { name: string, spec: string }[]
---@param cb fun(literals?: table<string,string>, raw?: string[], err?: string)
function M.resolve(conn, declared, cb)
  if #declared == 0 then
    return cb({}, {})
  end
  if type(conn.aws) ~= "table" then
    return cb(nil, nil, "-- @secret needs an AWS connection (one with an aws block); " .. conn.name .. " has none")
  end
  local specs = {}
  for _, d in ipairs(declared) do
    local spec, err = M.parse(d.spec)
    if not spec then
      return cb(nil, nil, "-- @secret " .. d.name .. ": " .. err)
    end
    specs[#specs + 1] = { name = d.name, spec = spec }
  end
  local aws = require("dbgrid.aws")
  local literals, raw = {}, {}
  local i = 0
  local function next_one()
    i = i + 1
    local s = specs[i]
    if not s then
      return cb(literals, raw)
    end
    aws.secret_json(conn.aws, s.spec.id, function(secret, err)
      if not secret then
        return cb(nil, nil, "-- @secret " .. s.name .. ": " .. tostring(err))
      end
      local v, verr = M.value(s.spec, secret)
      if not v then
        return cb(nil, nil, "-- @secret " .. s.name .. ": " .. verr)
      end
      literals[s.name] = M.sql_literal(v)
      raw[#raw + 1] = v
      next_one()
    end)
  end
  next_one()
end

local MASK = "***"

---Replace every raw secret value in a string.
---@param s string
---@param raw string[]
---@return string
function M.redact(s, raw)
  if type(s) ~= "string" then
    return s
  end
  for _, v in ipairs(raw or {}) do
    if v ~= "" then
      s = s:gsub(v:gsub("%W", "%%%0"), MASK)
    end
  end
  return s
end

---Redact every string inside a table (a run result), in place.
---@param t table
---@param raw string[]
---@param seen? table
function M.redact_table(t, raw, seen)
  if type(t) ~= "table" or not raw or #raw == 0 then
    return
  end
  seen = seen or {}
  if seen[t] then
    return
  end
  seen[t] = true
  for k, v in pairs(t) do
    if type(v) == "string" then
      t[k] = M.redact(v, raw)
    elseif type(v) == "table" then
      M.redact_table(v, raw, seen)
    end
  end
end

return M
