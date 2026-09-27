-- Schema and settings comparison between two connections, shown in a scratch buffer.
local util = require("dbgrid.util")

local M = {}

---Open (or reuse) a scratch buffer with lines and a ]c / [c jump list.
---@param name string
---@param lines string[]
---@param jumps? { lnum: integer }[]
---@param hl? { [1]: integer, [2]: integer, [3]: integer, [4]: string }[]  lnum(1-based), s, e, group
function M.open_scratch(name, lines, jumps, hl)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "dbgrid-diff"
  pcall(vim.api.nvim_buf_set_name, buf, "dbgrid://" .. name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("dbgrid.compare")
  for i, l in ipairs(lines) do
    local group = l:match("^%s*%+") and "DbgridDiffAdd"
      or l:match("^%s*%-") and "DbgridDiffDelete"
      or l:match("^%s*~") and "DbgridDiffChange"
      or nil
    if group then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, { end_col = #l, hl_group = group })
    end
  end
  for _, h in ipairs(hl or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h[1] - 1, h[2], { end_col = h[3], hl_group = h[4] })
  end
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = false
  vim.wo.number = false
  vim.wo.cursorline = true
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, desc = "dbgrid: " .. desc, silent = true, nowait = true })
  end
  map("q", function()
    pcall(vim.api.nvim_win_close, 0, true)
  end, "close")
  local lnums = {}
  for _, j in ipairs(jumps or {}) do
    lnums[#lnums + 1] = j.lnum
  end
  table.sort(lnums)
  map("]c", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    for _, l in ipairs(lnums) do
      if l > cur then
        return vim.api.nvim_win_set_cursor(0, { l, 0 })
      end
    end
  end, "next changed table")
  map("[c", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    for i = #lnums, 1, -1 do
      if lnums[i] < cur then
        return vim.api.nvim_win_set_cursor(0, { lnums[i], 0 })
      end
    end
  end, "previous changed table")
  return buf
end

---@param a dbgrid.Connection
---@param b dbgrid.Connection
---@param cb? fun(diff?: table, err?: string)
function M.schema(a, b, cb)
  local schema = require("dbgrid.schema")
  util.notify(string.format("comparing schemas of %s and %s…", a.name, b.name))
  schema.get(a, function(sa, ea)
    if not sa then
      util.error("schema of " .. a.name .. ": " .. tostring(ea))
      return cb and cb(nil, ea)
    end
    schema.get(b, function(sb, eb)
      if not sb then
        util.error("schema of " .. b.name .. ": " .. tostring(eb))
        return cb and cb(nil, eb)
      end
      local d = schema.diff(sa, sb, { a_name = a.name, b_name = b.name })
      M.open_scratch("schema-diff/" .. a.name .. "-" .. b.name, d.lines, d.tables)
      if cb then
        cb(d)
      end
    end, { force = true })
  end, { force = true })
end

---@param conn dbgrid.Connection
---@param cb fun(rows?: any[][], err?: string)
local function settings_rows(conn, cb)
  local connections = require("dbgrid.connections")
  local adapters = require("dbgrid.adapters")
  connections.resolve(conn, function(eff, err)
    if not eff then
      return cb(nil, err)
    end
    local adapter = adapters.for_connection(eff)
    adapter.run(
      eff,
      { { sql = require("dbgrid.schema").SETTINGS_SQL, kind = "select", class = "read", line = 1 } },
      {},
      function(res)
        if not res.ok then
          return cb(nil, res.error and res.error.message or "failed")
        end
        local set = res.statements[1] and res.statements[1].sets[1]
        cb(set and set.rows or {})
      end
    )
  end)
end

---@param a dbgrid.Connection
---@param b dbgrid.Connection
---@param cb? fun(diff?: table, err?: string)
function M.settings(a, b, cb)
  util.notify(string.format("comparing settings of %s and %s…", a.name, b.name))
  settings_rows(a, function(ra, ea)
    if not ra then
      util.error("settings of " .. a.name .. ": " .. tostring(ea))
      return cb and cb(nil, ea)
    end
    settings_rows(b, function(rb, eb)
      if not rb then
        util.error("settings of " .. b.name .. ": " .. tostring(eb))
        return cb and cb(nil, eb)
      end
      local d = require("dbgrid.schema").settings_diff(ra, rb, { a_name = a.name, b_name = b.name })
      M.open_scratch("settings-diff/" .. a.name .. "-" .. b.name, d.lines)
      if cb then
        cb(d)
      end
    end)
  end)
end

return M
