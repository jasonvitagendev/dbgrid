-- Result-set diff: compare two runs of the same query row by row, by key when
-- one is known, otherwise as multisets of whole rows. Pure functions, no UI.
local util = require("dbgrid.util")

local M = {}

---@class dbgrid.RowDiff
---@field added any[][]        rows only in the after set
---@field removed any[][]      rows only in the before set
---@field changed { before: any[], after: any[], cols: integer[] }[]   same key, different values
---@field same integer         rows present in both
---@field key integer[]|nil    column indexes the rows were matched by (positions in `columns`)
---@field columns_changed boolean   the two sets had different columns
---@field columns string[]     the columns every row above is laid out in (the shared ones when they changed)

---@param v any
---@return string
local function cell_key(v)
  if v == nil or v == vim.NIL then
    return "\0"
  end
  return tostring(v)
end

---Column indexes to match rows by: the table's primary key when every one of
---its columns is in `columns`, else a column named `id`, else nil.
---@param columns string[]
---@param schema_table? dbgrid.SchemaTable
---@return integer[]?
function M.pick_key(columns, schema_table)
  local pos = {}
  for i, c in ipairs(columns or {}) do
    local lower = c:lower()
    if not pos[lower] then
      pos[lower] = i
    end
  end
  for _, con in ipairs(schema_table and schema_table.constraints or {}) do
    if con.type == "p" and #(con.columns or {}) > 0 then
      local key = {}
      for _, c in ipairs(con.columns) do
        local i = pos[c:lower()]
        if not i then
          key = nil
          break
        end
        key[#key + 1] = i
      end
      if key then
        return key
      end
    end
  end
  if pos.id then
    return { pos.id }
  end
  return nil
end

---Diff two result sets (`{ columns, rows }`, rows of strings / vim.NIL).
---With `opts.key` (indexes into the after set's columns) rows are matched by
---the key tuple and compared column by column; without one, whole rows are
---compared as a multiset and only added / removed rows are reported. When the
---columns differ the diff runs over the columns present in both (by name) and
---every row in the result is projected onto them.
---@param before_set { columns: string[], rows: any[][] }
---@param after_set { columns: string[], rows: any[][] }
---@param opts? { key?: integer[] }
---@return dbgrid.RowDiff
function M.rows(before_set, after_set, opts)
  opts = opts or {}
  local bcols, acols = before_set.columns or {}, after_set.columns or {}
  local columns_changed = not vim.deep_equal(bcols, acols)
  local columns, bidx, aidx = acols, nil, nil
  if columns_changed then
    local bpos = {}
    for i, c in ipairs(bcols) do
      bpos[c] = bpos[c] or i
    end
    columns, bidx, aidx = {}, {}, {}
    for i, c in ipairs(acols) do
      if bpos[c] then
        columns[#columns + 1] = c
        aidx[#aidx + 1] = i
        bidx[#bidx + 1] = bpos[c]
      end
    end
  end
  local function project(row, idx)
    if not idx then
      return row
    end
    local out = {}
    for k, i in ipairs(idx) do
      out[k] = row[i]
    end
    return out
  end
  local brows, arows = {}, {}
  for i, r in ipairs(before_set.rows or {}) do
    brows[i] = project(r, bidx)
  end
  for i, r in ipairs(after_set.rows or {}) do
    arows[i] = project(r, aidx)
  end
  -- the key comes as positions in the after set's columns; map them onto `columns`
  local key
  if opts.key and #opts.key > 0 then
    key = {}
    for _, i in ipairs(opts.key) do
      local p = i
      if aidx then
        p = nil
        for k, ai in ipairs(aidx) do
          if ai == i then
            p = k
          end
        end
      end
      if not p then
        key = nil
        break
      end
      key[#key + 1] = p
    end
  end
  local result = {
    added = {},
    removed = {},
    changed = {},
    same = 0,
    key = key,
    columns_changed = columns_changed,
    columns = columns,
  }
  local ncols = #columns
  if key then
    local function key_of(row)
      local parts = {}
      for k, p in ipairs(key) do
        parts[k] = cell_key(row[p])
      end
      return table.concat(parts, "\1")
    end
    local groups, matched = {}, {}
    for _, r in ipairs(brows) do
      local k = key_of(r)
      groups[k] = groups[k] or {}
      table.insert(groups[k], r)
    end
    for _, r in ipairs(arows) do
      local group = groups[key_of(r)]
      if group and #group > 0 then
        local b = table.remove(group, 1)
        matched[b] = true
        local cols = {}
        for i = 1, ncols do
          if cell_key(b[i]) ~= cell_key(r[i]) then
            cols[#cols + 1] = i
          end
        end
        if #cols == 0 then
          result.same = result.same + 1
        else
          result.changed[#result.changed + 1] = { before = b, after = r, cols = cols }
        end
      else
        result.added[#result.added + 1] = r
      end
    end
    for _, r in ipairs(brows) do
      if not matched[r] then
        result.removed[#result.removed + 1] = r
      end
    end
  else
    local function row_key(r)
      local parts = {}
      for i = 1, ncols do
        parts[i] = cell_key(r[i])
      end
      return table.concat(parts, "\1")
    end
    local remaining = {}
    for _, r in ipairs(brows) do
      local k = row_key(r)
      remaining[k] = (remaining[k] or 0) + 1
    end
    for _, r in ipairs(arows) do
      local k = row_key(r)
      if (remaining[k] or 0) > 0 then
        remaining[k] = remaining[k] - 1
        result.same = result.same + 1
      else
        result.added[#result.added + 1] = r
      end
    end
    for _, r in ipairs(brows) do
      local k = row_key(r)
      if remaining[k] > 0 then
        remaining[k] = remaining[k] - 1
        result.removed[#result.removed + 1] = r
      end
    end
  end
  return result
end

local SEP = " │ "

---Render a diff as a grid: a summary line, a blank, then the header, a rule
---and one line per added (`+ `), removed (`- `) and changed (`~ `) row.
---Changed cells read `old → new`. Highlights are `{ lnum (1-based), s, e
---(0-based bytes), group }`: whole added / removed lines and only the changed
---cells of changed rows.
---@param diff dbgrid.RowDiff
---@param columns? string[]   defaults to the diff's columns
---@param opts? { null_text?: string }
---@return string[] lines, { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] hl
function M.render(diff, columns, opts)
  opts = opts or {}
  columns = columns or diff.columns or {}
  local null_text = opts.null_text or "NULL"
  local function text(v)
    if v == nil or v == vim.NIL then
      return null_text
    end
    return (tostring(v):gsub("\r?\n", "↵"))
  end
  local lines, hl = {}, {}
  lines[1] = string.format(
    " +%d added · −%d removed · ~%d changed · %d same",
    #diff.added,
    #diff.removed,
    #diff.changed,
    diff.same
  )
  lines[2] = ""
  local ncols = #columns
  local rows = {}
  local function cells_of(row)
    local cells = {}
    for j = 1, ncols do
      cells[j] = text(row[j])
    end
    return cells
  end
  for _, r in ipairs(diff.added) do
    rows[#rows + 1] = { prefix = "+ ", cells = cells_of(r), group = "DbgridDiffAdd" }
  end
  for _, r in ipairs(diff.removed) do
    rows[#rows + 1] = { prefix = "- ", cells = cells_of(r), group = "DbgridDiffDelete" }
  end
  for _, c in ipairs(diff.changed) do
    local cells, changed = cells_of(c.after), {}
    for _, j in ipairs(c.cols) do
      cells[j] = text(c.before[j]) .. " → " .. text(c.after[j])
      changed[j] = true
    end
    rows[#rows + 1] = { prefix = "~ ", cells = cells, changed = changed }
  end
  if #rows == 0 then
    lines[#lines + 1] = " (no differences)"
    return lines, hl
  end
  local widths = {}
  for j = 1, ncols do
    widths[j] = util.width(columns[j])
  end
  for _, r in ipairs(rows) do
    for j = 1, ncols do
      widths[j] = math.max(widths[j], util.width(r.cells[j]))
    end
  end
  ---@return string line, { [1]: integer, [2]: integer }[] spans   0-based byte range of each cell
  local function build(prefix, cells)
    local parts, spans = { prefix }, {}
    local pos = #prefix
    for j = 1, ncols do
      if j > 1 then
        parts[#parts + 1] = SEP
        pos = pos + #SEP
      end
      local padded = util.pad(cells[j], widths[j])
      spans[j] = { pos, pos + #padded }
      parts[#parts + 1] = padded
      pos = pos + #padded
    end
    return table.concat(parts), spans
  end
  local header = build("  ", columns)
  lines[#lines + 1] = header
  hl[#hl + 1] = { #lines, 0, #header, "DbgridColumnHeader" }
  local rule = {}
  for j = 1, ncols do
    rule[j] = string.rep("─", widths[j] + (j == 1 and 2 or 0))
  end
  local rule_line = table.concat(rule, "─┼─")
  lines[#lines + 1] = rule_line
  hl[#hl + 1] = { #lines, 0, #rule_line, "DbgridRule" }
  for _, r in ipairs(rows) do
    local line, spans = build(r.prefix, r.cells)
    lines[#lines + 1] = line
    if r.group then
      hl[#hl + 1] = { #lines, 0, #line, r.group }
    else
      for j = 1, ncols do
        if r.changed[j] then
          hl[#hl + 1] = { #lines, spans[j][1], spans[j][2], "DbgridDiffChange" }
        end
      end
    end
  end
  return lines, hl
end

return M
