-- Undo for writes. Before an UPDATE or DELETE with a WHERE clause runs, the
-- rows it is about to touch are read (by primary key) and kept with the
-- cell's result; afterwards the statements that put them back can be written
-- as a cell to review and run. The capture reuses the SELECT the write
-- preview counts with, so the rows are the ones the statement saw, as they
-- were right before it ran.
local config = require("dbgrid.config")
local sqlmod = require("dbgrid.sql")
local schemamod = require("dbgrid.schema")
local cells = require("dbgrid.cells")
local notebook = require("dbgrid.notebook")
local util = require("dbgrid.util")

local M = {}

---@class dbgrid.UndoEntry
---@field stmt_index integer     statement of the cell the rows belong to
---@field kind "update"|"delete"
---@field table string           display name of the table
---@field ref string             quoted table reference for SQL
---@field columns string[]       captured columns (the key first)
---@field types string[]         their declared types (for literal quoting)
---@field key integer[]          indexes into `columns` of the primary key
---@field rows any[][]
---@field overriding? boolean    an identity ALWAYS column is restored (INSERT ... OVERRIDING SYSTEM VALUE)

---@class dbgrid.UndoPlan
---@field stmt_index integer
---@field kind "update"|"delete"
---@field table dbgrid.SchemaTable
---@field columns dbgrid.SchemaColumn[]
---@field key integer[]
---@field sql string

local function is_identity_always(col)
  return col.identity == "a"
end

local function is_generated(col)
  return col.generated ~= nil and col.generated ~= vim.NIL and col.generated ~= ""
end

---Primary-key columns of a table, in constraint order; nil without one.
---@param tbl dbgrid.SchemaTable
---@return string[]?
local function primary_key(tbl)
  for _, con in ipairs(tbl.constraints or {}) do
    if con.type == "p" and #(con.columns or {}) > 0 then
      return con.columns
    end
  end
  return nil
end

