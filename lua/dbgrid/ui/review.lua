-- The answer float: what was asked about a cell's query and result, and what
-- the agent replied. One transcript per cell, kept until the cell is re-run.
local config = require("dbgrid.config")
local util = require("dbgrid.util")
local cells = require("dbgrid.cells")

local M = {}

local function key_label(v)
  if type(v) == "table" then
    v = v[1]
  end
  return (tostring(v or ""):gsub("<localleader>", vim.g.maplocalleader or "\\"))
end

---Transcript as markdown lines.
---@param transcript { turns: { question: string, answer: string }[] }
---@return string[] lines, integer[] question_lnums
function M.lines(transcript)
  local lines, marks = {}, {}
  for i, turn in ipairs(transcript.turns) do
    if i > 1 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "---"
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "**Q:** " .. turn.question
    marks[#marks + 1] = #lines
    lines[#lines + 1] = ""
    for _, l in ipairs(util.lines(turn.answer)) do
      lines[#lines + 1] = l
    end
  end
  return lines, marks
end

---@param s dbgrid.State
function M.close(s)
  local win = s.review_win
  s.review_win = nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---Show the transcript of a cell in a focused float: `q` closes it, the ask
---key asks a follow-up, leaving the window closes it.
---@param s dbgrid.State
---@param cell dbgrid.Cell
function M.open(s, cell)
  local rt = s.runtime[cell.id]
  local transcript = rt and rt.review
  if not transcript or #transcript.turns == 0 then
    return util.notify("nothing has been asked about this cell yet")
  end
  M.close(s)
  local lines, marks = M.lines(transcript)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "markdown"
  local width = math.max(40, math.min(100, vim.o.columns - 4))
  local wrapped = 0
  for _, l in ipairs(lines) do
    wrapped = wrapped + math.max(1, math.ceil(util.width(l) / width))
  end
  local height = math.max(3, math.min(wrapped, vim.o.lines - 6))
  local last = transcript.turns[#transcript.turns]
  local icons = config.get().icons
  local ask_key = key_label(config.get().keymaps.results.ask)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. icons.generated .. " q" .. cell.index .. " " .. cells.label(cell, 30) .. " · " .. last.agent .. " ",
    title_pos = "left",
    footer = (ask_key ~= "" and (" " .. ask_key .. " follow-up · ") or " ") .. "q close ",
    footer_pos = "right",
  })
  s.review_win = win
  local wo = vim.wo[win]
  wo.wrap = true
  wo.linebreak = true
  wo.conceallevel = 2
  wo.concealcursor = "nc"
  -- start at the latest question so its answer is what is on screen
  pcall(vim.api.nvim_win_set_cursor, win, { marks[#marks] or 1, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zt")
  end)
  local function map(keys, fn, desc)
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
  map({ "q", "<Esc>" }, function()
    M.close(s)
  end, "close")
  map(config.get().keymaps.results.ask, function()
    M.close(s)
    require("dbgrid.ai").review(s, cells.by_id(s.buf, cell.id) or cell)
  end, "ask a follow-up")
  local group = vim.api.nvim_create_augroup("dbgrid_review_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if s.review_win == win then
          M.close(s)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      if s.review_win == win then
        s.review_win = nil
      end
    end,
  })
end

return M
