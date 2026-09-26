-- Windows: a query pane (the notebook file) and a results pane, usually in a
-- tab of their own.
local config = require("dbgrid.config")
local state = require("dbgrid.state")
local util = require("dbgrid.util")

local M = {}

local function esc(s)
  return (tostring(s or ""):gsub("%%", "%%%%"))
end

---Open (or focus) a notebook.
---@param nb dbgrid.Notebook
---@param opts? { tab?: boolean }
---@return dbgrid.State
function M.open(nb, opts)
  opts = opts or {}
  for _, s in pairs(state.by_buf) do
    if s.nb.path == nb.path and vim.api.nvim_buf_is_valid(s.buf) then
      M.focus(s)
      return s
    end
  end
  local cfg = config.get().layout
  local use_tab = opts.tab
  if use_tab == nil then
    use_tab = cfg.tab
  end
  if use_tab then
    vim.cmd("tabnew")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(nb.path))
  local buf = vim.api.nvim_get_current_buf()
  local s = state.attach(buf, nb)
  s.query_win = vim.api.nvim_get_current_win()
  s.tab = vim.api.nvim_get_current_tabpage()
  s.last_used = util.now()
  require("dbgrid.ui.query").attach(s)
  M.ensure_results(s)
  vim.api.nvim_set_current_win(s.query_win)
  require("dbgrid.ui.query").on_cursor(s, true)
  return s
end

---Attach to a notebook buffer that was opened by hand (:edit).
---@param buf integer
---@param nb dbgrid.Notebook
function M.adopt(buf, nb)
  local s = state.attach(buf, nb)
  s.last_used = util.now()
  require("dbgrid.ui.query").attach(s)
  return s
end

---Make sure the results window exists next to the query window.
---@param s dbgrid.State
function M.ensure_results(s)
  if s.results_win and vim.api.nvim_win_is_valid(s.results_win) then
    return
  end
  if not s.query_win or not vim.api.nvim_win_is_valid(s.query_win) then
    local w = vim.fn.bufwinid(s.buf)
    if w == -1 then
      return
    end
    s.query_win = w
    s.tab = vim.api.nvim_win_get_tabpage(w)
  end
  if not s.results_buf or not vim.api.nvim_buf_is_valid(s.results_buf) then
    local rb = vim.api.nvim_create_buf(false, true)
    vim.bo[rb].buftype = "nofile"
    vim.bo[rb].bufhidden = "hide"
    vim.bo[rb].swapfile = false
    vim.bo[rb].buflisted = false
    vim.bo[rb].filetype = "dbgrid-results"
    pcall(vim.api.nvim_buf_set_name, rb, "dbgrid://results/" .. s.nb.name)
    s.results_buf = rb
  end
  local cfg = config.get().layout
  local pos = cfg.results or "left"
  local split = ({ left = "left", right = "right", bottom = "below", top = "above" })[pos] or "left"
  local wopts = { split = split, win = s.query_win }
  if split == "left" or split == "right" then
    wopts.width = math.max(20, math.floor(vim.o.columns * (cfg.size or 0.5)))
  else
    wopts.height = math.max(5, math.floor(vim.o.lines * (cfg.size or 0.5)))
  end
  local win = vim.api.nvim_open_win(s.results_buf, false, wopts)
  s.results_win = win
  local wo = vim.wo[win]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.cursorline = true
  wo.list = false
  wo.spell = false
  wo.sidescrolloff = 4
  wo.scrolloff = 2
  wo.winfixwidth = split == "left" or split == "right"
  wo.winbar = "%{%v:lua.require'dbgrid.ui.layout'.winbar_results(" .. s.buf .. ")%}"
  require("dbgrid.ui.results").attach(s)
end

---@param s dbgrid.State
function M.focus(s)
  if s.tab and vim.api.nvim_tabpage_is_valid(s.tab) then
    vim.api.nvim_set_current_tabpage(s.tab)
  end
  if s.query_win and vim.api.nvim_win_is_valid(s.query_win) then
    vim.api.nvim_set_current_win(s.query_win)
  else
    vim.cmd("buffer " .. s.buf)
    s.query_win = vim.api.nvim_get_current_win()
    s.tab = vim.api.nvim_get_current_tabpage()
  end
  M.ensure_results(s)
  s.last_used = util.now()
  -- back to the grid of the cell under the cursor; plan/record views are transient
  s.view = { truncate = s.view and s.view.truncate }
  require("dbgrid.ui.query").on_cursor(s, true)
