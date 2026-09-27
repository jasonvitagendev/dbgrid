local H = _G.H
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local fake = root .. "/tests/fixtures/fake-aws"
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("dbgrid").setup({
  storage = { data_dir = tmp .. "/data", mode = "data" },
  aws = { cli = fake, login_cmd = { "aws", "sso", "login", "--profile", "{profile}" }, ssl = "require" },
})
local aws = require("dbgrid.aws")
local tunnel = require("dbgrid.tunnel")
local util = require("dbgrid.util")

local CLUSTER_JSON = [[
{
    "DBClusters": [
        {
            "AllocatedStorage": 1,
            "AvailabilityZones": ["ap-southeast-1a", "ap-southeast-1b"],
            "DBClusterIdentifier": "app-prod",
            "DBClusterParameterGroup": "default.aurora-postgresql16",
            "Status": "available",
            "Endpoint": "app-prod.cluster-abc123.ap-southeast-1.rds.amazonaws.com",
            "ReaderEndpoint": "app-prod.cluster-ro-abc123.ap-southeast-1.rds.amazonaws.com",
            "MultiAZ": true,
            "Engine": "aurora-postgresql",
            "EngineVersion": "16.4",
            "Port": 5432,
            "MasterUsername": "postgres",
            "DBClusterMembers": [
                { "DBInstanceIdentifier": "app-prod-1", "IsClusterWriter": true, "PromotionTier": 1 },
                { "DBInstanceIdentifier": "app-prod-2", "IsClusterWriter": false, "PromotionTier": 1 }
            ],
            "DBClusterArn": "arn:aws:rds:ap-southeast-1:123456789012:cluster:app-prod",
            "MasterUserSecret": {
                "SecretArn": "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:rds!cluster-1-AbCdEf",
                "SecretStatus": "active",
                "KmsKeyId": "arn:aws:kms:ap-southeast-1:123456789012:key/x"
            },
            "DeletionProtection": true
        }
    ]
}
]]

local INSTANCE_JSON = [[
{
    "DBInstances": [
        {
            "DBInstanceIdentifier": "app-solo",
            "DBInstanceClass": "db.m6g.large",
            "Engine": "postgres",
            "DBInstanceStatus": "available",
            "MasterUsername": "postgres",
            "Endpoint": {
                "Address": "app-solo.abc123.ap-southeast-1.rds.amazonaws.com",
                "Port": 5432,
                "HostedZoneId": "Z1"
            },
            "EngineVersion": "16.3",
            "ReadReplicaDBInstanceIdentifiers": ["app-solo-r1", "app-solo-r2"],
            "PendingModifiedValues": {},
            "DBInstanceArn": "arn:aws:rds:ap-southeast-1:123456789012:db:app-solo",
            "MasterUserSecret": {
                "SecretArn": "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:x",
                "SecretStatus": "active"
            }
        }
    ]
}
]]

-- SecretString is itself a JSON document, as the real CLI returns it
local SECRET_JSON = vim.json.encode({
  ARN = "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:rds!cluster-1-AbCdEf",
  Name = "rds!cluster-1",
  VersionId = "0b1c2d3e",
  SecretString = '{"username":"app","password":"p@ss:w/rd","engine":"postgres","host":"h","port":5432,"dbname":"app"}',
  VersionStages = { "AWSCURRENT" },
  CreatedDate = "2026-09-01T00:00:00+00:00",
})

local EVENTS_JSON = [[
{
    "Events": [
        {
            "SourceIdentifier": "app-prod",
            "SourceType": "db-cluster",
            "Message": "Started failover",
            "EventCategories": ["failover"],
            "Date": "2026-09-26T01:02:03+00:00"
        },
        {
            "SourceIdentifier": "app-prod",
            "SourceType": "db-cluster",
            "Message": "Completed failover",
            "EventCategories": ["failover"],
            "Date": "2026-09-26T01:02:33+00:00"
        }
    ]
}
]]

local METRICS_JSON = [[
{
    "MetricDataResults": [
        {
            "Id": "m1",
            "Label": "CPUUtilization",
            "Timestamps": ["2026-09-27T00:04:00+00:00", "2026-09-27T00:03:00+00:00"],
            "Values": [12.5, 14.75],
            "StatusCode": "Complete"
        },
        {
            "Id": "m2",
            "Label": "FreeableMemory",
            "Timestamps": ["2026-09-27T00:04:00+00:00"],
            "Values": [8589934592],
            "StatusCode": "Complete"
        },
        { "Id": "m3", "Label": "ReplicaLag", "Timestamps": [], "Values": [], "StatusCode": "Complete" }
    ],
    "Messages": []
}
]]

local BLUEGREEN_JSON = [[
{
    "BlueGreenDeployments": [
        {
            "BlueGreenDeploymentIdentifier": "bgd-1", "BlueGreenDeploymentName": "upgrade", "Status": "AVAILABLE",
            "Source": "arn:src", "Target": "arn:tgt",
            "SwitchoverDetails": [
                { "SourceMember": "arn:src", "TargetMember": "arn:tgt", "Status": "AVAILABLE" },
                { "SourceMember": "arn:src-1", "TargetMember": "arn:tgt-1", "Status": "PROVISIONING" }
            ]
        },
        {
            "BlueGreenDeploymentIdentifier": "bgd-2", "Status": "PROVISIONING",
            "Source": "arn:s2", "Target": "arn:t2", "SwitchoverDetails": []
        }
    ]
}
]]

