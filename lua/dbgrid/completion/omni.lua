-- Built-in omnifunc (<C-x><C-o>) for notebook buffers.
local M = {}

function M.omnifunc(findstart, base)
  local buf = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if findstart == 1 then
    local ctx = require("dbgrid.completion").context(buf, row, col)
    return ctx.start_col
  end
  local ok, items = pcall(require("dbgrid.completion").items, buf, row, col)
  if not ok then
    return {}
  end
  local out = {}
  local needle = (base or ""):lower()
  for _, it in ipairs(items) do
    if needle == "" or it.label:lower():find(needle, 1, true) == 1 then
      out[#out + 1] = {
        word = it.insert or it.label,
        abbr = it.label,
        menu = it.detail,
        kind = it.kind_name:sub(1, 1),
        info = it.documentation,
        icase = 1,
        dup = 0,
      }
    end
  end
  return out
end

return M
