-- Schema cache per connection: fetched through the adapter, kept in memory and
-- on disk so completion and hover are instant on the next start.
local util = require("dbgrid.util")
local config = require("dbgrid.config")
local project = require("dbgrid.project")
local adapters = require("dbgrid.adapters")

local M = {}

---@class dbgrid.SchemaColumn
---@field name string
---@field type string
---@field notnull boolean
---@field default string|nil
---@field comment string|nil

---@class dbgrid.SchemaTable
---@field schema string
---@field name string
---@field kind string   r table, v view, m matview, p partitioned, f foreign
---@field rows integer
---@field comment string|nil
---@field columns dbgrid.SchemaColumn[]
---@field indexes { name: string, unique: boolean, primary: boolean, def: string, columns: string[] }[]
---@field constraints { name: string, type: string, def: string, columns: string[], ref_table: string|nil, ref_columns: string[]|nil }[]

---@class dbgrid.SchemaData
---@field version string
---@field schemas string[]
---@field tables dbgrid.SchemaTable[]
---@field enums { name: string, values: string[] }[]
---@field functions string[]
---@field fetched_at integer
---@field by_name table<string, dbgrid.SchemaTable>
---@field referenced_by table<string, dbgrid.Edge[]>|nil  built on demand by dbgrid.relations

local memory = {} ---@type table<string, dbgrid.SchemaData>
local inflight = {} ---@type table<string, fun(schema?: dbgrid.SchemaData, err?: string)[]>

---@param conn dbgrid.Connection
function M.key(conn)
  return util.hash(util.redact_url(conn.url or conn.name))
end

---@param conn dbgrid.Connection
local function disk_path(conn)
  return project.data_dir() .. "/schema/" .. M.key(conn) .. ".json"
end