---What to capture for each UPDATE / DELETE of a cell: the table, the columns
---worth keeping (everything for a DELETE, the key plus the assigned columns
---for an UPDATE) and the SELECT that reads them. Statements that cannot be
---undone are listed with the reason.
---@param sch dbgrid.SchemaData?
---@param stmts dbgrid.Statement[]
---@param opts? { max_rows?: integer }
---@return dbgrid.UndoPlan[] plans, string[] skipped
function M.plan(sch, stmts, opts)
  opts = opts or {}
  local plans, skipped = {}, {}
  for i, st in ipairs(stmts) do
    if st.kind == "update" or st.kind == "delete" then
      local what = st.kind:upper()
      local parts = sqlmod.preview_from(st)
      if not parts then
        if not sqlmod.first_top_level_word(st, { where = true }) then
          skipped[#skipped + 1] = what .. " has no WHERE clause"
        else
          skipped[#skipped + 1] = what .. " is too unusual to read its rows first"
        end
      else
        local tbl = sch and schemamod.find_table(sch, parts.target.name)
        if not tbl then
          skipped[#skipped + 1] = parts.target.name .. " is not in the schema cache"
        elseif tbl.kind ~= "r" and tbl.kind ~= "p" then
          skipped[#skipped + 1] = schemamod.display_name(tbl) .. " is not a plain table"
        else
          local pk = primary_key(tbl)
          if not pk then
            skipped[#skipped + 1] = schemamod.display_name(tbl) .. " has no primary key"
          else
            -- columns: the key first, then what the statement changes
            local wanted, seen = {}, {}
            local function add(name)
              local col = schemamod.find_column(tbl, name)
              if col and not seen[col.name:lower()] and not is_generated(col) then
                seen[col.name:lower()] = true
                wanted[#wanted + 1] = col
              end
            end
            for _, name in ipairs(pk) do
              add(name)
            end
            local assigned = st.kind == "update" and sqlmod.set_columns(st) or nil
            local key_changed = false
            if assigned then
              for _, name in ipairs(assigned) do
                add(name)
                for _, pkc in ipairs(pk) do
                  if pkc:lower() == name:lower():gsub('^"(.*)"$', "%1") then
                    key_changed = true
                  end
                end
              end
            else
              for _, col in ipairs(tbl.columns or {}) do
                add(col.name)
              end
            end
            local key = {}
            for k = 1, #pk do
              key[k] = k
            end
            if #wanted < #pk then
              skipped[#skipped + 1] = schemamod.display_name(tbl) .. ": its primary key cannot be read"
            else
              local prefix = parts.target.alias or parts.target.name
              local list = {}
              for k, col in ipairs(wanted) do
                list[k] = prefix .. "." .. util.sql_ident(col.name)
              end
              local sql = sqlmod.preview_select(st, table.concat(list, ", "))
              if opts.max_rows then
                sql = sql .. " LIMIT " .. (opts.max_rows + 1)
              end
              plans[#plans + 1] = {
                stmt_index = i,
                kind = st.kind,
                table = tbl,
                columns = wanted,
                key = key,
                sql = sql,
                key_changed = key_changed or nil,
              }
            end
          end
        end
      end
    end
  end
  return plans, skipped
end

---Turn a captured result set into an undo entry: rows deduplicated by key
---(a join in the write's FROM / USING list can repeat them).
---@param plan dbgrid.UndoPlan
---@param set { columns: string[], rows: any[][] }
---@return dbgrid.UndoEntry
local function entry_from(plan, set)
  local rows, seen = {}, {}
  for _, row in ipairs(set.rows or {}) do
    local parts = {}
    for _, k in ipairs(plan.key) do
      local v = row[k]
      parts[#parts + 1] = (v == nil or v == vim.NIL) and "\0" or tostring(v)
    end
    local id = table.concat(parts, "\1")
    if not seen[id] then
      seen[id] = true
      rows[#rows + 1] = row
    end
  end
  local names, types, overriding = {}, {}, false
  for k, col in ipairs(plan.columns) do
    names[k] = col.name
    types[k] = tostring(col.type or "")
    if plan.kind == "delete" and is_identity_always(col) then
      overriding = true
    end
  end
  return {
    stmt_index = plan.stmt_index,
    kind = plan.kind,
    table = schemamod.display_name(plan.table),
    ref = require("dbgrid.follow").table_ref(plan.table),
    columns = names,
    types = types,
    key = plan.key,
    rows = rows,
    overriding = overriding or nil,
    key_changed = plan.key_changed or nil,
  }
end

---Read the rows the UPDATE / DELETE statements of a cell are about to touch.
---Calls back with the entries kept and a note about what was not (nil when
---everything was, or nothing applied); `cancelled` is set when the read was
---cancelled, in which case the write should not run either.
---@param conn dbgrid.Connection
---@param adapter dbgrid.Adapter
---@param sch dbgrid.SchemaData?
---@param stmts dbgrid.Statement[]
---@param cb fun(entries: dbgrid.UndoEntry[]?, note?: string, cancelled?: boolean)
---@return dbgrid.Job?
function M.capture(conn, adapter, sch, stmts, cb)
  local max_rows = config.get().query.undo_rows or 0
  if max_rows <= 0 then
    return cb(nil)
  end
  local plans, skipped = M.plan(sch, stmts, { max_rows = max_rows })
  local function note()
    if #skipped == 0 then
      return nil
    end
    return "no undo: " .. table.concat(util.uniq(skipped), "; ")
  end
  if #plans == 0 then
    return cb(nil, note())
  end
  local run_stmts = {}
  for k, p in ipairs(plans) do
    run_stmts[k] = { sql = p.sql, kind = "select", class = "read", line = 1 }
  end
  return adapter.run(conn, run_stmts, { timeout_ms = 15000 }, function(res)
    if res.cancelled then
      return cb(nil, nil, true)
    end
    local entries = {}
    for k, p in ipairs(plans) do
      local st = res.statements[k]
      local set = st and st.sets and st.sets[1]
      if not set then
        skipped[#skipped + 1] = p.kind:upper()
          .. " on "
          .. schemamod.display_name(p.table)
          .. ": "
          .. (res.error and res.error.message or "the rows could not be read")
      elseif #set.rows > max_rows then
        skipped[#skipped + 1] = string.format(
          "%s on %s touches more than %s rows (query.undo_rows)",
          p.kind:upper(),
          schemamod.display_name(p.table),
          util.fmt_int(max_rows)
        )
      else
        entries[#entries + 1] = entry_from(p, set)
      end
    end
    cb(#entries > 0 and entries or nil, note())
  end)
end

---Entries whose statement actually ran: all of them after a successful run;
---after a failure, only the ones before the failing statement when the cell
---did not run inside one transaction.
---@param entries dbgrid.UndoEntry[]?
---@param res { ok: boolean, error?: { stmt_index?: integer } }
---@param transaction boolean
---@return dbgrid.UndoEntry[]?
function M.applied(entries, res, transaction)
  if not entries then
    return nil
  end
  if res.ok then
    return entries
  end
  if transaction then
    return nil
  end
  local failed = res.error and res.error.stmt_index or 1
  local kept = {}
  for _, e in ipairs(entries) do
    if e.stmt_index < failed then
      kept[#kept + 1] = e
    end
  end
  return #kept > 0 and kept or nil
end

local NUMERIC = {
  "^int",
  "^smallint",
  "^bigint",
  "^integer",
  "^serial",
  "^bigserial",
  "^smallserial",
  "^numeric",
  "^decimal",
  "^real",
  "^double",
  "^float",
  "^money$",
  "^oid$",
  "^tinyint",
  "^mediumint",
  "^unsigned",
}

---SQL literal for a captured value: numbers and booleans bare when the
---column's type says so (a text column keeps '00123' as text), everything
---else a quoted string, which the server casts to the column's type.
---@param v any
---@param type_name? string
---@return string
function M.literal(v, type_name)
  if v == nil or v == vim.NIL then
    return "NULL"
  end
  local s = tostring(v)
  local t = (type_name or ""):lower()
  if t == "boolean" or t == "bool" then
    if s == "t" or s == "true" then
      return "true"
    elseif s == "f" or s == "false" then
      return "false"
    end
  end
  for _, pat in ipairs(NUMERIC) do
    if t:find(pat) and s:match("^%-?%d+%.?%d*$") then
      return s
    end
  end
  return util.sql_literal(s)
end

---Primary-key condition for one captured row.
---@param e dbgrid.UndoEntry
---@param row any[]
---@return string
local function key_where(e, row)
  local parts = {}
  for _, k in ipairs(e.key) do
    local v = row[k]
    if v == nil or v == vim.NIL then
      parts[#parts + 1] = util.sql_ident(e.columns[k]) .. " IS NULL"
    else
      parts[#parts + 1] = util.sql_ident(e.columns[k]) .. " = " .. M.literal(v, e.types[k])
    end
  end
  return table.concat(parts, " AND ")
end

---The statements that put one entry's rows back: an INSERT of the deleted
---rows, or one UPDATE per row restoring the assigned columns.
---@param e dbgrid.UndoEntry
---@return string[] lines
function M.reverse_lines(e)
  local lines = {}
  if #e.rows == 0 then
    return lines
  end
  local is_key = {}
  for _, k in ipairs(e.key) do
    is_key[k] = true
  end
  if e.kind == "delete" then
    local names = {}
    for k, name in ipairs(e.columns) do
      names[k] = util.sql_ident(name)
    end
    lines[#lines + 1] = string.format("INSERT INTO %s (%s)", e.ref, table.concat(names, ", "))
    if e.overriding then
      lines[#lines + 1] = "OVERRIDING SYSTEM VALUE"
    end
    lines[#lines + 1] = "VALUES"
    for r, row in ipairs(e.rows) do
      local vals = {}
      for k = 1, #e.columns do
        vals[k] = M.literal(row[k], e.types[k])
      end
      lines[#lines + 1] = "  (" .. table.concat(vals, ", ") .. ")" .. (r < #e.rows and "," or ";")
    end
    return lines
  end
  -- update: SET every captured non-key column back, row by row
  local set_cols = {}
  for k = 1, #e.columns do
    if not is_key[k] then
      set_cols[#set_cols + 1] = k
    end
  end
  if #set_cols == 0 then
    -- the statement only touched key columns: restore them through the new values is impossible
    -- without knowing them; say so instead of writing a no-op
    lines[#lines + 1] = "-- " .. e.table .. ": the UPDATE changed only primary-key columns; nothing to restore by key"
    return lines
  end
  for _, row in ipairs(e.rows) do
    local sets = {}
    for _, k in ipairs(set_cols) do
      sets[#sets + 1] = util.sql_ident(e.columns[k]) .. " = " .. M.literal(row[k], e.types[k])
    end
    lines[#lines + 1] = string.format("UPDATE %s SET %s WHERE %s;", e.ref, table.concat(sets, ", "), key_where(e, row))
  end
  return lines
end

---Body of the undo cell for a result: directives, a comment per statement
---saying what is restored, and the reverse statements, last write first.
---@param result table          the cell's result (with `undo`)
---@param opts? { conn?: string, label?: string }
---@return string[]? lines, string? err
function M.cell_body(result, opts)
  opts = opts or {}
  local entries = result and result.undo
  if not entries or #entries == 0 then
    return nil, "no rows were kept before this cell ran"
  end
  local lines = {}
  if opts.conn then
    lines[#lines + 1] = "-- @conn " .. opts.conn
  end
  local when = result.ran_at and os.date("%Y-%m-%d %H:%M:%S", result.ran_at) or "?"
  lines[#lines + 1] = string.format(
    "-- undo of %s, run at %s%s: the rows as they were right before it",
    opts.label or "the cell",
    when,
    result.connection and (" on " .. result.connection) or ""
  )
  for i = #entries, 1, -1 do
    local e = entries[i]
    local n = #e.rows
    local rows = util.fmt_int(n) .. (n == 1 and " row" or " rows")
    if e.kind == "delete" then
      lines[#lines + 1] = string.format("-- re-inserts %s deleted from %s", rows, e.table)
    else
      lines[#lines + 1] = string.format("-- restores %s of %s changed by the UPDATE", rows, e.table)
      if e.key_changed then
        lines[#lines + 1] = "-- the UPDATE assigned a primary-key column too; the WHERE below uses the old key"
      end
    end
    vim.list_extend(lines, M.reverse_lines(e))
  end
  return lines
end

---One line for the footer of a result: what was kept, or why nothing was.
---@param result table
---@param key_hint string   how the undo key is shown
---@return string? text, boolean warn
function M.footer(result, key_hint)
  local icons = config.get().icons
  if result.undo and #result.undo > 0 then
    local parts = {}
    for _, e in ipairs(result.undo) do
      parts[#parts + 1] = util.fmt_int(#e.rows) .. " " .. (#e.rows == 1 and "row" or "rows") .. " of " .. e.table
    end
    return string.format(
      " %s %s kept before the %s%s",
      icons.undo or "↶",
      table.concat(parts, ", "),
      result.undo[1].kind == "delete" and "DELETE" or "UPDATE",
      key_hint ~= "" and ("; " .. key_hint .. " writes the undo as a cell") or ""
    ),
      false
  end
  if result.undo_skipped then
    return " " .. (icons.warn or "⚠") .. " " .. result.undo_skipped, true
  end
  return nil, false
end

---Write the undo of a cell's last run as a new cell below it (`\u`,
---`:Dbgrid undo`). Nothing runs until that cell is run.
---@param s dbgrid.State
---@param cell? dbgrid.Cell   the cell whose result is shown when nil
---@return string? id
function M.write_cell(s, cell)
  cell = cell or (s.view.cell_id and cells.by_id(s.buf, s.view.cell_id)) or nil
  if not cell then
    util.notify("put the cursor on a cell first")
    return nil
  end
  local result = notebook.result_of(s.nb, cell.id)
  if not result then
    util.notify("this cell has not run yet")
    return nil
  end
  local conn = result.connection
  if conn and conn == s.nb.meta.connection then
    conn = nil
  end
  local label = cell.title and cell.title ~= "" and ('"' .. cell.title .. '"') or ("q" .. cell.index)
  local body, err = M.cell_body(result, { conn = conn, label = label })
  if not body then
    util.notify(err or "nothing to undo")
    return nil
  end
  local title = "undo " .. (cell.title and cell.title ~= "" and cell.title or ("q" .. cell.index))
  local id, lnum = cells.insert(s.buf, "below", cell, title)
  vim.api.nvim_buf_set_lines(s.buf, lnum, lnum + 1, false, body)
  vim.b[s.buf].dbgrid_cells_cache = nil
  local query = require("dbgrid.ui.query")
  query.render(s)
  if s.query_win and vim.api.nvim_win_is_valid(s.query_win) then
    pcall(vim.api.nvim_win_set_cursor, s.query_win, { lnum + 1, 0 })
  end
  require("dbgrid.ui.layout").focus_query(s)
  local n = 0
  for _, e in ipairs(result.undo) do
    n = n + #e.rows
  end
  util.notify(
    string.format("undo written as cell %s (%s %s): review it and run it", id, util.fmt_int(n), n == 1 and "row" or "rows")
  )
  return id
end

return M