H.describe("aws parsers", function()
  H.it("parses a cluster", function()
    local info = aws.parse_cluster(CLUSTER_JSON)
    H.eq(info.id, "app-prod")
    H.eq(info.status, "available")
    H.eq(info.engine_version, "16.4")
    H.eq(info.writer, { host = "app-prod.cluster-abc123.ap-southeast-1.rds.amazonaws.com", port = 5432 })
    H.eq(info.reader, { host = "app-prod.cluster-ro-abc123.ap-southeast-1.rds.amazonaws.com", port = 5432 })
    H.eq(info.members, { { id = "app-prod-1", writer = true }, { id = "app-prod-2", writer = false } })
    H.eq(info.secret_arn, "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:rds!cluster-1-AbCdEf")
    H.eq(info.arn, "arn:aws:rds:ap-southeast-1:123456789012:cluster:app-prod")
    H.eq(aws.parse_cluster(vim.json.decode(CLUSTER_JSON)).id, "app-prod")
    local none, err = aws.parse_cluster('{"DBClusters": []}')
    H.eq(none, nil)
    H.matches(err, "no cluster")
    H.eq(aws.parse_cluster("not json"), nil)
  end)

  H.it("parses an instance", function()
    local info = aws.parse_instance(INSTANCE_JSON)
    H.eq(info.id, "app-solo")
    H.eq(info.status, "available")
    H.eq(info.engine_version, "16.3")
    H.eq(info.writer, { host = "app-solo.abc123.ap-southeast-1.rds.amazonaws.com", port = 5432 })
    H.eq(info.replicas, { "app-solo-r1", "app-solo-r2" })
    H.eq(info.source, nil)
    H.eq(info.secret_arn, "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:x")
    H.eq(info.pending_maintenance, nil)
    local replica = aws.parse_instance({
      DBInstances = {
        {
          DBInstanceIdentifier = "r1",
          DBInstanceStatus = "available",
          Endpoint = { Address = "r1.x", Port = 5433 },
          ReadReplicaSourceDBInstanceIdentifier = "app-solo",
          PendingModifiedValues = { AllocatedStorage = 200 },
        },
      },
    })
    H.eq(replica.source, "app-solo")
    H.eq(replica.replicas, {})
    H.eq(replica.writer.port, 5433)
    H.matches(replica.pending_maintenance, "AllocatedStorage")
  end)

  H.it("parses a secret", function()
    local s = aws.parse_secret(SECRET_JSON)
    H.eq(s, { username = "app", password = "p@ss:w/rd", host = "h", port = 5432, dbname = "app", engine = "postgres" })
    local managed = aws.parse_secret('{"SecretString": "{\\"username\\":\\"postgres\\",\\"password\\":\\"x\\"}"}')
    H.eq(managed.username, "postgres")
    H.eq(managed.dbname, nil)
    local bad, err = aws.parse_secret('{"SecretString": "{\\"foo\\":1}"}')
    H.eq(bad, nil)
    H.matches(err, "username/password")
    H.eq(aws.parse_secret('{"SecretBinary": "AAAA"}'), nil)
  end)

  H.it("parses events newest first", function()
    local rows = aws.parse_events(EVENTS_JSON)
    H.eq(rows, {
      { "2026-09-26T01:02:33+00:00", "app-prod", "Completed failover" },
      { "2026-09-26T01:02:03+00:00", "app-prod", "Started failover" },
    })
    H.eq(aws.parse_events('{"Events": []}'), {})
  end)

  H.it("parses metrics with last/min/max", function()
    local rows = aws.parse_metrics(METRICS_JSON)
    H.eq(rows[1], { "CPUUtilization", "12.5 %", "12.5 %", "14.8 %" })
    H.eq(rows[2], { "FreeableMemory", "8.00 GiB", "8.00 GiB", "8.00 GiB" })
    H.eq(rows[3], { "ReplicaLag", "n/a", "", "" })
  end)

  H.it("parses blue/green deployments per switchover member", function()
    local rows = aws.parse_bluegreen(BLUEGREEN_JSON)
    H.eq(rows, {
      { "upgrade", "AVAILABLE", "arn:src", "arn:tgt", "AVAILABLE" },
      { "upgrade", "AVAILABLE", "arn:src-1", "arn:tgt-1", "PROVISIONING" },
      { "bgd-2", "PROVISIONING", "arn:s2", "arn:t2", "" },
    })
  end)

  H.it("parses pending maintenance", function()
    local json = [[{"PendingMaintenanceActions": [{"ResourceIdentifier": "arn:x", "PendingMaintenanceActionDetails": [
      {"Action": "system-update", "Description": "New Operating System update",
       "CurrentApplyDate": "2026-10-01T00:00:00+00:00"}]}]}]]
    H.eq(aws.parse_pending_maintenance(json), "system-update by 2026-10-01T00:00:00+00:00")
    H.eq(aws.parse_pending_maintenance('{"PendingMaintenanceActions": []}'), nil)
  end)
end)

