-- A markdown window for agent answers (plan analysis, error explanation).
-- `i` inserts the answer's SQL blocks as cells below the analyzed cell,
-- `y` yanks the whole answer, `q` closes.
local util = require("dbgrid.util")

local M = {}

---@param s dbgrid.State
---@return integer buf
local function ensure_buf(s)
  if s.analysis_buf and vim.api.nvim_buf_is_valid(s.analysis_buf) then
    return s.analysis_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, "dbgrid://analysis/" .. s.nb.name)
  s.analysis_buf = buf
  return buf
end

---@param s dbgrid.State
---@return integer win
local function ensure_win(s)
  if s.analysis_win and vim.api.nvim_win_is_valid(s.analysis_win) then
    return s.analysis_win
  end
  local buf = ensure_buf(s)
  local anchor = s.results_win and vim.api.nvim_win_is_valid(s.results_win) and s.results_win or s.query_win
  local win = vim.api.nvim_open_win(buf, false, {
    split = "below",
    win = anchor,
    height = math.max(8, math.floor(vim.o.lines * 0.4)),
  })
  local wo = vim.wo[win]
  wo.wrap = true
  wo.linebreak = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.spell = false
  wo.conceallevel = 2
  s.analysis_win = win
  return win
end

---@param s dbgrid.State
function M.close(s)
  if s.analysis_win and vim.api.nvim_win_is_valid(s.analysis_win) then
    pcall(vim.api.nvim_win_close, s.analysis_win, true)
  end
  s.analysis_win = nil
end

---Insert the SQL blocks of the shown answer as new cells below the analyzed cell.
---@param s dbgrid.State
function M.insert_sql(s)
  local shown = s.analysis
  if not shown then
    return
  end
  local blocks = require("dbgrid.ai").sql_blocks(shown.text)
  if #blocks == 0 then
    return util.notify("the answer has no ```sql block")
  end
  local cells = require("dbgrid.cells")
  local cell = shown.cell_id and cells.by_id(s.buf, shown.cell_id)
  local at = cell and cell.last or vim.api.nvim_buf_line_count(s.buf)
  local lines = {}
  for i, b in ipairs(blocks) do
    lines[#lines + 1] = ""
    local title = "suggested " .. i .. " (" .. (shown.title or "analysis") .. ")"
    lines[#lines + 1] = cells.header_line(util.short_id(4), title)
    for _, l in ipairs(util.lines(b)) do
      lines[#lines + 1] = l
    end
  end
  vim.api.nvim_buf_set_lines(s.buf, at, at, false, lines)
  vim.b[s.buf].dbgrid_cells_cache = nil
  require("dbgrid.ui.query").render(s)
  util.notify(string.format("inserted %d cell%s", #blocks, #blocks == 1 and "" or "s"))
  if s.query_win and vim.api.nvim_win_is_valid(s.query_win) then
    vim.api.nvim_set_current_win(s.query_win)
    pcall(vim.api.nvim_win_set_cursor, s.query_win, { at + 2, 0 })
  end
end

---Show an answer.
---@param s dbgrid.State
---@param opts { title: string, text: string, cell_id?: string, focus?: boolean }
function M.show(s, opts)
  local buf = ensure_buf(s)
  local win = ensure_win(s)
  s.analysis = { title = opts.title, text = opts.text, cell_id = opts.cell_id }
  local lines = { "# " .. opts.title, "" }
  for _, l in ipairs(util.lines(opts.text)) do
    lines[#lines + 1] = l
  end
  local k = "i: insert SQL as cells · y: yank · q: close"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "_" .. k .. "_"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  if not vim.b[buf].dbgrid_analysis_attached then
    vim.b[buf].dbgrid_analysis_attached = true
    local function map(key, fn, desc)
      vim.keymap.set("n", key, fn, { buffer = buf, desc = "dbgrid: " .. desc, silent = true, nowait = true })
    end
    map("q", function()
      M.close(s)
    end, "close analysis")
    map("i", function()
      M.insert_sql(s)
    end, "insert suggested SQL as cells")
    map("y", function()
      vim.fn.setreg('"', s.analysis and s.analysis.text or "")
      pcall(vim.fn.setreg, "+", s.analysis and s.analysis.text or "")
      util.notify("yanked analysis")
    end, "yank analysis")
  end
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  if opts.focus ~= false and #vim.api.nvim_list_uis() > 0 then
    vim.api.nvim_set_current_win(win)
  end
  return buf, win
end

return M
