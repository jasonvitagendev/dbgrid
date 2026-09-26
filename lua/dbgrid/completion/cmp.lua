-- nvim-cmp source. Register with:
--   require("cmp").register_source("dbgrid", require("dbgrid.completion.cmp").new())
--   and add { name = "dbgrid" } to your sources.
local source = {}
source.__index = source

function source.new()
  return setmetatable({}, source)
end

function source:is_available()
  return vim.b.dbgrid ~= nil
end

function source:get_trigger_characters()
  return { "." }
end

function source:get_debug_name()
  return "dbgrid"
end

function source:complete(params, callback)
  local buf = vim.api.nvim_get_current_buf()
  local row, col = params.context.cursor.row, params.context.cursor.col - 1
  local ok, items = pcall(require("dbgrid.completion").items, buf, row, col)
  if not ok then
    return callback({ items = {}, isIncomplete = false })
  end
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = {
      label = it.label,
      kind = it.kind,
      insertText = it.insert or it.label,
      detail = it.detail,
      documentation = it.documentation,
      sortText = it.sort,
    }
  end
  callback({ items = out, isIncomplete = false })
end

return source
