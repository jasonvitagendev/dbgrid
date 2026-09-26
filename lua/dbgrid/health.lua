local M = {}

function M.check()
  local health = vim.health
  health.start("dbgrid")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end
  local cfg = require("dbgrid.config").get()
  if vim.fn.executable("psql") == 1 then
    local v = vim.fn.system({ "psql", "--version" })
    health.ok("psql: " .. vim.trim(v))
  else
    health.error("psql is not on PATH (brew install libpq && brew link --force libpq)")
  end
  for name, agent in pairs(cfg.ai.agents) do
    if vim.fn.executable(agent.cmd[1]) == 1 then
      health.ok("agent " .. name .. ": " .. agent.cmd[1] .. (cfg.ai.agent == name and " (default)" or ""))
    else
      (cfg.ai.agent == name and health.warn or health.info)("agent " .. name .. ": '" .. agent.cmd[1] .. "' not found")
    end
  end
  local conns = require("dbgrid.connections").all()
  if #conns == 0 then
    health.warn(
      "no connections: add one in setup({ connections = ... }), in .env (DATABASE_URL) or with :Dbgrid connections"
    )
  end
  for _, c in ipairs(conns) do
    local a, err = require("dbgrid.adapters").for_connection(c)
    if not a then
      health.error(c.name .. ": " .. tostring(err))
    else
      local ok_sys, res = pcall(function()
        return vim
          .system({ a.executable, c.url, "-X", "-A", "-t", "-c", "select 1" }, {
            env = { PGCONNECT_TIMEOUT = "3" },
            text = true,
            timeout = 5000,
          })
          :wait()
      end)
      if ok_sys and res.code == 0 then
        health.ok(c.name .. " (" .. (c.source or "setup") .. "): reachable")
      else
        health.warn(c.name .. ": " .. vim.trim(ok_sys and (res.stderr or "") or tostring(res)))
      end
    end
  end
  local root = require("dbgrid.project").root()
  local dir, mode = require("dbgrid.project").store_dir(root)
  health.info("project " .. root .. "\nnotebooks in " .. dir .. " (" .. mode .. ")")
end

return M
