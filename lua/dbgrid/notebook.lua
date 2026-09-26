-- Notebooks: one `.sql` file of cells plus a small `.json` (tags, connection,
-- per-cell run info) and a disposable `.cache.json` (last results), stored per
-- project.
local util = require("dbgrid.util")
local config = require("dbgrid.config")
local project = require("dbgrid.project")

local M = {}

---@class dbgrid.CellMeta
---@field title string
---@field sql_hash string
---@field ran_at integer
---@field status "ok"|"error"
---@field row_count integer?
---@field elapsed_ms number?
---@field warnings string[]?
---@field connection string?

---@class dbgrid.NotebookMeta
---@field name string
---@field title string
---@field tags string[]
---@field connection string?
---@field agent string?            coding agent used for prompts (overrides ai.agent)
---@field params table<string,string>  parameter values entered for this notebook
---@field created_at integer
---@field updated_at integer
---@field cells table<string, dbgrid.CellMeta>

---@class dbgrid.Notebook
---@field name string
---@field dir string
---@field path string
---@field meta_path string
---@field cache_path string
---@field meta dbgrid.NotebookMeta
---@field cache table<string, table>?
---@field root string

local cache_writers = {} ---@type table<string, fun()>

---@param dir string
---@param name string
---@return dbgrid.Notebook
local function make(dir, name, root)
  return {
    name = name,
    dir = dir,
    root = root,
    path = dir .. "/" .. name .. ".sql",
    meta_path = dir .. "/" .. name .. ".json",
    cache_path = dir .. "/" .. name .. ".cache.json",
  }
end

---@param nb dbgrid.Notebook
local function load_meta(nb)
  local meta = util.read_json(nb.meta_path) or {}
  meta.name = nb.name
  meta.title = meta.title or nb.name
  meta.tags = meta.tags or {}
  meta.cells = meta.cells or {}
  meta.params = meta.params or {}
  if meta.params == vim.NIL then
    meta.params = {}
  end
  if meta.agent == vim.NIL then
    meta.agent = nil
  end
  meta.created_at = meta.created_at or util.epoch()
  meta.updated_at = meta.updated_at or meta.created_at
  if meta.connection == vim.NIL then
    meta.connection = nil
  end
  nb.meta = meta
end

