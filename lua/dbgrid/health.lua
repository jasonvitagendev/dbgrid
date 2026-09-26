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
  for _, c in ipairs(conns) do
    local a, err = adapters.for_connection(c)
    if not a then
      health.error(c.name .. ": " .. tostring(err))
    elseif vim.fn.executable(a.executable) ~= 1 then
      health.warn(c.name .. ": needs '" .. a.executable .. "' on PATH")
    else
      local ok, msg
      local started = pcall(a.test, c, function(o, m)
        ok, msg = o, m
      end)
      if started then
        vim.wait(8000, function()
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
  local project = require("dbgrid.project")
  local root = project.root()
  local dir, mode = project.store_dir(root)
  local fw = project.framework(root)
  health.info(
    "project " .. root .. (fw and (" (" .. fw .. ")") or "") .. "\nnotebooks in " .. dir .. " (" .. mode .. ")"
  )
end

return M
