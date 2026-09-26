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
---@param entry table
---@return any[][]
local function display_rows(s, entry)
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
  local rows = display_rows(s, entry)
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
  for i, frow in ipairs(formatted) do
    local raw = rows[i]
    local line, starts, ends, hls = build(frow, function(j)
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
  if #lines > 0 and lines[#lines] ~= "" then
    add("")
  end
  add(" " .. table.concat(parts, " · "), "DbgridFooter")
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
    { key(k.tags) .. "  " .. key(k.connection), "tags · connection" },
    { key(k.tables) .. "  " .. key(k.describe), "browse tables · describe the identifier under the cursor" },
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
  local rows = display_rows(s, entry)
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
  local rt = cell and s.runtime[cell.id] or {}
  if rt.plan_text then
    add(" " .. (rt.plan_kind or "EXPLAIN"), "DbgridSetTitle")
    add("")
    for _, l in ipairs(rt.plan_text) do
      add(l, l:match("^ERROR") and "DbgridError" or nil)
    end
    return
  end
  local explain = require("dbgrid.explain")
  local any = false
  for i, st in ipairs(result and result.statements or {}) do
    if st.plan then
      any = true
      add(
        string.format(
          " plan for statement %d (%s), estimated cost %s",
          i,
          st.kind:upper(),
          tostring(explain.total_cost(st.plan))
        ),
        "DbgridSetTitle"
      )
      add("")
      for _, l in ipairs(explain.to_lines(st.plan)) do
        add(l, l:find("Seq Scan", 1, true) and "DbgridWarn" or nil)
      end
      add("")
    end
  end
  if not any then
    add(" no plan yet: run the cell (index check on) or use the explain keymap", "DbgridStatusDim")
  end
end

---Show a cell's result in the results pane.
---@param s dbgrid.State
---@param cell_id string
---@param opts? { view?: "grid"|"record"|"plan" }
function M.show(s, cell_id, opts)
  opts = opts or {}
  require("dbgrid.ui.layout").ensure_results(s)
  if not s.results_buf or not vim.api.nvim_buf_is_valid(s.results_buf) then
    return
  end
  local same = s.view.cell_id == cell_id
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
  if mode == "plan" then
    render_plan(s, cell, result, ctx)
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
    if reset_cursor then
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
      .. (running.kind == "explain" and "planning" or "running")
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
function M.inspect(s)
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
  for _, row in ipairs(display_rows(s, entry)) do
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
  map(buf, k.inspect, function()
    M.inspect(s)
  end, "inspect value")
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
  util.refresh_keymap_hints(buf)
end

return M
