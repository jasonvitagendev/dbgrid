-- Export a notebook as markdown: every cell with its SQL and its last result.
local util = require("dbgrid.util")
local cells = require("dbgrid.cells")
local notebook = require("dbgrid.notebook")

local M = {}

---@param set dbgrid.ResultSet
---@param max_rows integer
---@return string[]
local function table_lines(set, max_rows)
  local out = {}
  local function cell(v)
    if v == vim.NIL or v == nil then
      return "NULL"
    end
    return (tostring(v):gsub("|", "\\|"):gsub("\r?\n", " "))
  end
  out[#out + 1] = "| " .. table.concat(vim.tbl_map(cell, set.columns), " | ") .. " |"
  out[#out + 1] = "|" .. string.rep(" --- |", #set.columns)
  for i, row in ipairs(set.rows) do
    if i > max_rows then
      out[#out + 1] = string.format("| … %d more rows |", (set.row_count or #set.rows) - max_rows)
      break
    end
    local vals = {}
    for j = 1, #set.columns do
      vals[j] = cell(row[j])
    end
    out[#out + 1] = "| " .. table.concat(vals, " | ") .. " |"
  end
  if #set.rows == 0 then
    out[#out + 1] = "_(no rows)_"
  end
  return out
end

---@param s dbgrid.State
---@param opts? { max_rows?: integer }
---@return string
function M.markdown(s, opts)
  opts = opts or {}
  local max_rows = opts.max_rows or 50
  local nb = s.nb
  local lines = { "# " .. nb.meta.title, "" }
  local meta = {}
  if nb.meta.connection then
    meta[#meta + 1] = "connection: " .. nb.meta.connection
  end
  if #nb.meta.tags > 0 then
    meta[#meta + 1] = "tags: " .. table.concat(nb.meta.tags, ", ")
  end
  meta[#meta + 1] = "exported: " .. os.date("%Y-%m-%d %H:%M")
  lines[#lines + 1] = "_" .. table.concat(meta, " · ") .. "_"
  lines[#lines + 1] = ""
  for _, cell in ipairs(cells.parse(s.buf)) do
    lines[#lines + 1] = "## " .. cells.label(cell, 80)
    lines[#lines + 1] = ""
    local body = util.trim(cells.body_text(cell))
    if body ~= "" then
      lines[#lines + 1] = "```sql"
      for _, l in ipairs(util.lines(body)) do
        lines[#lines + 1] = l
      end
      lines[#lines + 1] = "```"
      lines[#lines + 1] = ""
    end
    local r = cell.id and notebook.result_of(nb, cell.id)
    if r and r ~= vim.NIL and r.statements then
      if r.error then
        lines[#lines + 1] = "**ERROR:** " .. tostring(r.error.message)
        lines[#lines + 1] = ""
      end
      for _, st in ipairs(r.statements) do
        for _, set in ipairs(st.sets or {}) do
          for _, l in ipairs(table_lines(set, max_rows)) do
            lines[#lines + 1] = l
          end
          lines[#lines + 1] = ""
        end
        for _, tag in ipairs(st.tags or {}) do
          lines[#lines + 1] = "`" .. tag .. "`"
          lines[#lines + 1] = ""
        end
      end
      local foot = {}
      if r.elapsed_ms then
        foot[#foot + 1] = util.fmt_ms(r.elapsed_ms)
      end
      if r.ran_at then
        foot[#foot + 1] = os.date("%Y-%m-%d %H:%M:%S", r.ran_at)
      end
      if r.connection then
        foot[#foot + 1] = "via " .. r.connection
      end
      if #foot > 0 then
        lines[#lines + 1] = "_" .. table.concat(foot, " · ") .. "_"
        lines[#lines + 1] = ""
      end
      if r.analysis and r.analysis.text then
        lines[#lines + 1] = "### Analysis"
        lines[#lines + 1] = ""
        for _, l in ipairs(util.lines(r.analysis.text)) do
          lines[#lines + 1] = l
        end
        lines[#lines + 1] = ""
      end
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

return M
