-- AWS RDS / Aurora support built on the `aws` CLI (v2): endpoint discovery,
-- credentials from Secrets Manager or IAM auth tokens, an SSM port-forward
-- through a bastion (see tunnel.lua) and a few read-only views (status,
-- events, blue/green deployments). Every CLI call is asynchronous.
local util = require("dbgrid.util")
local config = require("dbgrid.config")
local project = require("dbgrid.project")

local M = {}

---@class dbgrid.AwsConfig               the `aws` block of a connection
---@field profile? string
---@field region? string
---@field cluster? string                Aurora cluster identifier (or `instance`)
---@field instance? string               RDS instance identifier
---@field bastion? string                SSM target instance id; nil = connect directly
---@field secret? string                 Secrets Manager id/ARN (default: the RDS managed master secret)
---@field auth? "secret"|"iam"
---@field user? string                   database user for iam auth
---@field database? string               database name (default: from the secret)
---@field document? string               SSM document for the port forward
---@field parameters? table<string,string>
---@field login_cmd? string|string[]     overrides config.aws.login_cmd
---@field cli? string                    overrides config.aws.cli

---@class dbgrid.AwsEndpoint
---@field host string
---@field port integer

---@class dbgrid.AwsCreds
---@field username string
---@field password? string
---@field dbname string
---@field token_expires? integer         epoch seconds (iam auth)

local DEFAULT_LOGIN = { "aws", "sso", "login", "--profile", "{profile}" }
local IAM_TOKEN_TTL = 14 * 60
local CLI_TIMEOUT_MS = 60000

local EXPIRED_MARKERS = {
  "expiredtoken",
  "expiredtokenexception",
  "token has expired",
  "the sso session associated with this profile has expired",
  "sso login",
  "unable to locate credentials",
  "invalidclienttokenid",
  "the security token included in the request is expired",
  "error loading sso token",
}

local function cfg()
  return config.get().aws or {}
end

---vim.json.decode turns JSON null into vim.NIL; treat it as nil.
local function nz(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---@param json string|table
---@return table? data, string? err
local function decode(json)
  if type(json) == "table" then
    return json
  end
  if type(json) ~= "string" then
    return nil, "expected JSON text from the aws CLI"
  end
  local ok, data = pcall(vim.json.decode, json)
  if not ok or type(data) ~= "table" then
    return nil, "the aws CLI did not return JSON: " .. util.trim(json):sub(1, 200)
  end
  return data
end

---@param aws_cfg dbgrid.AwsConfig
local function profile_of(aws_cfg)
  return aws_cfg.profile or "default"
end

---@param aws_cfg dbgrid.AwsConfig
local function id_of(aws_cfg)
  return aws_cfg.cluster or aws_cfg.instance
end

---Key of the endpoint / credential caches.
---@param aws_cfg dbgrid.AwsConfig
local function cache_key(aws_cfg)
  return (aws_cfg.profile or "") .. "|" .. (aws_cfg.region or "") .. "|" .. (id_of(aws_cfg) or "")
end

---@param s any
local function trim_str(s)
  return util.trim(tostring(s or ""))
end

local function iso_utc(t)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t) --[[@as string]]
end

-- Parsers ---------------------------------------------------------------------