H.describe("aws helpers", function()
  H.it("recognises expired credentials", function()
    local yes = {
      "An error occurred (ExpiredToken) when calling the DescribeDBClusters operation: "
        .. "The security token included in the request is expired",
      "An error occurred (ExpiredTokenException) when calling ...",
      "Error when retrieving token from sso: Token has expired and refresh failed",
      "The SSO session associated with this profile has expired or is otherwise invalid. "
        .. "To refresh this SSO session run aws sso login with the corresponding profile.",
      "Unable to locate credentials. You can configure credentials by running \"aws configure\".",
      "An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation",
      "Error loading SSO Token: Token for https://x.awsapps.com/start does not exist",
      "please run: aws sso login",
    }
    for _, s in ipairs(yes) do
      H.truthy(aws.is_expired(s), "should be expired: " .. s)
    end
    H.falsy(aws.is_expired("An error occurred (DBClusterNotFoundFault): DBCluster x not found."))
    H.falsy(aws.is_expired(""))
    H.falsy(aws.is_expired(nil))
  end)

  H.it("builds the login command", function()
    H.eq(aws.login_argv({ profile = "prod" }), { "aws", "sso", "login", "--profile", "prod" })
    H.eq(aws.login_argv({ profile = "prod" }, { login_cmd = "granted sso login {profile}" }), {
      "granted",
      "sso",
      "login",
      "prod",
    })
    local per_conn = { profile = "prod", login_cmd = { "aws-vault", "login", "{profile}" } }
    H.eq(aws.login_argv(per_conn, { login_cmd = "x {profile}" }), { "aws-vault", "login", "prod" })
    H.eq(aws.login_argv({}), { "aws", "sso", "login", "--profile", "default" })
  end)

  H.it("builds the effective url", function()
    local creds = { username = "app@x", password = "secret", dbname = "my db" }
    local ep = { host = "db.internal", port = 5432 }
    local base = "postgres://app%40x@db.internal:5432/my%20db?"
    H.eq(
      aws.effective_url(creds, ep, 15432, { ssl = "verify-full", sslrootcert = "/tmp/rds.pem" }),
      base .. "hostaddr=127.0.0.1&port=15432&sslmode=verify-full&sslrootcert=%2ftmp%2frds.pem"
    )
    H.eq(aws.effective_url(creds, ep, 15432), base .. "hostaddr=127.0.0.1&port=15432&sslmode=require")
    H.eq(aws.effective_url(creds, ep, nil, { ssl = "disable" }), base .. "sslmode=disable")
    H.falsy(aws.effective_url(creds, ep, 1):find("secret", 1, true))
  end)

  H.it("expands a cluster into writer and reader", function()
    local conn = { name = "prod", aws = { profile = "p", region = "r", cluster = "app-prod", bastion = "i-1" } }
    local list = aws.expand(conn)
    H.eq(#list, 2)
    H.eq(list[1].name, "prod/writer")
    H.eq(list[1].aws_role, "writer")
    H.eq(list[1].readonly, nil)
    H.eq(list[1].url, "aws://p/app-prod/writer")
    H.eq(list[1].adapter, "postgres")
    H.eq(list[1].parent, "prod")
    H.eq(list[1].aws.bastion, "i-1")
    H.eq(list[2].name, "prod/reader")
    H.eq(list[2].aws_role, "reader")
    H.eq(list[2].readonly, true)
    H.eq(list[2].url, "aws://p/app-prod/reader")
    H.eq(aws.expand(conn, aws.parse_cluster(CLUSTER_JSON))[2].name, "prod/reader")
    -- an explicit readonly = false is respected on readers
    local rw = aws.expand({ name = "x", readonly = false, aws = { cluster = "c" } })
    H.eq(rw[2].readonly, false)
  end)

  H.it("expands an instance by its replicas", function()
    local conn = { name = "solo", adapter = "postgres", aws = { profile = "p", instance = "app-solo" } }
    local info = aws.parse_instance(INSTANCE_JSON)
    info.replica_endpoints = {
      { id = "app-solo-r1", host = "r1", port = 5432 },
      { id = "app-solo-r2", host = "r2", port = 5432 },
    }
    local names = vim.tbl_map(function(c)
      return c.name .. ":" .. c.aws_role
    end, aws.expand(conn, info))
    H.eq(names, { "solo/writer:writer", "solo/reader:reader", "solo/reader-2:reader-2" })
    info.replicas, info.replica_endpoints = {}, {}
    H.eq(#aws.expand(conn, info), 1)
    H.eq(#aws.expand(conn, nil), 2)
  end)

  H.it("picks endpoints by role", function()
    local info = aws.parse_cluster(CLUSTER_JSON)
    H.eq(aws.pick_endpoint(info, "writer"), info.writer)
    H.eq(aws.pick_endpoint(info, "reader"), info.reader)
    local _, err = aws.pick_endpoint(info, "reader-2")
    H.matches(err, "no reader endpoint")
    local inst = aws.parse_instance(INSTANCE_JSON)
    H.eq(select(2, aws.pick_endpoint(inst, "reader")), "connection has no reader endpoint")
    inst.replica_endpoints = { { id = "r1", host = "r1", port = 1 }, { id = "r2", host = "r2", port = 2 } }
    H.eq(aws.pick_endpoint(inst, "reader-2"), { host = "r2", port = 2 })
  end)

  H.it("reads the endpoint cache with a ttl", function()
    local a = { profile = "p", region = "r", cluster = "c" }
    H.eq(aws.cached_endpoints(a), nil)
    local path = tmp .. "/data/aws/endpoints.json"
    local fresh = { fetched_at = os.time() - 10, info = { id = "c", writer = { host = "h", port = 1 } } }
    util.write_json(path, { ["p|r|c"] = fresh })
    H.eq(aws.cached_endpoints(a).writer.host, "h")
    util.write_json(path, { ["p|r|c"] = { fetched_at = os.time() - 90000, info = { id = "c" } } })
    H.eq(aws.cached_endpoints(a), nil)
    aws.forget_endpoints(a)
    H.eq(util.read_json(path), vim.empty_dict())
  end)
end)

-- End to end through the fake CLI --------------------------------------------

local log = tmp .. "/aws.log"
vim.env.DBGRID_FAKE_AWS_LOG = log

local function log_count(needle)
  local n = 0
  for _, l in ipairs(util.lines(util.read_file(log) or "")) do
    if l:find(needle, 1, true) then
      n = n + 1
    end
  end
  return n
end

---Run an async fn(cb) synchronously; returns the callback's arguments.
local function sync(fn, timeout)
  local out
  fn(function(...)
    out = { ... }
  end)
  H.truthy(H.wait(timeout or 20000, function()
    return out ~= nil
  end), "callback never called")
  return unpack(out, 1, 3)
end

local test_url = os.getenv("DBGRID_TEST_URL")
local prod = {
  name = "prod",
  url = "aws://prod/app-prod",
  ssl = "disable",
  aws = { profile = "prod", region = "ap-southeast-1", cluster = "app-prod", bastion = "i-0123456789abcdef0" },
}

H.describe("aws resolve", function()
  H.it("resolves endpoints, credentials and a tunnel", function()
    local eff, err = sync(function(cb)
      aws.resolve(prod, cb)
    end)
    H.eq(err, nil)
    H.matches(eff.url, "hostaddr=127.0.0.1&port=%d+")
    H.matches(eff.url, "^postgres://postgres@db%.internal:%d+/dbgrid_test%?")
    H.matches(eff.url, "sslmode=disable")
    H.eq(eff.env.PGPASSWORD, "x")
    H.eq(eff.host, "db.internal")
    H.eq(eff.role, "writer")
    H.eq(eff.local_port, tonumber(eff.url:match("&port=(%d+)")))
    H.matches(eff.tunnel_key, "^ssm|prod|i%-0123456789abcdef0|db%.internal:%d+$")
    H.truthy(util.exists(tmp .. "/data/aws/endpoints.json"), "endpoint cache not written")
    H.eq(aws.cached_endpoints(prod.aws).writer.host, "db.internal")
    H.eq(log_count("describe-db-clusters --db-cluster-identifier app-prod"), 1)
    H.eq(log_count("secretsmanager get-secret-value"), 1)
    H.eq(log_count("ssm start-session --target i-0123456789abcdef0"), 1)
    H.matches(util.read_file(log), "localPortNumber=" .. eff.local_port)
    H.matches(util.read_file(log), "%-%-profile prod %-%-region ap%-southeast%-1")
    H.eq(#tunnel.list(), 1)
    H.eq(tunnel.list()[1].ok, true)
  end)

  H.it("reuses the cache, the credentials and the tunnel", function()
    local first = tunnel.list()[1]
    local eff, err = sync(function(cb)
      aws.resolve(prod, cb)
    end)
    H.eq(err, nil)
    H.eq(eff.local_port, first.port)
    H.eq(log_count("describe-db-clusters --db-cluster-identifier app-prod"), 1)
    H.eq(log_count("secretsmanager get-secret-value"), 1)
    H.eq(log_count("ssm start-session"), 1)
    H.eq(tunnel.list()[1].pid, first.pid)
  end)

  if test_url then
    H.it("runs a query through the effective url", function()
      local eff = sync(function(cb)
        aws.resolve(prod, cb)
      end)
      local pg = require("dbgrid.adapters.postgres")
      local result = sync(function(cb)
        pg.run({ name = "prod", url = eff.url, env = eff.env }, {
          { sql = "select 1", kind = "select", class = "read", line = 1 },
        }, {}, cb)
      end)
      H.eq(result.ok, true, vim.inspect(result.error))
      H.eq(result.statements[1].sets[1].rows, { { "1" } })
    end)
  else
    io.write("  skip aws query integration (DBGRID_TEST_URL not set)\n")
  end

  H.it("uses the reader endpoint for reader roles", function()
    local conn = vim.deepcopy(prod)
    conn.name, conn.aws_role, conn.readonly = "prod/reader", "reader", true
    local eff, err = sync(function(cb)
      aws.resolve(conn, cb)
    end)
    H.eq(err, nil)
    H.eq(eff.host, "db-ro.internal")
    H.eq(eff.role, "reader")
    H.matches(eff.url, "^postgres://postgres@db%-ro%.internal:")
    H.eq(#tunnel.list(), 2)
    H.eq(log_count("describe-db-clusters --db-cluster-identifier app-prod"), 1)
  end)

  H.it("connects directly without a bastion", function()
    local conn = vim.deepcopy(prod)
    conn.aws.bastion = nil
    conn.sslrootcert = "/tmp/rds.pem"
    local eff, err = sync(function(cb)
      aws.resolve(conn, cb)
    end)
    H.eq(err, nil)
    H.eq(eff.local_port, nil)
    H.eq(eff.tunnel_key, nil)
    H.matches(eff.url, "^postgres://postgres@db%.internal:%d+/dbgrid_test%?sslmode=disable&sslrootcert=")
    H.matches(eff.url, "&sslrootcert=%%2ftmp%%2frds%.pem$")
    H.eq(#tunnel.list(), 2)
  end)

  H.it("describes replicas of an instance and resolves reader-N", function()
    local conn = {
      name = "solo",
      url = "aws://prod/app-solo",
      ssl = "disable",
      aws = { profile = "prod", instance = "app-solo" },
    }
    local info, err = sync(function(cb)
      aws.endpoints(conn.aws, cb)
    end)
    H.eq(err, nil)
    H.eq(info.replicas, { "app-solo-r1", "app-solo-r2" })
    H.eq(#info.replica_endpoints, 2)
    H.eq(info.replica_endpoints[2].id, "app-solo-r2")
    H.eq(log_count("describe-db-instances --db-instance-identifier app-solo-r2"), 1)
    local names = vim.tbl_map(function(c)
      return c.name
    end, aws.expand(conn, aws.cached_endpoints(conn.aws)))
    H.eq(names, { "solo/writer", "solo/reader", "solo/reader-2" })
    conn.aws_role = "reader-2"
    local eff, rerr = sync(function(cb)
      aws.resolve(conn, cb)
    end)
    H.eq(rerr, nil)
    H.matches(eff.host, "^app%-solo%-r2%.")
    conn.aws_role = "reader-3"
    local _, e3 = sync(function(cb)
      aws.resolve(conn, cb)
    end)
    H.matches(e3, "no reader endpoint")
  end)

  H.it("reports missing configuration in plain words", function()
    local _, err = sync(function(cb)
      aws.resolve({ name = "x", aws = { profile = "prod" } }, cb)
    end)
    H.matches(err, "needs `cluster` or `instance`")
    _, err = sync(function(cb)
      aws.resolve({ name = "x" }, cb)
    end)
    H.matches(err, "has no aws block")
    _, err = sync(function(cb)
      aws.resolve({ name = "x", aws = { profile = "prod", cluster = "nope" } }, cb)
    end)
    H.matches(err, "describing cluster nope failed: .*DBClusterNotFoundFault")
    _, err = sync(function(cb)
      local iam = { profile = "prod", cluster = "app-prod", auth = "iam" }
      aws.credentials(iam, { writer = { host = "h", port = 1 } }, cb)
    end)
    H.matches(err, "iam auth needs `user`")
  end)

  H.it("generates iam tokens", function()
    local a = {
      profile = "prod",
      region = "ap-southeast-1",
      cluster = "app-prod",
      auth = "iam",
      user = "iam_user",
      database = "app",
    }
    local creds, err = sync(function(cb)
      aws.credentials(a, { writer = { host = "db.internal", port = 5432 } }, cb)
    end)
    H.eq(err, nil)
    H.eq(creds.username, "iam_user")
    H.eq(creds.dbname, "app")
    H.matches(creds.password, "^db%.internal:5432/%?Action=connect&DBUser=iam_user")
    H.truthy(creds.token_expires > os.time() + 600)
    H.eq(log_count("rds generate-db-auth-token --hostname db.internal --port 5432 --username iam_user"), 1)
    sync(function(cb)
      aws.credentials(a, { writer = { host = "db.internal", port = 5432 } }, cb)
    end)
    H.eq(log_count("generate-db-auth-token"), 1, "token should be cached")
    aws.forget_credentials(a)
    sync(function(cb)
      aws.credentials(a, { writer = { host = "db.internal", port = 5432 } }, cb)
    end)
    H.eq(log_count("generate-db-auth-token"), 2)
  end)
end)

H.describe("aws views", function()
  H.it("status combines describe, maintenance and metrics", function()
    local rows, columns, err = sync(function(cb)
      aws.status(prod, cb)
    end)
    H.eq(err, nil)
    H.eq(columns, { "item", "last", "min", "max" })
    H.eq(rows[1], { "status", "available", "", "" })
    H.eq(rows[2], { "engine", "aurora-postgresql 16.4", "", "" })
    H.matches(rows[3][2], "^db%.internal:%d+$")
    H.eq(rows[4][1], "reader")
    H.eq(rows[5], { "members", "app-prod-1 (writer), app-prod-2", "", "" })
    H.eq(rows[6], { "pending maintenance", "none", "", "" })
    local by_name = {}
    for _, r in ipairs(rows) do
      by_name[r[1]] = r
    end
    H.eq(by_name.CPUUtilization, { "CPUUtilization", "12.5 %", "11.0 %", "14.8 %" })
    H.eq(by_name.DatabaseConnections, { "DatabaseConnections", "42", "40", "45" })
    H.eq(by_name.VolumeBytesUsed[2], "100.00 GiB")
    H.eq(by_name.AuroraReplicaLag, { "AuroraReplicaLag", "20 ms", "18 ms", "25 ms" })
    H.eq(log_count("describe-pending-maintenance-actions --resource-identifier arn:aws:rds:"), 1)
    H.eq(log_count("cloudwatch get-metric-data"), 1)
    H.matches(util.read_file(log), '"Namespace":"AWS/RDS"')
    -- vim.json.encode does not order keys, so check the dimension name and value separately
    H.matches(util.read_file(log), '"Name":"DBClusterIdentifier"')
    H.matches(util.read_file(log), '"Value":"app%-prod"')
    H.eq(log_count("describe-db-clusters --db-cluster-identifier app-prod"), 2, "status must refresh the description")
  end)

  H.it("lists events and blue/green deployments", function()
    local rows, columns, err = sync(function(cb)
      aws.events(prod, cb)
    end)
    H.eq(err, nil)
    H.eq(columns, { "date", "source", "message" })
    H.eq(#rows, 2)
    H.matches(rows[1][3], "^Completed failover")
    H.eq(log_count("describe-events --source-identifier app-prod --source-type db-cluster --duration 1440"), 1)
    rows, columns, err = sync(function(cb)
      aws.bluegreen(prod, cb)
    end)
    H.eq(err, nil)
    H.eq(columns, { "deployment", "status", "source", "target", "member_status" })
    H.eq(#rows, 2)
    H.eq(rows[1][1], "app-prod-upgrade")
    local _, _, e = sync(function(cb)
      aws.events({ name = "x" }, cb)
    end)
    H.matches(e, "has no aws block")
  end)
end)

H.describe("aws cli", function()
  H.it("logs in and retries when credentials have expired", function()
    local marker = tmp .. "/logged-in"
    vim.env.DBGRID_FAKE_AWS_EXPIRED_UNTIL = marker
    local a = { profile = "prod", cli = fake, login_cmd = { "touch", marker } }
    local res = sync(function(cb)
      aws.cli(a, { "sts", "get-caller-identity" }, cb)
    end)
    H.eq(res.ok, true, res.stderr)
    H.eq(res.json.Account, "123456789012")
    H.truthy(util.exists(marker), "login command did not run")
    H.eq(log_count("sts get-caller-identity --output json --profile prod"), 2)
    -- no_login: report the expiry instead
    os.remove(marker)
    res = sync(function(cb)
      aws.cli(a, { "sts", "get-caller-identity" }, cb, { no_login = true })
    end)
    H.eq(res.ok, false)
    H.eq(res.expired, true)
    H.falsy(util.exists(marker))
    vim.env.DBGRID_FAKE_AWS_EXPIRED_UNTIL = nil
  end)

  H.it("reports a missing executable and text output", function()
    local res = sync(function(cb)
      aws.cli({ cli = tmp .. "/no-such-aws" }, { "sts", "get-caller-identity" }, cb)
    end)
    H.eq(res.ok, false)
    H.eq(res.stderr, "aws CLI not found on PATH")
    res = sync(function(cb)
      aws.cli({ profile = "prod" }, { "configure", "list-profiles" }, cb, { text = true })
    end)
    H.eq(res.ok, true)
    H.eq(res.json, nil)
    H.eq(res.stdout, "default\nprod\nstaging\n")
    H.eq(log_count("configure list-profiles --profile prod"), 1)
  end)
end)

H.describe("aws add_interactive", function()
  H.it("walks through the prompts and saves the connection", function()
    local select_prompts, input_prompts = {}, {}
    local orig_select, orig_input = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, opts, on_choice)
      select_prompts[#select_prompts + 1] = opts.prompt
      if opts.format_item then
        for _, item in ipairs(items) do
          opts.format_item(item)
        end
      end
      local pick = items[1]
      for _, item in ipairs(items) do
        if item == "prod" or (type(item) == "table" and item.id == "app-prod") then
          pick = item
        end
      end
      vim.schedule(function()
        on_choice(pick, 1)
      end)
    end
    vim.ui.input = function(opts, on_confirm)
      input_prompts[#input_prompts + 1] = opts.prompt
      local answer = opts.default
      if opts.prompt:find("SSM target") then
        answer = "i-0bastion"
      end
      vim.schedule(function()
        on_confirm(answer or "")
      end)
    end
    local conn = sync(function(cb)
      aws.add_interactive(cb)
    end)
    vim.ui.select, vim.ui.input = orig_select, orig_input
    H.truthy(conn, "no connection returned")
    H.eq(conn.name, "app-prod")
    H.eq(conn.url, "aws://prod/app-prod")
    H.eq(conn.adapter, "postgres")
    H.eq(conn.aws.profile, "prod")
    H.eq(conn.aws.region, "ap-southeast-1")
    H.eq(conn.aws.cluster, "app-prod")
    H.eq(conn.aws.instance, nil)
    H.eq(conn.aws.bastion, "i-0bastion", "the one online jumpbox in the database's VPC is taken without asking")
    H.eq(conn.aws.secret, nil, "the managed secret needs no explicit id")
    H.eq(conn.aws.auth, "secret")
    H.eq(select_prompts, { "AWS profile", "RDS cluster / instance" })
    H.eq(#input_prompts, 3)
    H.matches(input_prompts[1], "region")
    for _, prompt in ipairs(input_prompts) do
      H.falsy(prompt:find("SSM target"), "the bastion must not be asked for")
    end
    H.eq(log_count("ssm describe-instance-information"), 1)
    H.eq(log_count("ec2 describe-instances --filters Name=instance-state-name,Values=running"), 1)
    H.eq(log_count("configure get region --profile prod"), 1)
    H.truthy(aws.cached_endpoints(conn.aws), "endpoints from the picker should be cached")
    local saved = util.read_json(tmp .. "/data/connections.json")
    H.eq(saved.connections[#saved.connections].name, "app-prod")
  end)
end)

H.describe("aws bastions", function()
  H.it("parses ssm + ec2 into candidates and ranks jumpboxes first", function()
    local ssm = {
      InstanceInformationList = {
        { InstanceId = "i-web", PingStatus = "Online" },
        { InstanceId = "i-jump", PingStatus = "Online" },
        { InstanceId = "i-old", PingStatus = "ConnectionLost", ComputerName = "ip-10-9-9-9" },
        { InstanceId = "mi-hybrid", PingStatus = "Online", Name = "office-bastion" },
      },
    }
    local ec2 = {
      Reservations = {
        {
          Instances = {
            {
              InstanceId = "i-web",
              VpcId = "vpc-a",
              PrivateIpAddress = "10.0.2.20",
              Tags = { { Key = "Name", Value = "web-1" } },
            },
            {
              InstanceId = "i-jump",
              VpcId = "vpc-a",
              Tags = { { Key = "env", Value = "prod" }, { Key = "Name", Value = "Jump-Host" } },
            },
            { InstanceId = "i-old", VpcId = "vpc-b", Tags = { { Key = "Name", Value = "bastion-legacy" } } },
            { InstanceId = "i-notssm", VpcId = "vpc-a", Tags = { { Key = "Name", Value = "bastion-noagent" } } },
          },
        },
      },
    }
    local list = aws.parse_bastions(ssm, ec2)
    H.eq(#list, 4, "only ssm-managed instances are candidates")
    local by_id = {}
    for _, c in ipairs(list) do
      by_id[c.id] = c
    end
    H.eq(by_id["i-jump"].name, "Jump-Host")
    H.eq(by_id["i-jump"].vpc, "vpc-a")
    H.eq(by_id["i-old"].online, false)
    H.eq(by_id["mi-hybrid"].name, "office-bastion")
    H.eq(by_id["i-web"].ip, "10.0.2.20")
    H.eq(by_id["i-old"].name, "bastion-legacy")
    -- names win, the database's vpc breaks ties, offline instances sort last
    local ranked = aws.rank_bastions(list, { vpc = "vpc-a" })
    H.eq(ranked[1].id, "i-jump")
    H.truthy(ranked[1].match)
    H.eq(ranked[1].why, { "name", "same vpc" })
    H.eq(ranked[2].id, "mi-hybrid")
    H.eq(ranked[3].id, "i-web")
    H.falsy(ranked[3].match)
    H.eq(ranked[4].id, "i-old")
    H.eq(ranked[4].why, { "name", "offline" })
    -- the current bastion (by id or by name) comes first whatever it is called
    H.eq(aws.rank_bastions(list, { current = "i-web" })[1].id, "i-web")
    H.eq(aws.rank_bastions(list, { current = "web-1" })[1].why, { "current" })
    -- aws.bastion_names can be overridden
    H.eq(aws.rank_bastions(list, { patterns = { "web" } })[1].id, "i-web")
    -- names only from ssm when ec2 is unavailable
    local ssm_only = {}
    for _, c in ipairs(aws.parse_bastions(ssm)) do
      ssm_only[c.id] = c.name
    end
    H.eq(ssm_only, { ["i-old"] = "ip-10-9-9-9", ["mi-hybrid"] = "office-bastion" })
    local _, err = aws.parse_bastions("not json")
    H.matches(err, "did not return JSON")
    H.truthy(aws.is_instance_id("i-0123456789abcdef0"))
    H.truthy(aws.is_instance_id("mi-0123456789abcdef0"))
    H.falsy(aws.is_instance_id("bastion-prod"))
    H.falsy(aws.is_instance_id("auto"))
    H.falsy(aws.is_instance_id(nil))
  end)

  H.it("resolves a bastion by its Name tag or auto, and caches the id", function()
    local ec2_before = log_count("ec2 describe-instances")
    local conn = vim.deepcopy(prod)
    conn.name = "prod-by-name"
    conn.aws.bastion = "bastion-prod"
    local eff, err = sync(function(cb)
      aws.resolve(conn, cb)
    end)
    H.eq(err, nil)
    H.matches(eff.tunnel_key, "^ssm|prod|i%-0bastion|db%.internal:%d+$")
    H.eq(aws.cached_bastion(conn.aws), "i-0bastion")
    H.eq(log_count("ec2 describe-instances"), ec2_before + 1)
    -- the second resolve reads the cached id
    eff, err = sync(function(cb)
      aws.resolve(vim.deepcopy(conn), cb)
    end)
    H.eq(err, nil)
    H.matches(eff.tunnel_key, "i%-0bastion")
    H.eq(log_count("ec2 describe-instances"), ec2_before + 1)
    -- the cache is keyed by name and dropped with the endpoints
    local auto = { profile = "prod", region = "ap-southeast-1", cluster = "app-prod", bastion = "auto" }
    H.eq(aws.cached_bastion(auto), nil)
    local id, aerr = sync(function(cb)
      aws.bastion_id(auto, {}, cb)
    end)
    H.eq(aerr, nil)
    H.eq(id, "i-0bastion", "jumpbox-legacy matches too but is offline")
    H.eq(aws.cached_bastion(auto), "i-0bastion")
    aws.forget_bastion(auto)
    H.eq(aws.cached_bastion(auto), nil)
    -- `aws refresh` (forget_endpoints) drops the looked-up bastion as well
    local other = { profile = "prod", region = "ap-southeast-1", cluster = "other", bastion = "bastion-prod" }
    H.eq(aws.cached_bastion(other), "i-0bastion", "the bastion cache is per name, not per database")
    aws.forget_endpoints(other)
    H.eq(aws.cached_bastion(conn.aws), nil)
    H.truthy(aws.cached_endpoints(conn.aws), "the endpoints of app-prod are untouched")
    -- instance ids pass through untouched; unknown names and offline instances are errors
    H.eq(
      sync(function(cb)
        aws.bastion_id({ profile = "prod", bastion = "i-0123456789abcdef0" }, {}, cb)
      end),
      "i-0123456789abcdef0"
    )
    local _, nerr = sync(function(cb)
      aws.bastion_id({ profile = "prod", bastion = "nope" }, {}, cb)
    end)
    H.matches(nerr, "no SSM%-managed instance named nope for profile prod")
    local _, oerr = sync(function(cb)
      aws.bastion_id({ profile = "prod", bastion = "jumpbox-legacy" }, {}, cb)
    end)
    H.matches(oerr, "jumpbox%-legacy %(i%-0oldjump%) is not online")
  end)

  H.it("edit offers the current bastion, the candidates and a direct option", function()
    local items_seen
    local orig_select, orig_input = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, opts, on_choice)
      items_seen = vim.tbl_map(function(i)
        return opts.format_item(i)
      end, items)
      vim.schedule(function()
        on_choice(items[3], 3)
      end)
    end
    vim.ui.input = function(opts, on_confirm)
      vim.schedule(function()
        on_confirm(opts.default or "")
      end)
    end
    local draft = {
      name = "prod",
      aws = {
        profile = "prod",
        region = "ap-southeast-1",
        cluster = "app-prod",
        bastion = "i-0web",
        secret = "prod/db",
      },
    }
    local ok = sync(function(cb)
      aws.edit_interactive(draft, cb)
    end)
    vim.ui.select, vim.ui.input = orig_select, orig_input
    H.truthy(ok)
    H.eq(items_seen, {
      "keep i-0web",
      "i-0web  web-1  online  (current)",
      "i-0bastion  bastion-prod  online",
      "i-0oldjump  jumpbox-legacy  offline",
      "connect directly (no bastion)",
      "type an instance id",
    })
    H.eq(draft.aws.bastion, "i-0bastion")
    H.eq(draft.aws.secret, "prod/db", "the secret prompt is prefilled")
  end)
end)

H.describe("aws health", function()
  H.it("reports the cli, the plugin and every aws connection", function()
    require("dbgrid.config").setup({
      storage = { data_dir = tmp .. "/data", mode = "data" },
      aws = { cli = fake },
      connections = { prod, { name = "plain", url = "postgres://localhost/x" } },
    })
    local msgs = {}
    local function collect(level)
      return function(msg)
        msgs[#msgs + 1] = level .. ": " .. msg
      end
    end
    aws.health({ ok = collect("ok"), warn = collect("warn"), error = collect("error"), info = collect("info") })
    local text = table.concat(msgs, "\n")
    H.matches(text, "ok: aws CLI: aws%-cli/2%.17%.0")
    H.matches(text, "warn: session%-manager%-plugin not found")
    H.matches(text, "info: prod %(prod/app%-prod%): endpoints cached")
    H.matches(text, "ok: prod %(prod/app%-prod%): credentials ok %(arn:aws:sts::123456789012")
    H.falsy(text:find("plain", 1, true))
  end)
end)

tunnel.kill_all()
