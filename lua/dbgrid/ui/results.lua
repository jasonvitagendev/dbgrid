-- The results pane: grid, record and plan views of the active cell's result.
local config = require("dbgrid.config")
local util = require("dbgrid.util")
local cells = require("dbgrid.cells")
local notebook = require("dbgrid.notebook")
local state_mod = require("dbgrid.state")

local M = {}

M.ns = vim.api.nvim_create_namespace("dbgrid.results")

local NUMBER = "^%-?%d+%.?%d*[eE]?[%-+]?%d*$"
local BOOL = { t = true, f = true, ["true"] = true, ["false"] = true }

local function map(buf, keys, fn, desc, modes)
  if not keys then
    return
  end
  if type(keys) == "string" then
    keys = { keys }
  end
  for _, k in ipairs(keys) do
    vim.keymap.set(modes or "n", k, fn, { buffer = buf, desc = "dbgrid: " .. desc, silent = true, nowait = true })
  end
end

---@param s dbgrid.State
local function current_result(s)
  if not s.view.cell_id then
    return nil
  end
  return notebook.result_of(s.nb, s.view.cell_id)
end

---Flatten the result sets of a result.
---@param result table
---@return { set: dbgrid.ResultSet, stmt: dbgrid.StatementResult, stmt_index: integer }[]
local function all_sets(result)
  local out = {}
  for i, st in ipairs(result.statements or {}) do
    for _, set in ipairs(st.sets or {}) do
      out[#out + 1] = { set = set, stmt = st, stmt_index = i }
    end
  end
  return out
end

---@param v any
---@return string
local function raw_text(v)
  if v == vim.NIL or v == nil then
    return "NULL"
  end
  return tostring(v)
end

local function is_number(v)
  return v ~= vim.NIL and v ~= "" and v:match(NUMBER) ~= nil and v:match("%d") ~= nil
end

---Rows of a set after the view's filter and sort.
---@param s dbgrid.State
---@param entry { set: dbgrid.ResultSet, stmt: dbgrid.StatementResult, stmt_index: integer }
---@return any[][]
function M.display_rows(s, entry)
  local rows = entry.set.rows
  local view = s.view
  if view.filter and view.filter ~= "" then
    local needle = view.filter:lower()
    local kept = {}
    for _, row in ipairs(rows) do
      for _, v in ipairs(row) do
        if v ~= vim.NIL and tostring(v):lower():find(needle, 1, true) then
          kept[#kept + 1] = row
          break
        end
      end
    end
    rows = kept
  end
  if view.sort and view.sort.col and view.sort.set == entry.stmt_index then
    local col = view.sort.col
    local desc = view.sort.dir == "desc"
    local indexed = {}
    for i, row in ipairs(rows) do
      indexed[i] = { i = i, row = row }
    end
    table.sort(indexed, function(a, b)
      local va, vb = a.row[col], b.row[col]
      if va == vim.NIL and vb == vim.NIL then
        return a.i < b.i
      elseif va == vim.NIL then
        return false
      elseif vb == vim.NIL then
        return true
      end
      local na, nb = tonumber(va), tonumber(vb)
      local less
      if na and nb then
        if na == nb then
          return a.i < b.i
        end
        less = na < nb
      else
        if va == vb then
          return a.i < b.i
        end
        less = tostring(va) < tostring(vb)
      end
      if desc then
        return not less
      end
      return less
    end)
    rows = vim.tbl_map(function(e)
      return e.row
    end, indexed)
  end
  local max = config.get().results.max_render_rows or 2000
  if #rows > max then
    rows = vim.list_slice(rows, 1, max)
  end
  return rows
end

---Build one set as grid lines.
---@param s dbgrid.State
---@param entry table
---@param ctx { lines: string[], line_hl: table, rows_layout: table, header_layout: table }
local function render_set(s, entry, ctx)
  local cfg = config.get().results
  local set = entry.set
  local columns = set.columns
  local rows = M.display_rows(s, entry)
  local truncate = s.view.truncate ~= false
  local ncols = #columns
  -- formatted values, numeric / bool detection, widths
  local widths, numeric, boolean = {}, {}, {}
  for j = 1, ncols do
    widths[j] = util.width(columns[j])
    numeric[j] = #rows > 0
    boolean[j] = #rows > 0
  end
  local formatted = {}
  for i, row in ipairs(rows) do
    local frow = {}
    for j = 1, ncols do
      local v = row[j]
      local text
      if v == vim.NIL or v == nil then
        text = cfg.null_text
        if numeric[j] and (i == #rows) and not frow.seen_value then
          -- all nulls so far; keep flags, decided below
        end
      else
        text = tostring(v):gsub("\r?\n", cfg.newline):gsub("\t", "  ")
        if not is_number(v) then
          numeric[j] = false
        end
        if not BOOL[v] then
          boolean[j] = false
        end
      end
      frow[j] = text
      local w = util.width(text)
      if w > widths[j] then
        widths[j] = w
      end
    end
    formatted[i] = frow
  end
  -- a column that is entirely NULL is neither numeric nor boolean
  for j = 1, ncols do
    local any = false
    for _, row in ipairs(rows) do
      if row[j] ~= vim.NIL and row[j] ~= nil then
        any = true
        break
      end
    end
    if not any then
      numeric[j], boolean[j] = false, false
    end
    if truncate and widths[j] > cfg.max_col_width then
      widths[j] = cfg.max_col_width
    end
  end
  local align_right = cfg.align_numbers

  local function build(values, hl_fn)
    local parts, starts, ends, hls = {}, {}, {}, {}
    local pos = 0
    for j = 1, ncols do
      local text = values[j]
      if truncate then
        text = util.truncate(text, widths[j])
      end
      local padded = util.pad(text, widths[j], align_right and numeric[j])
      if j == 1 then
        parts[#parts + 1] = " "
        pos = pos + 1
      else
        parts[#parts + 1] = " │ "
        hls[#hls + 1] = { pos + 1, pos + 4, "DbgridSeparator" }
        pos = pos + 4 -- " │ " is 1 + 3 + 1 bytes
      end
      starts[j] = pos
      parts[#parts + 1] = padded
      pos = pos + #padded
      ends[j] = pos
      local hl = hl_fn and hl_fn(j, text)
      if hl then
        hls[#hls + 1] = { starts[j], ends[j], hl }
      end
    end
    return table.concat(parts), starts, ends, hls
  end

  local lines, line_hl = ctx.lines, ctx.line_hl
  -- header
  local header, hstarts, hends, hhls = build(columns, function()
    return "DbgridColumnHeader"
  end)
  lines[#lines + 1] = header
  line_hl[#lines] = hhls
  ctx.header_layout[#lines] = { entry = entry, starts = hstarts, ends = hends }
  -- rule
  local rule = {}
  for j = 1, ncols do
    rule[#rule + 1] = string.rep("─", widths[j] + (j == 1 and 1 or 0) + (j == ncols and 1 or 0))
  end
  local rule_line = table.concat(rule, "─┼─")
  lines[#lines + 1] = rule_line
  line_hl[#lines] = { { 0, #rule_line, "DbgridRule" } }
  -- rows
  local live = s.live and s.view.cell_id and s.live[s.view.cell_id]
  local changed = live and live.changed or nil
  for i, frow in ipairs(formatted) do
    local raw = rows[i]
    local row_changed = changed and changed[raw] or nil
    local line, starts, ends, hls = build(frow, function(j)
      if row_changed and (row_changed[j] or row_changed[0]) then
        return "DbgridChanged"
      end
      local v = raw[j]
      if v == vim.NIL or v == nil then
        return "DbgridNull"
      elseif numeric[j] then
        return "DbgridNumber"
      elseif boolean[j] then
        return "DbgridBool"
      end
    end)
    lines[#lines + 1] = line
    line_hl[#lines] = hls
    ctx.rows_layout[#lines] = { entry = entry, row = raw, row_index = i, starts = starts, ends = ends }
  end
  if #rows == 0 then
    lines[#lines + 1] = " (no rows)"
    line_hl[#lines] = { { 0, 10, "DbgridStatusDim" } }
  end
  entry.display_count = #rows
end

---Lines for a result that errored / produced tags / notices.
---@param result table
---@param ctx table
local function render_notices(result, ctx)
  local icons = config.get().icons
  local lines, line_hl = ctx.lines, ctx.line_hl
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      line_hl[#lines] = { { 0, #text, hl } }
    end
  end
  local before = #lines
  for _, w in ipairs(result.warnings or {}) do
    add(icons.warn .. " " .. (type(w) == "table" and w.message or tostring(w)), "DbgridWarn")
  end
  for _, n in ipairs(result.notices or {}) do
    for _, l in ipairs(util.lines(n)) do
      add(l, "DbgridNotice")
    end
  end
  if result.error then
    local e = result.error
    add(icons.error .. " " .. (e.cancelled and "cancelled" or ("ERROR: " .. e.message)), "DbgridError")
    if e.line then
      add(
        string.format("  at line %d%s of the cell", e.line, e.col and (", column " .. e.col) or ""),
        "DbgridStatusDim"
      )
    end
    if e.detail then
      add("  DETAIL: " .. e.detail, "DbgridStatusDim")
    end
    if e.hint then
      add("  HINT: " .. e.hint, "DbgridNotice")
    end
    if e.context then
      add("  CONTEXT: " .. e.context, "DbgridStatusDim")
    end
  end
  if #lines > before then
    add("")
  end
end

---@param s dbgrid.State
---@param result table
---@param ctx table
local function render_footer(s, result, ctx)
  local icons = config.get().icons
  local lines, line_hl = ctx.lines, ctx.line_hl
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      line_hl[#lines] = { { 0, #text, hl } }
    end
  end
  local total = 0
  local limit
  local evicted = false
  for _, st in ipairs(result.statements or {}) do
    if st.limit_applied then
      limit = st.limit_applied
    end
    for _, set in ipairs(st.sets or {}) do
      total = total + (set.row_count or #set.rows)
      if set.evicted then
        evicted = true
      end
    end
  end
  local parts = {}
  parts[#parts + 1] = util.fmt_int(total) .. (total == 1 and " row" or " rows")
  parts[#parts + 1] = util.fmt_ms(result.elapsed_ms or 0)
    .. (result.server_ms and result.server_ms > 0 and (" (server " .. util.fmt_ms(result.server_ms) .. ")") or "")
  if limit then
    parts[#parts + 1] = "LIMIT " .. limit .. " added"
  end
  if result.ran_at then
    parts[#parts + 1] = os.date("%H:%M:%S", result.ran_at) .. " · " .. util.ago(result.ran_at)
  end
  if result.connection then
    parts[#parts + 1] = "via " .. result.connection
  end
  if result.dry_run then
    parts[#parts + 1] = "dry run, rolled back"
  end
  local live = s.live and s.view.cell_id and s.live[s.view.cell_id]
  if live then
    parts[#parts + 1] = string.format(
      "%s live every %s · tick %d%s",
      icons.live,
      util.fmt_ms(live.interval),
      live.ticks or 0,
      (live.changed_count or 0) > 0 and (" · " .. live.changed_count .. " changed") or ""
    )
  end
  if #lines > 0 and lines[#lines] ~= "" then
    add("")
  end
  add(" " .. table.concat(parts, " · "), "DbgridFooter")
  if result.params and next(result.params) then
    local names = vim.tbl_keys(result.params)
    table.sort(names)
    local shown = {}
    for _, name in ipairs(names) do
      shown[#shown + 1] = ":" .. name .. " = " .. tostring(result.params[name])
    end
    add(" with " .. table.concat(shown, ", "), "DbgridFooter")
  end
  if result.refs and #result.refs > 0 then
    local names = {}
    for _, id in ipairs(result.refs) do
      local c = cells.by_id(s.buf, id)
      names[#names + 1] = c and cells.ref_name(c) or id
    end
    add(" inlines " .. table.concat(util.uniq(names), ", "), "DbgridFooter")
  end
  if result.truncated then
    add(
      " "
        .. icons.warn
        .. " only the first "
        .. limit
        .. " rows were fetched (LIMIT "
        .. limit
        .. " was added); write your own LIMIT to change it",
      "DbgridWarn"
    )
  end
  if evicted then
    add(
      " "
        .. icons.warn
        .. " the cached copy keeps "
        .. (config.get().storage.cache_rows or 500)
        .. " rows; re-run to see everything",
      "DbgridWarn"
    )
  end
end

---@param s dbgrid.State
---@param cell dbgrid.Cell?
---@param ctx table
local function render_placeholder(s, cell, ctx)
  local cfg = config.get()
  local icons = cfg.icons
  local k = cfg.keymaps.query
  local function key(v)
    if type(v) == "table" then
      v = v[1]
    end
    return (tostring(v or ""):gsub("<localleader>", vim.g.maplocalleader or "\\"):gsub("<CR>", "Enter"))
  end
  local lines, line_hl = ctx.lines, ctx.line_hl
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      line_hl[#lines] = { { 0, #text, hl } }
    end
  end
  local rt = cell and s.runtime[cell.id] or {}
  if rt.status == "generating" then
    add(" " .. icons.generated .. " generating SQL…", "DbgridStatusRunning")
    return
  end
  add(" " .. icons.idle .. " this cell has not been run yet", "DbgridStatusDim")
  add("")
  local rows = {
    { key(k.run), "run the cell (SELECTs get LIMIT " .. tostring(cfg.query.limit) .. " when they have none)" },
    { key(k.explain) .. "  " .. key(k.explain_analyze), "explain · explain analyze (rolled back)" },
    { key(k.generate), "generate SQL from a `-- ? prompt` line" },
    { key(k.next_cell) .. "  " .. key(k.prev_cell), "next · previous cell" },
    { key(k.new_cell) .. "  " .. key(k.new_cell_below), "new cell at the end · below this one" },
    { key(k.clone_cell) .. "  " .. key(k.last_error), "clone the cell · show its last error" },
    { key(k.tags) .. "  " .. key(k.connection), "tags · connection" },
    { key(k.tables) .. "  " .. key(k.describe), "browse tables · describe the identifier under the cursor" },
    { key(k.schema_view) .. "  " .. key(k.params), "schema document (foldable) · parameters" },
    { key(k.format) .. "  " .. key(k.agent), "format the cell · pick the coding agent" },
    { key(k.analyze) .. "  " .. key(k.explain_error), "analyze the plan · explain the error (agent)" },
    { key(k.focus_results), "jump to this pane" },
  }
  for _, r in ipairs(rows) do
    local text = "   " .. util.pad(r[1], 12) .. r[2]
    add(text)
    line_hl[#lines] = { { 0, 3 + 12, "DbgridKey" }, { 15, #text, "DbgridStatusDim" } }
  end
  if cell and rt.warnings and #rt.warnings > 0 then
    add("")
    for _, w in ipairs(rt.warnings) do
      add(" " .. icons.warn .. " " .. w.message, "DbgridWarn")
    end
  end
end

---@param s dbgrid.State
---@param result table
---@param ctx table
local function render_record(s, result, ctx)
  local cfg = config.get().results
  local sets = all_sets(result)
  local entry = sets[s.view.record_set or 1] or sets[1]
  local lines, line_hl = ctx.lines, ctx.line_hl
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      line_hl[#lines] = { { 0, #text, hl } }
    end
  end
  if not entry then
    add(" (no rows)", "DbgridStatusDim")
    return
  end
  local rows = M.display_rows(s, entry)
  local idx = math.max(1, math.min(s.view.record_row or 1, #rows))
  s.view.record_row = idx
  local row = rows[idx]
  if not row then
    add(" (no rows)", "DbgridStatusDim")
    return
  end
  add(string.format(" row %d of %d", idx, #rows), "DbgridSetTitle")
  add("")
  local w = 0
  for _, c in ipairs(entry.set.columns) do
    w = math.max(w, util.width(c))
  end
  for j, c in ipairs(entry.set.columns) do
    local v = row[j]
    local text = (v == vim.NIL or v == nil) and cfg.null_text or tostring(v)
    local vlines = util.lines(text)
    for k, vl in ipairs(vlines) do
      local prefix = k == 1 and (" " .. util.pad(c, w) .. " │ ") or (" " .. string.rep(" ", w) .. " │ ")
      local line = prefix .. vl
      lines[#lines + 1] = line
      local hls = { { 0, #prefix, k == 1 and "DbgridColumnHeader" or "DbgridSeparator" } }
      if v == vim.NIL or v == nil then
        hls[#hls + 1] = { #prefix, #line, "DbgridNull" }
      elseif is_number(v) then
        hls[#hls + 1] = { #prefix, #line, "DbgridNumber" }
      end
      line_hl[#lines] = hls
      ctx.rows_layout[#lines] = { entry = entry, row = row, row_index = idx, col = j, record = true }
    end
  end
end

---@param s dbgrid.State
---@param cell dbgrid.Cell?
---@param result table?
---@param ctx table
local function render_plan(s, cell, result, ctx)
  local lines, line_hl = ctx.lines, ctx.line_hl
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      line_hl[#lines] = { { 0, #text, hl } }
    end
  end
  local icons = config.get().icons
  local rt = cell and s.runtime[cell.id] or {}
  local explain = require("dbgrid.explain")
  if result and result.analysis and result.analysis.text then
    add(
      string.format(" %s analysis (%s, %s)", icons.generated, result.analysis.kind or "", util.ago(result.analysis.at)),
      "DbgridSetTitle"
    )
    for _, l in ipairs(util.lines(result.analysis.text)) do
      add(l)
    end
    add("")
  end
  if rt.plan_text then
    local title = " " .. (rt.plan_kind or "EXPLAIN")
    if rt.plan_params and next(rt.plan_params) then
      local names = vim.tbl_keys(rt.plan_params)
      table.sort(names)
      local shown = {}
      for _, name in ipairs(names) do
        shown[#shown + 1] = ":" .. name .. " = " .. tostring(rt.plan_params[name])
      end
      title = title .. "  with " .. table.concat(shown, ", ")
    end
    add(title, "DbgridSetTitle")
    local info = rt.plan_info or {}
    local findings = info.findings or {}
    if #findings > 0 then
      add("")
      for _, f in ipairs(findings) do
        add(
          " " .. (f.severity == "warn" and icons.warn or "ℹ") .. " " .. f.message,
          f.severity == "warn" and "DbgridFindingWarn" or "DbgridFindingInfo"
        )
        if f.suggestion then
          add("     → " .. f.suggestion, "DbgridStatusDim")
        end
      end
    elseif rt.plan_kind == "EXPLAIN ANALYZE" and info.plan then
      add("")
      add(" " .. icons.ok .. " row estimates, sorts and hashes look fine", "DbgridStatusOk")
    end
    add("")
    local marks = info.marks or {}
    for i, l in ipairs(rt.plan_text) do
      add(l, l:match("^ERROR") and "DbgridError" or marks[i])
    end
    return
  end
  local any = false
  for i, st in ipairs(result and result.statements or {}) do
    if st.plan then
      any = true
      local cost = explain.total_cost(st.plan)
      add(
        string.format(
          " plan for statement %d (%s)%s",
          i,
          st.kind:upper(),
          cost and (", estimated cost " .. tostring(cost)) or ""
        ),
        "DbgridSetTitle"
      )
      add("")
      local plan_lines, marks = explain.to_lines(st.plan)
      for j, l in ipairs(plan_lines) do
        add(l, marks[j])
      end
      add("")
    end
  end
  if not any then
    add(" no plan yet: run the cell (index check on) or use the explain keymap", "DbgridStatusDim")
  end
end

local KIND_NAME = { r = "table", v = "view", m = "materialized view", p = "partitioned table", f = "foreign table" }

---Lines of the schema document: one foldable block per table with its
---columns, indexes and foreign keys.
---@param sch dbgrid.SchemaData
---@param opts? { filter?: string, icons?: table }
---@return string[] lines, table<integer, table> line_hl, table<integer, dbgrid.SchemaTable> tables_at
function M.schema_lines(sch, opts)
  opts = opts or {}
  local icons = opts.icons or config.get().icons
  local schemamod = require("dbgrid.schema")
  local lines, hls, tables_at = {}, {}, {}
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      hls[#lines] = hl
    end
  end
  local filter = opts.filter and opts.filter:lower() or nil
  local sorted = vim.list_slice(sch.tables, 1, #sch.tables)
  table.sort(sorted, function(a, b)
    if a.schema ~= b.schema then
      if a.schema == "public" or a.schema == "main" then
        return true
      elseif b.schema == "public" or b.schema == "main" then
        return false
      end
      return a.schema < b.schema
    end
    return a.name < b.name
  end)
  for _, t in ipairs(sorted) do
    local name = schemamod.display_name(t)
    if not filter or name:lower():find(filter, 1, true) then
      local head = icons.table .. " " .. name
      local summary = string.format(
        "  ~%s rows · %d cols · %d %s%s",
        util.fmt_int(t.rows or 0),
        #(t.columns or {}),
        #(t.indexes or {}),
        #(t.indexes or {}) == 1 and "index" or "indexes",
        t.kind ~= "r" and ("  " .. (KIND_NAME[t.kind] or t.kind)) or ""
      )
      add(head .. summary, { { 0, #head, "DbgridSchemaTable" }, { #head, #head + #summary, "DbgridSchemaDim" } })
      tables_at[#lines] = t
      if t.comment then
        add("    " .. t.comment, { { 0, 4 + #t.comment, "DbgridSchemaDim" } })
      end
      local pk, fk = {}, {}
      for _, con in ipairs(t.constraints or {}) do
        if con.type == "p" then
          for _, c in ipairs(con.columns or {}) do
            pk[c] = true
          end
        elseif con.type == "f" then
          for i, c in ipairs(con.columns or {}) do
            fk[c] = (con.ref_table or "?"):gsub("^public%.", ""):gsub("^main%.", "")
              .. "("
              .. ((con.ref_columns or {})[i] or "?")
              .. ")"
          end
        end
      end
      local w = 0
      for _, c in ipairs(t.columns or {}) do
        w = math.max(w, util.width(c.name))
      end
      for _, c in ipairs(t.columns or {}) do
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
        local col_part = "    " .. util.pad(c.name, w)
        local type_part = "  " .. c.type
        local flag_part = #flags > 0 and ("  " .. table.concat(flags, ", ")) or ""
        if c.comment then
          flag_part = flag_part .. "  -- " .. c.comment
        end
        add(col_part .. type_part .. flag_part, {
          { 4, #col_part, "DbgridSchemaColumn" },
          { #col_part + 2, #col_part + #type_part, "DbgridSchemaType" },
          { #col_part + #type_part, #col_part + #type_part + #flag_part, "DbgridSchemaDim" },
        })
      end
      if #(t.indexes or {}) > 0 then
        add("    indexes", { { 0, 11, "DbgridSchemaDim" } })
        for _, ix in ipairs(t.indexes) do
          local kind = ix.primary and "PRIMARY KEY" or (ix.unique and "UNIQUE" or "")
          local cols = "(" .. table.concat(ix.columns or {}, ", ") .. ")"
          local method = ix.def and ix.def:match("USING (%a+)")
          local ix_line = "      " .. icons.index .. " " .. ix.name
          local rest = "  "
            .. cols
            .. (kind ~= "" and ("  " .. kind) or "")
            .. (method and method ~= "btree" and ("  " .. method) or "")
          add(
            ix_line .. rest,
            { { 6, #ix_line, "DbgridSchemaIndex" }, { #ix_line, #ix_line + #rest, "DbgridSchemaDim" } }
          )
        end
      end
      add("")
    end
  end
  if #lines == 0 then
    add(
      filter and (" no table matches “" .. opts.filter .. "”") or " (no tables)",
      { { 0, 40, "DbgridStatusDim" } }
    )
  end
  return lines, hls, tables_at
end

---Fold expression for the schema document: every table is one fold.
---@param lnum integer
---@return string
function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  if line == "" then
    return "0"
  end
  if line:sub(1, 1) ~= " " then
    return ">1"
  end
  return "1"
end

---Window options that make the schema document foldable (and undo them).
---@param win integer
---@param on boolean
local function fold_options(win, on)
  local wo = vim.wo[win]
  if on then
    wo.foldenable = true
    wo.foldmethod = "expr"
    wo.foldexpr = "v:lua.require'dbgrid.ui.results'.foldexpr(v:lnum)"
    wo.foldtext = ""
    wo.foldlevel = 0
    wo.foldminlines = 0
    wo.fillchars = "fold: "
  elseif wo.foldmethod == "expr" then
    wo.foldenable = false
    wo.foldmethod = "manual"
    wo.foldexpr = "0"
    wo.foldtext = "foldtext()"
  end
end

---@param s dbgrid.State
---@param ctx table
---@return boolean? changed   false when the document is already up to date
local function render_schema(s, ctx)
  local icons = config.get().icons
  local lines, line_hl = ctx.lines, ctx.line_hl
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      line_hl[#lines] = { { 0, #text, hl } }
    end
  end
  local conn_name = s.nb.meta.connection
  local conn = conn_name and require("dbgrid.connections").get(conn_name)
  if not conn then
    add(" no connection yet: pick one with " .. tostring(config.get().keymaps.query.connection), "DbgridStatusDim")
    s.view.schema_key = nil
    return true
  end
  local schemamod = require("dbgrid.schema")
  local sch = schemamod.loaded(conn)
  if not sch then
    add(" " .. icons.running .. " loading the schema of " .. conn.name .. "…", "DbgridStatusRunning")
    s.view.schema_key = nil
    if not s.view.schema_loading then
      s.view.schema_loading = true
      schemamod.get(conn, function(_, err)
        s.view.schema_loading = nil
        if err then
          util.warn("schema: " .. err)
        end
        if s.view.mode == "schema" then
          M.render(s, true)
        end
      end)
    end
    return true
  end
  local key = schemamod.key(conn) .. ":" .. tostring(sch.fetched_at) .. ":" .. tostring(s.view.schema_filter)
  if s.view.schema_key == key then
    return false
  end
  s.view.schema_key = key
  local doc, hls, tables_at = M.schema_lines(sch, { filter = s.view.schema_filter, icons = icons })
  for i, l in ipairs(doc) do
    lines[#lines + 1] = l
    line_hl[#lines] = hls[i]
  end
  s.view.schema_tables = tables_at
  return true
end

---Table of the schema document line under the cursor (header or detail line).
---@param s dbgrid.State
---@return dbgrid.SchemaTable?, integer? header_lnum
local function schema_table_at_cursor(s)
  local win = s.results_win
  if not win or not vim.api.nvim_win_is_valid(win) or not s.view.schema_tables then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  for l = lnum, 1, -1 do
    local t = s.view.schema_tables[l]
    if t then
      return t, l
    end
    if l < lnum and vim.api.nvim_buf_get_lines(s.results_buf, l - 1, l, false)[1] == "" then
      return nil
    end
  end
  return nil
end

---Open the folds of the tables the current cell refers to and land on the first.
---@param s dbgrid.State
local function reveal_referenced_tables(s)
  local win = s.results_win
  local cell = s.view.cell_id and cells.by_id(s.buf, s.view.cell_id)
  if not cell or not win or not vim.api.nvim_win_is_valid(win) or not s.view.schema_tables then
    return
  end
  local wanted = {}
  for _, ref in ipairs(require("dbgrid.sql").referenced_tables(cells.body_text(cell))) do
    wanted[ref.name:lower():gsub('"', "")] = true
  end
  local first
  local schemamod = require("dbgrid.schema")
  for lnum, t in pairs(s.view.schema_tables) do
    if wanted[t.name:lower()] or wanted[schemamod.display_name(t):lower()] then
      if not first or lnum < first then
        first = lnum
      end
      vim.api.nvim_win_call(win, function()
        pcall(vim.cmd, lnum .. "foldopen")
      end)
    end
  end
  if first then
    pcall(vim.api.nvim_win_set_cursor, win, { first, 0 })
  end
end

---Toggle the schema document in the results pane.
---@param s dbgrid.State
function M.toggle_schema(s)
  require("dbgrid.ui.layout").ensure_results(s)
  if s.view.mode == "schema" then
    s.view.mode = "grid"
    s.view.schema_key = nil
    M.render(s, true)
    return
  end
  s.view.mode = "schema"
  s.view.schema_key = nil
  M.render(s, true)
end

---Keys that mean something else in the schema document.
---@param s dbgrid.State
---@param action "toggle"|"describe"|"yank"|"next"|"prev"|"filter"
---@return boolean handled
function M.schema_action(s, action)
  if s.view.mode ~= "schema" then
    return false
  end
  local win = s.results_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return true
  end
  if action == "toggle" then
    local _, header = schema_table_at_cursor(s)
    if header then
      vim.api.nvim_win_call(win, function()
        pcall(vim.api.nvim_win_set_cursor, win, { header, 0 })
        pcall(vim.cmd, "normal! za")
      end)
    end
  elseif action == "describe" then
    local t = schema_table_at_cursor(s)
    if t then
      local schemamod = require("dbgrid.schema")
      local conn = s.nb.meta.connection and require("dbgrid.connections").get(s.nb.meta.connection)
      vim.lsp.util.open_floating_preview(
        schemamod.describe_lines(t, conn and schemamod.loaded(conn) or nil),
        "",
        { border = "rounded", focusable = true, title = " " .. schemamod.display_name(t) .. " " }
      )
    end
  elseif action == "yank" then
    local t, header = schema_table_at_cursor(s)
    if t then
      local lnum = vim.api.nvim_win_get_cursor(win)[1]
      local text = require("dbgrid.schema").display_name(t)
      if lnum ~= header then
        local line = vim.api.nvim_buf_get_lines(s.results_buf, lnum - 1, lnum, false)[1] or ""
        local col = line:match('^    ([%w_"]+)%s')
        if col then
          text = col
        end
      end
      vim.fn.setreg('"', text)
      pcall(vim.fn.setreg, "+", text)
      util.notify("yanked " .. text)
    end
  elseif action == "next" or action == "prev" then
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local best
    for l in pairs(s.view.schema_tables or {}) do
      if action == "next" and l > lnum and (not best or l < best) then
        best = l
      elseif action == "prev" and l < lnum and (not best or l > best) then
        best = l
      end
    end
    if best then
      pcall(vim.api.nvim_win_set_cursor, win, { best, 0 })
    end
  elseif action == "filter" then
    vim.ui.input({ prompt = "Tables containing: ", default = s.view.schema_filter or "" }, function(input)
      if input == nil then
        return
      end
      s.view.schema_filter = input ~= "" and input or nil
      s.view.schema_key = nil
      M.render(s, true)
    end)
  end
  return true
end

---@param s dbgrid.State
function M.refresh_winbar(s)
  local win = s.results_win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].winbar = "%{%v:lua.require'dbgrid.ui.layout'.winbar_results(" .. s.buf .. ")%}"
  end
end

---@param s dbgrid.State
---@param ctx table
local function render_diff(s, ctx)
  local lines, line_hl = ctx.lines, ctx.line_hl
  local d = s.view.diff
  if not d then
    lines[#lines + 1] = " no diff: run the cell twice, or :Dbgrid diff <connection>"
    line_hl[#lines] = { { 0, #lines[#lines], "DbgridStatusDim" } }
    return
  end
  lines[#lines + 1] = string.format(" %s → %s", d.a_name, d.b_name)
  line_hl[#lines] = { { 0, #lines[#lines], "DbgridSetTitle" } }
  for _, l in ipairs(d.lines) do
    lines[#lines + 1] = l
  end
  for _, h in ipairs(d.hl or {}) do
    local lnum = h[1] + 1
    line_hl[lnum] = line_hl[lnum] or {}
    line_hl[lnum][#line_hl[lnum] + 1] = { h[2], h[3], h[4] }
  end
end

---Diff two results of a cell and show it.
---@param s dbgrid.State
---@param cell_id string
---@param before table
---@param after table
---@param opts { a_name: string, b_name: string }
function M.show_diff(s, cell_id, before, after, opts)
  local diff = require("dbgrid.diff")
  local sets_a, sets_b = all_sets(before), all_sets(after)
  local a, b = sets_a[1], sets_b[1]
  if not a or not b then
    return util.warn("nothing to diff (no rows)")
  end
  local key
  local sql = a.stmt.sql or ""
  local refs = require("dbgrid.sql").referenced_tables(sql)
  local conn = s.nb.meta.connection and require("dbgrid.connections").get(s.nb.meta.connection)
  local sch = conn and require("dbgrid.schema").loaded(conn)
  local tbl = sch and refs[1] and require("dbgrid.schema").find_table(sch, refs[1].name)
  if diff.pick_key then
    key = diff.pick_key(a.set.columns, tbl)
  end
  local d = diff.rows({ columns = a.set.columns, rows = a.set.rows }, { columns = b.set.columns, rows = b.set.rows }, {
    key = key,
  })
  local lines, hl = diff.render(d, b.set.columns, {})
  s.view.cell_id = cell_id
  s.view.mode = "diff"
  s.view.diff = { lines = lines, hl = hl, a_name = opts.a_name, b_name = opts.b_name, result = d }
  M.render(s, true)
  util.notify(
    string.format("diff: %d added, %d removed, %d changed, %d same", #d.added, #d.removed, #d.changed, d.same or 0)
  )
end

---Diff the current result against the previous run of the same cell.
---@param s dbgrid.State
function M.diff_previous(s)
  if s.view.mode == "diff" then
    s.view.mode = "grid"
    return M.render(s, true)
  end
  local id = s.view.cell_id
  local result = current_result(s)
  local previous = id and s.previous and s.previous[id]
  if not result or not previous then
    return util.notify("no previous run to diff against (run the cell again, or :Dbgrid diff <connection>)")
  end
  M.show_diff(s, id, previous, result, {
    a_name = "previous run (" .. os.date("%H:%M:%S", previous.ran_at or 0) .. ")",
    b_name = "this run (" .. os.date("%H:%M:%S", result.ran_at or 0) .. ")",
  })
end

---Text sparkline of the column under the cursor across the live ticks of the cell.
---@param s dbgrid.State
function M.sparkline(s)
  local c = M.cell_at_cursor(s)
  local live = s.live and s.view.cell_id and s.live[s.view.cell_id]
  if not c then
    return util.notify("put the cursor on a value first")
  end
  if not live or #live.history == 0 then
    return util.notify("no live history for this cell (start it with -- @every)")
  end
  -- position of the row inside its set
  local pos
  for i, row in ipairs(c.entry.set.rows) do
    if row == c.row then
      pos = i
      break
    end
  end
  local values = {}
  for _, tick in ipairs(live.history) do
    local row = tick.rows[pos or 1]
    local v = row and row[c.col]
    values[#values + 1] = (v ~= nil and v ~= vim.NIL) and tonumber(v) or nil
  end
  local nums = vim.tbl_filter(function(v)
    return v ~= nil
  end, values)
  if #nums == 0 then
    return util.notify("column " .. c.column .. " is not numeric")
  end
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(nums) do
    lo, hi = math.min(lo, v), math.max(hi, v)
  end
  local bars = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  local out = {}
  for _, v in ipairs(values) do
    if v == nil then
      out[#out + 1] = " "
    elseif hi == lo then
      out[#out + 1] = bars[4]
    else
      out[#out + 1] = bars[math.max(1, math.min(8, math.floor((v - lo) / (hi - lo) * 7 + 1.5)))]
    end
  end
  local lines = {
    table.concat(out),
    string.format(
      "%s · %d ticks · min %s · max %s · last %s",
      c.column,
      #values,
      tostring(lo),
      tostring(hi),
      tostring(nums[#nums])
    ),
  }
  vim.lsp.util.open_floating_preview(lines, "", { border = "rounded", title = " live " .. c.column .. " " })
end

---Show arbitrary rows (aws status, events, ...) in the results pane, or in a
---scratch buffer when no notebook is open.
---@param s dbgrid.State?
---@param set { columns: string[], rows: any[][] }
---@param opts? { title?: string }
function M.show_rows(s, set, opts)
  opts = opts or {}
  local result = {
    ok = true,
    ran_at = require("dbgrid.util").epoch(),
    elapsed_ms = 0,
    statements = {
      {
        sql = opts.title or "",
        kind = "select",
        class = "read",
        sets = { { columns = set.columns, rows = set.rows, row_count = #set.rows } },
        tags = {},
      },
    },
    notices = opts.title and { opts.title } or {},
  }
  if s and vim.api.nvim_buf_is_valid(s.buf) then
    local id = "__" .. (opts.title or "rows"):gsub("[^%w]+", "_")
    notebook.set_result_memory(s.nb, { id = id }, result)
    require("dbgrid.ui.layout").ensure_results(s)
    s.view = { truncate = s.view.truncate, cell_id = id, mode = "grid" }
    M.render(s, true)
    return
  end
  local lines = {}
  local widths = {}
  for j, c in ipairs(set.columns) do
    widths[j] = util.width(c)
    for _, row in ipairs(set.rows) do
      widths[j] = math.max(widths[j], util.width(raw_text(row[j])))
    end
  end
  local function fmt(vals)
    local parts = {}
    for j = 1, #set.columns do
      parts[j] = util.pad(raw_text(vals[j]), widths[j])
    end
    return " " .. table.concat(parts, " │ ")
  end
  lines[#lines + 1] = fmt(set.columns)
  lines[#lines + 1] = string.rep("─", #lines[1] + 2)
  for _, row in ipairs(set.rows) do
    lines[#lines + 1] = fmt(row)
  end
  require("dbgrid.compare").open_scratch(opts.title or "rows", lines)
end

---Yank the JSON plan of the statement under the cursor (for plan visualizers).
---@param s dbgrid.State
function M.yank_plan(s)
  local result = current_result(s)
  if not result then
    return util.notify("no result")
  end
  local c = M.cell_at_cursor(s)
  local st = c and c.entry.stmt or (result.statements or {})[1]
  local plan = st and st.plan
  if not plan then
    for _, other in ipairs(result.statements or {}) do
      if other.plan then
        plan = other.plan
        break
      end
    end
  end
  if not plan then
    return util.notify("no plan attached to this result (index check off?)")
  end
  local text = vim.json.encode(plan)
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  util.notify("yanked the plan JSON (paste it into explain.dalibo.com or explain.depesz.com)")
end

---Show a cell's result in the results pane.
---
---The schema document is not tied to a cell, so moving between cells keeps
---it; a fresh result (`opts.ran`) or an explicit view replaces it.
---@param s dbgrid.State
---@param cell_id string
---@param opts? { view?: "grid"|"record"|"plan"|"diff"|"schema", ran?: boolean }
function M.show(s, cell_id, opts)
  opts = opts or {}
  require("dbgrid.ui.layout").ensure_results(s)
  if not s.results_buf or not vim.api.nvim_buf_is_valid(s.results_buf) then
    return
  end
  local same = s.view.cell_id == cell_id
  if s.view.mode == "schema" then
    if not opts.view and not opts.ran then
      s.view.cell_id = cell_id
      M.refresh_winbar(s)
      return
    end
    s.view.mode = "grid"
    s.view.schema_key = nil
  end
  local mode = opts.view or (same and s.view.mode) or "grid"
  if not same then
    s.view = { truncate = s.view.truncate }
  end
  s.view.cell_id = cell_id
  s.view.mode = mode
  M.render(s, not same)
end

---Re-render the results buffer from the view state.
---@param s dbgrid.State
---@param reset_cursor? boolean
function M.render(s, reset_cursor)
  local buf = s.results_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cell = s.view.cell_id and cells.by_id(s.buf, s.view.cell_id) or nil
  local result = current_result(s)
  local ctx = { lines = {}, line_hl = {}, rows_layout = {}, header_layout = {} }
  local mode = s.view.mode or "grid"
  if mode == "schema" then
    if render_schema(s, ctx) == false then
      M.refresh_winbar(s)
      return
    end
  elseif mode == "plan" then
    render_plan(s, cell, result, ctx)
  elseif mode == "diff" then
    render_diff(s, ctx)
  elseif not result then
    render_placeholder(s, cell, ctx)
  elseif mode == "record" then
    render_notices(result, ctx)
    render_record(s, result, ctx)
    render_footer(s, result, ctx)
  else
    render_notices(result, ctx)
    local sets = all_sets(result)
    for _, entry in ipairs(sets) do
      if #sets > 1 then
        local title =
          string.format(" %s statement %d · %s", config.get().icons.cell, entry.stmt_index, entry.stmt.kind:upper())
        ctx.lines[#ctx.lines + 1] = title
        ctx.line_hl[#ctx.lines] = { { 0, #title, "DbgridSetTitle" } }
      end
      render_set(s, entry, ctx)
      ctx.lines[#ctx.lines + 1] = ""
    end
    for _, st in ipairs(result.statements or {}) do
      if #(st.sets or {}) == 0 then
        for _, tag in ipairs(st.tags or {}) do
          ctx.lines[#ctx.lines + 1] = " " .. tag
          ctx.line_hl[#ctx.lines] = { { 0, #tag + 1, "DbgridTag" } }
        end
      end
    end
    if #sets == 0 and not result.error then
      local any_tag = false
      for _, st in ipairs(result.statements or {}) do
        if #(st.tags or {}) > 0 then
          any_tag = true
        end
      end
      if not any_tag then
        ctx.lines[#ctx.lines + 1] = " (no rows)"
        ctx.line_hl[#ctx.lines] = { { 0, 10, "DbgridStatusDim" } }
      end
    end
    render_footer(s, result, ctx)
  end
  if #ctx.lines == 0 then
    ctx.lines = { "" }
  end
  s.view.line_hl = ctx.line_hl
  s.view.rows_layout = ctx.rows_layout
  s.view.header_layout = ctx.header_layout
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, ctx.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  local win = s.results_win
  if win and vim.api.nvim_win_is_valid(win) then
    fold_options(win, mode == "schema")
    if mode == "schema" then
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ topline = 1, leftcol = 0 })
        pcall(vim.cmd, "normal! zM")
      end)
      reveal_referenced_tables(s)
    elseif reset_cursor then
      -- land on the first data row, keeping the notices and header visible
      local target
      for lnum in pairs(ctx.rows_layout) do
        if not target or lnum < target then
          target = lnum
        end
      end
      target = target or 1
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(target, #ctx.lines), 0 })
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ topline = 1, leftcol = 0 })
      end)
    else
      local cur = vim.api.nvim_win_get_cursor(win)
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(cur[1], #ctx.lines), cur[2] })
    end
    vim.wo[win].winbar = "%{%v:lua.require'dbgrid.ui.layout'.winbar_results(" .. s.buf .. ")%}"
  end
  M.update_cursor_column(s)
end

---The grid cell under the cursor of the results window.
---@param s dbgrid.State
---@return { entry: table, row: any[], row_index: integer, col: integer, column: string, value: any, record?: boolean }?
function M.cell_at_cursor(s)
  local win = s.results_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local pos = vim.api.nvim_win_get_cursor(win)
  local layout = (s.view.rows_layout or {})[pos[1]]
  if not layout then
    return nil
  end
  local col
  if layout.record then
    col = layout.col
  else
    col = 1
    for j, st in ipairs(layout.starts) do
      if pos[2] >= st then
        col = j
      end
    end
  end
  return {
    entry = layout.entry,
    row = layout.row,
    row_index = layout.row_index,
    col = col,
    column = layout.entry.set.columns[col],
    value = layout.row[col],
    record = layout.record,
  }
end

---Remember the cursor column for the column highlight.
---@param s dbgrid.State
function M.update_cursor_column(s)
  local c = M.cell_at_cursor(s)
  local new = c and not c.record and c.col or nil
  if new ~= s.view.cursor_col then
    s.view.cursor_col = new
    if s.results_win and vim.api.nvim_win_is_valid(s.results_win) then
      pcall(vim.api.nvim__redraw, { win = s.results_win, valid = false, flush = false })
    end
  end
end

---Text for the results winbar.
---@param s dbgrid.State
function M.winbar(s)
  local icons = config.get().icons
  local function esc(t)
    return (tostring(t or ""):gsub("%%", "%%%%"))
  end
  if s.view.mode == "schema" then
    local conn = s.nb.meta.connection
    local c = conn and require("dbgrid.connections").get(conn)
    local sch = c and require("dbgrid.schema").loaded(c)
    return "%#DbgridWinbarTitle# "
      .. esc(icons.table)
      .. " schema "
      .. "%#DbgridWinbarDim#│%#DbgridWinbarConn# "
      .. esc(conn or "no connection")
      .. " %#DbgridWinbarDim#"
      .. (sch and (#sch.tables .. " tables ") or "")
      .. (s.view.schema_filter and ("· filter “" .. esc(s.view.schema_filter) .. "” ") or "")
      .. "│ <CR> fold · K describe · / search · Tab next table"
  end
  local cell = s.view.cell_id and cells.by_id(s.buf, s.view.cell_id)
  if not cell then
    return "%#DbgridWinbarDim# results"
  end
  local parts = {}
  parts[#parts + 1] = "%#DbgridWinbarTitle# "
    .. esc(icons.cell)
    .. " q"
    .. cell.index
    .. " "
    .. esc(cells.label(cell, 30))
    .. " "
  parts[#parts + 1] = "%#DbgridWinbarDim#│"
  local running = s.running[cell.id]
  local meta = s.nb.meta.cells[cell.id]
  if running then
    parts[#parts + 1] = "%#DbgridWinbarWarn# "
      .. esc(icons.running)
      .. " "
      .. require("dbgrid.ui.query").running_label(running)
      .. " "
  elseif meta then
    if meta.status == "ok" then
      parts[#parts + 1] = "%#DbgridWinbarOk# " .. esc(icons.ok) .. " "
      parts[#parts + 1] = "%#DbgridWinbarDim#"
        .. util.fmt_int(meta.row_count or 0)
        .. " rows · "
        .. util.fmt_ms(meta.elapsed_ms or 0)
        .. " "
    else
      parts[#parts + 1] = "%#DbgridWinbarError# " .. esc(icons.error) .. " error "
    end
    if meta.warnings and #meta.warnings > 0 then
      parts[#parts + 1] = "%#DbgridWinbarWarn#" .. esc(icons.warn) .. " seq scan "
    end
  else
    parts[#parts + 1] = "%#DbgridWinbarDim# " .. esc(icons.idle) .. " not run "
  end
  local live = s.live and s.live[cell.id]
  if live then
    parts[#parts + 1] = "%#DbgridWinbarLive#" .. esc(icons.live) .. " live "
  end
  parts[#parts + 1] = "%#DbgridWinbarDim#│ " .. (s.view.mode or "grid")
  if s.view.sort and s.view.sort.col then
    local entry = all_sets(current_result(s) or {})[s.view.sort.set]
    local name = entry and entry.set.columns[s.view.sort.col] or "?"
    parts[#parts + 1] = " · sort " .. esc(name) .. (s.view.sort.dir == "desc" and " ↓" or " ↑")
  end
  if s.view.filter and s.view.filter ~= "" then
    parts[#parts + 1] = " · filter “" .. esc(s.view.filter) .. "”"
  end
  if s.view.truncate == false then
    parts[#parts + 1] = " · full width"
  end
  return table.concat(parts)
end

---Show the full value under the cursor in a float.
---@param s dbgrid.State
function M.inspect(s, key)
  if M.schema_action(s, key == "K" and "describe" or "toggle") then
    return
  end
  local c = M.cell_at_cursor(s)
  if not c then
    return
  end
  local text = raw_text(c.value)
  local ft = "text"
  if c.value ~= vim.NIL and util.looks_json(text) then
    local pretty, ok = util.pretty_json(text)
    if ok then
      text, ft = pretty, "json"
    end
  end
  local lines = util.lines(text)
  local _, win = vim.lsp.util.open_floating_preview(lines, ft, {
    border = "rounded",
    wrap = true,
    focusable = true,
    focus_id = "dbgrid_inspect",
    title = " " .. c.column .. " ",
    max_width = math.floor(vim.o.columns * 0.8),
    max_height = math.floor(vim.o.lines * 0.7),
  })
  if win and vim.api.nvim_win_is_valid(win) then
    local fbuf = vim.api.nvim_win_get_buf(win)
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = fbuf, nowait = true })
  end
end

---@param s dbgrid.State
function M.toggle_record(s)
  if s.view.mode == "record" then
    s.view.mode = "grid"
    M.render(s, true)
    return
  end
  local c = M.cell_at_cursor(s)
  s.view.record_row = c and c.row_index or 1
  s.view.record_set = c and c.entry.stmt_index or 1
  s.view.mode = "record"
  M.render(s, true)
end

---@param s dbgrid.State
function M.toggle_plan(s)
  s.view.mode = s.view.mode == "plan" and "grid" or "plan"
  M.render(s, true)
end

---@param s dbgrid.State
function M.toggle_truncate(s)
  s.view.truncate = s.view.truncate == false
  M.render(s)
end

---@param s dbgrid.State
function M.sort(s)
  if s.view.mode == "schema" then
    return
  end
  local c = M.cell_at_cursor(s)
  if not c then
    return util.notify("put the cursor on a column first")
  end
  local sort = s.view.sort
  if sort and sort.set == c.entry.stmt_index and sort.col == c.col then
    if sort.dir == "asc" then
      s.view.sort = { set = c.entry.stmt_index, col = c.col, dir = "desc" }
    else
      s.view.sort = nil
    end
  else
    s.view.sort = { set = c.entry.stmt_index, col = c.col, dir = "asc" }
  end
  M.render(s)
end

---@param s dbgrid.State
function M.filter(s)
  if M.schema_action(s, "filter") then
    return
  end
  vim.ui.input({ prompt = "Filter rows containing: ", default = s.view.filter or "" }, function(input)
    if input == nil then
      return
    end
    s.view.filter = input ~= "" and input or nil
    M.render(s, true)
  end)
end

local function yank(text, what)
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  util.notify("yanked " .. what)
end

---@param s dbgrid.State
function M.yank_cell(s)
  if M.schema_action(s, "yank") then
    return
  end
  local c = M.cell_at_cursor(s)
  if not c then
    return
  end
  yank(raw_text(c.value), c.column)
end

---@param s dbgrid.State
function M.yank_row_json(s)
  local c = M.cell_at_cursor(s)
  if not c then
    return
  end
  local obj = {}
  for j, name in ipairs(c.entry.set.columns) do
    local v = c.row[j]
    obj[name] = (v == nil) and vim.NIL or v
  end
  local pretty = util.pretty_json(vim.json.encode(obj))
  yank(pretty, "row as JSON")
end

---@param s dbgrid.State
function M.yank_csv(s)
  local result = current_result(s)
  if not result then
    return
  end
  local c = M.cell_at_cursor(s)
  local entry = c and c.entry or all_sets(result)[1]
  if not entry then
    return
  end
  local out = { table.concat(vim.tbl_map(util.csv_escape, entry.set.columns), ",") }
  for _, row in ipairs(M.display_rows(s, entry)) do
    local vals = {}
    for j = 1, #entry.set.columns do
      local v = row[j]
      vals[j] = (v == vim.NIL or v == nil) and "" or util.csv_escape(tostring(v))
    end
    out[#out + 1] = table.concat(vals, ",")
  end
  yank(table.concat(out, "\n") .. "\n", (#out - 1) .. " rows as CSV")
end

---@param s dbgrid.State
function M.yank_insert(s)
  local c = M.cell_at_cursor(s)
  if not c then
    return
  end
  local refs = require("dbgrid.sql").referenced_tables(c.entry.stmt.sql or "")
  local tbl = refs[1] and refs[1].name or "<table>"
  local vals = {}
  for j = 1, #c.entry.set.columns do
    vals[j] = util.sql_literal(c.row[j])
  end
  local stmt = string.format(
    "INSERT INTO %s (%s) VALUES (%s);",
    tbl,
    table.concat(c.entry.set.columns, ", "),
    table.concat(vals, ", ")
  )
  yank(stmt, "row as INSERT")
end

---Move to the next / previous column (grid) or row (record view).
---@param s dbgrid.State
---@param delta integer
function M.move_column(s, delta)
  if M.schema_action(s, delta > 0 and "next" or "prev") then
    return
  end
  if s.view.mode == "record" then
    s.view.record_row = (s.view.record_row or 1) + delta
    M.render(s, true)
    return
  end
  local win = s.results_win
  local pos = vim.api.nvim_win_get_cursor(win)
  local layout = (s.view.rows_layout or {})[pos[1]] or (s.view.header_layout or {})[pos[1]]
  if not layout then
    return
  end
  local col = 1
  for j, st in ipairs(layout.starts) do
    if pos[2] >= st then
      col = j
    end
  end
  local target = math.max(1, math.min(#layout.starts, col + delta))
  vim.api.nvim_win_set_cursor(win, { pos[1], layout.starts[target] })
end

---Decoration provider: ephemeral highlights for visible lines only.
local provider_set = false
local function ensure_provider()
  if provider_set then
    return
  end
  provider_set = true
  vim.api.nvim_set_decoration_provider(M.ns, {
    on_win = function(_, _, buf)
      local s = state_mod.by_results_buf(buf)
      return s ~= nil and s.view ~= nil
    end,
    on_line = function(_, _, buf, row)
      local s = state_mod.by_results_buf(buf)
      if not s or not s.view then
        return
      end
      local lnum = row + 1
      local layout = s.view.rows_layout and s.view.rows_layout[lnum]
      if layout and s.view.cursor_col and not layout.record and layout.starts[s.view.cursor_col] then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, layout.starts[s.view.cursor_col], {
          end_col = layout.ends[s.view.cursor_col],
          hl_group = "DbgridCurrentColumn",
          ephemeral = true,
          priority = 90,
          hl_mode = "combine",
        })
      end
      local hls = s.view.line_hl and s.view.line_hl[lnum]
      if hls then
        for _, h in ipairs(hls) do
          pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, h[1], {
            end_col = h[2],
            hl_group = h[3],
            ephemeral = true,
            priority = 100,
            hl_mode = "combine",
          })
        end
      end
    end,
  })
end

---Keymaps and autocmds for the results buffer.
---@param s dbgrid.State
function M.attach(s)
  ensure_provider()
  local buf = s.results_buf
  if vim.b[buf].dbgrid_results_attached then
    return
  end
  vim.b[buf].dbgrid_results_attached = true
  local k = config.get().keymaps.results
  local layout = require("dbgrid.ui.layout")
  local query = require("dbgrid.ui.query")
  if type(k.inspect) == "table" then
    for _, key in ipairs(k.inspect) do
      map(buf, key, function()
        M.inspect(s, key)
      end, "inspect value")
    end
  else
    map(buf, k.inspect, function()
      M.inspect(s, k.inspect)
    end, "inspect value")
  end
  map(buf, k.schema_view, function()
    M.toggle_schema(s)
  end, "toggle the schema document")
  map(buf, k.record_view, function()
    M.toggle_record(s)
  end, "toggle record view")
  map(buf, k.plan_view, function()
    M.toggle_plan(s)
  end, "toggle plan view")
  map(buf, k.toggle_truncate, function()
    M.toggle_truncate(s)
  end, "toggle column truncation")
  map(buf, k.sort, function()
    M.sort(s)
  end, "sort by column")
  map(buf, k.filter, function()
    M.filter(s)
  end, "filter rows")
  map(buf, k.diff, function()
    M.diff_previous(s)
  end, "diff against the previous run")
  map(buf, k.history, function()
    M.sparkline(s)
  end, "sparkline of the column across live ticks")
  map(buf, k.yank_plan, function()
    M.yank_plan(s)
  end, "yank the plan JSON")
  map(buf, k.yank_cell, function()
    M.yank_cell(s)
  end, "yank value")
  map(buf, k.yank_row_json, function()
    M.yank_row_json(s)
  end, "yank row as JSON")
  map(buf, k.yank_csv, function()
    M.yank_csv(s)
  end, "yank result as CSV")
  map(buf, k.yank_insert, function()
    M.yank_insert(s)
  end, "yank row as INSERT")
  map(buf, k.ask, function()
    local cell = s.view.cell_id and cells.by_id(s.buf, s.view.cell_id)
    if not cell then
      return util.notify("move to a cell first")
    end
    require("dbgrid.ai").review(s, cell)
  end, "ask the agent about the query and its result")
  map(buf, k.next_col, function()
    M.move_column(s, 1)
  end, "next column / row")
  map(buf, k.prev_col, function()
    M.move_column(s, -1)
  end, "previous column / row")
  map(buf, k.next_cell, function()
    query.move(s, 1)
  end, "next cell")
  map(buf, k.prev_cell, function()
    query.move(s, -1)
  end, "previous cell")
  map(buf, k.focus_query, function()
    layout.focus_query(s)
  end, "focus query pane")
  map(buf, k.zoom, function()
    layout.zoom(s)
  end, "zoom pane")
  map(buf, k.close, function()
    layout.close(s)
  end, "close notebook")
  local group = vim.api.nvim_create_augroup("dbgrid_results_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      M.update_cursor_column(s)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      if tonumber(ev.match) == s.results_win then
        s.results_win = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
    group = group,
    callback = function(ev)
      local win = vim.api.nvim_get_current_win()
      if win == s.results_win and ev.buf ~= buf and vim.api.nvim_buf_is_loaded(buf) then
        vim.schedule(function()
          layout.reclaim_results(s, ev.buf)
        end)
      end
    end,
  })
  util.refresh_keymap_hints(buf)
end

return M
