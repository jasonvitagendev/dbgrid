-- Foreign-key relationships from the schema cache: which tables reference a
-- table, what a DELETE or TRUNCATE on it reaches through ON DELETE rules, and
-- a text tree of a table's neighbourhood.
local M = {}

---@class dbgrid.Edge
---@field from dbgrid.SchemaTable        the table that holds the foreign key
---@field to dbgrid.SchemaTable|nil      the referenced table (nil when not in the cache)
---@field to_name string                 referenced table as the catalog names it
---@field columns string[]               foreign-key columns on `from`
---@field ref_columns string[]           referenced columns on `to`
---@field rule string                    ON DELETE rule: cascade | set null | set default | restrict | no action
---@field name string                    constraint name

---@class dbgrid.DeleteImpact
---@field cascade { table: dbgrid.SchemaTable, edge: dbgrid.Edge, via?: dbgrid.SchemaTable }[]  rows deleted too
---@field set_null { table: dbgrid.SchemaTable, edge: dbgrid.Edge, via?: dbgrid.SchemaTable }[] rows updated
---@field blocked { table: dbgrid.SchemaTable, edge: dbgrid.Edge, via?: dbgrid.SchemaTable }[]  rows that make it fail

local function schemamod()
  return require("dbgrid.schema")
end

local function key(tbl)
  return (tbl.schema .. "." .. tbl.name):lower()
end

---Display name of a table, or the bare catalog name when it is not in the cache.
---@param tbl? dbgrid.SchemaTable
---@param fallback? string
local function display(tbl, fallback)
  if tbl then
    return schemamod().display_name(tbl)
  end
  return ((fallback or "?"):gsub("^public%.", ""))
end

---ON DELETE rule of a foreign-key constraint, read from its definition.
---@param con { def?: string }
---@return string
function M.delete_rule(con)
  local def = (con.def or ""):lower():gsub("%s+", " ")
  local rule = def:match("on delete (cascade)")
    or def:match("on delete (set null)")
    or def:match("on delete (set default)")
    or def:match("on delete (restrict)")
    or def:match("on delete (no action)")
  return rule or "no action"
end

---Build (once per schema document) the index of incoming foreign keys.
---@param schema dbgrid.SchemaData
---@return table<string, dbgrid.Edge[]>
local function incoming_index(schema)
  if schema.referenced_by then
    return schema.referenced_by
  end
  local by = {}
  for _, t in ipairs(schema.tables or {}) do
    for _, con in ipairs(t.constraints or {}) do
      if con.type == "f" and con.ref_table then
        local target = schema.by_name[con.ref_table:lower()]
        if target then
          local k = key(target)
          by[k] = by[k] or {}
          by[k][#by[k] + 1] = {
            from = t,
            to = target,
            to_name = con.ref_table,
            columns = con.columns or {},
            ref_columns = con.ref_columns or {},
            rule = M.delete_rule(con),
            name = con.name or "",
          }
        end
      end
    end
  end
  for _, list in pairs(by) do
    table.sort(list, function(a, b)
      local an, bn = display(a.from), display(b.from)
      if an ~= bn then
        return an < bn
      end
      return table.concat(a.columns, ",") < table.concat(b.columns, ",")
    end)
  end
  schema.referenced_by = by
  return by
end

---Foreign keys that point at `tbl`.
---@param schema dbgrid.SchemaData
---@param tbl dbgrid.SchemaTable
---@return dbgrid.Edge[]
function M.incoming(schema, tbl)
  return incoming_index(schema)[key(tbl)] or {}
end

---Foreign keys of `tbl` itself.
---@param schema dbgrid.SchemaData
---@param tbl dbgrid.SchemaTable
---@return dbgrid.Edge[]
function M.outgoing(schema, tbl)
  local out = {}
  for _, con in ipairs(tbl.constraints or {}) do
    if con.type == "f" then
      out[#out + 1] = {
        from = tbl,
        to = con.ref_table and schema.by_name[con.ref_table:lower()] or nil,
        to_name = con.ref_table or "?",
        columns = con.columns or {},
        ref_columns = con.ref_columns or {},
        rule = M.delete_rule(con),
        name = con.name or "",
      }
    end
  end
  return out
end

