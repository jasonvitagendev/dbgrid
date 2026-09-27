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
  local any_aws = false
  for _, c in ipairs(conns) do
    local a, err = require("dbgrid.adapters").for_connection(c)
    if c.aws then
      any_aws = true
    end
    if not a then
      health.error(c.name .. ": " .. tostring(err))
    elseif c.aws and c.aws_role ~= "writer" then
      health.info(c.name .. ": reader entry of " .. tostring(c.parent))
    else
      local done, ok, msg = false, false, nil
      require("dbgrid.connections").test(c, function(good, m)
        done, ok, msg = true, good, m
      end)
      vim.wait(c.aws and 60000 or 8000, function()
        return done
      end, 50)
      if done and ok then
        health.ok(c.name .. " (" .. (c.source or "setup") .. "): reachable · " .. tostring(msg))
      elseif done then
        health.warn(c.name .. ": " .. vim.trim(tostring(msg)))
      else
        health.warn(c.name .. ": no answer within the timeout")
      end
    end
  end
  if any_aws then
    local ok_aws, aws = pcall(require, "dbgrid.aws")
    if ok_aws and aws.health then
      health.start("dbgrid: aws")
      aws.health({
        ok = health.ok,
        warn = health.warn,
        error = health.error,
        info = health.info,
      })
    end
  end
  local ok_tunnel, tunnel = pcall(require, "dbgrid.tunnel")
  if ok_tunnel and tunnel.list then
    for _, t in ipairs(tunnel.list()) do
      (t.ok and health.ok or health.warn)(
        string.format("tunnel %s: localhost:%d%s", t.key, t.port or 0, t.ok and "" or " (dead)")
      )
    end
  end
  local root = require("dbgrid.project").root()
  local dir, mode = require("dbgrid.project").store_dir(root)
  health.info("project " .. root .. "\nnotebooks in " .. dir .. " (" .. mode .. ")")
end

return M
