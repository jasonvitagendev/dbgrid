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
---@field host? string                   reach the database at this host instead (PrivateLink endpoint, another account); no describe calls
---@field read_host? string              reader host of a `host` connection
---@field port? integer|string           port of a `host` connection (default: the secret's, else 5432)
---@field bastion? string                SSM target: an instance id, the Name tag of one, or "auto"; nil = connect directly
---@field secret? string                 Secrets Manager id/ARN (default: the RDS managed master secret)
---@field auth? "secret"|"iam"
---@field user? string                   database user for iam auth
---@field database? string               database name (default: the secret's dbname/db, the cluster's initial database, else asked once)
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
---Regions scanned for databases when `ec2 describe-regions` is denied (the ones enabled by default).
M.DEFAULT_REGIONS = {
  "us-east-1",
  "us-east-2",
  "us-west-1",
  "us-west-2",
  "ap-south-1",
  "ap-northeast-1",
  "ap-northeast-2",
  "ap-northeast-3",
  "ap-southeast-1",
  "ap-southeast-2",
  "ca-central-1",
  "eu-central-1",
  "eu-west-1",
  "eu-west-2",
  "eu-west-3",
  "eu-north-1",
  "sa-east-1",
}
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
  return aws_cfg.cluster or aws_cfg.instance or aws_cfg.host or aws_cfg.secret
end

---Is the database reached by host name rather than through describe-db-*?
---@param aws_cfg dbgrid.AwsConfig
local function by_host(aws_cfg)
  return not aws_cfg.cluster and not aws_cfg.instance
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
    database = nz(c.DatabaseName),
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
    vpc = nz(i.DBSubnetGroup) and nz(i.DBSubnetGroup.VpcId) or nil,
    public = nz(i.PubliclyAccessible) == true,
    database = nz(i.DBName),
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
  -- hand-written secrets name their keys freely: {db, hostWrite, hostRead, port: "5432"} is common
  local dbname = nz(s.dbname) or nz(s.db) or nz(s.database) or nz(s.dbName)
  return {
    username = tostring(s.username),
    password = tostring(s.password),
    host = nz(s.host) or nz(s.hostWrite) or nz(s.hostname),
    read_host = nz(s.hostRead),
    port = tonumber(nz(s.port)),
    dbname = dbname and tostring(dbname) or nil,
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

---Column a metric is shown under and the factor its value is multiplied by:
---byte counts become MiB and the latencies CloudWatch reports in seconds
---become milliseconds, so every column of a `-- @metrics` cell is a plain
---number with its unit in the name.
---@param name string
---@return string column, number factor
function M.metric_column(name)
  if
    name:find("Memory")
    or name:find("Storage")
    or name:find("Bytes")
    or name:find("DiskUsage")
    or name:find("SlotLag")
    or name == "SwapUsage"
  then
    return name .. "_MiB", 1 / 1024 ^ 2
  elseif name == "ReadLatency" or name == "WriteLatency" then
    return name .. "_ms", 1000
  elseif name:find("Latency$") then
    return name .. "_ms", 1
  end
  return name, 1
end

---@param v number
---@return string
local function plain_number(v)
  if v == math.floor(v) then
    return string.format("%d", v)
  elseif math.abs(v) >= 100 then
    return string.format("%.1f", v)
  elseif math.abs(v) >= 1 then
    return string.format("%.2f", v)
  end
  return (string.format("%.5f", v):gsub("0+$", ""))
end

---The newest datapoint of every metric as one row, for a `-- @metrics` cell.
---@param json string|table   `aws cloudwatch get-metric-data` output (Values newest first)
---@return { columns: string[], rows: any[][], row_count: integer }? set, string? err
function M.parse_metric_row(json)
  local data, err = decode(json)
  if not data then
    return nil, err
  end
  local columns, row, newest = { "datapoint_utc" }, { vim.NIL }, nil
  for _, r in ipairs(nz(data.MetricDataResults) or {}) do
    local name = tostring(nz(r.Label) or nz(r.Id) or "?")
    local column, factor = M.metric_column(name)
    local values = nz(r.Values) or {}
    local stamps = nz(r.Timestamps) or {}
    columns[#columns + 1] = column
    row[#row + 1] = values[1] and plain_number(values[1] * factor) or vim.NIL
    if stamps[1] and (not newest or tostring(stamps[1]) > newest) then
      newest = tostring(stamps[1])
    end
  end
  if #columns == 1 then
    return nil, "CloudWatch returned no metrics"
  end
  if newest then
    row[1] = (newest:gsub("T", " "):gsub("[%+Z].*$", ""))
  end
  return { columns = columns, rows = { row }, row_count = 1 }
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

---Is this an EC2 / SSM managed-instance id (as opposed to a Name tag or "auto")?
---@param s any
---@return boolean
function M.is_instance_id(s)
  return type(s) == "string" and (s:match("^i%-%x+$") ~= nil or s:match("^mi%-%x+$") ~= nil)
end

---Is this something `ssm start-session --target` takes as is: an instance id,
---or an ECS Exec target (`ecs:<cluster>_<task id>_<runtime id>`) for accounts
---that run on Fargate and have no instance to jump through?
---@param s any
---@return boolean
function M.is_ssm_target(s)
  return M.is_instance_id(s) or (type(s) == "string" and s:match("^ecs:[^_].*_%x+_%x+%-%d+$") ~= nil)
end

---Merge `ssm describe-instance-information` and `ec2 describe-instances` into
---the instances an SSM session can target, with their Name tag and VPC. Without
---the SSM listing (nil) every running EC2 instance is a candidate and `online`
---is nil: unknown.
---@param ssm_json? string|table
---@param ec2_json? string|table
---@return table[]? list  { id, name?, online?, vpc?, ip?, platform? }, string? err
function M.parse_bastions(ssm_json, ec2_json)
  if ssm_json == nil and ec2_json == nil then
    return nil, "neither the SSM nor the EC2 listing is available"
  end
  local ssm, err
  if ssm_json ~= nil then
    ssm, err = decode(ssm_json)
    if not ssm then
      return nil, err
    end
  end
  local ec2 = ec2_json and decode(ec2_json) or {}
  local by_id, ids = {}, {}
  for _, r in ipairs(nz(ec2.Reservations) or {}) do
    for _, i in ipairs(nz(r.Instances) or {}) do
      local name
      for _, t in ipairs(nz(i.Tags) or {}) do
        if nz(t.Key) == "Name" then
          name = nz(t.Value)
        end
      end
      local id = nz(i.InstanceId)
      if id then
        ids[#ids + 1] = id
        by_id[id] = { name = name, vpc = nz(i.VpcId), ip = nz(i.PrivateIpAddress) }
      end
    end
  end
  local out = {}
  if ssm then
    for _, m in ipairs(nz(ssm.InstanceInformationList) or {}) do
      local id = nz(m.InstanceId)
      if id then
        local e = by_id[id] or {}
        out[#out + 1] = {
          id = id,
          name = e.name or nz(m.Name) or nz(m.ComputerName),
          online = nz(m.PingStatus) == "Online",
          vpc = e.vpc,
          ip = e.ip or nz(m.IPAddress),
          platform = nz(m.PlatformName),
        }
      end
    end
  else
    for _, id in ipairs(ids) do
      local e = by_id[id]
      out[#out + 1] = { id = id, name = e.name, online = nil, vpc = e.vpc, ip = e.ip }
    end
  end
  table.sort(out, function(a, b)
    return (a.name or a.id) < (b.name or b.id)
  end)
  return out
end

---Order bastion candidates: the current one first, then online instances whose
---Name matches `aws.bastion_names` ("bastion", "jump" by default), preferring
---the database's VPC. Each copy carries `score`, `match` (name matched) and `why`.
---@param list table[]              parse_bastions() output
---@param hints? { vpc?: string, patterns?: string[], current?: string }
---@return table[] ranked
function M.rank_bastions(list, hints)
  hints = hints or {}
  local patterns = hints.patterns or cfg().bastion_names or { "bastion", "jump" }
  local current = hints.current and hints.current:lower() or nil
  local out = {}
  for _, c in ipairs(list) do
    local r = vim.deepcopy(c)
    local lname = (c.name or ""):lower()
    r.score, r.why, r.match = 0, {}, false
    if current and (c.id:lower() == current or lname == current) then
      r.score = r.score + 8
      r.why[#r.why + 1] = "current"
    end
    for _, p in ipairs(patterns) do
      if lname:find(p:lower(), 1, true) then
        r.score = r.score + 4
        r.match = true
        r.why[#r.why + 1] = "name"
        break
      end
    end
    if hints.vpc and c.vpc == hints.vpc then
      r.score = r.score + 2
      r.why[#r.why + 1] = "same vpc"
    end
    if c.online == false then
      r.score = r.score - 16
      r.why[#r.why + 1] = "offline"
    end
    out[#out + 1] = r
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return (a.name or a.id) < (b.name or b.id)
  end)
  return out
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
  elseif a.instance then
    readers = info and #(info.replica_endpoints or info.replicas or {}) or 1
  else
    -- reached by host: a reader only when a distinct read host is known (block or cached secret)
    readers = ((a.read_host and a.read_host ~= a.host) or (info and info.reader)) and 1 or 0
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

---Cache key of a bastion looked up by name.
---@param aws_cfg dbgrid.AwsConfig
---@return string?
local function bastion_key(aws_cfg)
  if type(aws_cfg.bastion) ~= "string" or M.is_ssm_target(aws_cfg.bastion) then
    return nil
  end
  return "bastion|" .. profile_of(aws_cfg) .. "|" .. (aws_cfg.region or "") .. "|" .. aws_cfg.bastion:lower()
end

---Instance id a Name-tag / "auto" bastion resolved to, unless older than endpoint_ttl_seconds.
---@param aws_cfg dbgrid.AwsConfig
---@return string? id
function M.cached_bastion(aws_cfg)
  local key = bastion_key(aws_cfg)
  local entry = key and read_endpoint_cache()[key] or nil
  if type(entry) ~= "table" or type(entry.id) ~= "string" then
    return nil
  end
  if util.epoch() - (tonumber(entry.fetched_at) or 0) > (cfg().endpoint_ttl_seconds or 86400) then
    return nil
  end
  return entry.id
end

---@param aws_cfg dbgrid.AwsConfig
---@param id string
local function store_bastion(aws_cfg, id)
  local key = bastion_key(aws_cfg)
  if key then
    local all = read_endpoint_cache()
    all[key] = { fetched_at = util.epoch(), id = id }
    util.write_json(endpoints_path(), all)
  end
end

---Forget which instance a Name-tag / "auto" bastion resolved to (looked up again on the next run).
---@param aws_cfg dbgrid.AwsConfig
function M.forget_bastion(aws_cfg)
  local key = bastion_key(aws_cfg)
  local all = read_endpoint_cache()
  if key and all[key] ~= nil then
    all[key] = nil
    util.write_json(endpoints_path(), all)
  end
end

---@param aws_cfg dbgrid.AwsConfig
function M.forget_endpoints(aws_cfg)
  local all = read_endpoint_cache()
  local changed = false
  for _, key in ipairs({ cache_key(aws_cfg), bastion_key(aws_cfg) }) do
    if all[key] ~= nil then
      all[key] = nil
      changed = true
    end
  end
  if changed then
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
    return cb(nil, "the aws block of the connection needs `cluster`, `instance`, `host` or a `secret` naming the host")
  end
  if not opts.force then
    local cached = M.cached_endpoints(aws_cfg)
    if cached then
      return cb(cached)
    end
  end
  if by_host(aws_cfg) then
    return M.host_endpoints(aws_cfg, cb)
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

---Endpoints of a database reached by host: `host` / `read_host` / `port` of
---the aws block, else `hostWrite` / `hostRead` / `port` of the secret. No RDS
---describe call; cached like described endpoints so the picker knows about the reader.
---@param aws_cfg dbgrid.AwsConfig
---@param cb fun(info?: table, err?: string)
function M.host_endpoints(aws_cfg, cb)
  local function finish(host, read_host, port)
    local info = {
      kind = "host",
      id = host,
      status = "reached by host",
      writer = { host = host, port = port },
      reader = (read_host and read_host ~= host) and { host = read_host, port = port } or nil,
      members = {},
    }
    store_endpoints(aws_cfg, info)
    cb(info)
  end
  local port = tonumber(aws_cfg.port)
  if aws_cfg.host then
    return finish(aws_cfg.host, aws_cfg.read_host, port or 5432)
  end
  if not aws_cfg.secret then
    return cb(nil, "the aws block of the connection needs `cluster`, `instance`, `host` or a `secret` naming the host")
  end
  M.secret(aws_cfg, aws_cfg.secret, function(secret, err)
    if not secret then
      return cb(nil, err)
    end
    if not secret.host then
      return cb(nil, "secret " .. aws_cfg.secret .. " names no host; set `host` in the aws block of the connection")
    end
    finish(secret.host, aws_cfg.read_host or secret.read_host, port or secret.port or 5432)
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
local secret_cache = {} ---@type table<string, table>   parsed secrets, per profile/region/secret id

---@param aws_cfg dbgrid.AwsConfig
---@param endpoint? dbgrid.AwsEndpoint
local function creds_key(aws_cfg, endpoint)
  return cache_key(aws_cfg) .. "|" .. (aws_cfg.auth or "secret") .. "|" .. (endpoint and endpoint.host or "")
end

---@param aws_cfg dbgrid.AwsConfig
function M.forget_credentials(aws_cfg)
  local prefix = cache_key(aws_cfg) .. "|"
  for _, cache in ipairs({ creds_cache, secret_cache }) do
    for k in pairs(cache) do
      if k:sub(1, #prefix) == prefix then
        cache[k] = nil
      end
    end
  end
end

---Read and parse a Secrets Manager secret, once per session (see forget_credentials).
---@param aws_cfg dbgrid.AwsConfig
---@param secret_id string
---@param cb fun(secret?: table, err?: string)
function M.secret(aws_cfg, secret_id, cb)
  local key = cache_key(aws_cfg) .. "|secret|" .. secret_id
  if secret_cache[key] then
    return cb(secret_cache[key])
  end
  M.cli(aws_cfg, { "secretsmanager", "get-secret-value", "--secret-id", secret_id }, function(res)
    if not res.ok then
      return cb(nil, cli_error(aws_cfg, "reading secret " .. secret_id, res))
    end
    local secret, err = M.parse_secret(res.json or res.stdout)
    if not secret then
      return cb(nil, err)
    end
    secret_cache[key] = secret
    cb(secret)
  end)
end

---Read a secret as its decoded JSON object (`{ value = ... }` for a plain-text
---secret), once per session, for `-- @secret` cells. Not validated like M.secret:
---any keys go.
---@param aws_cfg dbgrid.AwsConfig
---@param secret_id string
---@param cb fun(secret?: table, err?: string)
function M.secret_json(aws_cfg, secret_id, cb)
  local key = cache_key(aws_cfg) .. "|secret-json|" .. secret_id
  if secret_cache[key] then
    return cb(secret_cache[key])
  end
  M.cli(aws_cfg, { "secretsmanager", "get-secret-value", "--secret-id", secret_id }, function(res)
    if not res.ok then
      return cb(nil, cli_error(aws_cfg, "reading secret " .. secret_id, res))
    end
    local data, err = decode(res.json or res.stdout)
    if not data then
      return cb(nil, err)
    end
    local text = nz(data.SecretString)
    if type(text) ~= "string" then
      return cb(nil, "the secret has no SecretString (binary secrets are not supported)")
    end
    local ok, obj = pcall(vim.json.decode, text)
    local secret = (ok and type(obj) == "table") and obj or { value = text }
    secret_cache[key] = secret
    cb(secret)
  end)
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
    return cb(nil, "unknown aws auth mode '" .. tostring(auth) .. '\' (use "secret" or "iam")')
  end
  local secret_id = aws_cfg.secret or info.secret_arn
  if not secret_id then
    return cb(nil, "no secret configured and RDS does not manage the master password")
  end
  M.secret(aws_cfg, secret_id, function(secret, err)
    if not secret then
      return cb(nil, err)
    end
    -- RDS-managed master secrets carry only username/password: fall back to the
    -- cluster's initial database; when that is unknown too, dbname stays nil and
    -- resolve() asks once
    local dbname = aws_cfg.database or secret.dbname or info.database
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

---The secret names no database and the cluster has no initial one: ask, and
---keep the answer on the saved connection (or say how to set it in setup()).
---@param conn dbgrid.Connection
---@param info table   endpoints info
---@param cb fun(database?: string)
function M.ask_database(conn, info, cb)
  local name = conn.parent or conn.name or "?"
  local prompt = string.format("Database for %s (the secret names none): ", name)
  vim.ui.input({ prompt = prompt, default = info.database or "postgres" }, function(v)
    v = v and util.trim(v) or ""
    if v == "" then
      return cb(nil)
    end
    conn.aws.database = v
    local connections = require("dbgrid.connections")
    local entry, scope = connections.saved_entry(name)
    if entry and type(entry.aws) == "table" then
      entry.aws.database = v
      connections.save(entry, scope)
      util.notify("dbgrid: database " .. v .. " saved on connection " .. name)
    else
      util.notify(string.format('dbgrid: using database %s; add `database = "%s"` to the aws block of %s', v, v, name))
    end
    cb(v)
  end)
end

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
      if not creds.dbname then
        return M.ask_database(conn, info, function(db)
          if not db then
            return cb(nil, "no database chosen for " .. tostring(conn.name))
          end
          creds.dbname = db -- the cached credentials carry it from now on
          M.resolve(conn, cb)
        end)
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
      M.bastion_id(a, { vpc = info.vpc }, function(target, berr)
        if not target then
          return cb(nil, berr)
        end
        local key = "ssm|" .. (a.profile or "") .. "|" .. target .. "|" .. endpoint.host .. ":" .. endpoint.port
        require("dbgrid.tunnel").ensure({
          key = key,
          kind = "ssm",
          profile = a.profile,
          region = a.region,
          target = target,
          host = endpoint.host,
          port = endpoint.port,
          document = a.document,
          parameters = a.parameters,
          cli = cli_exe(a),
          handshake = "postgres",
        }, function(port, terr)
          if not port then
            -- a jumpbox found by name may have been replaced: look it up again next time
            M.forget_bastion(a)
            return cb(nil, terr)
          end
          finish(port, key)
        end)
      end)
    end, endpoint)
  end)
end

-- Bastions ---------------------------------------------------------------------

---SSM-managed instances of the account (with EC2 Name tags and VPCs), for
---picking a jumpbox. Both CLI calls run in parallel; a failing ec2 call only
---loses the names, a failing ssm call falls back to the running EC2 instances
---(their SSM status unknown) and says so in `note`.
---@param aws_cfg dbgrid.AwsConfig
---@param cb fun(list?: table[], err?: string, note?: string)
function M.bastions(aws_cfg, cb)
  local ssm_res, ec2_res
  parallel({
    function(done)
      M.cli(aws_cfg, { "ssm", "describe-instance-information" }, function(res)
        ssm_res = res
        done()
      end)
    end,
    function(done)
      local args = { "ec2", "describe-instances", "--filters", "Name=instance-state-name,Values=running" }
      M.cli(aws_cfg, args, function(res)
        ec2_res = res
        done()
      end)
    end,
  }, function()
    local ec2_json = ec2_res.ok and ec2_res.json or nil
    if ssm_res.ok and ssm_res.json then
      return cb(M.parse_bastions(ssm_res.json, ec2_json))
    end
    local why = cli_error(aws_cfg, "listing SSM managed instances", ssm_res)
    if ec2_json then
      -- usually a role without ssm:DescribeInstanceInformation: offer the running instances by name
      local list, perr = M.parse_bastions(nil, ec2_json)
      return cb(list, perr, why)
    end
    cb(nil, why)
  end)
end

---Turn `aws.bastion` into an SSM target: an instance id is taken as is, "auto"
---picks the best candidate by `aws.bastion_names`, anything else is the Name
---tag of the instance (the first online one wins). Looked-up ids are cached
---with the endpoints, so a replaced jumpbox costs one lookup per day.
---@param aws_cfg dbgrid.AwsConfig
---@param hints? { vpc?: string }
---@param cb fun(id?: string, err?: string)
function M.bastion_id(aws_cfg, hints, cb)
  local want = aws_cfg.bastion
  if type(want) ~= "string" or want == "" or M.is_ssm_target(want) then
    return cb(want)
  end
  local cached = M.cached_bastion(aws_cfg)
  if cached then
    return cb(cached)
  end
  M.bastions(aws_cfg, function(list, err)
    if not list then
      return cb(nil, err)
    end
    local ranked, what
    if want == "auto" then
      ranked = M.rank_bastions(list, hints)
      what = "named like " .. table.concat(cfg().bastion_names or { "bastion", "jump" }, " / ")
    else
      local exact = vim.tbl_filter(function(c)
        return (c.name or ""):lower() == want:lower()
      end, list)
      ranked = M.rank_bastions(#exact > 0 and exact or list, { vpc = hints and hints.vpc, patterns = { want } })
      what = "named " .. want
    end
    local best = ranked[1]
    if not best or not best.match then
      return cb(
        nil,
        string.format(
          "no SSM-managed instance %s for profile %s; set aws.bastion to an instance id",
          what,
          profile_of(aws_cfg)
        )
      )
    end
    if best.online == false then
      return cb(nil, string.format("bastion %s (%s) is not online in SSM", best.name or best.id, best.id))
    end
    store_bastion(aws_cfg, best.id)
    cb(best.id)
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

---Metrics a `-- @metrics` cell samples when it names none: what a migration
---loads (CPU, memory, I/O, storage) and what a replication slot costs the
---publisher. A metric the engine does not publish comes back as NULL.
M.LIVE_METRICS = {
  instance = {
    "CPUUtilization",
    "DatabaseConnections",
    "FreeableMemory",
    "FreeStorageSpace",
    "ReadIOPS",
    "WriteIOPS",
    "ReadLatency",
    "WriteLatency",
    "DiskQueueDepth",
    "TransactionLogsDiskUsage",
    "ReplicationSlotDiskUsage",
    "OldestReplicationSlotLag",
  },
  cluster = {
    "CPUUtilization",
    "DatabaseConnections",
    "FreeableMemory",
    "ReadIOPS",
    "WriteIOPS",
    "CommitThroughput",
    "CommitLatency",
    "VolumeBytesUsed",
    "VolumeReadIOPs",
    "VolumeWriteIOPs",
    "ReplicationSlotDiskUsage",
    "OldestReplicationSlotLag",
  },
}

---@param aws_cfg dbgrid.AwsConfig
---@param info table
---@param names? string[]   metric names (default: the ones of `aws status`)
---@param window? integer   seconds to look back (default 300)
---@return string[] args
local function metric_args(aws_cfg, info, names, window)
  names = names or (aws_cfg.cluster and CLUSTER_METRICS or INSTANCE_METRICS)
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
    iso_utc(now - (window or 300)),
    "--end-time",
    iso_utc(now),
    "--scan-by",
    "TimestampDescending",
  }
end
M._metric_args = metric_args

---@param conn dbgrid.Connection
---@return dbgrid.AwsConfig?, string? err
local function aws_of(conn)
  if type(conn) ~= "table" or type(conn.aws) ~= "table" then
    return nil, "connection " .. tostring(conn and conn.name) .. " has no aws block"
  end
  if by_host(conn.aws) then
    return nil,
      "this view needs `cluster` or `instance` in the aws block; " .. tostring(conn.name) .. " is reached by host"
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

---The newest CloudWatch datapoint of each metric of a connection's cluster or
---instance, as a one-row result set (what a `-- @metrics` cell runs).
---@param conn dbgrid.Connection
---@param names? string[]   metric names (default `M.LIVE_METRICS`)
---@param cb fun(set?: table, err?: string)
function M.metrics(conn, names, cb)
  local a, err = aws_of(conn)
  if not a then
    return cb(nil, err)
  end
  M.endpoints(a, function(info, derr)
    if not info then
      return cb(nil, derr)
    end
    if not names or #names == 0 then
      names = M.LIVE_METRICS[a.cluster and "cluster" or "instance"]
    end
    -- ten minutes back: some metrics (VolumeBytesUsed) only arrive every five
    M.cli(a, metric_args(a, info, names, 600), function(res)
      if not res.ok then
        return cb(nil, cli_error(a, "cloudwatch get-metric-data", res))
      end
      cb(M.parse_metric_row(res.json or res.stdout))
    end)
  end)
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

---@param c table  ranked candidate
---@return string
local function bastion_label(c)
  local parts = { c.id }
  if c.name then
    parts[#parts + 1] = c.name
  end
  parts[#parts + 1] = c.online == true and "online" or (c.online == false and "offline" or "ssm status unknown")
  local why = vim.tbl_filter(function(w)
    return w == "same vpc" or w == "current"
  end, c.why or {})
  if #why > 0 then
    parts[#parts + 1] = "(" .. table.concat(why, ", ") .. ")"
  end
  return table.concat(parts, "  ")
end

---Choose the SSM bastion for a connection from the account's SSM-managed
---instances, likely jumpboxes first (`aws.bastion_names`, the database's VPC).
---One clear online candidate is taken without asking; otherwise the list is
---shown with "connect directly" and "type an id"; when the lookup fails, a
---plain prompt. `cancelled` is set when the user backs out of the list.
---@param aws_cfg dbgrid.AwsConfig
---@param hints { vpc?: string, current?: string, public?: boolean }
---@param cb fun(bastion?: string, cancelled?: boolean)
function M.pick_bastion(aws_cfg, hints, cb)
  hints = hints or {}
  local function manual(reason)
    local prompt = "SSM target instance id (" .. (reason and (reason .. "; ") or "") .. "empty = connect directly): "
    vim.ui.input({ prompt = prompt, default = hints.current }, function(v)
      if v == nil then
        -- Esc: while adding it means "directly" (as it always did), while editing it cancels
        return cb(nil, hints.current ~= nil)
      end
      v = util.trim(v)
      cb(v ~= "" and v or nil)
    end)
  end
  M.bastions(aws_cfg, function(list, err, note)
    if note then
      util.warn("dbgrid: " .. note .. "; offering the running EC2 instances instead")
    end
    if not list or #list == 0 then
      -- say why the old prompt appears: the lookup failed, or nothing is registered there
      if err then
        util.warn("dbgrid: could not list SSM instances (" .. err .. ")")
        return manual("lookup failed, see :messages")
      end
      util.warn(
        string.format(
          "dbgrid: no %s for profile %s in %s; enter the bastion instance id",
          note and "running EC2 instances" or "SSM-managed instances",
          profile_of(aws_cfg),
          aws_cfg.region or "the default region"
        )
      )
      return manual("none found")
    end
    local ranked = M.rank_bastions(list, { vpc = hints.vpc, current = hints.current })
    local best, second = ranked[1], ranked[2]
    local clear = best.match
      and best.online ~= false
      and not hints.current
      and not hints.public
      and (not second or second.score < best.score or second.name == best.name)
    if clear then
      util.notify(
        string.format(
          "dbgrid: using bastion %s (%s); :Dbgrid connections edit changes it",
          best.name or best.id,
          best.id
        )
      )
      return cb(best.id)
    end
    local items = {}
    if hints.current then
      items[#items + 1] = { kind = "keep", label = "keep " .. hints.current }
    end
    for _, c in ipairs(ranked) do
      items[#items + 1] = { kind = "instance", id = c.id, label = bastion_label(c) }
    end
    local direct = { kind = "direct", label = "connect directly (no bastion)" }
    if hints.public then
      table.insert(items, 1, direct)
    else
      items[#items + 1] = direct
    end
    items[#items + 1] = { kind = "manual", label = "type an instance id" }
    vim.ui.select(items, {
      prompt = "SSM bastion",
      format_item = function(item)
        return item.label
      end,
    }, function(item)
      if not item then
        return cb(nil, true)
      elseif item.kind == "keep" then
        return cb(hints.current)
      elseif item.kind == "instance" then
        return cb(item.id)
      elseif item.kind == "direct" then
        return cb(nil)
      end
      manual()
    end)
  end)
end

---Edit the parts of an aws block that change over time: the bastion (jumpboxes
---get replaced) and the secret. Profile, region and cluster identify the
---connection; `:Dbgrid aws add` makes a new one for a different database.
---@param conn dbgrid.Connection   a saved entry with an `aws` block, changed in place
---@param cb fun(ok: boolean)
function M.edit_interactive(conn, cb)
  local a = conn.aws
  local info = id_of(a) and M.cached_endpoints(a) or nil
  local hints = { vpc = info and info.vpc, current = a.bastion, public = info and info.public }
  M.pick_bastion(a, hints, function(bastion, cancelled)
    if cancelled then
      return cb(false)
    end
    a.bastion = bastion
    ask("Secrets Manager secret (id or ARN; empty = the RDS managed secret): ", a.secret, function(secret)
      a.secret = secret
      local prompt = "Database (empty = the secret's dbname, else the cluster's initial database, else postgres): "
      ask(prompt, a.database, function(database)
        a.database = database
        if not a.host then
          return cb(true)
        end
        ask("Database host: ", a.host, function(host)
          a.host = host or a.host
          cb(true)
        end)
      end)
    end)
  end)
end

---Settle the database of a new aws connection: nothing to store when the
---secret carries a dbname; otherwise ask, prefilled with the cluster's initial
---database (or postgres).
---@param aws_cfg dbgrid.AwsConfig
---@param info? table   parse_cluster / parse_instance result
---@param next_step fun(database?: string)
local function pick_database_name(aws_cfg, info, next_step)
  local secret_id = aws_cfg.secret or (info and info.secret_arn) or nil
  local function prompt(reason)
    ask("Database (" .. reason .. "): ", (info and info.database) or "postgres", next_step)
  end
  if not secret_id then
    return prompt("no secret to read it from")
  end
  M.secret(aws_cfg, secret_id, function(secret)
    if secret and secret.dbname then
      return next_step(nil)
    end
    prompt(secret and "the secret names none" or "the secret could not be read")
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
  ---The clusters and standalone instances of a region as picker items, plus
  ---the describe calls that failed (nil when both worked).
  ---@param aws_cfg dbgrid.AwsConfig
  ---@param cb fun(items: table[], failed?: { what: string, res: dbgrid.AwsCliResult }[])
  ---@param opts? { no_login?: boolean }
  local function list_databases(aws_cfg, cb, opts)
    local clusters, instances, placement, failed = {}, {}, {}, {}
    parallel({
      function(done)
        M.cli(aws_cfg, { "rds", "describe-db-clusters" }, function(res)
          if not res.ok then
            failed[#failed + 1] = { what = "listing clusters", res = res }
          end
          for _, c in ipairs(res.json and nz(res.json.DBClusters) or {}) do
            clusters[#clusters + 1] = c
          end
          done()
        end, opts)
      end,
      function(done)
        M.cli(aws_cfg, { "rds", "describe-db-instances" }, function(res)
          if not res.ok then
            failed[#failed + 1] = { what = "listing instances", res = res }
          end
          for _, i in ipairs(res.json and nz(res.json.DBInstances) or {}) do
            local cid = nz(i.DBClusterIdentifier)
            if cid then
              -- cluster members tell the VPC and exposure of their cluster
              placement[cid] = placement[cid] or {}
              placement[cid].vpc = placement[cid].vpc or (nz(i.DBSubnetGroup) and nz(i.DBSubnetGroup.VpcId)) or nil
              placement[cid].public = placement[cid].public or nz(i.PubliclyAccessible) == true
            else
              instances[#instances + 1] = i
            end
          end
          done()
        end, opts)
      end,
    }, function()
      local items = {}
      for _, c in ipairs(clusters) do
        local where = placement[c.DBClusterIdentifier] or {}
        items[#items + 1] = {
          kind = "cluster",
          id = c.DBClusterIdentifier,
          raw = c,
          region = aws_cfg.region,
          vpc = where.vpc,
          public = where.public,
        }
      end
      for _, i in ipairs(instances) do
        items[#items + 1] = {
          kind = "instance",
          id = i.DBInstanceIdentifier,
          raw = i,
          region = aws_cfg.region,
          vpc = nz(i.DBSubnetGroup) and nz(i.DBSubnetGroup.VpcId) or nil,
          public = nz(i.PubliclyAccessible) == true,
        }
      end
      cb(items, #failed > 0 and failed or nil)
    end)
  end
  ---The region is empty: look through the account's other regions (a database
  ---created in a region other than the profile's default is easy to miss).
  ---Regions a service control policy denies are skipped silently.
  ---@param aws_cfg dbgrid.AwsConfig
  ---@param cb fun(items: table[])
  local function scan_regions(aws_cfg, cb)
    M.cli(aws_cfg, { "ec2", "describe-regions", "--query", "Regions[].RegionName" }, function(res)
      local regions = {}
      for _, r in ipairs(res.ok and res.json or M.DEFAULT_REGIONS) do
        if r ~= aws_cfg.region then
          regions[#regions + 1] = r
        end
      end
      local found = {}
      local fns = {}
      for _, r in ipairs(regions) do
        fns[#fns + 1] = function(done)
          local there = vim.tbl_extend("force", aws_cfg, { region = r })
          list_databases(there, function(items)
            vim.list_extend(found, items)
            done()
          end, { no_login = true })
        end
      end
      parallel(fns, function()
        table.sort(found, function(a, b)
          return a.region < b.region or (a.region == b.region and a.id < b.id)
        end)
        cb(found)
      end)
    end)
  end
  local function pick_database(aws_cfg, next_step)
    local function offer(items, elsewhere)
      items[#items + 1] = { kind = "host", id = "by host", raw = {} }
      vim.ui.select(items, {
        prompt = "RDS cluster / instance",
        format_item = function(item)
          if item.kind == "host" then
            return "other: reach the database by host name (PrivateLink endpoint, another account)"
          end
          local status = nz(item.raw.Status) or nz(item.raw.DBInstanceStatus) or ""
          local where = elsewhere and (item.region .. "  ") or ""
          return where .. item.kind .. " " .. item.id .. "  " .. status
        end,
      }, next_step)
    end
    list_databases(aws_cfg, function(items, failed)
      for _, f in ipairs(failed or {}) do
        util.warn("dbgrid: " .. cli_error(aws_cfg, f.what, f.res))
      end
      if #items > 0 or failed then
        return offer(items)
      end
      local where = "profile " .. profile_of(aws_cfg) .. " in " .. (aws_cfg.region or "the default region")
      util.notify("dbgrid: no RDS clusters or instances visible to " .. where .. "; looking in the other regions")
      scan_regions(aws_cfg, function(found)
        if #found == 0 then
          util.warn("dbgrid: no RDS clusters or instances visible to " .. where .. " or any other region")
        end
        offer(found, true)
      end)
    end)
  end
  ---Finish a connection: bastion, database (when the secret names none) and name, then save.
  ---@param aws_cfg dbgrid.AwsConfig
  ---@param info? table
  ---@param hints table   pick_bastion hints
  ---@param id string     what the url and the default name are built from
  local function finish(aws_cfg, info, hints, id, default_name)
    M.pick_bastion(aws_cfg, hints, function(bastion, cancelled)
      if cancelled then
        return cancel()
      end
      aws_cfg.bastion = bastion
      pick_database_name(aws_cfg, info, function(database)
        aws_cfg.database = database
        ask("Connection name: ", default_name or id, function(name)
          if not name then
            return cancel()
          end
          local conn = {
            name = name,
            url = "aws://" .. profile_of(aws_cfg) .. "/" .. id,
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
  end
  ---A database reached by host: the secret carries host / port / db, or they are asked.
  ---@param aws_cfg dbgrid.AwsConfig
  local function add_by_host(aws_cfg)
    ask("Secrets Manager secret (id or ARN) with the database credentials: ", nil, function(secret_id)
      if not secret_id then
        return cancel()
      end
      aws_cfg.secret = secret_id
      aws_cfg.auth = "secret"
      M.secret(aws_cfg, secret_id, function(secret, err)
        if not secret then
          util.warn("dbgrid: " .. tostring(err))
        end
        local function with_host(host)
          if not host then
            return cancel()
          end
          if not (secret and secret.host == host) then
            aws_cfg.host = host -- not in the secret: keep it in the block
          end
          finish(aws_cfg, nil, {}, host, secret and secret.dbname or nil)
        end
        if secret and secret.host then
          return with_host(secret.host)
        end
        ask("Database host (as reachable from the bastion): ", nil, with_host)
      end)
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
        if item.kind == "host" then
          return add_by_host(aws_cfg)
        end
        aws_cfg.region = item.region or aws_cfg.region
        aws_cfg[item.kind] = item.id
        local info = item.kind == "cluster" and M.parse_cluster({ DBClusters = { item.raw } })
          or M.parse_instance({ DBInstances = { item.raw } })
        if info then
          store_endpoints(aws_cfg, info)
        end
        local managed = info and info.secret_arn or nil
        ask("Secrets Manager secret (id or ARN): ", managed, function(secret)
          if secret and secret ~= managed then
            aws_cfg.secret = secret
          elseif not managed then
            util.warn('dbgrid: no secret given; set aws.secret (or aws.auth = "iam") before connecting')
          end
          aws_cfg.auth = "secret"
          finish(aws_cfg, info, { vpc = item.vpc, public = item.public }, item.id)
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
      report.error(label .. ": the aws block needs `cluster`, `instance`, `host` or a `secret` naming the host")
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
