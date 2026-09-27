-- Local port-forward tunnels (SSM, ssh, or any command) kept alive for the
-- Neovim session. A tunnel is identified by a key the caller builds from the
-- connection; `ensure` reuses a live one, spawns it otherwise, and waits until
-- the local port accepts connections before calling back.
local util = require("dbgrid.util")
local config = require("dbgrid.config")

local uv = vim.uv or vim.loop

local M = {}

---@class dbgrid.TunnelSpec
---@field key string            unique id of the tunnel (callers build it from connection fields)
---@field kind "ssm"|"ssh"|"cmd"
---@field local_port? integer   fixed local port; nil = stable_port(key) if free, else a free port
---@field ready_ms? integer     how long to wait for the port after spawn (default aws.tunnel_ready_ms or 15000)
---@field handshake? "postgres"  protocol spoken at the far end: probes wait for the server's reply, not just the TCP accept
---@field env? table<string,string>
---@field profile? string       ssm
---@field region? string        ssm
---@field target? string        ssm: bastion instance id
---@field host? string          ssm: remote endpoint
---@field port? integer         ssm: remote port
---@field document? string      ssm: session document (default AWS-StartPortForwardingSessionToRemoteHost)
---@field parameters? table<string,string> ssm: extra document parameters
---@field cli? string           ssm: aws executable (default "aws")
---@field remote? string        ssh: "host:port"
---@field ssh_args? string[]    ssh: extra arguments
---@field cmd? string[]         cmd: argv, every "{port}" replaced by the local port

---@class dbgrid.Tunnel
---@field spec dbgrid.TunnelSpec
---@field job? vim.SystemObj
---@field port integer
---@field pid? integer
---@field started integer       epoch seconds
---@field stderr string[]       last lines of stderr
---@field starting? fun(port?: integer, err?: string)[]  callbacks waiting for readiness
---@field exited? boolean
---@field code? integer

local STDERR_LINES = 20
local POLL_MS = 200

-- First packet of a probe per protocol. A forwarder whose session has died
-- (SSM idle timeout) still accepts TCP connections but never answers, so a
-- plain connect cannot tell it from a live tunnel; a reply from the server can.
-- postgres: an 8-byte GSSENCRequest (protocol 1234.5680). Every server answers
-- one byte ('N', or 'G' with GSSAPI) and, unlike an abandoned SSLRequest,
-- logs nothing when the client hangs up after 'N'.
local HANDSHAKE = { postgres = string.char(0, 0, 0, 8, 4, 210, 22, 48) }

---@type table<string, dbgrid.Tunnel>
local tunnels = {}

local function aws_cfg()
  return config.get().aws or {}
end

---Hand a result to every callback that waited for the tunnel, on the main loop.
---@param t dbgrid.Tunnel
---@param port? integer
---@param err? string
local function settle(t, port, err)
  local cbs = t.starting
  t.starting = nil
  if not cbs then
    return
  end
  vim.schedule(function()
    for _, cb in ipairs(cbs) do
      cb(port, err)
    end
  end)
end