end

---@param s dbgrid.State
function M.focus_results(s)
  M.ensure_results(s)
  if s.results_win and vim.api.nvim_win_is_valid(s.results_win) then
    vim.api.nvim_set_current_win(s.results_win)
  end
end

---@param s dbgrid.State
function M.focus_query(s)
  if s.query_win and vim.api.nvim_win_is_valid(s.query_win) then
    vim.api.nvim_set_current_win(s.query_win)
  end
end

---Toggle maximising the current pane of the notebook.
---@param s dbgrid.State
function M.zoom(s)
  local win = vim.api.nvim_get_current_win()
  if s.zoomed then
    s.zoomed = nil
    vim.cmd("wincmd =")
    if s.results_win and vim.api.nvim_win_is_valid(s.results_win) then
      local cfg = config.get().layout
      local pos = cfg.results or "left"
      if pos == "left" or pos == "right" then
        pcall(vim.api.nvim_win_set_width, s.results_win, math.floor(vim.o.columns * (cfg.size or 0.5)))
      else
        pcall(vim.api.nvim_win_set_height, s.results_win, math.floor(vim.o.lines * (cfg.size or 0.5)))
      end
    end
    return
  end
  s.zoomed = win
  vim.cmd("wincmd |")
  vim.cmd("wincmd _")
end

---Close the notebook UI (writes the query buffer first).
---@param s dbgrid.State
function M.close(s)
  if vim.api.nvim_buf_is_valid(s.buf) and vim.bo[s.buf].modified then
    vim.api.nvim_buf_call(s.buf, function()
      pcall(vim.cmd, "silent update")
    end)
  end
  local tab = s.tab
  if s.results_win and vim.api.nvim_win_is_valid(s.results_win) then
    pcall(vim.api.nvim_win_close, s.results_win, true)
  end
  s.results_win = nil
  if config.get().layout.tab and tab and vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
    local wins = vim.api.nvim_tabpage_list_wins(tab)
    local only_ours = true
    for _, w in ipairs(wins) do
      if vim.api.nvim_win_get_buf(w) ~= s.buf then
        only_ours = false
      end
    end
    if only_ours then
      pcall(vim.api.nvim_set_current_tabpage, tab)
      pcall(vim.cmd, "tabclose")
      return
    end
  end
  if s.query_win and vim.api.nvim_win_is_valid(s.query_win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.api.nvim_win_close, s.query_win, false)
  end
end

---Winbar of the query pane.
---@param buf integer
function M.winbar_query(buf)
  local s = state.get(buf)
  if not s then
    return ""
  end
  local icons = config.get().icons
  local parts = {}
  local conn = s.nb.meta.connection
  local c = conn and require("dbgrid.connections").get(conn)
  parts[#parts + 1] = "%#DbgridWinbarConn# "
    .. esc(icons.connection)
    .. " "
    .. esc(conn or "no connection")
    .. (c and c.readonly and " [ro]" or "")
    .. " "
  parts[#parts + 1] = "%#DbgridWinbarDim#│"
  if #s.nb.meta.tags > 0 then
    local tags = {}
    for _, t in ipairs(s.nb.meta.tags) do
      tags[#tags + 1] = esc(icons.tag .. t)
    end
    parts[#parts + 1] = "%#DbgridWinbarTag# " .. table.concat(tags, " ") .. " "
  else
    parts[#parts + 1] = "%#DbgridWinbarDim# no tags "
  end
  parts[#parts + 1] = "%#DbgridWinbarDim#│"
  parts[#parts + 1] = "%#DbgridWinbarTitle# " .. esc(s.nb.meta.title) .. " "
  local n = #require("dbgrid.cells").parse(buf)
  parts[#parts + 1] = "%#DbgridWinbarDim#" .. n .. (n == 1 and " cell" or " cells")
  return table.concat(parts)
end

---Winbar of the results pane.
---@param buf integer
function M.winbar_results(buf)
  local s = state.get(buf)
  if not s then
    return ""
  end
  return require("dbgrid.ui.results").winbar(s)
end

return M
