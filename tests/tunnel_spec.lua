local H = _G.H
local tunnel = require("dbgrid.tunnel")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local forwarder = root .. "/tests/fixtures/forwarder.py"

---Run tunnel.probe synchronously.
local function probe(port, timeout_ms, handshake)
  local result
  tunnel.probe(port, timeout_ms or 500, function(ok)
    result = ok
  end, handshake)
  H.truthy(
    H.wait(5000, function()
      return result ~= nil
    end),
    "probe never called back"
  )
  return result
end

---Run tunnel.ensure synchronously.
local function ensure(spec)
  local port, err, called
  tunnel.ensure(spec, function(p, e)
    port, err, called = p, e, true
  end)
  H.truthy(
    H.wait(20000, function()
      return called
    end),
    "ensure never called back"
  )
  return port, err
end

H.describe("tunnel ports", function()
  H.it("free_port returns an unprivileged port", function()
    local p = tunnel.free_port()
    H.truthy(type(p) == "number" and p > 1024, "got " .. tostring(p))
  end)

  H.it("stable_port is deterministic and in 15000..15999", function()
    local a = tunnel.stable_port("ssm|prod|i-0123|db.internal:5432")
    local b = tunnel.stable_port("ssm|prod|i-0123|db.internal:5432")
    H.eq(a, b)
    H.truthy(a >= 15000 and a <= 15999, "out of range: " .. a)
    H.truthy(tunnel.stable_port("other") ~= a or tunnel.stable_port("other2") ~= a)
  end)

  H.it("probe reports closed ports without blocking", function()
    local p = tunnel.free_port()
    H.eq(probe(p, 300), false)
  end)
end)

H.describe("tunnel argv", function()
  H.it("builds the ssm command", function()
    local argv = tunnel.argv({
      key = "k",
      kind = "ssm",
      profile = "prod",
      region = "ap-southeast-1",
      target = "i-0123",
      host = "db.internal",
      port = 5432,
      parameters = { foo = "bar" },
    }, 15432)
    H.eq(argv, {
      "aws",
      "ssm",
      "start-session",
      "--target",
      "i-0123",
      "--document-name",
      "AWS-StartPortForwardingSessionToRemoteHost",
      "--parameters",
      "host=db.internal,portNumber=5432,localPortNumber=15432,foo=bar",
      "--profile",
      "prod",
      "--region",
      "ap-southeast-1",
    })
  end)

  H.it("builds the ssh command", function()
    local argv = tunnel.argv({
      key = "k",
      kind = "ssh",
      host = "ec2-user@bastion",
      remote = "db.internal:5432",
      ssh_args = { "-i", "~/.ssh/id" },
    }, 15432)
    H.eq(argv, {
      "ssh",
      "-N",
      "-o",
      "ExitOnForwardFailure=yes",
      "-o",
      "BatchMode=yes",
      "-i",
      "~/.ssh/id",
      "-L",
      "15432:db.internal:5432",
      "ec2-user@bastion",
    })
  end)

  H.it("substitutes {port} in cmd tunnels", function()
    local argv = tunnel.argv({ key = "k", kind = "cmd", cmd = { "fwd", "--listen={port}", "{port}" } }, 1234)
    H.eq(argv, { "fwd", "--listen=1234", "1234" })
    H.eq(tunnel.argv({ key = "k", kind = "nope" }, 1), nil)
  end)

  H.it("describes a tunnel without secrets", function()
    local d = tunnel.describe({ key = "x", kind = "ssm", target = "i-0123", host = "db.internal", port = 5432 })
    H.matches(d, "^ssm i%-0123 → db%.internal:5432 via localhost:%d+$")
    H.matches(tunnel.describe({ key = "y", kind = "cmd", cmd = { "/usr/bin/socat", "secret" } }), "^cmd socat via")
  end)
end)