---@param t dbgrid.Tunnel
---@param data string
local function push_stderr(t, data)
  for _, line in ipairs(util.lines(data)) do
    if line ~= "" then
      t.stderr[#t.stderr + 1] = line
    end
  end
  while #t.stderr > STDERR_LINES do
    table.remove(t.stderr, 1)
  end
end

---@param t dbgrid.Tunnel
---@param n? integer
local function last_stderr(t, n)
  local lines = {}
  for i = math.max(1, #t.stderr - (n or 5) + 1), #t.stderr do
    lines[#lines + 1] = t.stderr[i]
  end
  return table.concat(lines, " | ")
end

---@param t dbgrid.Tunnel
local function running(t)
  return t.job ~= nil and not t.exited
end

---Send SIGTERM to the tunnel's process group (the aws CLI runs
---session-manager-plugin as a child), falling back to the process itself.
---@param t dbgrid.Tunnel
local function terminate(t)
  if not running(t) then
    return
  end
  local ok = t.pid and pcall(uv.kill, -t.pid, 15)
  if not ok then
    pcall(t.job.kill, t.job, 15)
  end
end

---Is anything listening on 127.0.0.1:port? A bind that fails means yes (or the port is otherwise unusable).
---@param port integer
---@return boolean
local function port_free(port)
  local sock = uv.new_tcp()
  if not sock then
    return false
  end
  local ok, res = pcall(sock.bind, sock, "127.0.0.1", port) -- bind returns nil, err instead of throwing
  sock:close()
  return ok and res ~= nil
end

---Deterministic port for a key, in 15000..15999.
---@param key string
---@return integer
function M.stable_port(key)
  return 15000 + (tonumber(util.hash(key):sub(1, 4), 16) % 1000)
end

---An unused local port (bind port 0, read it back, close).
---@return integer
function M.free_port()
  local sock = assert(uv.new_tcp())
  assert(sock:bind("127.0.0.1", 0))
  local name = sock:getsockname()
  sock:close()
  return name.port
end

---TCP connect to 127.0.0.1:port; never blocks. cb(true) when the connection is
---accepted, or, with a handshake, when the server behind the port answers it.
---@param port integer
---@param timeout_ms integer
---@param cb fun(ok: boolean)
---@param handshake? "postgres"
function M.probe(port, timeout_ms, cb, handshake)
  local sock = uv.new_tcp()
  local timer = uv.new_timer()
  local done = false
  local function finish(ok)
    if done then
      return
    end
    done = true
    if timer then
      timer:stop()
      timer:close()
    end
    if sock and not sock:is_closing() then
      sock:close()
    end
    vim.schedule(function()
      cb(ok)
    end)
  end
  if not sock or not timer then
    return finish(false)
  end
  local payload = handshake and HANDSHAKE[handshake]
  timer:start(timeout_ms, 0, function()
    finish(false)
  end)
  local ok, req = pcall(sock.connect, sock, "127.0.0.1", port, function(cerr)
    if cerr or not payload then
      return finish(cerr == nil)
    end
    sock:read_start(function(rerr, data)
      finish(rerr == nil and data ~= nil) -- EOF or an error: nothing answers behind the port
    end)
    sock:write(payload, function(werr)
      if werr then
        finish(false)
      end
    end)
  end)
  if not ok or req == nil then
    -- connect failed synchronously (bad port, no socket): no callback will come
    finish(false)
  end
end

---Probe timeout for a tunnel: a handshake crosses the tunnel and back, a plain connect stays local.
---@param handshake? string
---@return integer
local function probe_timeout(handshake)
  local cfg = aws_cfg()
  if handshake then
    return cfg.handshake_ms or 3000
  end
  return cfg.probe_ms or 500
end

---@param t dbgrid.Tunnel
---@param cb fun(ok: boolean)
local function probe_tunnel(t, cb)
  M.probe(t.port, probe_timeout(t.spec.handshake), cb, t.spec.handshake)
end

---Does the tunnel with this key still forward? cb(false) for an unknown, dead or still-starting one.
---@param key string
---@param cb fun(ok: boolean)
function M.check(key, cb)
  local t = tunnels[key]
  if not t or not running(t) or t.starting then
    return vim.schedule(function()
      cb(false)
    end)
  end
  probe_tunnel(t, cb)
end

---Command line for a spec on a given local port.
---@param spec dbgrid.TunnelSpec
---@param port integer
---@return string[]? argv, string? err
function M.argv(spec, port)
  if spec.kind == "ssm" then
    if not spec.target or not spec.host or not spec.port then
      return nil, "ssm tunnel needs target, host and port"
    end
    local params = { "host=" .. spec.host, "portNumber=" .. spec.port, "localPortNumber=" .. port }
    local extra = vim.tbl_keys(spec.parameters or {})
    table.sort(extra)
    for _, k in ipairs(extra) do
      params[#params + 1] = k .. "=" .. tostring(spec.parameters[k])
    end
    local argv = {
      spec.cli or aws_cfg().cli or "aws",
      "ssm",
      "start-session",
      "--target",
      spec.target,
      "--document-name",
      spec.document or "AWS-StartPortForwardingSessionToRemoteHost",
      "--parameters",
      table.concat(params, ","),
    }
    if spec.profile then
      vim.list_extend(argv, { "--profile", spec.profile })
    end
    if spec.region then
      vim.list_extend(argv, { "--region", spec.region })
    end
    return argv
  elseif spec.kind == "ssh" then
    if not spec.host or not spec.remote then
      return nil, "ssh tunnel needs host and remote"
    end
    local argv = { "ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes" }
    vim.list_extend(argv, spec.ssh_args or {})
    vim.list_extend(argv, { "-L", port .. ":" .. spec.remote, spec.host })
    return argv
  elseif spec.kind == "cmd" then
    if type(spec.cmd) ~= "table" or #spec.cmd == 0 then
      return nil, "cmd tunnel needs a cmd table"
    end
    local argv = {}
    for i, a in ipairs(spec.cmd) do
      argv[i] = (tostring(a):gsub("{port}", tostring(port)))
    end
    return argv
  end
  return nil, "unknown tunnel kind " .. tostring(spec.kind)
end

---Spawn the tunnel process and poll the port until it answers, the process dies, or ready_ms passes.
---@param spec dbgrid.TunnelSpec
---@param cbs fun(port?: integer, err?: string)[]
local function start(spec, cbs)
  local port = spec.local_port
  if not port then
    port = M.stable_port(spec.key)
    if not port_free(port) then
      port = M.free_port()
    end
  end
  ---@type dbgrid.Tunnel
  local t = { spec = spec, port = port, started = util.epoch(), stderr = {}, starting = cbs }
  local argv, aerr = M.argv(spec, port)
  if not argv then
    return settle(t, nil, aerr)
  end
  tunnels[spec.key] = t
  local ok, job = pcall(vim.system, argv, {
    env = spec.env,
    detach = true, -- own process group, so kill() can take the whole session down
    stdout = function() end,
    stderr = function(_, data)
      if data then
        push_stderr(t, data)
      end
    end,
  }, function(out)
    t.exited = true
    t.code = out.code
    if t.starting then
      settle(t, nil, string.format("%s tunnel exited with code %d: %s", spec.kind, out.code, last_stderr(t)))
    end
  end)
  if not ok then
    tunnels[spec.key] = nil
    return settle(t, nil, spec.kind .. " tunnel could not be started: " .. tostring(job))
  end
  t.job = job
  t.pid = job.pid
  local ready_ms = spec.ready_ms or aws_cfg().tunnel_ready_ms or 15000
  local deadline = util.now() + ready_ms / 1000
  local function poll()
    if not t.starting then
      return -- exited (settled by on_exit) or killed
    end
    probe_tunnel(t, function(open)
      if not t.starting then
        return
      end
      if open then
        return settle(t, port)
      end
      if t.exited then
        return -- on_exit settles with the exit code
      end
      if util.now() > deadline then
        local msg = string.format("%s tunnel did not open localhost:%d within %d ms", spec.kind, port, ready_ms)
        settle(t, nil, msg .. ": " .. last_stderr(t))
        terminate(t)
        return
      end
      vim.defer_fn(poll, POLL_MS)
    end)
  end
  vim.defer_fn(poll, POLL_MS)
end

---Get a working tunnel for the spec: reuse the live one with the same key when its port answers,
---otherwise (re)spawn and wait for readiness. Concurrent calls for one key share the result.
---@param spec dbgrid.TunnelSpec
---@param cb fun(port?: integer, err?: string)
function M.ensure(spec, cb)
  local t = tunnels[spec.key]
  if t and t.starting then
    t.starting[#t.starting + 1] = cb
    return
  end
  if t and running(t) then
    t.starting = { cb }
    probe_tunnel(t, function(open)
      if open then
        return settle(t, t.port)
      end
      -- the process is alive but nothing answers: replace it
      local cbs = t.starting
      t.starting = nil
      terminate(t)
      tunnels[spec.key] = nil
      start(spec, cbs)
    end)
    return
  end
  tunnels[spec.key] = nil
  start(spec, { cb })
end

---@return { key: string, kind: string, port: integer, pid?: integer, started: integer, ok: boolean }[]
function M.list()
  local out = {}
  for key, t in pairs(tunnels) do
    out[#out + 1] = { key = key, kind = t.spec.kind, port = t.port, pid = t.pid, started = t.started, ok = running(t) }
  end
  table.sort(out, function(a, b)
    return a.key < b.key
  end)
  return out
end

---Stop a tunnel and forget it.
---@param key string
---@return boolean existed
function M.kill(key)
  local t = tunnels[key]
  if not t then
    return false
  end
  tunnels[key] = nil
  terminate(t)
  if t.starting then
    settle(t, nil, t.spec.kind .. " tunnel was stopped")
  end
  return true
end

function M.kill_all()
  for key in pairs(tunnels) do
    M.kill(key)
  end
end

---One line for pickers and messages; carries no secrets.
---@param spec dbgrid.TunnelSpec
---@return string
function M.describe(spec)
  local t = tunnels[spec.key]
  local port = (t and t.port) or spec.local_port or M.stable_port(spec.key)
  local via = " via localhost:" .. port
  if spec.kind == "ssm" then
    return "ssm " .. tostring(spec.target) .. " → " .. tostring(spec.host) .. ":" .. tostring(spec.port) .. via
  elseif spec.kind == "ssh" then
    return "ssh " .. tostring(spec.host) .. " → " .. tostring(spec.remote) .. via
  end
  local exe = type(spec.cmd) == "table" and spec.cmd[1] or "?"
  return "cmd " .. vim.fs.basename(tostring(exe)) .. via
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("DbgridTunnel", { clear = true }),
  callback = M.kill_all,
})

return M
