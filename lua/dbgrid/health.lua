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
  local adapters = require("dbgrid.adapters")
  for _, name in ipairs(adapters.names()) do
    local a = adapters.get(name)
    if a then
      if vim.fn.executable(a.executable) == 1 then
        local v = vim.fn.system({ a.executable, "--version" })
        health.ok(string.format("%s adapter: %s (%s)", name, a.executable, vim.trim(v):gsub("\n.*", "")))
      else
        health.warn(
          string.format("%s adapter: '%s' is not on PATH", name, a.executable)
            .. (name == "postgres" and " (brew install libpq && brew link --force libpq)" or "")
        )
      end
    end
  end
  for name, agent in pairs(cfg.ai.agents) do
    if vim.fn.executable(agent.cmd[1]) == 1 then
      health.ok("agent " .. name .. ": " .. agent.cmd[1] .. (cfg.ai.agent == name and " (default)" or ""))
    else
      (cfg.ai.agent == name and health.warn or health.info)("agent " .. name .. ": '" .. agent.cmd[1] .. "' not found")
    end
  end
  local fmt = require("dbgrid.format").resolve("postgres")
  health.info("formatter: " .. fmt.name .. (cfg.format.on_save and " (on save)" or " (manual)"))
  local conns = require("dbgrid.connections").all()
  if #conns == 0 then
    health.warn(
      "no connections: add one in setup({ connections = ... }), in .env (DATABASE_URL), in config/database.yml or with :Dbgrid connections"
    )
  end
  local any_aws = false
  for _, c in ipairs(conns) do
    local a, err = adapters.for_connection(c)
    if c.aws then
      any_aws = true
    end
    if not a then
      health.error(c.name .. ": " .. tostring(err))
    elseif vim.fn.executable(a.executable) ~= 1 then
      health.warn(c.name .. ": needs '" .. a.executable .. "' on PATH")
    elseif c.aws and c.aws_role ~= "writer" then
      health.info(c.name .. ": reader entry of " .. tostring(c.parent))
    else
      -- through connections.test so tunnels, aws blocks and password_cmd are resolved
      local ok, msg
      local started = pcall(require("dbgrid.connections").test, c, function(o, m)
        ok, msg = o, m
      end)
      if started then
        vim.wait(c.aws and 60000 or 8000, function()
          return ok ~= nil
        end, 50)
      end
      if ok then
        health.ok(c.name .. " (" .. (c.source or "setup") .. "): " .. tostring(msg))
      else
        health.warn(c.name .. ": " .. tostring(msg or "no answer"))
      end
    end
  end
  if any_aws then
    local ok_aws, aws = pcall(require, "dbgrid.aws")
    if ok_aws and aws.health then
      health.start("dbgrid: aws")
      aws.health({ ok = health.ok, warn = health.warn, error = health.error, info = health.info })
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
  local project = require("dbgrid.project")
  local root = project.root()
  local dir, mode = project.store_dir(root)
  local fw = project.framework(root)
  health.info(
    "project " .. root .. (fw and (" (" .. fw .. ")") or "") .. "\nnotebooks in " .. dir .. " (" .. mode .. ")"
  )
end

return M
