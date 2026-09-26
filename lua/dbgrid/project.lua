-- Project (repo) detection and the per-project storage directory.
local util = require("dbgrid.util")
local config = require("dbgrid.config")

local M = {}

local root_cache = {}

---Root of the project the current working directory belongs to.
---@param cwd? string
---@return string
function M.root(cwd)
  cwd = cwd or vim.fn.getcwd()
  if root_cache[cwd] then
    return root_cache[cwd]
  end
  local root = cwd
  local git = vim.fs.find(".git", { path = cwd, upward = true, type = "directory" })[1]
  if git then
    root = vim.fs.dirname(git)
  else
    local gitfile = vim.fs.find(".git", { path = cwd, upward = true, type = "file" })[1] -- worktrees
    if gitfile then
      root = vim.fs.dirname(gitfile)
    end
  end
  root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  root_cache[cwd] = root
  return root
end

---Slug used for the per-project directory inside the data dir.
---@param root string
function M.slug(root)
  return util.slug(vim.fs.basename(root)) .. "-" .. util.hash(root)
end

---Directory notebooks of this project live in.
---@param root? string
---@return string dir, "project"|"data" mode
function M.store_dir(root)
  root = root or M.root()
  local st = config.get().storage
  local in_project = root .. "/" .. st.project_dir
  if st.mode == "project" or (st.mode == "auto" and util.exists(in_project)) then
    return in_project, "project"
  end
  return st.data_dir .. "/projects/" .. M.slug(root), "data"
end

---Global data directory (schema cache, connections).
function M.data_dir()
  return config.get().storage.data_dir
end

local framework_cache = {}

---Framework the project is built with, when it matters to dbgrid ("rails"), else nil.
---@param root? string
---@return string?
function M.framework(root)
  root = root or M.root()
  if framework_cache[root] == nil then
    framework_cache[root] = require("dbgrid.rails").is_rails(root) and "rails" or false
  end
  return framework_cache[root] or nil
end

---Human readable name of the project.
---@param root? string
function M.name(root)
  return vim.fs.basename(root or M.root())
end

return M