---All notebooks of a project, most recently updated first.
---@param root? string
---@return dbgrid.Notebook[]
function M.list(root)
  root = root or project.root()
  local dir = project.store_dir(root)
  local out = {}
  for _, f in ipairs(vim.fn.glob(dir .. "/*.sql", false, true)) do
    local name = vim.fn.fnamemodify(f, ":t:r")
    local nb = make(dir, name, root)
    load_meta(nb)
    out[#out + 1] = nb
  end
  table.sort(out, function(a, b)
    return (a.meta.updated_at or 0) > (b.meta.updated_at or 0)
  end)
  return out
end

---@param name string
---@param root? string
---@return dbgrid.Notebook?
function M.load(name, root)
  root = root or project.root()
  local dir = project.store_dir(root)
  local nb = make(dir, name, root)
  if not util.exists(nb.path) then
    return nil
  end
  load_meta(nb)
  return nb
end

---Notebook owning a `.sql` path, if it lives in a dbgrid store.
---@param path string
---@return dbgrid.Notebook?
function M.from_path(path)
  path = vim.fn.fnamemodify(path, ":p")
  if not path:match("%.sql$") then
    return nil
  end
  -- buffer names are symlink-resolved (macOS /var -> /private/var), config paths may not be
  local function real(p)
    return vim.uv.fs_realpath(p) or p
  end
  local dir = vim.fs.dirname(path)
  local name = vim.fn.fnamemodify(path, ":t:r")
  local st = config.get().storage
  local data_projects = real(vim.fn.fnamemodify(st.data_dir, ":p"):gsub("/$", "") .. "/projects") .. "/"
  local in_data = real(dir):sub(1, #data_projects) == data_projects
  local in_project = vim.fs.basename(dir) == st.project_dir
  if not (in_data or in_project) then
    return nil
  end
  local root = in_project and vim.fs.dirname(dir) or project.root()
  local nb = make(dir, name, root)
  load_meta(nb)
  return nb
end

---@param title string
---@param opts? { tags?: string[], connection?: string, root?: string }
---@return dbgrid.Notebook
function M.create(title, opts)
  opts = opts or {}
  local root = opts.root or project.root()
  local dir = project.store_dir(root)
  util.mkdirp(dir)
  if project.store_dir(root) == root .. "/" .. config.get().storage.project_dir then
    -- keep result caches out of the repository
    local gi = dir .. "/.gitignore"
    if not util.exists(gi) then
      util.write_file(gi, "*.cache.json\n")
    end
  end
  title = util.trim(title or "")
  if title == "" then
    title = "untitled " .. os.date("%Y-%m-%d %H%M")
  end
  local base = util.slug(title)
  local name, n = base, 1
  while util.exists(dir .. "/" .. name .. ".sql") do
    n = n + 1
    name = base .. "-" .. n
  end
  local nb = make(dir, name, root)
  nb.meta = {
    name = name,
    title = title,
    tags = opts.tags or {},
    connection = opts.connection,
    created_at = util.epoch(),
    updated_at = util.epoch(),
    cells = {},
    params = {},
  }
  local id = util.short_id(4)
  util.write_file(nb.path, require("dbgrid.cells").header_line(id) .. "\n\n")
  M.save_meta(nb)
  return nb
end

---@param nb dbgrid.Notebook
function M.save_meta(nb)
  nb.meta.updated_at = util.epoch()
  util.write_json(nb.meta_path, nb.meta)
end

---@param nb dbgrid.Notebook
---@param tags string[]
function M.set_tags(nb, tags)
  local clean = {}
  for _, t in ipairs(tags) do
    t = util.trim(t):gsub("^#", "")
    if t ~= "" then
      clean[#clean + 1] = t
    end
  end
  nb.meta.tags = util.uniq(clean)
  M.save_meta(nb)
end

---@param nb dbgrid.Notebook
---@param tag string
function M.add_tag(nb, tag)
  local tags = vim.deepcopy(nb.meta.tags)
  tags[#tags + 1] = tag
  M.set_tags(nb, tags)
end

---@param nb dbgrid.Notebook
---@param tag string
function M.remove_tag(nb, tag)
  local tags = {}
  for _, t in ipairs(nb.meta.tags) do
    if t ~= tag then
      tags[#tags + 1] = t
    end
  end
  M.set_tags(nb, tags)
end

---Every tag used in the project with its notebook count.
---@param root? string
---@return table<string, integer>, string[] sorted
function M.all_tags(root)
  local counts = {}
  for _, nb in ipairs(M.list(root)) do
    for _, t in ipairs(nb.meta.tags) do
      counts[t] = (counts[t] or 0) + 1
    end
  end
  local names = vim.tbl_keys(counts)
  table.sort(names)
  return counts, names
end

---Rename (moves the three files).
---@param nb dbgrid.Notebook
---@param title string
---@return boolean ok, string? err
function M.rename(nb, title)
  title = util.trim(title)
  if title == "" then
    return false, "empty title"
  end
  local base = util.slug(title)
  local name, n = base, 1
  while name ~= nb.name and util.exists(nb.dir .. "/" .. name .. ".sql") do
    n = n + 1
    name = base .. "-" .. n
  end
  local new = make(nb.dir, name, nb.root)
  if name ~= nb.name then
    os.rename(nb.path, new.path)
    os.rename(nb.meta_path, new.meta_path)
    if util.exists(nb.cache_path) then
      os.rename(nb.cache_path, new.cache_path)
    end
  end
  nb.name, nb.path, nb.meta_path, nb.cache_path = new.name, new.path, new.meta_path, new.cache_path
  nb.meta.name = name
  nb.meta.title = title
  M.save_meta(nb)
  return true
end

---@param nb dbgrid.Notebook
function M.delete(nb)
  for _, p in ipairs({ nb.path, nb.meta_path, nb.cache_path }) do
    if util.exists(p) then
      os.remove(p)
    end
  end
end

---@param nb dbgrid.Notebook
local function ensure_cache(nb)
  if not nb.cache then
    nb.cache = util.read_json(nb.cache_path) or {}
  end
  return nb.cache
end

---Last result of a cell (nil when never run or evicted).
---@param nb dbgrid.Notebook
---@param cell_id string
---@return table?
function M.result_of(nb, cell_id)
  local r = ensure_cache(nb)[cell_id]
  if r == vim.NIL then
    return nil
  end
  return r
end

---Strip a result down to what is worth caching.
---@param result table
---@return table
local function slim(result)
  local max_rows = config.get().storage.cache_rows or 500
  local copy = {
    ok = result.ok,
    ran_at = result.ran_at,
    elapsed_ms = result.elapsed_ms,
    server_ms = result.server_ms,
    connection = result.connection,
    notices = result.notices,
    warnings = result.warnings,
    error = result.error,
    sql_hash = result.sql_hash,
    truncated = result.truncated,
    cancelled = result.cancelled,
    params = result.params,
    refs = result.refs,
    statements = {},
  }
  for i, st in ipairs(result.statements or {}) do
    local sets = {}
    for j, set in ipairs(st.sets or {}) do
      local rows = set.rows
      local evicted = false
      if #rows > max_rows then
        rows = vim.list_slice(rows, 1, max_rows)
        evicted = true
      end
      sets[j] = { columns = set.columns, rows = rows, row_count = set.row_count, evicted = evicted }
    end
    copy.statements[i] = {
      sql = st.sql,
      kind = st.kind,
      class = st.class,
      line = st.line,
      limit_applied = st.limit_applied,
      sets = sets,
      tags = st.tags,
      server_ms = st.server_ms,
      ran = st.ran,
      plan = st.plan,
    }
  end
  return copy
end

---@param nb dbgrid.Notebook
local function schedule_cache_write(nb)
  local key = nb.cache_path
  if not cache_writers[key] then
    cache_writers[key] = util.debounce(500, function()
      if nb.cache and (config.get().storage.cache_rows or 0) > 0 then
        pcall(util.write_json, nb.cache_path, nb.cache)
      end
    end)
  end
  cache_writers[key]()
end

---Store a result for a cell and update its meta.
---@param nb dbgrid.Notebook
---@param cell dbgrid.Cell
---@param result table
function M.set_result(nb, cell, result)
  local cache = ensure_cache(nb)
  cache[cell.id] = slim(result)
  local rows
  for _, st in ipairs(result.statements or {}) do
    for _, set in ipairs(st.sets or {}) do
      rows = (rows or 0) + (set.row_count or #set.rows)
    end
  end
  local warnings = {}
  for _, w in ipairs(result.warnings or {}) do
    warnings[#warnings + 1] = type(w) == "table" and w.message or tostring(w)
  end
  nb.meta.cells[cell.id] = {
    title = cell.title,
    sql_hash = result.sql_hash,
    ran_at = result.ran_at,
    status = result.ok and "ok" or "error",
    row_count = rows,
    elapsed_ms = result.elapsed_ms,
    warnings = warnings,
    connection = result.connection,
  }
  M.save_meta(nb)
  schedule_cache_write(nb)
end

---Forget a cell's result.
---@param nb dbgrid.Notebook
---@param cell_id string
function M.clear_result(nb, cell_id)
  ensure_cache(nb)[cell_id] = nil
  nb.meta.cells[cell_id] = nil
  M.save_meta(nb)
  schedule_cache_write(nb)
end

---Drop meta/cache for cells that no longer exist in the buffer.
---@param nb dbgrid.Notebook
---@param live_ids string[]
function M.prune(nb, live_ids)
  local live = {}
  for _, id in ipairs(live_ids) do
    live[id] = true
  end
  local changed = false
  for id in pairs(nb.meta.cells) do
    if not live[id] then
      nb.meta.cells[id] = nil
      changed = true
    end
  end
  local cache = ensure_cache(nb)
  for id in pairs(cache) do
    if not live[id] then
      cache[id] = nil
      changed = true
    end
  end
  if changed then
    M.save_meta(nb)
    schedule_cache_write(nb)
  end
end

---@param nb dbgrid.Notebook
---@param connection string?
function M.set_connection(nb, connection)
  nb.meta.connection = connection
  M.save_meta(nb)
end

---Remember a parameter value (nil forgets it).
---@param nb dbgrid.Notebook
---@param name string
---@param value string?
function M.set_param(nb, name, value)
  nb.meta.params = nb.meta.params or {}
  nb.meta.params[name] = value
  M.save_meta(nb)
end

---Coding agent for this notebook (nil = the configured default).
---@param nb dbgrid.Notebook
---@param agent string?
function M.set_agent(nb, agent)
  nb.meta.agent = agent
  M.save_meta(nb)
end

---One-line summary for pickers.
---@param nb dbgrid.Notebook
function M.describe(nb)
  local tags = {}
  for _, t in ipairs(nb.meta.tags) do
    tags[#tags + 1] = "#" .. t
  end
  local parts = { nb.meta.title }
  if #tags > 0 then
    parts[#parts + 1] = table.concat(tags, " ")
  end
  if nb.meta.connection then
    parts[#parts + 1] = "@" .. nb.meta.connection
  end
  parts[#parts + 1] = util.ago(nb.meta.updated_at)
  return table.concat(parts, "  ")
end

return M