H.describe("tunnel lifecycle", function()
  local key = "test|listener"
  local spec = { key = key, kind = "cmd", cmd = { "python3", forwarder, "{port}" }, ready_ms = 10000 }

  H.it("ensure spawns a process and waits for the port", function()
    local port, err = ensure(spec)
    H.eq(err, nil)
    H.truthy(type(port) == "number", "no port")
    H.eq(probe(port), true)
    local list = tunnel.list()
    H.eq(#list, 1)
    H.eq(list[1].key, key)
    H.eq(list[1].kind, "cmd")
    H.eq(list[1].port, port)
    H.eq(list[1].ok, true)
    H.truthy(list[1].pid and list[1].pid > 0)
    H.truthy(list[1].started and list[1].started > 0)
    H.matches(tunnel.describe(spec), "via localhost:" .. port .. "$")
  end)

  H.it("ensure reuses the live tunnel", function()
    local before = tunnel.list()[1]
    local port, err = ensure(spec)
    H.eq(err, nil)
    H.eq(port, before.port)
    local after = tunnel.list()
    H.eq(#after, 1)
    H.eq(after[1].pid, before.pid)
  end)

  H.it("concurrent ensure calls share one process", function()
    local key2 = "test|concurrent"
    local spec2 = { key = key2, kind = "cmd", cmd = { "python3", forwarder, "{port}" }, ready_ms = 10000 }
    local ports = {}
    for _ = 1, 3 do
      tunnel.ensure(spec2, function(p, e)
        ports[#ports + 1] = p or ("err: " .. tostring(e))
      end)
    end
    H.truthy(H.wait(20000, function()
      return #ports == 3
    end))
    H.eq(ports[1], ports[2])
    H.eq(ports[2], ports[3])
    H.truthy(type(ports[1]) == "number", vim.inspect(ports))
    H.eq(#tunnel.list(), 2)
    H.truthy(tunnel.kill(key2))
  end)

  H.it("kill stops the process and closes the port", function()
    local port = tunnel.list()[1].port
    H.truthy(tunnel.kill(key))
    H.eq(tunnel.kill(key), false)
    H.eq(#tunnel.list(), 0)
    H.truthy(
      H.wait(5000, function()
        return probe(port, 200) == false
      end),
      "port still open after kill"
    )
  end)

  H.it("reports a process that exits before the port opens", function()
    local port, err = ensure({
      key = "test|exit",
      kind = "cmd",
      cmd = { "python3", "-c", "import sys; sys.stderr.write('boom\\n'); sys.exit(3)" },
      ready_ms = 5000,
    })
    H.eq(port, nil)
    H.matches(err, "cmd tunnel exited with code 3")
    H.matches(err, "boom")
    local list = tunnel.list()
    H.eq(#list, 1)
    H.eq(list[1].ok, false)
    tunnel.kill("test|exit")
  end)

  H.it("reports a process that never opens the port", function()
    local port, err = ensure({
      key = "test|sleep",
      kind = "cmd",
      cmd = { "python3", "-c", "import time; time.sleep(30)" },
      ready_ms = 700,
    })
    H.eq(port, nil)
    H.matches(err, "did not open localhost:%d+ within 700 ms")
    H.truthy(
      H.wait(5000, function()
        return tunnel.list()[1] == nil or tunnel.list()[1].ok == false
      end),
      "process not terminated after timeout"
    )
    tunnel.kill("test|sleep")
  end)

  H.it("handshake probe needs a reply from behind the port", function()
    local live = { key = "test|answer", kind = "cmd", cmd = { "python3", forwarder, "{port}", "--answer" } }
    local port, err = ensure(vim.tbl_extend("force", live, { handshake = "postgres", ready_ms = 10000 }))
    H.eq(err, nil)
    H.eq(probe(port, 2000, "postgres"), true)
    -- a listener that swallows the request looks fine to a plain connect only
    local stale = { key = "test|stale", kind = "cmd", cmd = { "python3", forwarder, "{port}", "--stale" } }
    local sport = ensure(stale)
    H.eq(probe(sport, 500), true)
    H.eq(probe(sport, 500, "postgres"), false)
    -- and so does one that hangs up (the plain listener closes every connection)
    local closing = ensure({ key = "test|closing", kind = "cmd", cmd = { "python3", forwarder, "{port}" } })
    H.eq(probe(closing, 500, "postgres"), false)
    tunnel.kill_all()
  end)

  H.it("check probes a known tunnel with its handshake and replaces a stale one", function()
    local checked
    tunnel.check("test|unknown", function(ok)
      checked = ok
    end)
    H.truthy(H.wait(2000, function()
      return checked ~= nil
    end))
    H.eq(checked, false)
    -- a stale forwarder with a handshake never becomes ready: ensure gives up and terminates it
    local port, err = ensure({
      key = "test|stale-hs",
      kind = "cmd",
      cmd = { "python3", forwarder, "{port}", "--stale" },
      handshake = "postgres",
      ready_ms = 1500,
    })
    H.eq(port, nil)
    H.matches(err, "did not open localhost:%d+ within 1500 ms")
    tunnel.kill_all()
    -- a live one passes check
    port, err = ensure({
      key = "test|live-hs",
      kind = "cmd",
      cmd = { "python3", forwarder, "{port}", "--answer" },
      handshake = "postgres",
      ready_ms = 10000,
    })
    H.eq(err, nil)
    checked = nil
    tunnel.check("test|live-hs", function(ok)
      checked = ok
    end)
    H.truthy(H.wait(5000, function()
      return checked ~= nil
    end))
    H.eq(checked, true)
    tunnel.kill_all()
  end)

  H.it("respects a fixed local_port", function()
    local fixed = tunnel.free_port()
    local port, err = ensure({
      key = "test|fixed",
      kind = "cmd",
      cmd = { "python3", forwarder, "{port}" },
      local_port = fixed,
    })
    H.eq(err, nil)
    H.eq(port, fixed)
    tunnel.kill_all()
    H.eq(#tunnel.list(), 0)
  end)
end)

local url = os.getenv("DBGRID_TEST_URL")
if not url then
  io.write("  skip tunnel integration (DBGRID_TEST_URL not set)\n")
  return
end

H.describe("tunnel integration", function()
  H.it("forwards psql through the tunnel", function()
    local db_port = url:match("@[^/:]+:(%d+)") or "5432"
    local port, err = ensure({
      key = "test|db",
      kind = "cmd",
      cmd = { "python3", forwarder, "{port}", db_port },
      ready_ms = 10000,
    })
    H.eq(err, nil)
    local pg = require("dbgrid.adapters.postgres")
    local result
    pg.run(
      { name = "t", url = "postgres://postgres@127.0.0.1:" .. port .. "/dbgrid_test" },
      { { sql = "select 1", kind = "select", class = "read", line = 1 } },
      {},
      function(r)
        result = r
      end
    )
    H.truthy(H.wait(15000, function()
      return result ~= nil
    end))
    H.eq(result.ok, true, vim.inspect(result.error))
    H.eq(result.statements[1].sets[1].rows, { { "1" } })
    tunnel.kill_all()
  end)
end)
