-- Per-notebook runtime state, keyed by the query buffer number.
local M = {}

---@class dbgrid.State
---@field buf integer             query buffer
---@field nb dbgrid.Notebook
---@field results_buf integer?
---@field results_win integer?
---@field query_win integer?
---@field tab integer?
---@field active_cell string?     id of the cell whose result is shown
---@field running table<string, { job: dbgrid.Job, started: number, kind: string }>
---@field runtime table<string, table>   per-cell transient status (warnings, generated flag)
---@field view table              results view state

M.by_buf = {} ---@type table<integer, dbgrid.State>

---@param buf integer
---@return dbgrid.State?
function M.get(buf)
  return M.by_buf[buf]
end

---@param buf integer
---@param nb dbgrid.Notebook
---@return dbgrid.State
function M.attach(buf, nb)
  local s = M.by_buf[buf]
  if s then
    s.nb = nb
    return s
  end
  s = { buf = buf, nb = nb, running = {}, runtime = {}, view = {} }
  M.by_buf[buf] = s
  return s
end

---@param buf integer
function M.detach(buf)
  M.by_buf[buf] = nil
end

---State owning a results buffer.
---@param results_buf integer
---@return dbgrid.State?
function M.by_results_buf(results_buf)
  for _, s in pairs(M.by_buf) do
    if s.results_buf == results_buf then
      return s
    end
  end
end

---State for the current window's buffer (query or results side).
---@param buf? integer
---@return dbgrid.State?
function M.current(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return M.by_buf[buf] or M.by_results_buf(buf)
end

---Most recently used notebook state.
---@return dbgrid.State?
function M.last()
  local best
  for _, s in pairs(M.by_buf) do
    if vim.api.nvim_buf_is_valid(s.buf) and (not best or (s.last_used or 0) > (best.last_used or 0)) then
      best = s
    end
  end
  return best
end

return M
