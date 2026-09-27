-- dbgrid.nvim: SQL notebooks for Neovim (query cells on one side, results on
-- the other), with tags per project, schema-aware completion, index warnings
-- and prompt-to-SQL through your coding agent.
local config = require("dbgrid.config")

local M = {}

---@param opts? table
function M.setup(opts)
  config.setup(opts)
  require("dbgrid.highlights").setup()
  local group = vim.api.nvim_create_augroup("dbgrid_setup", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      require("dbgrid.highlights").setup()
    end,
  })
  M._setup_done = true
end

local function ensure_setup()
  if not M._setup_done then
    M.setup({})
  end
end

---Open a notebook by name, or pick one.
---@param name? string
function M.open(name)
  ensure_setup()
  local notebook = require("dbgrid.notebook")
  local layout = require("dbgrid.ui.layout")
  if name and name ~= "" then
    local nb = notebook.load(name) or notebook.load(require("dbgrid.util").slug(name))
    if not nb then
      -- fuzzy: title match
      for _, cand in ipairs(notebook.list()) do
        if cand.meta.title:lower():find(name:lower(), 1, true) then
          nb = cand
          break
        end
      end
    end
    if not nb then
      require("dbgrid.util").warn("no notebook named '" .. name .. "'")
      return
    end
    return layout.open(nb)
  end
  require("dbgrid.ui.picker").notebook({}, function(nb, action, nbs)
    if action == "new" then
      return M.new()
    elseif action == "delete" and nb then
      return M.delete(nbs or nb)
    elseif nb then
      layout.open(nb)
    end
  end)
end

---Create a notebook (prompts for a title when none is given).
---@param title? string
---@param opts? { tags?: string[], connection?: string }
function M.new(title, opts)
  ensure_setup()
  local notebook = require("dbgrid.notebook")
  local layout = require("dbgrid.ui.layout")
  local function create(t)
    local nb = notebook.create(t, opts)
    local s = layout.open(nb)
    if not nb.meta.connection then
      require("dbgrid.runner").with_connection(s, nil, function() end)
    end
    return s
  end
  if title then
    return create(title)
  end
  vim.ui.input({ prompt = "Notebook title: " }, function(t)
    if t == nil then
      return
    end
    create(t)
  end)
end

---Browse notebooks by tag.
function M.tags()
  ensure_setup()
  require("dbgrid.ui.picker").tag(function(nb, action, nbs)
    if action == "delete" and nb then
      return M.delete(nbs or nb)
    elseif nb then
      require("dbgrid.ui.layout").open(nb)
    end
  end)
end

---Jump to the most recently used notebook (or pick one).
function M.last()
  ensure_setup()
  local s = require("dbgrid.state").last()
  if s then
    require("dbgrid.ui.layout").focus(s)
    return
  end
  local list = require("dbgrid.notebook").list()
  if list[1] then
    require("dbgrid.ui.layout").open(list[1])
  else
    M.open()
  end
end

---Close the current notebook layout.
function M.close()
  local s = require("dbgrid.state").current()
  if s then
    require("dbgrid.ui.layout").close(s)
  end
end

---Delete one notebook or a list of them after a single confirmation.
---@param nbs dbgrid.Notebook|dbgrid.Notebook[]
function M.delete(nbs)
  if nbs.meta then
    nbs = { nbs }
  end
  if #nbs == 0 then
    return
  end
  local msg
  if #nbs == 1 then
    msg = "Delete notebook '" .. nbs[1].meta.title .. "' and its cached results?"
  else
    local lines = { ("Delete %d notebooks and their cached results?"):format(#nbs) }
    for i, nb in ipairs(nbs) do
      if i > 8 then
        lines[#lines + 1] = ("  ... and %d more"):format(#nbs - 8)
        break
      end
      lines[#lines + 1] = "  " .. nb.meta.title
    end
    msg = table.concat(lines, "\n")
  end
  if vim.fn.confirm(msg, "&Delete\n&Cancel", 2, "Warning") ~= 1 then
    return
  end
  local notebook = require("dbgrid.notebook")
  for _, nb in ipairs(nbs) do
    for buf, s in pairs(require("dbgrid.state").by_buf) do
      if s.nb.path == nb.path then
        require("dbgrid.ui.layout").close(s)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    notebook.delete(nb)
  end
  require("dbgrid.util").notify(
    #nbs == 1 and ("deleted " .. nbs[1].meta.title) or ("deleted %d notebooks"):format(#nbs)
  )
end

---Attach a `.sql` buffer that lives in a dbgrid store.
---@param buf? integer
---@return dbgrid.State?
function M.attach(buf)
  ensure_setup()
  buf = buf or vim.api.nvim_get_current_buf()
  if require("dbgrid.state").get(buf) then
    return require("dbgrid.state").get(buf)
  end
  local nb = require("dbgrid.notebook").from_path(vim.api.nvim_buf_get_name(buf))
  if not nb then
    return nil
  end
  return require("dbgrid.ui.layout").adopt(buf, nb)
end

---Register a database adapter.
---@param adapter dbgrid.Adapter
function M.register_adapter(adapter)
  require("dbgrid.adapters").register(adapter)
end

---Current notebook state (query or results side).
function M.current()
  return require("dbgrid.state").current()
end

return M
