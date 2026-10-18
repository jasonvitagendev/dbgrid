-- Where a value in a result leads, and how to change it: the row a foreign
-- key points at, the rows that point back at a primary key, and the UPDATE
-- that sets the value under the cursor. Everything here is pure: it takes the
-- schema cache, the statement that produced the result and the row, and
-- returns SQL text. The results pane runs it.
local util = require("dbgrid.util")
local sqlmod = require("dbgrid.sql")
local schemamod = require("dbgrid.schema")

local M = {}

---@class dbgrid.FollowTarget
---@field direction "→"|"←"       → the referenced row, ← the rows that reference this one
---@field table dbgrid.SchemaTable
---@field where { column: string, value: any }[]
---@field sql string
---@field label string
---@field via string               constraint name, or "name" for a naming-convention guess

---Quoted `schema.table` (the schema left out when it is the default one).
---@param tbl dbgrid.SchemaTable
---@return string
function M.table_ref(tbl)
  if schemamod.is_default_schema(tbl.schema) then
    return util.sql_ident(tbl.name)
  end
  return util.sql_ident(tbl.schema) .. "." .. util.sql_ident(tbl.name)
end

---Tables the statement reads, resolved in the schema, in FROM order.
---@param sch dbgrid.SchemaData
---@param sql string
---@return { table: dbgrid.SchemaTable, alias?: string }[]
function M.source_tables(sch, sql)
  local out, seen = {}, {}
  for _, ref in ipairs(sqlmod.referenced_tables(sql or "")) do
    local t = schemamod.find_table(sch, ref.name)
    if t and not seen[t] then
      seen[t] = true
      out[#out + 1] = { table = t, alias = ref.alias }
    end
  end
  return out
end

---The table a result column most likely came from: the first table the
---statement reads that has a column of that name.
---@param sch dbgrid.SchemaData
---@param sql string
---@param column string
---@return dbgrid.SchemaTable?, dbgrid.SchemaColumn?
function M.column_source(sch, sql, column)
  for _, src in ipairs(M.source_tables(sch, sql)) do
    local c = schemamod.find_column(src.table, column)
    if c then
      return src.table, c
    end
  end
  return nil, nil
end

---`a = 'x' AND b IS NULL`
---@param conds { column: string, value: any }[]
---@return string
function M.where_sql(conds)
  local parts = {}
  for _, c in ipairs(conds) do
    if c.value == nil or c.value == vim.NIL then
      parts[#parts + 1] = util.sql_ident(c.column) .. " IS NULL"
    else
      parts[#parts + 1] = util.sql_ident(c.column) .. " = " .. util.sql_literal(c.value)
    end
  end
  return table.concat(parts, " AND ")
end

local function short_value(v)
  if v == nil or v == vim.NIL then
    return "NULL"
  end
  return util.truncate(tostring(v):gsub("%s+", " "), 24)
end

---@param direction "→"|"←"
---@param tbl dbgrid.SchemaTable
---@param conds { column: string, value: any }[]
---@param via string
---@return dbgrid.FollowTarget
local function make_target(direction, tbl, conds, via)
  local shown = {}
  for _, c in ipairs(conds) do
    shown[#shown + 1] = c.column .. " = " .. short_value(c.value)
  end
  return {
    direction = direction,
    table = tbl,
    where = conds,
    via = via,
    sql = "SELECT *\nFROM " .. M.table_ref(tbl) .. "\nWHERE " .. M.where_sql(conds),
    label = direction .. " " .. schemamod.display_name(tbl) .. " where " .. table.concat(shown, " and "),
  }
end

local function contains(list, name)
  for _, v in ipairs(list or {}) do
    if v:lower() == name:lower() then
      return true
    end
  end
  return false
end

---Plural forms a table could have for a `<base>_id` column.
---@param base string
---@return string[]
local function plural_candidates(base)
  local out = { base, base .. "s", base .. "es" }
  if base:match("y$") then
    out[#out + 1] = base:gsub("y$", "ies")
  end
  return out
end

---Singular forms of a table name (`users` → `user`, `categories` → `category`).
---@param name string
---@return string[]
local function singular_candidates(name)
  local out = {}
  if name:match("ies$") then
    out[#out + 1] = name:gsub("ies$", "y")
  end
  if name:match("ses$") or name:match("xes$") or name:match("ches$") or name:match("shes$") then
    out[#out + 1] = name:gsub("es$", "")
  end
  if name:match("s$") then
    out[#out + 1] = name:gsub("s$", "")
  end
  out[#out + 1] = name
  return util.uniq(out)
end

---Where the value in column `col` of `row` leads. Foreign keys of the schema
---come first (outgoing, then incoming); when the schema has none for the
---column, naming conventions (`user_id` → `users.id`, `users.id` ←
---`invoices.user_id`) are tried.
---@param sch dbgrid.SchemaData
---@param sql string          the statement that produced the result
---@param columns string[]
---@param row any[]
---@param col integer
---@return dbgrid.FollowTarget[] targets, string? reason  why there are none
function M.targets(sch, sql, columns, row, col)
  local column = columns[col]
  local value = row[col]
  if column == nil then
    return {}, "no column under the cursor"
  end
  if value == nil or value == vim.NIL then
    return {}, "NULL leads nowhere"
  end
  local pos = {}
  for i, c in ipairs(columns) do
    if not pos[c:lower()] then
      pos[c:lower()] = i
    end
  end
  local relations = require("dbgrid.relations")
  local tbl = M.column_source(sch, sql, column)
  local out, seen = {}, {}
  local function add(t)
    local k = t.direction .. (t.table.schema or "") .. "." .. t.table.name .. ":" .. t.via
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = t
    end
  end
  if tbl then
    for _, con in ipairs(tbl.constraints or {}) do
      if con.type == "f" and contains(con.columns, column) then
        local target = con.ref_table and sch.by_name[con.ref_table:lower()]
        if target then
          local conds = {}
          for i, c in ipairs(con.columns) do
            local j = pos[c:lower()]
            local rc = (con.ref_columns or {})[i]
            if j and rc and row[j] ~= vim.NIL and row[j] ~= nil then
              conds[#conds + 1] = { column = rc, value = row[j] }
            end
          end
          if #conds > 0 then
            add(make_target("→", target, conds, con.name or "fk"))
          end
        end
      end
    end
    for _, e in ipairs(relations.incoming(sch, tbl)) do
      if contains(e.ref_columns, column) then
        local conds = {}
        for i, rc in ipairs(e.ref_columns) do
          local j = pos[rc:lower()]
          local fk = e.columns[i]
          if j and fk and row[j] ~= vim.NIL and row[j] ~= nil then
            conds[#conds + 1] = { column = fk, value = row[j] }
          end
        end
        if #conds > 0 then
          add(make_target("←", e.from, conds, e.name or "fk"))
        end
      end
    end
  end
  if #out > 0 then
    return out
  end
  -- naming conventions
  local base = column:lower():match("^(.+)_id$")
  if base then
    for _, cand in ipairs(plural_candidates(base)) do
      local t = schemamod.find_table(sch, cand)
      if t and schemamod.find_column(t, "id") and t ~= tbl then
        add(make_target("→", t, { { column = "id", value = value } }, "name"))
        break
      end
    end
  end
  if tbl and (column:lower() == "id" or base) then
    for _, singular in ipairs(singular_candidates(tbl.name:lower())) do
      local fk = singular .. "_id"
      for _, t in ipairs(sch.tables or {}) do
        if t ~= tbl and schemamod.find_column(t, fk) then
          add(make_target("←", t, { { column = fk, value = value } }, "name"))
        end
      end
    end
  end
  if #out == 0 then
    local where = tbl and (schemamod.display_name(tbl) .. ".") or ""
    return {}, "no foreign key leads from or to " .. where .. column
  end
  return out
end

---The value as a SQL expression to prefill an edit prompt with.
---@param v any
---@return string
function M.literal_default(v)
  if v == nil or v == vim.NIL then
    return "NULL"
  end
  local s = tostring(v)
  if s:match("^%-?%d+%.?%d*$") or s == "true" or s == "false" then
    return s
  end
  if s == "t" then
    return "true"
  elseif s == "f" then
    return "false"
  end
  return util.sql_literal(s)
end

---`UPDATE t SET col = expr WHERE pk = …` for the value in column `col` of `row`.
---@param sch dbgrid.SchemaData
---@param sql string          the statement that produced the result
---@param columns string[]
---@param row any[]
---@param col integer
---@param expr string         SQL expression for the new value
---@return string? sql, string? err, dbgrid.SchemaTable? tbl
function M.update_sql(sch, sql, columns, row, col, expr)
  local column = columns[col]
  if not column then
    return nil, "no column under the cursor"
  end
  local tbl = M.column_source(sch, sql, column)
  if not tbl then
    return nil, "cannot tell which table " .. column .. " comes from"
  end
  local name = schemamod.display_name(tbl)
  if tbl.kind ~= "r" and tbl.kind ~= "p" then
    return nil, name .. " is not a plain table"
  end
  local key = require("dbgrid.diff").pick_key(columns, tbl)
  if not key then
    return nil, "the result has no primary key of " .. name .. " (select it too)"
  end
  local conds = {}
  for _, j in ipairs(key) do
    conds[#conds + 1] = { column = columns[j], value = row[j] }
  end
  local text = string.format(
    "UPDATE %s\nSET %s = %s\nWHERE %s;",
    M.table_ref(tbl),
    util.sql_ident(column),
    expr,
    M.where_sql(conds)
  )
  return text, nil, tbl
end

return M