---@param json string|table   `aws rds describe-db-clusters` output
---@return table? info, string? err
function M.parse_cluster(json)
  local data, err = decode(json)
  if not data then
    return nil, err
  end
  local c = nz(data.DBClusters) and data.DBClusters[1] or (data.DBClusterIdentifier and data) or nil
  if not c then
    return nil, "describe-db-clusters returned no cluster"
  end
  local port = tonumber(nz(c.Port)) or 5432
  local info = {
    kind = "cluster",
    id = nz(c.DBClusterIdentifier),
    arn = nz(c.DBClusterArn),
    status = nz(c.Status),
    engine = nz(c.Engine),
    engine_version = nz(c.EngineVersion),
    writer = { host = nz(c.Endpoint), port = port },
    reader = nz(c.ReaderEndpoint) and { host = c.ReaderEndpoint, port = port } or nil,
    members = {},
    secret_arn = nz(c.MasterUserSecret) and nz(c.MasterUserSecret.SecretArn) or nil,
  }
  for _, m in ipairs(nz(c.DBClusterMembers) or {}) do
    info.members[#info.members + 1] = { id = nz(m.DBInstanceIdentifier), writer = nz(m.IsClusterWriter) == true }
  end
  return info
end

---@param json string|table   `aws rds describe-db-instances` output
---@return table? info, string? err
function M.parse_instance(json)
  local data, err = decode(json)
  if not data then
    return nil, err
  end
  local i = nz(data.DBInstances) and data.DBInstances[1] or (data.DBInstanceIdentifier and data) or nil
  if not i then
    return nil, "describe-db-instances returned no instance"
  end
  local ep = nz(i.Endpoint) or {}
  local info = {
    kind = "instance",
    id = nz(i.DBInstanceIdentifier),
    arn = nz(i.DBInstanceArn),
    cluster = nz(i.DBClusterIdentifier),
    status = nz(i.DBInstanceStatus),
    engine = nz(i.Engine),
    engine_version = nz(i.EngineVersion),
    writer = { host = nz(ep.Address), port = tonumber(nz(ep.Port)) or 5432 },
    replicas = {},
    source = nz(i.ReadReplicaSourceDBInstanceIdentifier),
    secret_arn = nz(i.MasterUserSecret) and nz(i.MasterUserSecret.SecretArn) or nil,
  }
  for _, r in ipairs(nz(i.ReadReplicaDBInstanceIdentifiers) or {}) do
    info.replicas[#info.replicas + 1] = r
  end
  local pending = nz(i.PendingModifiedValues)
  if type(pending) == "table" and not vim.tbl_isempty(pending) then
    local keys = vim.tbl_keys(pending)
    table.sort(keys)
    info.pending_maintenance = "pending changes: " .. table.concat(keys, ", ")
  end
  return info
end

---@param json string|table   `aws secretsmanager get-secret-value` output
---@return table? secret, string? err
function M.parse_secret(json)
  local data, err = decode(json)
  if not data then
    return nil, err
  end
  local text = nz(data.SecretString)
  if type(text) ~= "string" then
    return nil, "the secret has no SecretString (binary secrets are not supported)"
  end
  local ok, s = pcall(vim.json.decode, text)
  if not ok or type(s) ~= "table" then
    return nil, "the secret value is not a JSON object with username/password"
  end
  if not nz(s.username) or not nz(s.password) then
    return nil, "the secret has no username/password fields"
  end
  return {
    username = tostring(s.username),
    password = tostring(s.password),
    host = nz(s.host),
    port = tonumber(nz(s.port)),
    dbname = nz(s.dbname),
    engine = nz(s.engine),
  }
end

---@param json string|table   `aws rds describe-events` output
---@return table? rows {date, source, message}[] newest first, string? err
function M.parse_events(json)
  local data, err = decode(json)
  if not data then
    return nil, err
  end
  local events = {}
  for _, e in ipairs(nz(data.Events) or {}) do
    events[#events + 1] = e
  end
  table.sort(events, function(a, b)
    return tostring(nz(a.Date) or "") > tostring(nz(b.Date) or "")
  end)
  local rows = {}
  for _, e in ipairs(events) do
    rows[#rows + 1] = {
      tostring(nz(e.Date) or ""),
      tostring(nz(e.SourceIdentifier) or ""),
      tostring(nz(e.Message) or ""),
    }
  end
  return rows
end

---Human readable metric value, by metric name.
---@param name string
---@param v number
---@return string
local function fmt_metric(name, v)
  if name:find("Memory") or name:find("Storage") or name:find("Bytes") then
    if v >= 1024 ^ 3 then
      return string.format("%.2f GiB", v / 1024 ^ 3)
    elseif v >= 1024 ^ 2 then
      return string.format("%.1f MiB", v / 1024 ^ 2)
    end
    return string.format("%d B", v)
  elseif name == "CPUUtilization" then
    return string.format("%.1f %%", v)
  elseif name == "AuroraReplicaLag" then
    return string.format("%.0f ms", v)
  elseif name == "ReplicaLag" then
    return string.format("%.0f s", v)
  elseif v == math.floor(v) then
    return string.format("%d", v)
  end
  return string.format("%.2f", v)
end

---@param json string|table   `aws cloudwatch get-metric-data` output (Values newest first)
---@return table? rows {metric, last, min, max}[], string? err
function M.parse_metrics(json)
  local data, err = decode(json)
  if not data then
    return nil, err
  end
  local rows = {}
  for _, r in ipairs(nz(data.MetricDataResults) or {}) do
    local name = tostring(nz(r.Label) or nz(r.Id) or "?")
    local values = nz(r.Values) or {}
    if #values == 0 then
      rows[#rows + 1] = { name, "n/a", "", "" }
    else
      local last, lo, hi = values[1], values[1], values[1]
      for _, v in ipairs(values) do
        lo = math.min(lo, v)
        hi = math.max(hi, v)
      end
      rows[#rows + 1] = { name, fmt_metric(name, last), fmt_metric(name, lo), fmt_metric(name, hi) }
    end
  end
  return rows
end

---@param json string|table   `aws rds describe-blue-green-deployments` output
---@return table? rows {deployment, status, source, target, member_status}[], string? err
function M.parse_bluegreen(json)
  local data, err = decode(json)
  if not data then
    return nil, err
  end
  local rows = {}
  for _, d in ipairs(nz(data.BlueGreenDeployments) or {}) do
    local name = tostring(nz(d.BlueGreenDeploymentName) or nz(d.BlueGreenDeploymentIdentifier) or "?")
    local status = tostring(nz(d.Status) or "")
    local details = nz(d.SwitchoverDetails) or {}
    if #details == 0 then
      rows[#rows + 1] = { name, status, tostring(nz(d.Source) or ""), tostring(nz(d.Target) or ""), "" }
    end
    for _, s in ipairs(details) do
      rows[#rows + 1] = {
        name,
        status,
        tostring(nz(s.SourceMember) or ""),
        tostring(nz(s.TargetMember) or ""),
        tostring(nz(s.Status) or ""),
      }
    end
  end
  return rows
end

---@param json string|table   `aws rds describe-pending-maintenance-actions` output
---@return string? summary  nil when nothing is pending
function M.parse_pending_maintenance(json)
  local data = decode(json)
  if not data then
    return nil
  end
  local parts = {}
  for _, r in ipairs(nz(data.PendingMaintenanceActions) or {}) do
    for _, a in ipairs(nz(r.PendingMaintenanceActionDetails) or {}) do
      local when = nz(a.CurrentApplyDate) or nz(a.AutoAppliedAfterDate)
      parts[#parts + 1] = tostring(nz(a.Action) or "?") .. (when and (" by " .. tostring(when)) or "")
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "; ")
end

---Does this stderr mean the credentials must be refreshed?
---@param stderr? string
---@return boolean
function M.is_expired(stderr)
  if type(stderr) ~= "string" or stderr == "" then
    return false
  end
  local s = stderr:lower()
  for _, marker in ipairs(EXPIRED_MARKERS) do
    if s:find(marker, 1, true) then
      return true
    end
  end
  return false
end

---Command that refreshes credentials for the profile.
---@param aws_cfg dbgrid.AwsConfig
---@param global_cfg? table   config.aws (default: the live config)
---@return string[]
function M.login_argv(aws_cfg, global_cfg)
  aws_cfg = aws_cfg or {}
  local raw = aws_cfg.login_cmd or (global_cfg or cfg()).login_cmd or DEFAULT_LOGIN
  if type(raw) == "string" then
    raw = vim.split(raw, "%s+", { trimempty = true })
  end
  local argv = {}
  for i, a in ipairs(raw) do
    argv[i] = (tostring(a):gsub("{profile}", profile_of(aws_cfg)))
  end
  return argv
end

---URL psql connects with. With a local port the URL keeps the real host (for
---SSL verification and ~/.pgpass) but connects to the tunnel via hostaddr/port.
---User, database and certificate path are percent-encoded (rfc2396: also "@", ":" and "/").
---@param creds dbgrid.AwsCreds
---@param endpoint dbgrid.AwsEndpoint
---@param local_port? integer   nil = connect directly
---@param opts? { ssl?: string, sslrootcert?: string }
---@return string
function M.effective_url(creds, endpoint, local_port, opts)
  opts = opts or {}
  local params = {}
  if local_port then
    params[#params + 1] = "hostaddr=127.0.0.1"
    params[#params + 1] = "port=" .. tostring(local_port)
  end
  params[#params + 1] = "sslmode=" .. (opts.ssl or cfg().ssl or "require")
  if opts.sslrootcert then
    params[#params + 1] = "sslrootcert=" .. vim.uri_encode(opts.sslrootcert, "rfc2396")
  end
  return "postgres://"
    .. vim.uri_encode(creds.username or "", "rfc2396")
    .. "@"
    .. endpoint.host
    .. ":"
    .. tostring(endpoint.port)
    .. "/"
    .. vim.uri_encode(creds.dbname or "", "rfc2396")
    .. "?"
    .. table.concat(params, "&")
end

---Picker entries for an aws connection: one per role (writer, reader, reader-N).
---@param conn dbgrid.Connection
---@param info? table   cached endpoints (parse_cluster / parse_instance result)
---@return dbgrid.Connection[]
function M.expand(conn, info)
  local a = conn.aws or {}
  local id = id_of(a) or "?"
  local function entry(role, reader)
    local c = vim.deepcopy(conn)
    c.name = conn.name .. "/" .. role
    c.aws_role = role
    c.parent = conn.name
    c.adapter = conn.adapter or "postgres"
    c.url = "aws://" .. profile_of(a) .. "/" .. id .. "/" .. role
    if reader then
      c.readonly = conn.readonly ~= false
    end
    return c
  end
  local out = { entry("writer", false) }
  local readers
  if a.cluster then
    readers = (info and info.reader == nil) and 0 or 1
  elseif info then
    readers = #(info.replica_endpoints or info.replicas or {})
  else
    readers = 1
  end
  for n = 1, readers do
    out[#out + 1] = entry(n == 1 and "reader" or ("reader-" .. n), true)
  end
  return out
end

-- Endpoint cache --------------------------------------------------------------

local function endpoints_path()
  return project.data_dir() .. "/aws/endpoints.json"
end

---@return table<string, { fetched_at: integer, info: table }>
local function read_endpoint_cache()
  local data = util.read_json(endpoints_path())
  return type(data) == "table" and data or {}
end

---Disk-cached endpoints of a connection, unless older than endpoint_ttl_seconds.
---@param aws_cfg dbgrid.AwsConfig
---@return table? info, integer? fetched_at
function M.cached_endpoints(aws_cfg)
  local entry = read_endpoint_cache()[cache_key(aws_cfg)]
  if type(entry) ~= "table" or type(entry.info) ~= "table" then
    return nil
  end
  local ttl = cfg().endpoint_ttl_seconds or 86400
  local age = util.epoch() - (tonumber(entry.fetched_at) or 0)
  if age > ttl then
    return nil
  end
  return entry.info, entry.fetched_at
end

---@param aws_cfg dbgrid.AwsConfig
---@param info table
local function store_endpoints(aws_cfg, info)
  local all = read_endpoint_cache()
  all[cache_key(aws_cfg)] = { fetched_at = util.epoch(), info = info }
  util.write_json(endpoints_path(), all)
end

---@param aws_cfg dbgrid.AwsConfig
function M.forget_endpoints(aws_cfg)
  local all = read_endpoint_cache()
  if all[cache_key(aws_cfg)] ~= nil then
    all[cache_key(aws_cfg)] = nil
    util.write_json(endpoints_path(), all)
  end
end

-- CLI -------------------------------------------------------------------------

---@class dbgrid.AwsCliResult
---@field ok boolean
---@field code integer
---@field stdout string
---@field stderr string
---@field json? table
---@field expired boolean

---@param aws_cfg dbgrid.AwsConfig
local function cli_exe(aws_cfg)
  return aws_cfg.cli or cfg().cli or "aws"
end

---@param aws_cfg dbgrid.AwsConfig
---@param args string[]
---@param text? boolean   skip --output json
---@return string[]
local function cli_argv(aws_cfg, args, text)
  local argv = { cli_exe(aws_cfg) }
  vim.list_extend(argv, args)
  if not text then
    vim.list_extend(argv, { "--output", "json" })
  end
  if aws_cfg.profile then
    vim.list_extend(argv, { "--profile", aws_cfg.profile })
  end
  if aws_cfg.region then
    vim.list_extend(argv, { "--region", aws_cfg.region })
  end
  return argv
end

---A sentence for the user out of a failed CLI result.
---@param aws_cfg dbgrid.AwsConfig
---@param what string
---@param res dbgrid.AwsCliResult
---@return string
local function cli_error(aws_cfg, what, res)
  if res.expired then
    return "AWS credentials for profile "
      .. profile_of(aws_cfg)
      .. " have expired; run: "
      .. table.concat(M.login_argv(aws_cfg), " ")
  end
  local last
  for _, l in ipairs(util.lines(res.stderr or "")) do
    if util.trim(l) ~= "" then
      last = util.trim(l)
    end
  end
  return what .. " failed: " .. (last or ("aws exited with code " .. tostring(res.code)))
end

local login_waiters = {} ---@type table<string, fun(ok: boolean)[]>

---Refresh credentials with login_argv in a terminal split (or silently when headless).
---@param aws_cfg dbgrid.AwsConfig
---@param cb fun(ok: boolean)
function M.login(aws_cfg, cb)
  local profile = profile_of(aws_cfg)
  if login_waiters[profile] then
    table.insert(login_waiters[profile], cb)
    return
  end
  login_waiters[profile] = { cb }
  local argv = M.login_argv(aws_cfg)
  local function finish(ok)
    local cbs = login_waiters[profile] or {}
    login_waiters[profile] = nil
    vim.schedule(function()
      for _, f in ipairs(cbs) do
        f(ok)
      end
    end)
  end
  util.notify("dbgrid: refreshing AWS credentials for profile " .. profile)
  if #vim.api.nvim_list_uis() == 0 then
    local ok, err = pcall(vim.system, argv, { text = true }, function(out)
      finish(out.code == 0)
    end)
    if not ok then
      util.error("dbgrid: login command failed to start: " .. tostring(err))
      finish(false)
    end
    return
  end
  local prev = vim.api.nvim_get_current_win()
  vim.cmd("botright 12split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  local function on_exit(_, code)
    vim.schedule(function()
      if code == 0 then
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_close, win, true)
        end
        if vim.api.nvim_win_is_valid(prev) then
          pcall(vim.api.nvim_set_current_win, prev)
        end
        util.notify("dbgrid: AWS credentials refreshed for profile " .. profile)
      else
        util.warn("dbgrid: AWS login exited with code " .. tostring(code))
      end
      finish(code == 0)
    end)
  end
  local job
  if vim.fn.has("nvim-0.11") == 1 then
    job = vim.fn.jobstart(argv, { term = true, on_exit = on_exit })
  else
    job = vim.fn.termopen(argv, { on_exit = on_exit })
  end
  if not job or job <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    util.error("dbgrid: could not start " .. table.concat(argv, " "))
    finish(false)
    return
  end
  vim.cmd("startinsert")
end

---Run the aws CLI. cb(result); expired credentials trigger a login and one retry
---unless opts.no_login. opts.text skips `--output json` (and JSON decoding).
---@param aws_cfg dbgrid.AwsConfig
---@param args string[]
---@param cb fun(res: dbgrid.AwsCliResult)
---@param opts? { no_login?: boolean, text?: boolean, timeout_ms?: integer }
function M.cli(aws_cfg, args, cb, opts)
  opts = opts or {}
  aws_cfg = aws_cfg or {}
  local exe = cli_exe(aws_cfg)
  if vim.fn.executable(exe) ~= 1 then
    return vim.schedule(function()
      cb({ ok = false, code = 127, stdout = "", stderr = "aws CLI not found on PATH", expired = false })
    end)
  end
  local argv = cli_argv(aws_cfg, args, opts.text)
  local timeout = opts.timeout_ms or CLI_TIMEOUT_MS
  local function run(may_login)
    local ok, err = pcall(vim.system, argv, { text = true, timeout = timeout, env = { AWS_PAGER = "" } }, function(out)
      vim.schedule(function()
        local res = { ok = out.code == 0, code = out.code, stdout = out.stdout or "", stderr = out.stderr or "" }
        if out.code == 124 and util.trim(res.stderr) == "" then
          res.stderr = "aws CLI timed out after " .. math.floor(timeout / 1000) .. " s"
        end
        res.expired = not res.ok and M.is_expired(res.stderr)
        if res.ok and not opts.text then
          local okj, decoded = pcall(vim.json.decode, res.stdout)
          if okj and type(decoded) == "table" then
            res.json = decoded
          end
        end
        if res.expired and may_login and not opts.no_login then
          M.login(aws_cfg, function(logged_in)
            if logged_in then
              run(false)
            else
              cb(res)
            end
          end)
          return
        end
        cb(res)
      end)
    end)
    if not ok then
      vim.schedule(function()
        local msg = "aws CLI could not be started: " .. tostring(err)
        cb({ ok = false, code = 127, stdout = "", stderr = msg, expired = false })
      end)
    end
  end
  run(true)
end

---Run several async steps and call cb once all have finished.
---@param fns fun(done: fun())[]
---@param cb fun()
local function parallel(fns, cb)
  local left = #fns
  if left == 0 then
    return cb()
  end
  for _, fn in ipairs(fns) do
    fn(function()
      left = left - 1
      if left == 0 then
        cb()
      end
    end)
  end
end

-- Endpoints -------------------------------------------------------------------

---Describe the cluster / instance (cached on disk for endpoint_ttl_seconds).
---@param aws_cfg dbgrid.AwsConfig
---@param cb fun(info?: table, err?: string)
---@param opts? { force?: boolean }
function M.endpoints(aws_cfg, cb, opts)
  opts = opts or {}
  local id = id_of(aws_cfg)
  if not id then
    return cb(nil, "the aws block of the connection needs `cluster` or `instance`")
  end
  if not opts.force then
    local cached = M.cached_endpoints(aws_cfg)
    if cached then
      return cb(cached)
    end
  end
  if aws_cfg.cluster then
    M.cli(aws_cfg, { "rds", "describe-db-clusters", "--db-cluster-identifier", aws_cfg.cluster }, function(res)
      if not res.ok then
        return cb(nil, cli_error(aws_cfg, "describing cluster " .. aws_cfg.cluster, res))
      end
      local info, err = M.parse_cluster(res.json or res.stdout)
      if not info then
        return cb(nil, err)
      end
      if not info.writer.host then
        return cb(nil, "cluster " .. aws_cfg.cluster .. " has no endpoint yet (status " .. tostring(info.status) .. ")")
      end
      store_endpoints(aws_cfg, info)
      cb(info)
    end)
    return
  end
  M.cli(aws_cfg, { "rds", "describe-db-instances", "--db-instance-identifier", aws_cfg.instance }, function(res)
    if not res.ok then
      return cb(nil, cli_error(aws_cfg, "describing instance " .. aws_cfg.instance, res))
    end
    local info, err = M.parse_instance(res.json or res.stdout)
    if not info then
      return cb(nil, err)
    end
    if not info.writer.host then
      return cb(nil, "instance " .. aws_cfg.instance .. " has no endpoint yet (status " .. tostring(info.status) .. ")")
    end
    local replica_endpoints = {}
    local steps = {}
    for i, rid in ipairs(info.replicas) do
      steps[#steps + 1] = function(done)
        M.cli(aws_cfg, { "rds", "describe-db-instances", "--db-instance-identifier", rid }, function(r)
          local rinfo = r.ok and M.parse_instance(r.json or r.stdout) or nil
          if rinfo and rinfo.writer.host then
            replica_endpoints[i] = { id = rid, host = rinfo.writer.host, port = rinfo.writer.port }
          else
            util.warn("dbgrid: could not describe replica " .. rid)
          end
          done()
        end)
      end
    end
    parallel(steps, function()
      info.replica_endpoints = {}
      for i = 1, #info.replicas do
        if replica_endpoints[i] then
          info.replica_endpoints[#info.replica_endpoints + 1] = replica_endpoints[i]
        end
      end
      store_endpoints(aws_cfg, info)
      cb(info)
    end)
  end)
end

---The endpoint a role connects to.
---@param info table
---@param role string   "writer" | "reader" | "reader-N"
---@return dbgrid.AwsEndpoint? endpoint, string? err
function M.pick_endpoint(info, role)
  role = role or "writer"
  if role == "writer" then
    return info.writer
  end
  local n = role == "reader" and 1 or tonumber(role:match("^reader%-(%d+)$"))
  if not n then
    return nil, "unknown role " .. tostring(role)
  end
  if n == 1 and info.reader then
    return info.reader
  end
  local r = info.replica_endpoints and info.replica_endpoints[n]
  if r then
    return { host = r.host, port = r.port }
  end
  return nil, "connection has no reader endpoint" .. (n > 1 and (" for " .. role) or "")
end

-- Credentials -----------------------------------------------------------------

local creds_cache = {} ---@type table<string, dbgrid.AwsCreds>

---@param aws_cfg dbgrid.AwsConfig
---@param endpoint? dbgrid.AwsEndpoint
local function creds_key(aws_cfg, endpoint)
  return cache_key(aws_cfg) .. "|" .. (aws_cfg.auth or "secret") .. "|" .. (endpoint and endpoint.host or "")
end

---@param aws_cfg dbgrid.AwsConfig
function M.forget_credentials(aws_cfg)
  local prefix = cache_key(aws_cfg) .. "|"
  for k in pairs(creds_cache) do
    if k:sub(1, #prefix) == prefix then
      creds_cache[k] = nil
    end
  end
end

---Database credentials: the Secrets Manager secret, or an IAM auth token.
---Cached in memory until forget_credentials() or the token expires.
---@param aws_cfg dbgrid.AwsConfig
---@param info table   endpoints (for the managed secret ARN and the token host)
---@param cb fun(creds?: dbgrid.AwsCreds, err?: string)
---@param endpoint? dbgrid.AwsEndpoint   host the IAM token is generated for (default: the writer)
function M.credentials(aws_cfg, info, cb, endpoint)
  local auth = aws_cfg.auth or "secret"
  endpoint = (auth == "iam" and endpoint) or info.writer
  local key = creds_key(aws_cfg, endpoint)
  local cached = creds_cache[key]
  if cached and (not cached.token_expires or cached.token_expires > util.epoch() + 30) then
    return cb(cached)
  end
  if auth == "iam" then
    if not aws_cfg.user then
      return cb(nil, "iam auth needs `user` in the aws block of the connection")
    end
    if not aws_cfg.database then
      return cb(nil, "iam auth needs `database` in the aws block of the connection")
    end
    local args = {
      "rds",
      "generate-db-auth-token",
      "--hostname",
      endpoint.host,
      "--port",
      tostring(endpoint.port),
      "--username",
      aws_cfg.user,
    }
    M.cli(aws_cfg, args, function(res)
      if not res.ok then
        return cb(nil, cli_error(aws_cfg, "generating an IAM auth token", res))
      end
      local creds = {
        username = aws_cfg.user,
        password = util.trim(res.stdout),
        dbname = aws_cfg.database,
        token_expires = util.epoch() + IAM_TOKEN_TTL,
      }
      creds_cache[key] = creds
      cb(creds)
    end, { text = true })
    return
  end
  if auth ~= "secret" then
    return cb(nil, "unknown aws auth mode '" .. tostring(auth) .. "' (use \"secret\" or \"iam\")")
  end
  local secret_id = aws_cfg.secret or info.secret_arn
  if not secret_id then
    return cb(nil, "no secret configured and RDS does not manage the master password")
  end
  M.cli(aws_cfg, { "secretsmanager", "get-secret-value", "--secret-id", secret_id }, function(res)
    if not res.ok then
      return cb(nil, cli_error(aws_cfg, "reading secret " .. secret_id, res))
    end
    local secret, err = M.parse_secret(res.json or res.stdout)
    if not secret then
      return cb(nil, err)
    end
    local dbname = aws_cfg.database or secret.dbname
    if not dbname then
      return cb(nil, "the secret has no dbname; set `database` in the aws block of the connection")
    end
    local creds = { username = secret.username, password = secret.password, dbname = dbname }
    creds_cache[key] = creds
    cb(creds)
  end)
end

-- Resolve ---------------------------------------------------------------------

---@class dbgrid.AwsEffective
---@field url string
---@field env table<string,string>
---@field host string
---@field port integer
---@field local_port? integer
---@field tunnel_key? string
---@field role string
---@field username string
---@field dbname string

---Everything needed to connect: endpoints, credentials and (with a bastion) the tunnel.
---@param conn dbgrid.Connection
---@param cb fun(effective?: dbgrid.AwsEffective, err?: string)
function M.resolve(conn, cb)
  local a = conn.aws
  if type(a) ~= "table" then
    return cb(nil, "connection " .. tostring(conn.name) .. " has no aws block")
  end
  local role = conn.aws_role or "writer"
  M.endpoints(a, function(info, err)
    if not info then
      return cb(nil, err)
    end
    local endpoint, perr = M.pick_endpoint(info, role)
    if not endpoint then
      return cb(nil, perr)
    end
    M.credentials(a, info, function(creds, cerr)
      if not creds then
        return cb(nil, cerr)
      end
      local ssl = { ssl = conn.ssl or cfg().ssl or "require", sslrootcert = conn.sslrootcert }
      local function finish(local_port, tunnel_key)
        cb({
          url = M.effective_url(creds, endpoint, local_port, ssl),
          env = creds.password and { PGPASSWORD = creds.password } or {},
          host = endpoint.host,
          port = endpoint.port,
          local_port = local_port,
          tunnel_key = tunnel_key,
          role = role,
          username = creds.username,
          dbname = creds.dbname,
        })
      end
      if not a.bastion then
        return finish(nil, nil)
      end
      local key = "ssm|" .. (a.profile or "") .. "|" .. a.bastion .. "|" .. endpoint.host .. ":" .. endpoint.port
      require("dbgrid.tunnel").ensure({
        key = key,
        kind = "ssm",
        profile = a.profile,
        region = a.region,
        target = a.bastion,
        host = endpoint.host,
        port = endpoint.port,
        document = a.document,
        parameters = a.parameters,
        cli = cli_exe(a),
      }, function(port, terr)
        if not port then
          return cb(nil, terr)
        end
        finish(port, key)
      end)
    end, endpoint)
  end)
end

-- Views -----------------------------------------------------------------------

local CLUSTER_METRICS = {
  "CPUUtilization",
  "DatabaseConnections",
  "FreeableMemory",
  "VolumeBytesUsed",
  "AuroraReplicaLag",
}
local INSTANCE_METRICS = { "CPUUtilization", "DatabaseConnections", "FreeableMemory", "FreeStorageSpace", "ReplicaLag" }

---@param aws_cfg dbgrid.AwsConfig
---@param info table
---@return string[] args
local function metric_args(aws_cfg, info)
  local names = aws_cfg.cluster and CLUSTER_METRICS or INSTANCE_METRICS
  local dimension = aws_cfg.cluster and "DBClusterIdentifier" or "DBInstanceIdentifier"
  local queries = {}
  for i, name in ipairs(names) do
    queries[i] = {
      Id = "m" .. i,
      Label = name,
      ReturnData = true,
      MetricStat = {
        Metric = {
          Namespace = "AWS/RDS",
          MetricName = name,
          Dimensions = { { Name = dimension, Value = info.id or id_of(aws_cfg) } },
        },
        Period = 60,
        Stat = "Average",
      },
    }
  end
  local now = util.epoch()
  return {
    "cloudwatch",
    "get-metric-data",
    "--metric-data-queries",
    vim.json.encode(queries),
    "--start-time",
    iso_utc(now - 300),
    "--end-time",
    iso_utc(now),
    "--scan-by",
    "TimestampDescending",
  }
end

---@param conn dbgrid.Connection
---@return dbgrid.AwsConfig?, string? err
local function aws_of(conn)
  if type(conn) ~= "table" or type(conn.aws) ~= "table" then
    return nil, "connection " .. tostring(conn and conn.name) .. " has no aws block"
  end
  if not id_of(conn.aws) then
    return nil, "the aws block of the connection needs `cluster` or `instance`"
  end
  return conn.aws
end

---@param ep? dbgrid.AwsEndpoint
local function ep_str(ep)
  return ep and ep.host and (ep.host .. ":" .. tostring(ep.port)) or "-"
end

---Status rows for `:Dbgrid aws status`: describe output, pending maintenance and 5 minutes of CloudWatch.
---@param conn dbgrid.Connection
---@param cb fun(rows?: string[][], columns?: string[], err?: string)
function M.status(conn, cb)
  local a, err = aws_of(conn)
  if not a then
    return cb(nil, nil, err)
  end
  M.endpoints(a, function(info, derr)
    if not info then
      return cb(nil, nil, derr)
    end
    local rows = {
      { "status", tostring(info.status or "?"), "", "" },
      { "engine", trim_str((info.engine or "") .. " " .. (info.engine_version or "")), "", "" },
      { "writer", ep_str(info.writer), "", "" },
    }
    if a.cluster then
      rows[#rows + 1] = { "reader", ep_str(info.reader), "", "" }
      local members = {}
      for _, m in ipairs(info.members or {}) do
        members[#members + 1] = m.id .. (m.writer and " (writer)" or "")
      end
      rows[#rows + 1] = { "members", #members > 0 and table.concat(members, ", ") or "-", "", "" }
    else
      local replicas = {}
      for _, r in ipairs(info.replica_endpoints or {}) do
        replicas[#replicas + 1] = r.id .. " " .. ep_str(r)
      end
      rows[#rows + 1] = { "replicas", #replicas > 0 and table.concat(replicas, ", ") or "-", "", "" }
      if info.source then
        rows[#rows + 1] = { "replica of", info.source, "", "" }
      end
    end
    local pending, metrics, metrics_err
    parallel({
      function(done)
        if not info.arn then
          return done()
        end
        M.cli(a, { "rds", "describe-pending-maintenance-actions", "--resource-identifier", info.arn }, function(res)
          if res.ok then
            pending = M.parse_pending_maintenance(res.json or res.stdout) or "none"
          else
            pending = cli_error(a, "describe-pending-maintenance-actions", res)
          end
          done()
        end)
      end,
      function(done)
        M.cli(a, metric_args(a, info), function(res)
          if res.ok then
            metrics, metrics_err = M.parse_metrics(res.json or res.stdout)
          else
            metrics_err = cli_error(a, "cloudwatch get-metric-data", res)
          end
          done()
        end)
      end,
    }, function()
      rows[#rows + 1] = { "pending maintenance", pending or info.pending_maintenance or "none", "", "" }
      for _, r in ipairs(metrics or {}) do
        rows[#rows + 1] = r
      end
      if metrics_err then
        rows[#rows + 1] = { "metrics", metrics_err, "", "" }
      end
      cb(rows, { "item", "last", "min", "max" })
    end)
  end, { force = true })
end

---RDS events of the last 24 hours, newest first.
---@param conn dbgrid.Connection
---@param cb fun(rows?: string[][], columns?: string[], err?: string)
function M.events(conn, cb)
  local a, err = aws_of(conn)
  if not a then
    return cb(nil, nil, err)
  end
  local args = {
    "rds",
    "describe-events",
    "--source-identifier",
    id_of(a),
    "--source-type",
    a.cluster and "db-cluster" or "db-instance",
    "--duration",
    "1440",
  }
  M.cli(a, args, function(res)
    if not res.ok then
      return cb(nil, nil, cli_error(a, "describe-events", res))
    end
    local rows, perr = M.parse_events(res.json or res.stdout)
    if not rows then
      return cb(nil, nil, perr)
    end
    cb(rows, { "date", "source", "message" })
  end)
end

---Blue/green deployments of the account/region.
---@param conn dbgrid.Connection
---@param cb fun(rows?: string[][], columns?: string[], err?: string)
function M.bluegreen(conn, cb)
  local a, err = aws_of(conn)
  if not a then
    return cb(nil, nil, err)
  end
  M.cli(a, { "rds", "describe-blue-green-deployments" }, function(res)
    if not res.ok then
      return cb(nil, nil, cli_error(a, "describe-blue-green-deployments", res))
    end
    local rows, perr = M.parse_bluegreen(res.json or res.stdout)
    if not rows then
      return cb(nil, nil, perr)
    end
    cb(rows, { "deployment", "status", "source", "target", "member_status" })
  end)
end

-- Interactive add -------------------------------------------------------------

---@param prompt string
---@param default? string
---@param cb fun(value?: string)
local function ask(prompt, default, cb)
  vim.ui.input({ prompt = prompt, default = default }, function(v)
    if v == nil then
      return cb(nil)
    end
    v = util.trim(v)
    cb(v ~= "" and v or nil)
  end)
end

---Walk the user through profile, region, cluster/instance, bastion, secret and name, then save globally.
---@param cb? fun(conn?: dbgrid.Connection)
function M.add_interactive(cb)
  cb = cb or function() end
  local function cancel()
    util.notify("dbgrid: aws connection not added")
    cb(nil)
  end
  local base = { cli = cfg().cli }
  local function pick_profile(next_step)
    M.cli(base, { "configure", "list-profiles" }, function(res)
      local profiles = {}
      for _, l in ipairs(util.lines(res.stdout or "")) do
        if util.trim(l) ~= "" then
          profiles[#profiles + 1] = util.trim(l)
        end
      end
      if not res.ok or #profiles == 0 then
        return ask("AWS profile: ", "default", next_step)
      end
      vim.ui.select(profiles, { prompt = "AWS profile" }, function(choice)
        next_step(choice)
      end)
    end, { text = true, no_login = true })
  end
  local function pick_region(aws_cfg, next_step)
    M.cli(aws_cfg, { "configure", "get", "region" }, function(res)
      local default = res.ok and util.trim(res.stdout or "") or ""
      ask("AWS region: ", default ~= "" and default or nil, next_step)
    end, { text = true, no_login = true })
  end
  local function pick_database(aws_cfg, next_step)
    local clusters, instances = {}, {}
    parallel({
      function(done)
        M.cli(aws_cfg, { "rds", "describe-db-clusters" }, function(res)
          for _, c in ipairs(res.json and nz(res.json.DBClusters) or {}) do
            clusters[#clusters + 1] = c
          end
          done()
        end)
      end,
      function(done)
        M.cli(aws_cfg, { "rds", "describe-db-instances" }, function(res)
          for _, i in ipairs(res.json and nz(res.json.DBInstances) or {}) do
            if not nz(i.DBClusterIdentifier) then
              instances[#instances + 1] = i
            end
          end
          done()
        end)
      end,
    }, function()
      local items = {}
      for _, c in ipairs(clusters) do
        items[#items + 1] = { kind = "cluster", id = c.DBClusterIdentifier, raw = c }
      end
      for _, i in ipairs(instances) do
        items[#items + 1] = { kind = "instance", id = i.DBInstanceIdentifier, raw = i }
      end
      if #items == 0 then
        util.error("dbgrid: no RDS clusters or instances found for profile " .. profile_of(aws_cfg))
        return next_step(nil)
      end
      vim.ui.select(items, {
        prompt = "RDS cluster / instance",
        format_item = function(item)
          local status = nz(item.raw.Status) or nz(item.raw.DBInstanceStatus) or ""
          return item.kind .. " " .. item.id .. "  " .. status
        end,
      }, next_step)
    end)
  end
  pick_profile(function(profile)
    if not profile then
      return cancel()
    end
    local aws_cfg = { profile = profile, cli = base.cli }
    pick_region(aws_cfg, function(region)
      aws_cfg.region = region
      pick_database(aws_cfg, function(item)
        if not item then
          return cancel()
        end
        aws_cfg[item.kind] = item.id
        local info = item.kind == "cluster" and M.parse_cluster({ DBClusters = { item.raw } })
          or M.parse_instance({ DBInstances = { item.raw } })
        if info then
          store_endpoints(aws_cfg, info)
        end
        ask("SSM target instance id (empty = connect directly): ", nil, function(bastion)
          aws_cfg.bastion = bastion
          local managed = info and info.secret_arn or nil
          ask("Secrets Manager secret (id or ARN): ", managed, function(secret)
            if secret and secret ~= managed then
              aws_cfg.secret = secret
            elseif not managed then
              util.warn("dbgrid: no secret given; set aws.secret (or aws.auth = \"iam\") before connecting")
            end
            aws_cfg.auth = "secret"
            ask("Connection name: ", item.id, function(name)
              if not name then
                return cancel()
              end
              local conn = {
                name = name,
                url = "aws://" .. profile .. "/" .. item.id,
                adapter = "postgres",
                aws = aws_cfg,
                ssl = cfg().ssl or "require",
              }
              require("dbgrid.connections").save(conn, "global")
              util.notify("dbgrid: saved aws connection " .. name)
              cb(conn)
            end)
          end)
        end)
      end)
    end)
  end)
end

-- Health ----------------------------------------------------------------------

---Synchronous checks for :checkhealth dbgrid.
---@param report { ok: fun(msg: string), warn: fun(msg: string), error: fun(msg: string), info: fun(msg: string) }
function M.health(report)
  local cli = cfg().cli or "aws"
  local function run(argv, timeout)
    local ok, res = pcall(function()
      return vim.system(argv, { text = true, timeout = timeout, env = { AWS_PAGER = "" } }):wait()
    end)
    if not ok then
      return { code = 127, stdout = "", stderr = tostring(res) }
    end
    return res
  end
  if vim.fn.executable(cli) == 1 then
    local res = run({ cli, "--version" }, 5000)
    local version = trim_str(res.stdout ~= "" and res.stdout or res.stderr)
    if version:find("aws%-cli/2") then
      report.ok("aws CLI: " .. version)
    else
      report.warn("aws CLI: " .. version .. " (v2 is required for RDS connections)")
    end
  else
    report.warn("aws CLI '" .. cli .. "' not found on PATH (needed for RDS connections)")
  end
  if vim.fn.executable("session-manager-plugin") == 1 then
    report.ok("session-manager-plugin found")
  else
    report.warn("session-manager-plugin not found on PATH (needed for SSM tunnels through a bastion)")
  end
  local conns, seen = {}, {}
  local lists = { require("dbgrid.connections").all(), config.get().connections or {} }
  for _, list in ipairs(lists) do
    for _, c in ipairs(list) do
      if type(c.aws) == "table" and not seen[c.name] then
        seen[c.name] = true
        conns[#conns + 1] = c
      end
    end
  end
  for _, c in ipairs(conns) do
    local a = c.aws
    local label = c.name .. " (" .. profile_of(a) .. "/" .. tostring(id_of(a) or "?") .. ")"
    if not id_of(a) then
      report.error(label .. ": the aws block needs `cluster` or `instance`")
    else
      local info, fetched_at = M.cached_endpoints(a)
      if info then
        report.info(label .. ": endpoints cached " .. util.ago(fetched_at) .. ", writer " .. ep_str(info.writer))
      else
        report.info(label .. ": endpoints not cached yet (fetched on first connect)")
      end
      local res = run(cli_argv(a, { "sts", "get-caller-identity" }), 5000)
      if res.code == 0 then
        local okj, who = pcall(vim.json.decode, res.stdout)
        report.ok(label .. ": credentials ok" .. (okj and who.Arn and (" (" .. who.Arn .. ")") or ""))
      else
        local r = { ok = false, code = res.code, stdout = res.stdout or "", stderr = res.stderr or "", expired = false }
        r.expired = M.is_expired(r.stderr)
        report.warn(label .. ": " .. cli_error(a, "sts get-caller-identity", r))
      end
    end
  end
end

return M
