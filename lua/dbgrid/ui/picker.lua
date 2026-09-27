-- Pickers: snacks.picker when present (with previews), vim.ui.select otherwise.
local util = require("dbgrid.util")

local M = {}

---@class dbgrid.PickItem
---@field text string
---@field preview? string[]
---@field preview_ft? string
---@field data any

local function has_snacks()
  return _G.Snacks ~= nil and Snacks.picker ~= nil
end

---@param items dbgrid.PickItem[]
---@param opts { prompt: string, on_select: fun(item?: dbgrid.PickItem), preview?: boolean, actions?: table<string, fun(item: dbgrid.PickItem)>, hint?: string }
function M.pick(items, opts)
  if #items == 0 then
    opts.on_select(nil)
    return
  end
  if has_snacks() then
    local ok = pcall(function()
      local sitems = {}
      for i, it in ipairs(items) do
        sitems[i] = {
          text = it.text,
          idx = i,
          preview = it.preview and { text = table.concat(it.preview, "\n"), ft = it.preview_ft or "text" } or nil,
          item = it,
        }
      end
      local keys = {}
      local actions = {}
      for key, fn in pairs(opts.actions or {}) do
        local name = "dbgrid_" .. key:gsub("[^%w]", "_")
        actions[name] = function(picker, item)
          picker:close()
          if item and item.item then
            fn(item.item)
          end
        end
        keys[key] = { name, mode = { "n", "i" } }
      end
      Snacks.picker.pick({
        source = "dbgrid",
        title = opts.hint and (opts.prompt .. "  " .. opts.hint) or opts.prompt,
        items = sitems,
        format = "text",
        preview = opts.preview ~= false and "preview" or false,
        layout = opts.preview ~= false and nil or { preset = "select" },
        actions = actions,
        win = { input = { keys = keys } },
        confirm = function(picker, item)
          picker:close()
          opts.on_select(item and item.item or nil)
        end,
      })
    end)
    if ok then
      return
    end
  end
  vim.ui.select(items, {
    prompt = opts.prompt,
    format_item = function(it)
      return it.text
    end,
  }, function(choice)
    opts.on_select(choice)
  end)
end

---Pick a notebook of the project (optionally filtered by tag).
---@param opts { tag?: string, prompt?: string, allow_new?: boolean }
---@param cb fun(nb?: dbgrid.Notebook, action?: string)
function M.notebook(opts, cb)
  opts = opts or {}
  local notebook = require("dbgrid.notebook")
  local items = {}
  for _, nb in ipairs(notebook.list()) do
    if not opts.tag or vim.tbl_contains(nb.meta.tags, opts.tag) then
      local preview = util.lines(util.read_file(nb.path) or "")
      items[#items + 1] = { text = notebook.describe(nb), preview = preview, preview_ft = "sql", data = nb }
    end
  end
  if opts.allow_new ~= false then
    items[#items + 1] =
      { text = "+ new notebook", data = "new", preview = { "Create a new notebook in this project." } }
  end
  local prompt = opts.prompt or ("Notebooks" .. (opts.tag and (" #" .. opts.tag) or ""))
  M.pick(items, {
    prompt = prompt,
    on_select = function(item)
      if not item then
        return cb(nil)
      end
      if item.data == "new" then
        return cb(nil, "new")
      end
      cb(item.data)
    end,
    actions = {
      ["<C-x>"] = function(item)
        if type(item.data) == "table" then
          cb(item.data, "delete")
        end
      end,
    },
  })
end

---Pick a tag, then a notebook carrying it.
---@param cb fun(nb?: dbgrid.Notebook, action?: string)
function M.tag(cb)
  local notebook = require("dbgrid.notebook")
  local counts, names = notebook.all_tags()
  if #names == 0 then
    util.warn("no tags yet: add some with the tags keymap inside a notebook")
    return cb(nil)
  end
  local items = {}
  for _, t in ipairs(names) do
    local preview = {}
    for _, nb in ipairs(notebook.list()) do
      if vim.tbl_contains(nb.meta.tags, t) then
        preview[#preview + 1] = notebook.describe(nb)
      end
    end
    items[#items + 1] = { text = string.format("#%s  (%d)", t, counts[t]), preview = preview, data = t }
  end
  M.pick(items, {
    prompt = "Tags",
    on_select = function(item)
      if not item then
        return cb(nil)
      end
      M.notebook({ tag = item.data, allow_new = false }, cb)
    end,
  })
end

---Pick a connection (or add one). With snacks, <C-e> edits and <C-x> removes
---the saved connection under the cursor and the picker reopens; without it,
---`:Dbgrid connections edit|remove` do the same.
---@param cb fun(conn?: dbgrid.Connection)
---@param opts? { prompt?: string, exclude?: string, saved_only?: boolean, allow_new?: boolean }
function M.connection(cb, opts)
  opts = opts or {}
  local connections = require("dbgrid.connections")
  local items = {}
  for _, c in ipairs(connections.all()) do
    local saved = c.source == "saved" or c.source == "project"
    if c.name ~= opts.exclude and (saved or not opts.saved_only) then
      items[#items + 1] = { text = connections.describe(c), data = c, preview = { util.redact_url(c.url or "") } }
    end
  end
  if opts.saved_only and #items == 0 then
    util.warn("no saved connections yet: add one with :Dbgrid connections")
    return cb(nil)
  end
  if opts.allow_new ~= false then
    items[#items + 1] = { text = "+ add connection", data = "new", preview = { "Save a new connection url." } }
    items[#items + 1] = {
      text = "+ add AWS RDS / Aurora connection",
      data = "aws",
      preview = { "Profile, cluster, bastion, secret." },
    }
  end
  local function reopen()
    M.connection(cb, opts)
  end
  M.pick(items, {
    prompt = opts.prompt or "Connections",
    hint = "(<C-e> edit, <C-x> remove)",
    preview = false,
    on_select = function(item)
      if not item then
        return cb(nil)
      end
      if item.data == "new" then
        return connections.add_interactive(cb)
      end
      if item.data == "aws" then
        return require("dbgrid.aws").add_interactive(cb)
      end
      cb(item.data)
    end,
    actions = {
      ["<C-e>"] = function(item)
        if type(item.data) == "table" then
          connections.edit_interactive(item.data, reopen)
        end
      end,
      ["<C-x>"] = function(item)
        if type(item.data) == "table" then
          connections.remove_interactive(item.data, reopen)
        end
      end,
    },
  })
end

---Pick a table from a schema.
---@param schema dbgrid.SchemaData
---@param cb fun(tbl?: dbgrid.SchemaTable)
function M.table(schema, cb)
  local schemamod = require("dbgrid.schema")
  local items = {}
  for _, t in ipairs(schema.tables) do
    items[#items + 1] = {
      text = string.format(
        "%s  (~%s rows, %d cols)",
        schemamod.display_name(t),
        util.fmt_int(t.rows or 0),
        #(t.columns or {})
      ),
      preview = schemamod.describe_lines(t),
      data = t,
    }
  end
  M.pick(items, {
    prompt = "Tables",
    on_select = function(item)
      cb(item and item.data or nil)
    end,
  })
end

return M
