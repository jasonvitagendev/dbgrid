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
  return util.hash(util.redact_url(conn.declared_url or conn.url or conn.name))
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
      -- bare names resolve to the default schema first, then the first schema seen
      local bare = t.name:lower()
      if not data.by_name[bare] or M.is_default_schema(t.schema) then
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
  require("dbgrid.connections").resolve(conn, function(eff, rerr)
    if not eff then
      done(nil, rerr or "connection could not be resolved")
      return
    end
    adapter.schema(eff, function(raw, e)
      if not raw then
        done(nil, e or "schema fetch failed")
        return
      end
      raw.fetched_at = util.epoch()
      pcall(util.write_json, disk_path(conn), raw)
      memory[key] = normalise(raw)
      done(memory[key])
    end)
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

---Schemas whose tables are referenced without a prefix.
---@param name string
function M.is_default_schema(name)
  return name == "public" or name == "main"
end

---Display name: `name` in the default schema, `schema.name` otherwise.
---@param tbl dbgrid.SchemaTable
function M.display_name(tbl)
  if M.is_default_schema(tbl.schema) then
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

---@class dbgrid.SchemaDiff
---@field lines string[]
---@field changes integer
---@field tables { name: string, lnum: integer }[]   1-based line of each `+ table` / `- table` / `~ table` line

---@param list table[]
---@return table<string, table>
local function index_by_name(list)
  local map = {}
  for _, item in ipairs(list or {}) do
    if item.name and not map[item.name] then
      map[item.name] = item
    end
  end
  return map
end

---@param c dbgrid.SchemaColumn
local function null_desc(c)
  return c.notnull and "not null" or "nullable"
end

---@param c dbgrid.SchemaColumn
local function default_desc(c)
  local def = nil_if_null(c.default)
  return def and ("default " .. def) or "no default"
end

---`text not null default 'x'` for added / removed columns.
---@param c dbgrid.SchemaColumn
local function column_desc(c)
  local s = c.type or ""
  if c.notnull then
    s = s .. " not null"
  end
  local def = nil_if_null(c.default)
  if def then
    s = s .. " default " .. def
  end
  return s
end

---Differences between two versions of one table.
---@param ta dbgrid.SchemaTable
---@param tb dbgrid.SchemaTable
---@return { op: string, kind: string, name: string, detail: string }[]
local function table_changes(ta, tb)
  local out = {}
  local function push(op, kind, name, detail)
    out[#out + 1] = { op = op, kind = kind, name = name, detail = detail or "" }
  end
  local ca, cb = index_by_name(ta.columns), index_by_name(tb.columns)
  for _, c in ipairs(ta.columns or {}) do
    local d = cb[c.name]
    if d then
      if (c.type or "") ~= (d.type or "") then
        push("~", "column", c.name, (c.type or "?") .. " → " .. (d.type or "?"))
      end
      if (c.notnull or false) ~= (d.notnull or false) then
        push("~", "column", c.name, null_desc(c) .. " → " .. null_desc(d))
      end
      if (nil_if_null(c.default) or "") ~= (nil_if_null(d.default) or "") then
        push("~", "column", c.name, default_desc(c) .. " → " .. default_desc(d))
      end
    end
  end
  for _, d in ipairs(tb.columns or {}) do
    if not ca[d.name] then
      push("+", "column", d.name, column_desc(d))
    end
  end
  for _, c in ipairs(ta.columns or {}) do
    if not cb[c.name] then
      push("-", "column", c.name, column_desc(c))
    end
  end
  for _, group in ipairs({ { "index", ta.indexes, tb.indexes }, { "constraint", ta.constraints, tb.constraints } }) do
    local kind, la, lb = group[1], group[2] or {}, group[3] or {}
    local ma, mb = index_by_name(la), index_by_name(lb)
    for _, x in ipairs(la) do
      local y = mb[x.name]
      if y and (nil_if_null(x.def) or "") ~= (nil_if_null(y.def) or "") then
        push("~", kind, x.name, (nil_if_null(x.def) or "?") .. " → " .. (nil_if_null(y.def) or "?"))
      end
    end
    for _, y in ipairs(lb) do
      if not ma[y.name] then
        push("+", kind, y.name, nil_if_null(y.def))
      end
    end
    for _, x in ipairs(la) do
      if not mb[x.name] then
        push("-", kind, x.name)
      end
    end
  end
  return out
end

---@param data dbgrid.SchemaData
---@return table<string, dbgrid.SchemaTable> map, string[] keys
local function table_map(data)
  local map, keys = {}, {}
  for _, t in ipairs(data.tables or {}) do
    local key = (t.schema .. "." .. t.name):lower()
    if not map[key] then
      keys[#keys + 1] = key
    end
    map[key] = t
  end
  return map, keys
end

---Compare two schema snapshots (two databases, or one before and after a migration).
---@param a dbgrid.SchemaData
---@param b dbgrid.SchemaData
---@param opts? { a_name?: string, b_name?: string }
---@return dbgrid.SchemaDiff
function M.diff(a, b, opts)
  opts = opts or {}
  local a_name, b_name = opts.a_name or "a", opts.b_name or "b"
  local ma, ka = table_map(a)
  local mb, kb = table_map(b)
  local keys = util.uniq(vim.list_extend(ka, kb))
  table.sort(keys)
  local body, tables, changes = {}, {}, 0
  for _, key in ipairs(keys) do
    local ta, tb = ma[key], mb[key]
    if not ta then
      body[#body + 1] = string.format("+ table %s (%d columns)", M.display_name(tb), #(tb.columns or {}))
      tables[#tables + 1] = { name = M.display_name(tb), lnum = #body }
      changes = changes + 1
    elseif not tb then
      body[#body + 1] = "- table " .. M.display_name(ta)
      tables[#tables + 1] = { name = M.display_name(ta), lnum = #body }
      changes = changes + 1
    else
      local list = table_changes(ta, tb)
      if #list > 0 then
        body[#body + 1] = "~ table " .. M.display_name(ta)
        tables[#tables + 1] = { name = M.display_name(ta), lnum = #body }
        local w = 0
        for _, c in ipairs(list) do
          w = math.max(w, util.width(c.name))
        end
        for _, c in ipairs(list) do
          local line = string.format("  %s %s %s", c.op, c.kind, c.name)
          if c.detail ~= "" then
            line = string.format("  %s %s %s  %s", c.op, c.kind, util.pad(c.name, w), c.detail)
          end
          body[#body + 1] = line
          changes = changes + 1
        end
      end
    end
  end
  -- enums: compared as sets of values
  local ea, eb = index_by_name(a.enums), index_by_name(b.enums)
  local names = {}
  for _, e in ipairs(a.enums or {}) do
    names[#names + 1] = e.name
  end
  for _, e in ipairs(b.enums or {}) do
    names[#names + 1] = e.name
  end
  names = util.uniq(names)
  table.sort(names)
  local function values_of(e)
    return type(e.values) == "table" and e.values or {}
  end
  for _, name in ipairs(names) do
    local x, y = ea[name], eb[name]
    if not x then
      body[#body + 1] = string.format("+ enum %s (%s)", name, table.concat(values_of(y), ", "))
      changes = changes + 1
    elseif not y then
      body[#body + 1] = "- enum " .. name
      changes = changes + 1
    else
      local va, vb = {}, {}
      for _, v in ipairs(values_of(x)) do
        va[v] = true
      end
      for _, v in ipairs(values_of(y)) do
        vb[v] = true
      end
      local parts = {}
      for _, v in ipairs(values_of(y)) do
        if not va[v] then
          parts[#parts + 1] = "+ " .. v
        end
      end
      for _, v in ipairs(values_of(x)) do
        if not vb[v] then
          parts[#parts + 1] = "- " .. v
        end
      end
      if #parts > 0 then
        body[#body + 1] = string.format("~ enum %s: %s", name, table.concat(parts, ", "))
        changes = changes + 1
      end
    end
  end
  local header
  if changes == 0 then
    header = string.format("%s and %s: schemas match (%d tables)", a_name, b_name, #(a.tables or {}))
  else
    header = string.format("%s → %s: %d difference%s", a_name, b_name, changes, changes == 1 and "" or "s")
  end
  local lines = { header }
  vim.list_extend(lines, body)
  for _, t in ipairs(tables) do
    t.lnum = t.lnum + 1
  end
  return { lines = lines, changes = changes, tables = tables }
end

---Non-default server settings, as rows of `{ name, setting, unit, source }`.
M.SETTINGS_SQL = "select name, setting, unit, source from pg_settings"
  .. " where source <> 'default' and name <> 'application_name' order by name"

---`4096kB` for a pg_settings row; units like `8kB` are multiplied out.
---@param row any[]
---@return string
local function setting_value(row)
  local v = row[2]
  if v == nil or v == vim.NIL then
    return "NULL"
  end
  v = tostring(v)
  local unit = row[3]
  if unit ~= nil and unit ~= vim.NIL and unit ~= "" then
    unit = tostring(unit)
    local mult, suffix = unit:match("^(%d+)(%a+)$")
    local n = tonumber(v)
    if mult and n then
      v = tostring(n * tonumber(mult)) .. suffix
    else
      v = v .. unit
    end
  end
  return v
end

---Compare the non-default settings of two connections (rows from `SETTINGS_SQL`).
---@param rows_a any[][]
---@param rows_b any[][]
---@param opts? { a_name?: string, b_name?: string }
---@return { lines: string[], changes: integer }
function M.settings_diff(rows_a, rows_b, opts)
  opts = opts or {}
  local a_name, b_name = opts.a_name or "a", opts.b_name or "b"
  local ma, mb, names = {}, {}, {}
  for _, r in ipairs(rows_a or {}) do
    ma[tostring(r[1])] = r
    names[#names + 1] = tostring(r[1])
  end
  for _, r in ipairs(rows_b or {}) do
    mb[tostring(r[1])] = r
    names[#names + 1] = tostring(r[1])
  end
  names = util.uniq(names)
  table.sort(names)
  local entries, w = {}, 0
  for _, name in ipairs(names) do
    local ra, rb = ma[name], mb[name]
    local entry
    if not ra then
      entry = { "+", name, setting_value(rb) }
    elseif not rb then
      entry = { "-", name, setting_value(ra) }
    else
      local va, vb = setting_value(ra), setting_value(rb)
      if va ~= vb then
        entry = { "~", name, va .. " → " .. vb }
      end
    end
    if entry then
      entries[#entries + 1] = entry
      w = math.max(w, util.width(name))
    end
  end
  local lines
  if #entries == 0 then
    lines = { string.format("%s and %s: settings match (%d settings)", a_name, b_name, #(rows_a or {})) }
  else
    local n = #entries
    lines = { string.format("%s → %s: %d difference%s", a_name, b_name, n, n == 1 and "" or "s") }
    for _, e in ipairs(entries) do
      lines[#lines + 1] = string.format("%s %s  %s", e[1], util.pad(e[2], w), e[3])
    end
  end
  return { lines = lines, changes = #entries }
end

---Forget cached schemas (tests).
function M._reset()
  memory = {}
end

return M