---What a DELETE on `tbl` reaches: tables whose rows go too (following ON DELETE
---CASCADE transitively), tables whose rows get NULL / a default, and tables
---whose rows block the delete (RESTRICT / NO ACTION).
---@param schema dbgrid.SchemaData
---@param tbl dbgrid.SchemaTable
---@return dbgrid.DeleteImpact
function M.delete_impact(schema, tbl)
  local out = { cascade = {}, set_null = {}, blocked = {} }
  local queued = { [key(tbl)] = true }
  local listed = {}
  local queue = { { tbl = tbl, depth = 0 } }
  while #queue > 0 do
    local cur = table.remove(queue, 1)
    for _, e in ipairs(M.incoming(schema, cur.tbl)) do
      local item = { table = e.from, edge = e, via = cur.depth > 0 and cur.tbl or nil }
      if e.rule == "cascade" then
        if not listed[key(e.from)] then
          listed[key(e.from)] = true
          out.cascade[#out.cascade + 1] = item
        end
        if not queued[key(e.from)] then
          queued[key(e.from)] = true
          queue[#queue + 1] = { tbl = e.from, depth = cur.depth + 1 }
        end
      elseif e.rule == "set null" or e.rule == "set default" then
        out.set_null[#out.set_null + 1] = item
      else
        out.blocked[#out.blocked + 1] = item
      end
    end
  end
  return out
end

---Tables outside `tbls` that reference any of them, directly or through other
---referencing tables. With TRUNCATE ... CASCADE these are truncated as well;
---without it their existence makes the TRUNCATE fail.
---@param schema dbgrid.SchemaData
---@param tbls dbgrid.SchemaTable[]
---@return { table: dbgrid.SchemaTable, via?: dbgrid.SchemaTable }[]
function M.truncate_impact(schema, tbls)
  local named, seen = {}, {}
  local queue = {}
  for _, t in ipairs(tbls) do
    named[key(t)] = true
    seen[key(t)] = true
    queue[#queue + 1] = { tbl = t, depth = 0 }
  end
  local out = {}
  while #queue > 0 do
    local cur = table.remove(queue, 1)
    for _, e in ipairs(M.incoming(schema, cur.tbl)) do
      if not seen[key(e.from)] then
        seen[key(e.from)] = true
        out[#out + 1] = { table = e.from, via = cur.depth > 0 and cur.tbl or nil }
        queue[#queue + 1] = { tbl = e.from, depth = cur.depth + 1 }
      end
    end
  end
  return out
end

---"a, b (via x), c" with at most `max` entries, then "+N more".
---@param items { table: dbgrid.SchemaTable, via?: dbgrid.SchemaTable, edge?: dbgrid.Edge }[]
---@param opts? { max?: integer, columns?: boolean }
local function join_tables(items, opts)
  opts = opts or {}
  local max = opts.max or 8
  local parts = {}
  for i, it in ipairs(items) do
    if i > max then
      parts[#parts + 1] = string.format("+%d more", #items - max)
      break
    end
    local s = display(it.table)
    if opts.columns and it.edge then
      s = s .. "." .. table.concat(it.edge.columns, ",")
    end
    if it.via then
      s = s .. " (via " .. display(it.via) .. ")"
    end
    parts[#parts + 1] = s
  end
  return table.concat(parts, ", ")
end

---Lines summarising a delete impact, for prompts and the relations view.
---@param impact dbgrid.DeleteImpact
---@param name string  display name of the deleted table
---@return string[] dangers  rows disappear elsewhere
---@return string[] notes    rows change or the delete fails
function M.impact_lines(impact, name)
  local dangers, notes = {}, {}
  if #impact.cascade > 0 then
    dangers[#dangers + 1] = string.format("DELETE on %s cascades to %s", name, join_tables(impact.cascade))
  end
  if #impact.set_null > 0 then
    notes[#notes + 1] =
      string.format("DELETE on %s sets NULL / default in %s", name, join_tables(impact.set_null, { columns = true }))
  end
  if #impact.blocked > 0 then
    notes[#notes + 1] = string.format(
      "DELETE on %s fails while rows in %s still reference it",
      name,
      join_tables(impact.blocked, { columns = true })
    )
  end
  return dangers, notes
end

---Cascade warnings for the statements of a cell, from the schema cache.
---@param schema? dbgrid.SchemaData
---@param stmts dbgrid.Statement[]
---@return string[] dangers  other tables lose rows
---@return string[] notes    informational
function M.write_warnings(schema, stmts)
  local dangers, notes = {}, {}
  if not schema then
    return dangers, notes
  end
  local sqlmod = require("dbgrid.sql")
  local sch = schemamod()
  local seen = {}
  for _, st in ipairs(stmts) do
    local targets = sqlmod.write_targets(st)
    if targets and targets.kind == "delete" then
      local tbl = sch.find_table(schema, targets.names[1])
      if tbl and not seen[key(tbl)] then
        seen[key(tbl)] = true
        local d, n = M.impact_lines(M.delete_impact(schema, tbl), display(tbl))
        vim.list_extend(dangers, d)
        vim.list_extend(notes, n)
      end
    elseif targets and targets.kind == "truncate" then
      local tbls, names = {}, {}
      for _, nm in ipairs(targets.names) do
        local tbl = sch.find_table(schema, nm)
        if tbl then
          tbls[#tbls + 1] = tbl
          names[#names + 1] = display(tbl)
        end
      end
      local extra = M.truncate_impact(schema, tbls)
      if #extra > 0 then
        local list = table.concat(names, ", ")
        if targets.cascade then
          dangers[#dangers + 1] = string.format("TRUNCATE %s CASCADE also truncates %s", list, join_tables(extra))
        else
          notes[#notes + 1] = string.format(
            "TRUNCATE %s fails: referenced by %s (add CASCADE or truncate %s too)",
            list,
            join_tables(extra),
            #extra == 1 and "it" or "them"
          )
        end
      end
    end
  end
  return dangers, notes
end

---One line for an edge seen from `tbl`: "→ plans (plan_id → id)  on delete cascade"
---or "← invoices (customer_id)  on delete cascade".
---@param e dbgrid.Edge
---@param direction "out"|"in"
local function edge_line(e, direction)
  local rule = e.rule ~= "no action" and ("  on delete " .. e.rule) or ""
  if direction == "out" then
    return string.format(
      "→ %s (%s → %s)%s",
      display(e.to, e.to_name),
      table.concat(e.columns, ", "),
      table.concat(e.ref_columns, ", "),
      rule
    )
  end
  return string.format("← %s (%s)%s", display(e.from), table.concat(e.columns, ", "), rule)
end

---Lines for the "Referenced by" part of a table description.
---@param schema dbgrid.SchemaData
---@param tbl dbgrid.SchemaTable
---@return string[]
function M.referenced_by_lines(schema, tbl)
  local lines = {}
  for _, e in ipairs(M.incoming(schema, tbl)) do
    lines[#lines + 1] = "  " .. edge_line(e, "in")
  end
  return lines
end

---Text tree of a table's foreign-key neighbourhood in both directions.
---@param schema dbgrid.SchemaData
---@param tbl dbgrid.SchemaTable
---@param opts? { depth?: integer }
---@return string[]
function M.tree_lines(schema, tbl, opts)
  opts = opts or {}
  local depth = opts.depth or 3
  local util = require("dbgrid.util")
  local lines = {}
  lines[#lines + 1] = string.format("%s  (~%s rows)", display(tbl), util.fmt_int(tbl.rows or 0))

  local function walk(t, direction, level, path)
    local edges = direction == "out" and M.outgoing(schema, t) or M.incoming(schema, t)
    for _, e in ipairs(edges) do
      local other = direction == "out" and e.to or e.from
      local line = string.rep("  ", level) .. edge_line(e, direction)
      local k = other and key(other)
      if k and path[k] then
        line = line .. "  (cycle)"
      end
      lines[#lines + 1] = line
      if other and k and not path[k] and level < depth then
        path[k] = true
        walk(other, direction, level + 1, path)
        path[k] = nil
      end
    end
  end

  local out = M.outgoing(schema, tbl)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "References:"
  if #out == 0 then
    lines[#lines + 1] = "  (none)"
  else
    walk(tbl, "out", 1, { [key(tbl)] = true })
  end
  local inc = M.incoming(schema, tbl)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Referenced by:"
  if #inc == 0 then
    lines[#lines + 1] = "  (none)"
  else
    walk(tbl, "in", 1, { [key(tbl)] = true })
  end

  local dangers, notes = M.impact_lines(M.delete_impact(schema, tbl), display(tbl))
  if #dangers + #notes > 0 then
    lines[#lines + 1] = ""
    for _, l in ipairs(dangers) do
      lines[#lines + 1] = l
    end
    for _, l in ipairs(notes) do
      lines[#lines + 1] = l
    end
  end
  return lines
end

return M
