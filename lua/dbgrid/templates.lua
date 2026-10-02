-- Bundled notebooks (lua/dbgrid/templates/*.sql) and user templates
-- (`templates.dir`). A template is a notebook file with a small header:
--
--   -- template-name: Diagnostics
--   -- template-tags: diagnostics
--   -- template-description: what is slow, who blocks whom, ...
--   -- template-connections: blue, green      <- `-- @conn blue` placeholders bound on creation
local util = require("dbgrid.util")
local config = require("dbgrid.config")

local M = {}

---@class dbgrid.Template
---@field name string          file name without extension
---@field title string
---@field tags string[]
---@field description string
---@field connections string[] placeholder connection names
---@field path string
---@field builtin boolean

---Directory of the bundled templates.
---@return string
function M.builtin_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h") .. "/templates"
end

---Parse the header of a template file.
---@param text string
---@return table meta, string body
function M.parse(text)
  local meta = { tags = {}, connections = {} }
  local lines = util.lines(text)
  local i = 1
  while lines[i] do
    local k, v = lines[i]:match("^%s*%-%-%s*template%-([%w_]+)%s*:%s*(.-)%s*$")
    if not k then
      break
    end
    if k == "tags" or k == "connections" then
      meta[k] = vim.split(v, "[,%s]+", { trimempty = true })
    else
      meta[k] = v
    end
    i = i + 1
  end
  while lines[i] and lines[i]:match("^%s*$") do
    i = i + 1
  end
  return meta, table.concat(vim.list_slice(lines, i, #lines), "\n")
end

---@param path string
---@param builtin boolean
---@return dbgrid.Template?
local function load(path, builtin)
  local text = util.read_file(path)
  if not text then
    return nil
  end
  local meta = M.parse(text)
  local name = vim.fn.fnamemodify(path, ":t:r")
  return {
    name = name,
    title = meta.name or name,
    tags = meta.tags or {},
    description = meta.description or "",
    connections = meta.connections or {},
    path = path,
    builtin = builtin,
  }
end

---Every template, user ones first (a user template shadows a bundled one with the same name).
---@return dbgrid.Template[]
function M.list()
  local out, seen = {}, {}
  local dirs = {}
  local user = config.get().templates and config.get().templates.dir
  if user and user ~= "" then
    dirs[#dirs + 1] = { vim.fn.expand(user), false }
  end
  dirs[#dirs + 1] = { M.builtin_dir(), true }
  for _, d in ipairs(dirs) do
    for _, f in ipairs(vim.fn.glob(d[1] .. "/*.sql", false, true)) do
      local t = load(f, d[2])
      if t and not seen[t.name] then
        seen[t.name] = true
        out[#out + 1] = t
      end
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

---@param name string
---@return dbgrid.Template?
function M.get(name)
  for _, t in ipairs(M.list()) do
    if t.name == name or t.title:lower() == tostring(name):lower() then
      return t
    end
  end
end

---Body of a template with its `-- @conn <placeholder>` lines bound to real connections.
---@param tpl dbgrid.Template
---@param bindings table<string,string>
---@return string
function M.body(tpl, bindings)
  local _, body = M.parse(util.read_file(tpl.path) or "")
  bindings = bindings or {}
  local lines = util.lines(body)
  for i, l in ipairs(lines) do
    local prefix, name = l:match("^(%s*%-%-%s*@conn%s+)([%w_%-%./]+)%s*$")
    if prefix and bindings[name] then
      lines[i] = prefix .. bindings[name]
    end
  end
  return table.concat(lines, "\n")
end

---Create a notebook from a template.
---@param tpl dbgrid.Template
---@param opts? { title?: string, bindings?: table<string,string>, connection?: string }
---@return dbgrid.Notebook
function M.instantiate(tpl, opts)
  opts = opts or {}
  local notebook = require("dbgrid.notebook")
  local nb = notebook.create(opts.title or tpl.title, {
    tags = vim.deepcopy(tpl.tags),
    connection = opts.connection,
    body = M.body(tpl, opts.bindings),
  })
  nb.meta.template = tpl.name
  notebook.save_meta(nb)
  return nb
end

---Ask for the connections a template needs, then create and open it.
---@param name_or_tpl string|dbgrid.Template
---@param opts? { title?: string }
---@param cb? fun(nb?: dbgrid.Notebook)
function M.create_interactive(name_or_tpl, opts, cb)
  opts = opts or {}
  local tpl = type(name_or_tpl) == "table" and name_or_tpl or M.get(name_or_tpl)
  if not tpl then
    util.error("no template named '" .. tostring(name_or_tpl) .. "' (see :Dbgrid templates)")
    return cb and cb(nil)
  end
  local bindings = {}
  local placeholders = vim.deepcopy(tpl.connections)
  local function next_binding()
    local ph = table.remove(placeholders, 1)
    if not ph then
      local nb = M.instantiate(tpl, {
        title = opts.title,
        bindings = bindings,
        connection = bindings[tpl.connections[1]],
      })
      return cb and cb(nb)
    end
    require("dbgrid.ui.picker").connection(function(conn)
      if not conn then
        return cb and cb(nil)
      end
      bindings[ph] = conn.name
      next_binding()
    end, { prompt = "Connection for '" .. ph .. "'" })
  end
  next_binding()
end

---Pick a template.
---@param cb fun(tpl?: dbgrid.Template)
function M.pick(cb)
  local items = {}
  for _, t in ipairs(M.list()) do
    local preview = util.lines(util.read_file(t.path) or "")
    items[#items + 1] = {
      text = string.format("%s  %s%s", t.title, t.description, t.builtin and "" or "  (user)"),
      preview = preview,
      preview_ft = "sql",
      data = t,
    }
  end
  require("dbgrid.ui.picker").pick(items, {
    prompt = "Templates",
    on_select = function(item)
      cb(item and item.data or nil)
    end,
  })
end

return M
