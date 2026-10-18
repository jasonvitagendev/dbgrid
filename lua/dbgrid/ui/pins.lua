-- Pinned results: a result kept in its own small window next to the results
-- pane while the pane keeps following the cursor and new runs. A pin tracks
-- its cell — reruns of the cell (and live ticks) re-render it — and closes
-- with `q`, a second toggle, or the notebook.
local config = require("dbgrid.config")
local util = require("dbgrid.util")
local cells = require("dbgrid.cells")
local notebook = require("dbgrid.notebook")
local state_mod = require("dbgrid.state")

local M = {}

local function map(buf, keys, fn, desc)
  if not keys then
    return
  end
  if type(keys) == "string" then
    keys = { keys }
  end
  for _, k in ipairs(keys) do
    vim.keymap.set("n", k, fn, { buffer = buf, desc = "dbgrid: " .. desc, silent = true, nowait = true })
  end
end

---Re-render the pin's buffer from the current result of its cell.
---@param s dbgrid.State
---@param pin table
---@param cell_id string
---@return table? ctx   lines/layout of the render, nil when there is no result
local function render_pin(s, pin, cell_id)
  local result = notebook.result_of(s.nb, cell_id)
  if not result or not vim.api.nvim_buf_is_valid(pin.buf) then
    return nil
  end
  local ctx = { lines = {}, line_hl = {}, rows_layout = {}, header_layout = {}, view = pin.view, cell_id = cell_id }
  require("dbgrid.ui.results").render_grid(s, result, ctx)
  if #ctx.lines == 0 then
    ctx.lines = { "" }
  end
  pin.view.line_hl = ctx.line_hl
  pin.view.rows_layout = ctx.rows_layout
  pin.view.header_layout = ctx.header_layout
  vim.bo[pin.buf].modifiable = true
  vim.api.nvim_buf_set_lines(pin.buf, 0, -1, false, ctx.lines)
  vim.bo[pin.buf].modifiable = false
  vim.bo[pin.buf].modified = false
  if pin.win and vim.api.nvim_win_is_valid(pin.win) then
    local cur = vim.api.nvim_win_get_cursor(pin.win)
    pcall(vim.api.nvim_win_set_cursor, pin.win, { math.min(cur[1], #ctx.lines), cur[2] })
  end
  return ctx
end

---Keymaps and cleanup for a pin window.
---@param s dbgrid.State
---@param pin table
local function attach(s, pin)
  local results = require("dbgrid.ui.results")
  local k = config.get().keymaps.results
  local buf = pin.buf
  local cell_id = pin.cell_id
  map(buf, k.close, function()
    M.close(s, cell_id)
  end, "unpin this result")
  map(buf, k.inspect, function()
    if not (pin.win and vim.api.nvim_win_is_valid(pin.win)) then
      return
    end
    local c = results.cell_at(pin.view, vim.api.nvim_win_get_cursor(pin.win))
    if c then
      results.inspect_value(c)
    end
  end, "inspect value")
  map(buf, k.toggle_truncate, function()
    pin.view.truncate = pin.view.truncate == false
    render_pin(s, pin, cell_id)
  end, "toggle column truncation")
  map(buf, k.follow, function()
    if not (pin.win and vim.api.nvim_win_is_valid(pin.win)) then
      return
    end
    local c = results.cell_at(pin.view, vim.api.nvim_win_get_cursor(pin.win))
    if c then
      results.follow(s, c)
    end
  end, "follow the foreign key of the value")
  local group = vim.api.nvim_create_augroup("dbgrid_pin_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      if tonumber(ev.match) == pin.win then
        if s.pins and s.pins[cell_id] == pin then
          s.pins[cell_id] = nil
        end
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end,
  })
end

---Pin a cell's result in its own window.
---@param s dbgrid.State
---@param cell_id string
function M.open(s, cell_id)
  require("dbgrid.ui.layout").ensure_results(s)
  if not s.results_win or not vim.api.nvim_win_is_valid(s.results_win) then
    return
  end
  s.pins = s.pins or {}
  local cell = cells.by_id(s.buf, cell_id)
  local existing = notebook.result_of(s.nb, cell_id)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "dbgrid-results"
  pcall(vim.api.nvim_buf_set_name, buf, "dbgrid://pin/" .. s.nb.name .. "/" .. cell_id)
  local pin = {
    buf = buf,
    cell_id = cell_id,
    label = cell and cells.label(cell, 30) or (existing and existing.title) or cell_id,
    index = cell and cell.index,
    view = { truncate = s.view.truncate ~= false },
  }
  local ctx = render_pin(s, pin, cell_id)
  if not ctx then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return
  end
  local pos = config.get().layout.results or "left"
  local wopts = { win = s.results_win }
  if pos == "bottom" or pos == "top" then
    wopts.split = "right"
    local w = 20
    for i = 1, math.min(#ctx.lines, 200) do
      w = math.max(w, util.width(ctx.lines[i]) + 1)
    end
    wopts.width = math.min(w, math.floor(vim.api.nvim_win_get_width(s.results_win) * 0.4))
  else
    wopts.split = "below"
    wopts.height = math.max(3, math.min(#ctx.lines + 1, math.floor(vim.api.nvim_win_get_height(s.results_win) * 0.4)))
  end
  local win = vim.api.nvim_open_win(buf, false, wopts)
  pin.win = win
  s.pins[cell_id] = pin
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
  wo.winfixheight = wopts.split == "below"
  wo.winfixwidth = wopts.split == "right"
  wo.winbar = "%{%v:lua.require'dbgrid.ui.pins'.winbar(" .. buf .. ")%}"
  local target
  for lnum in pairs(ctx.rows_layout) do
    if not target or lnum < target then
      target = lnum
    end
  end
  pcall(vim.api.nvim_win_set_cursor, win, { target or 1, 0 })
  attach(s, pin)
end

---Close the pin of a cell.
---@param s dbgrid.State
---@param cell_id string
function M.close(s, cell_id)
  local pin = s.pins and s.pins[cell_id]
  if not pin then
    return
  end
  s.pins[cell_id] = nil
  if pin.win and vim.api.nvim_win_is_valid(pin.win) then
    pcall(vim.api.nvim_win_close, pin.win, true)
  end
  if pin.buf and vim.api.nvim_buf_is_valid(pin.buf) then
    pcall(vim.api.nvim_buf_delete, pin.buf, { force = true })
  end
end

---Close every pin of the notebook.
---@param s dbgrid.State
function M.close_all(s)
  for cell_id in pairs(s.pins or {}) do
    M.close(s, cell_id)
  end
end

---Toggle the pin of a cell (default: the one shown in the results pane).
---@param s dbgrid.State
---@param cell_id? string
function M.toggle(s, cell_id)
  cell_id = cell_id or (s.view and s.view.cell_id)
  if not cell_id then
    return util.notify("no result to pin: run a cell first")
  end
  s.pins = s.pins or {}
  if s.pins[cell_id] then
    M.close(s, cell_id)
    return
  end
  if not notebook.result_of(s.nb, cell_id) then
    return util.notify("no result to pin: run the cell first")
  end
  M.open(s, cell_id)
end

---Re-render the pin of a cell after a rerun of the cell (also live ticks).
---@param s dbgrid.State
---@param cell_id string
function M.refresh(s, cell_id)
  local pin = s.pins and s.pins[cell_id]
  if not pin then
    return
  end
  if pin.win and not vim.api.nvim_win_is_valid(pin.win) then
    s.pins[cell_id] = nil
    pcall(vim.api.nvim_buf_delete, pin.buf, { force = true })
    return
  end
  render_pin(s, pin, cell_id)
end

---Winbar text of a pin window.
---@param buf integer  pin buffer
function M.winbar(buf)
  local s, pin, cell_id = state_mod.pin_of(buf)
  if not s then
    return ""
  end
  local icons = config.get().icons
  local function esc(t)
    return (tostring(t or ""):gsub("%%", "%%%%"))
  end
  local cell = cells.by_id(s.buf, cell_id)
  local parts = {}
  parts[#parts + 1] = "%#DbgridWinbarTitle# "
    .. esc(icons.pin)
    .. " q"
    .. tostring(cell and cell.index or pin.index or "?")
    .. " "
    .. esc(pin.label)
    .. " "
  parts[#parts + 1] = "%#DbgridWinbarDim#│"
  local running = s.running[cell_id]
  local meta = s.nb.meta.cells[cell_id]
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
  else
    parts[#parts + 1] = "%#DbgridWinbarDim# " .. esc(icons.idle) .. " not run "
  end
  if s.live and s.live[cell_id] then
    parts[#parts + 1] = "%#DbgridWinbarLive#" .. esc(icons.live) .. " live "
  end
  parts[#parts + 1] = "%#DbgridWinbarDim#│ q unpins "
  return table.concat(parts)
end

return M