local function nil_if_null(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---Normalise a decoded schema document.
---@param raw table
---@return dbgrid.SchemaData
local function normalise(raw)
  local data = {
    version = nil_if_null(raw.version) or "",
    schemas = nil_if_null(raw.schemas) or {},
    tables = {},
    enums = nil_if_null(raw.enums) or {},
    functions = nil_if_null(raw.functions) or {},
    fetched_at = raw.fetched_at or util.epoch(),
    by_name = {},
  }
  local excluded = {}
  for _, s in ipairs(config.get().schema.exclude or {}) do
    excluded[s] = true
  end
  for _, t in ipairs(nil_if_null(raw.tables) or {}) do
    if not excluded[t.schema] then
      t.comment = nil_if_null(t.comment)
      t.rows = tonumber(t.rows) or 0
      t.columns = nil_if_null(t.columns) or {}
      for _, c in ipairs(t.columns) do
        c.default = nil_if_null(c.default)
        c.comment = nil_if_null(c.comment)
      end
      t.indexes = nil_if_null(t.indexes) or {}
      for _, ix in ipairs(t.indexes) do
        ix.columns = nil_if_null(ix.columns) or {}
      end
      t.constraints = nil_if_null(t.constraints) or {}
      for _, con in ipairs(t.constraints) do
        con.columns = nil_if_null(con.columns) or {}
        con.ref_table = nil_if_null(con.ref_table)
        con.ref_columns = nil_if_null(con.ref_columns)
      end
      data.tables[#data.tables + 1] = t
      local full = (t.schema .. "." .. t.name):lower()
      data.by_name[full] = t
      -- bare names resolve to public first, then the first schema seen
      local bare = t.name:lower()
      if not data.by_name[bare] or t.schema == "public" then
        data.by_name[bare] = t
      end
    end
  end
  return data
end

---Schema already loaded in memory (no fetch), or nil.
---@param conn dbgrid.Connection
---@return dbgrid.SchemaData?
function M.loaded(conn)
  local key = M.key(conn)
  if memory[key] then
    return memory[key]
  end
  local raw = util.read_json(disk_path(conn))
  if raw then
    memory[key] = normalise(raw)
    return memory[key]
  end
end

---@param conn dbgrid.Connection
---@param cb fun(schema?: dbgrid.SchemaData, err?: string)
function M.refresh(conn, cb)
  local key = M.key(conn)
  if inflight[key] then
    inflight[key][#inflight[key] + 1] = cb
    return
  end
  inflight[key] = { cb }
  local adapter, err = adapters.for_connection(conn)
  local function done(schema, e)
    local cbs = inflight[key] or {}
    inflight[key] = nil
    for _, f in ipairs(cbs) do
      pcall(f, schema, e)
    end
  end
  if not adapter then
    done(nil, err)
    return
  end
  adapter.schema(conn, function(raw, e)
    if not raw then
      done(nil, e or "schema fetch failed")
      return
    end
    raw.fetched_at = util.epoch()
    pcall(util.write_json, disk_path(conn), raw)
    memory[key] = normalise(raw)
    done(memory[key])
  end)
end

---Get the schema, fetching when missing or older than the TTL.
---@param conn dbgrid.Connection
---@param cb fun(schema?: dbgrid.SchemaData, err?: string)
---@param opts? { force?: boolean }
function M.get(conn, cb, opts)
  opts = opts or {}
  local cached = M.loaded(conn)
  local ttl = config.get().schema.ttl_seconds or 3600
  if cached and not opts.force then
    if util.epoch() - (cached.fetched_at or 0) > ttl then
      -- serve stale immediately, refresh in the background
      M.refresh(conn, function() end)
    end
    cb(cached)
    return
  end
  M.refresh(conn, cb)
end

---@param name string
local function unquote(name)
  return (name:gsub('^"(.*)"$', "%1"))
end

---Find a table by bare or qualified name (case-insensitive).
---@param schema dbgrid.SchemaData
---@param name string
---@param schema_name? string
---@return dbgrid.SchemaTable?
function M.find_table(schema, name, schema_name)
  if not schema or not name then
    return nil
  end
  name = unquote(name)
  if schema_name then
    return schema.by_name[(schema_name .. "." .. name):lower()]
  end
  local s, n = name:match("^([^%.]+)%.(.+)$")
  if s then
    return schema.by_name[(unquote(s) .. "." .. unquote(n)):lower()]
  end
  return schema.by_name[name:lower()]
end

---Column of a table by name.
---@param tbl dbgrid.SchemaTable
---@param col string
function M.find_column(tbl, col)
  for _, c in ipairs(tbl.columns or {}) do
    if c.name:lower() == unquote(col):lower() then
      return c
    end
  end
end

---Display name: `name` for public, `schema.name` otherwise.
---@param tbl dbgrid.SchemaTable
function M.display_name(tbl)
  if tbl.schema == "public" then
    return tbl.name
  end
  return tbl.schema .. "." .. tbl.name
end

local KIND = { r = "table", v = "view", m = "materialized view", p = "partitioned table", f = "foreign table" }

---Lines describing a table (hover / describe). With the schema document the
---tables that reference this one are listed too.
---@param tbl dbgrid.SchemaTable
---@param sch? dbgrid.SchemaData
---@return string[]
function M.describe_lines(tbl, sch)
  local relations = require("dbgrid.relations")
  local lines = {}
  lines[#lines + 1] =
    string.format("%s %s  (~%s rows)", KIND[tbl.kind] or tbl.kind, M.display_name(tbl), util.fmt_int(tbl.rows or 0))
  if tbl.comment then
    lines[#lines + 1] = "  " .. tbl.comment
  end
  lines[#lines + 1] = ""
  local pk = {}
  local fk = {}
  for _, con in ipairs(tbl.constraints or {}) do
    if con.type == "p" then
      for _, c in ipairs(con.columns) do
        pk[c] = true
      end
    elseif con.type == "f" then
      local rule = relations.delete_rule(con)
      for _, c in ipairs(con.columns) do
        fk[c] = (con.ref_table or "?") .. "(" .. table.concat(con.ref_columns or {}, ", ") .. ")"
        if rule ~= "no action" then
          fk[c] = fk[c] .. " on delete " .. rule
        end
      end
    end
  end
  local w = 0
  for _, c in ipairs(tbl.columns or {}) do
    w = math.max(w, #c.name)
  end
  for _, c in ipairs(tbl.columns or {}) do
    local flags = {}
    if pk[c.name] then
      flags[#flags + 1] = "PK"
    end
    if fk[c.name] then
      flags[#flags + 1] = "→ " .. fk[c.name]
    end
    if c.notnull and not pk[c.name] then
      flags[#flags + 1] = "not null"
    end
    if c.default then
      flags[#flags + 1] = "default " .. c.default
    end
    local l = string.format("  %s  %s", util.pad(c.name, w), c.type)
    if #flags > 0 then
      l = l .. "  " .. table.concat(flags, ", ")
    end
    if c.comment then
      l = l .. "  -- " .. c.comment
    end
    lines[#lines + 1] = l
  end
  if #(tbl.indexes or {}) > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Indexes:"
    for _, ix in ipairs(tbl.indexes) do
      local kind = ix.primary and "PRIMARY KEY" or (ix.unique and "UNIQUE" or "")
      local def = ix.def:match("USING (.*)$") or ix.def
      lines[#lines + 1] = string.format("  %s  %s%s", ix.name, def, kind ~= "" and ("  " .. kind) or "")
    end
  end
  if sch then
    local refs = relations.referenced_by_lines(sch, tbl)
    if #refs > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Referenced by:"
      vim.list_extend(lines, refs)
    end
  end
  return lines
end

---Compact one-table description for the agent prompt.
---@param tbl dbgrid.SchemaTable
---@return string
function M.format_table_for_ai(tbl)
  local pk, fk = {}, {}
  for _, con in ipairs(tbl.constraints or {}) do
    if con.type == "p" then
      for _, c in ipairs(con.columns) do
        pk[c] = true
      end
    elseif con.type == "f" then
      for i, c in ipairs(con.columns) do
        fk[c] = (con.ref_table or "?"):gsub("^public%.", "") .. "." .. ((con.ref_columns or {})[i] or "?")
      end
    end
  end
  local cols = {}
  for _, c in ipairs(tbl.columns or {}) do
    local s = c.name .. " " .. c.type
    if pk[c.name] then
      s = s .. " PK"
    end
    if fk[c.name] then
      s = s .. " FK->" .. fk[c.name]
    end
    if c.notnull and not pk[c.name] then
      s = s .. " NOT NULL"
    end
    cols[#cols + 1] = s
  end
  local line = string.format("%s(%s)", M.display_name(tbl), table.concat(cols, ", "))
  if tbl.comment then
    line = line .. "  -- " .. tbl.comment
  end
  local idx = {}
  for _, ix in ipairs(tbl.indexes or {}) do
    if not ix.primary then
      idx[#idx + 1] = "(" .. table.concat(ix.columns or {}, ", ") .. ")" .. (ix.unique and " unique" or "")
    end
  end
  if #idx > 0 then
    line = line .. "\n  indexes: " .. table.concat(idx, ", ")
  end
  return line
end

---@param s string
local function words(s)
  local out = {}
  for w in (s or ""):lower():gmatch("[%a_][%w_]*") do
    out[#out + 1] = w
    if #w > 3 and w:sub(-1) == "s" then
      out[#out + 1] = w:sub(1, -2)
    end
  end
  return out
end

---Pick the tables most relevant to a prompt and some SQL context.
---@param schema dbgrid.SchemaData
---@param prompt string
---@param sql_context string
---@param max integer
---@return dbgrid.SchemaTable[]
function M.relevant_tables(schema, prompt, sql_context, max)
  local wanted = {}
  for _, w in ipairs(words(prompt)) do
    wanted[w] = 2
  end
  local sqlmod = require("dbgrid.sql")
  for _, ref in ipairs(sqlmod.referenced_tables(sql_context or "")) do
    local t = M.find_table(schema, ref.name)
    if t then
      wanted[t.name:lower()] = 10
    end
  end
  local scored = {}
  for _, t in ipairs(schema.tables) do
    local score = 0
    local tname = t.name:lower()
    local function hit(w)
      return wanted[w] or wanted[w .. "s"] or (#w > 3 and w:sub(-1) == "s" and wanted[w:sub(1, -2)]) or nil
    end
    if hit(tname) then
      score = score + hit(tname) * 5
    end
    for w in tname:gmatch("[%a]+") do
      if hit(w) then
        score = score + hit(w)
      end
    end
    for _, c in ipairs(t.columns or {}) do
      local cname = c.name:lower()
      if wanted[cname] and cname ~= "id" and cname ~= "name" and cname ~= "created_at" and cname ~= "updated_at" then
        score = score + 1
      end
    end
    scored[#scored + 1] = { t = t, score = score }
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return (a.t.rows or 0) > (b.t.rows or 0)
  end)
  local out = {}
  for i = 1, math.min(max, #scored) do
    out[#out + 1] = scored[i].t
  end
  -- also pull in tables referenced by foreign keys of the chosen ones (one hop)
  local chosen = {}
  for _, t in ipairs(out) do
    chosen[(t.schema .. "." .. t.name):lower()] = true
  end
  for _, t in ipairs(vim.list_slice(out, 1, #out)) do
    for _, con in ipairs(t.constraints or {}) do
      if con.type == "f" and con.ref_table and not chosen[con.ref_table:lower()] and #out < max + 5 then
        local ref = schema.by_name[con.ref_table:lower()]
        if ref then
          chosen[con.ref_table:lower()] = true
          out[#out + 1] = ref
        end
      end
    end
  end
  return out
end

---Forget cached schemas (tests).
function M._reset()
  memory = {}
end

return M
