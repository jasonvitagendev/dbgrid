-- blink.cmp source. Register with:
--   sources = { default = { "dbgrid", ... }, providers = { dbgrid = { name = "dbgrid", module = "dbgrid.completion.blink" } } }
local Source = {}
Source.__index = Source

function Source.new(opts)
  return setmetatable({ opts = opts or {} }, Source)
end

function Source:enabled()
  return vim.b.dbgrid ~= nil
end

function Source:get_trigger_characters()
  return { ".", "'" }
end

function Source:get_completions(ctx, callback)
  local buf = ctx.bufnr or vim.api.nvim_get_current_buf()
  local row, col = ctx.cursor[1], ctx.cursor[2]
  local ok, items, cctx = pcall(require("dbgrid.completion").items, buf, row, col)
  if not ok then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    return function() end
  end
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = {
      label = it.label,
      kind = it.kind,
      insertText = it.insert or it.label,
      labelDetails = it.detail and { description = it.detail } or nil,
      documentation = it.documentation and { kind = "plaintext", value = it.documentation } or nil,
      sortText = it.sort,
      filterText = it.label,
      textEdit = cctx and {
        newText = it.insert or it.label,
        range = {
          start = { line = row - 1, character = cctx.start_col },
          ["end"] = { line = row - 1, character = col },
        },
      } or nil,
    }
  end
  callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = out })
  return function() end
end

function Source:resolve(item, callback)
  callback(item)
end

return Source
