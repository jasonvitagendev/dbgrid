-- Windows: a query pane (the notebook file) and a results pane, usually in a
-- tab of their own. `ensure_results` is self-healing: a results window that
-- was closed, taken over by another buffer (:bdelete, a picker opening a
-- file in it), squeezed to nothing or left in another tab is brought back
-- next to the query window.
local config = require("dbgrid.config")
local state = require("dbgrid.state")
local util = require("dbgrid.util")

local M = {}

local function esc(s)
  return (tostring(s or ""):gsub("%%", "%%%%"))
end

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function buf_usable(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
end

---Open (or focus) a notebook.
---@param nb dbgrid.Notebook
---@param opts? { tab?: boolean }
---@return dbgrid.State
function M.open(nb, opts)
  opts = opts or {}
  for _, s in pairs(state.by_buf) do
    if s.nb.path == nb.path and buf_usable(s.buf) then
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

---Window options of a results window.
---@param win integer
---@param split string
local function style_results_win(win, split)
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
end

---Create the results buffer.
---@param s dbgrid.State
local function create_results_buf(s)
  local rb = vim.api.nvim_create_buf(false, true)
  vim.bo[rb].buftype = "nofile"
  vim.bo[rb].bufhidden = "hide"
  vim.bo[rb].swapfile = false
  vim.bo[rb].buflisted = false
  vim.bo[rb].filetype = "dbgrid-results"
  vim.bo[rb].shiftwidth = 2
  pcall(vim.api.nvim_buf_set_name, rb, "dbgrid://results/" .. s.nb.name .. "/" .. rb)
  s.results_buf = rb
  return rb
end

---Is the results buffer shown in its window?
---@param s dbgrid.State
---@return boolean
function M.results_visible(s)
  return buf_usable(s.results_buf)
    and win_valid(s.results_win)
    and vim.api.nvim_win_get_buf(s.results_win) == s.results_buf
end

---The window showing the query buffer (preferring the remembered one, then
---any window of the current tab, then any tab). `exclude` is a window that
---only counts as a last resort (the results window after :bdelete moved the
---query buffer into it).
---@param s dbgrid.State
---@param exclude? integer
---@return integer?
function M.query_window(s, exclude)
  local function shows_query(w)
    return win_valid(w) and vim.api.nvim_win_get_buf(w) == s.buf
  end
  if s.query_win ~= exclude and shows_query(s.query_win) then
    return s.query_win
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local wins = vim.fn.win_findbuf(s.buf)
  for _, w in ipairs(wins) do
    if w ~= exclude and vim.api.nvim_win_get_tabpage(w) == tab then
      return w
    end
  end
  for _, w in ipairs(wins) do
    if w ~= exclude then
      return w
    end
  end
  if exclude and shows_query(exclude) then
    return exclude
  end
  return nil
end

---Make sure the results window exists next to the query window and shows
---the results buffer.
---@param s dbgrid.State
function M.ensure_results(s)
  local cfg = config.get().layout
  local pos = cfg.results or "left"
  local split = ({ left = "left", right = "right", bottom = "below", top = "above" })[pos] or "left"
  local vertical = split == "left" or split == "right"
  -- 1. a usable results buffer (an unloaded one was :bdelete'd; start over)
  if s.results_buf and not buf_usable(s.results_buf) then
    if vim.api.nvim_buf_is_valid(s.results_buf) then
      pcall(vim.api.nvim_buf_delete, s.results_buf, { force = true })
    end
    s.results_buf = nil
    s.view = { truncate = s.view and s.view.truncate, mode = s.view and s.view.mode }
  end
  if not s.results_buf then
    create_results_buf(s)
  end
  -- 2. the query window we attach to
  local qwin = M.query_window(s, win_valid(s.results_win) and s.results_win or nil)
  if not qwin then
    return
  end
  if qwin == s.results_win then
    -- the query buffer only lives in the old results window now: that is the query window
    s.results_win = nil
  end
  s.query_win = qwin
  s.tab = vim.api.nvim_win_get_tabpage(qwin)
  -- 3. a window already showing the results buffer in the same tab? adopt it
  local shown
  for _, w in ipairs(vim.fn.win_findbuf(s.results_buf)) do
    if vim.api.nvim_win_get_tabpage(w) == s.tab and w ~= qwin then
      shown = (w == s.results_win) and w or (shown or w)
    end
  end
  if shown then
    s.results_win = shown
  elseif
    win_valid(s.results_win)
    and vim.api.nvim_win_get_tabpage(s.results_win) == s.tab
    and s.results_win ~= qwin
  then
    -- our window, but another buffer took it over (:bdelete, a picker, :e);
    -- take it back when that buffer is disposable, else leave it alone
    local other = vim.api.nvim_win_get_buf(s.results_win)
    local disposable = other == s.buf
      or (vim.api.nvim_buf_get_name(other) == "" and not vim.bo[other].modified and vim.bo[other].buftype == "")
    if disposable then
      pcall(vim.api.nvim_win_set_buf, s.results_win, s.results_buf)
    else
      s.results_win = nil
    end
  else
    s.results_win = nil
  end
  if not win_valid(s.results_win) then
    local wopts = { split = split, win = qwin }
    if vertical then
      wopts.width = math.max(20, math.floor(vim.o.columns * (cfg.size or 0.5)))
    else
      wopts.height = math.max(5, math.floor(vim.o.lines * (cfg.size or 0.5)))
    end
    local ok, win = pcall(vim.api.nvim_open_win, s.results_buf, false, wopts)
    if not ok then
      -- no room for a split: fall back to a plain vsplit/split next to the query window
      vim.api.nvim_win_call(qwin, function()
        vim.cmd(vertical and "vsplit" or "split")
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, s.results_buf)
      end)
      pcall(vim.api.nvim_set_current_win, qwin)
    end
    s.results_win = win
  end
  -- 4. a squeezed window (a zoom left behind, :wincmd |) gets its size back
  local win = s.results_win
  if vertical and vim.api.nvim_win_get_width(win) < 10 then
    pcall(vim.api.nvim_win_set_width, win, math.max(20, math.floor(vim.o.columns * (cfg.size or 0.5))))
    s.zoomed = nil
  elseif not vertical and vim.api.nvim_win_get_height(win) < 3 then
    pcall(vim.api.nvim_win_set_height, win, math.max(5, math.floor(vim.o.lines * (cfg.size or 0.5))))
    s.zoomed = nil
  end
  style_results_win(win, split)
  vim.wo[win].winbar = "%{%v:lua.require'dbgrid.ui.layout'.winbar_results(" .. s.buf .. ")%}"
  require("dbgrid.ui.results").attach(s)
end

---@param s dbgrid.State
function M.focus(s)
  if s.tab and vim.api.nvim_tabpage_is_valid(s.tab) then
    vim.api.nvim_set_current_tabpage(s.tab)
  end
  local qwin = M.query_window(s)
  if qwin then
    if vim.api.nvim_win_get_tabpage(qwin) ~= vim.api.nvim_get_current_tabpage() then
      vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(qwin))
    end
    vim.api.nvim_set_current_win(qwin)
  else
    -- the notebook's windows are gone: open it again the way it was opened
    if config.get().layout.tab then
      vim.cmd("tabnew")
    end
    vim.cmd("buffer " .. s.buf)
    s.query_win = vim.api.nvim_get_current_win()
    s.tab = vim.api.nvim_get_current_tabpage()
    require("dbgrid.ui.query").attach(s)
  end
  M.ensure_results(s)
  s.last_used = util.now()
  -- back to the grid of the cell under the cursor; plan/record views are transient
  s.view = { truncate = s.view and s.view.truncate, mode = s.view and s.view.mode == "schema" and "schema" or nil }
  require("dbgrid.ui.query").on_cursor(s, true)
end

---Show and focus the results pane (recreating it when needed).
---@param s dbgrid.State
function M.focus_results(s)
  M.ensure_results(s)
  if not M.results_visible(s) then
    util.warn("the results pane needs the notebook to be visible in a window")
    return
  end
  vim.api.nvim_set_current_win(s.results_win)
  if not s.view.cell_id then
    require("dbgrid.ui.query").on_cursor(s, true)
  end
end

---@param s dbgrid.State
function M.focus_query(s)
  local qwin = M.query_window(s)
  if qwin then
    vim.api.nvim_set_current_win(qwin)
  end
end

---Toggle maximising the current pane of the notebook.
---@param s dbgrid.State
function M.zoom(s)
  local win = vim.api.nvim_get_current_win()
  if s.zoomed then
    s.zoomed = nil
    vim.cmd("wincmd =")
    if win_valid(s.results_win) then
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
  if win_valid(s.results_win) then
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
  if win_valid(s.query_win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
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
  local agent = require("dbgrid.ai").agent_name(s)
  parts[#parts + 1] = " %#DbgridWinbarDim#│%#DbgridWinbarAgent# " .. esc(icons.agent) .. " " .. esc(agent) .. " "
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
