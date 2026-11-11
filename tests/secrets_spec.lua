local H = _G.H
local secrets = require("dbgrid.secrets")
local cells = require("dbgrid.cells")

local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

H.describe("secrets.parse", function()
  H.it("reads a secret id with the password key by default", function()
    local s = secrets.parse("prod/db")
    H.eq(s.id, "prod/db")
    H.eq(s.key, "password")
    H.eq(s.conninfo, false)
  end)
  H.it("reads another key after #", function()
    local s = secrets.parse("arn:aws:secretsmanager:ap-southeast-2:1:secret:prod/api-AbCdEf#api_key")
    H.eq(s.id, "arn:aws:secretsmanager:ap-southeast-2:1:secret:prod/api-AbCdEf")
    H.eq(s.key, "api_key")
  end)
  H.it("reads a conninfo spec with extra keywords", function()
    local s = secrets.parse("conninfo:prod/db sslmode=verify-full application_name=migration")
    H.eq(s.conninfo, true)
    H.eq(s.id, "prod/db")
    H.eq(s.extras, { { k = "sslmode", v = "verify-full" }, { k = "application_name", v = "migration" } })
  end)
  H.it("reads scram: and via, a connection name keeping its spaces", function()
    local s = secrets.parse("scram:prod/db#pw via app-db (prod)")
    H.eq(s.id, "prod/db")
    H.eq(s.key, "pw")
    H.eq(s.scram, true)
    H.eq(s.via, "app-db (prod)")
    local c = secrets.parse("conninfo:prod/db sslmode=verify-full via other")
    H.eq(c.conninfo, true)
    H.eq(c.extras, { { k = "sslmode", v = "verify-full" } })
    H.eq(c.via, "other")
    H.eq(secrets.parse("prod/db").via, nil)
    H.eq(secrets.parse("scram:conninfo:prod/db"), nil)
  end)
  H.it("rejects empty and malformed specs", function()
    H.eq(secrets.parse(""), nil)
    H.eq(secrets.parse("conninfo:prod/db notakeyvalue"), nil)
    H.eq(secrets.parse("two words"), nil)
  end)
end)

H.describe("secrets.declared", function()
  H.it("lists the @secret lines of a cell in order", function()
    local b = buf_with({
      "-- %% [ab12] subscribe",
      "-- @secret conn = conninfo:acme/infra/db-replication",
      "-- @secret token = prod/api#api_key",
      "-- @param days = 3",
      "create subscription s connection :conn publication p;",
    })
    local c = cells.parse(b)[1]
    H.eq(secrets.declared(c), {
      { name = "conn", spec = "conninfo:acme/infra/db-replication" },
      { name = "token", spec = "prod/api#api_key" },
    })
  end)
end)

H.describe("secrets.value", function()
  local secret = {
    username = "candix_replication_user",
    password = "p'w d",
    host = "rds.mini.example",
    port = "5432",
    dbname = "jobs",
    engine = "postgres",
  }
  H.it("quotes one key as a SQL literal", function()
    local spec = secrets.parse("x")
    H.eq(secrets.sql_literal(secrets.value(spec, secret)), "'p''w d'")
  end)
  H.it("builds a conninfo with quoted values and sslmode=require", function()
    local spec = secrets.parse("conninfo:x")
    H.eq(
      secrets.value(spec, secret),
      "host=rds.mini.example port=5432 dbname=jobs user=candix_replication_user password='p\\'w d' sslmode=require"
    )
  end)
  H.it("lets extras override and extend the conninfo", function()
    local spec = secrets.parse("conninfo:x sslmode=verify-full dbname=other")
    H.eq(
      secrets.value(spec, secret),
      "host=rds.mini.example port=5432 user=candix_replication_user password='p\\'w d' sslmode=verify-full dbname=other"
    )
  end)
  H.it("falls back to a plain-text secret for the password key", function()
    H.eq(secrets.value(secrets.parse("x"), { value = "plain" }), "plain")
    local v, err = secrets.value(secrets.parse("x#nope"), { value = "plain" })
    H.eq(v, nil)
    H.matches(err, "no 'nope' key")
  end)
end)

H.describe("scram", function()
  local scram = require("dbgrid.scram")
  local function hex(x)
    return (x:gsub(".", function(c)
      return ("%02x"):format(c:byte())
    end))
  end
  -- salt of the RFC 7677 example, base64 W22ZaJ0SNY7soEsUEjb6gQ==
  local salt = "\91\109\153\104\157\18\53\142\236\160\75\20\18\54\250\129"
  H.it("hashes like the reference implementations", function()
    H.eq(hex(scram.sha256("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    H.eq(hex(scram.sha256(("a"):rep(119))), "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb")
    H.eq(hex(scram.hmac(("k"):rep(100), "msg")), "bd56a1782c2830e8abc6ed866a57a1230661e650b84c62f7ee3accc5fa5af491")
  end)
  H.it("builds the verifier PostgreSQL stores", function()
    H.eq(
      scram.verifier("pencil", { salt = salt }),
      "SCRAM-SHA-256$4096:W22ZaJ0SNY7soEsUEjb6gQ==$WG5d8oPm3OtcPnkdi4Uo7BkeZkBFzpcXkuLmtbsT4qY=:wfPLwcE6nTWhTAmQ7tl2KeoiWGPlZqQxSrmfPwDl2dU="
    )
  end)
  H.it("salts each verifier and refuses what it cannot hash faithfully", function()
    local a, b = scram.verifier("pw"), scram.verifier("pw")
    H.matches(a, "^SCRAM%-SHA%-256%$4096:")
    H.eq(a ~= b, true)
    H.eq(scram.verifier(""), nil)
    local v, err = scram.verifier("p\195\164ss")
    H.eq(v, nil)
    H.matches(err, "printable ASCII")
  end)
  H.it("is what a scram: secret resolves to, never the password", function()
    local v = secrets.value(secrets.parse("scram:x"), { password = "pencil" })
    H.matches(v, "^SCRAM%-SHA%-256%$4096:")
    H.eq(v:find("pencil", 1, true), nil)
  end)
end)

H.describe("secrets.redact", function()
  H.it("masks raw values in strings and nested tables", function()
    local raw = { "p'w d", "s3cr(et)" }
    H.eq(secrets.redact("password='p\\'w d'", raw), "password='p\\'w d'")
    H.eq(secrets.redact("LINE 1: ... password=p'w d sslmode", raw), "LINE 1: ... password=*** sslmode")
    local res =
      { error = { message = "bad s3cr(et) here" }, statements = { { sets = { { rows = { { "s3cr(et)" } } } } } } }
    secrets.redact_table(res, raw)
    H.eq(res.error.message, "bad *** here")
    H.eq(res.statements[1].sets[1].rows[1][1], "***")
  end)
end)

H.describe("secrets.resolve", function()
  H.it("refuses a connection without an aws block", function()
    local got
    secrets.resolve({ name = "local" }, { { name = "pw", spec = "x" } }, function(lit, raw, err)
      got = { lit, raw, err }
    end)
    H.eq(got[1], nil)
    H.matches(got[3], "needs an AWS connection")
  end)
  H.it("reads each secret through aws.secret_json and keeps the raw values apart", function()
    local aws = require("dbgrid.aws")
    local orig = aws.secret_json
    aws.secret_json = function(_, id, cb)
      if id == "a" then
        return cb({ username = "u", password = "pw", host = "h", port = "1", dbname = "d" })
      end
      cb({ api_key = "k" })
    end
    local got
    secrets.resolve({ name = "c", aws = { profile = "p" } }, {
      { name = "conn", spec = "conninfo:a" },
      { name = "key", spec = "b#api_key" },
    }, function(lit, raw, err)
      got = { lit, raw, err }
    end)
    aws.secret_json = orig
    H.eq(got[3], nil)
    H.eq(got[1].conn, "'host=h port=1 dbname=d user=u password=pw sslmode=require'")
    H.eq(got[1].key, "'k'")
    H.eq(got[2], { "host=h port=1 dbname=d user=u password=pw sslmode=require", "k" })
  end)
  H.it("reads a via secret through the named connection's aws block", function()
    local aws = require("dbgrid.aws")
    local connections = require("dbgrid.connections")
    local orig, orig_get = aws.secret_json, connections.get
    local used = {}
    aws.secret_json = function(cfg, id, cb)
      used[#used + 1] = cfg.profile .. ":" .. id
      cb({ password = "pw" })
    end
    connections.get = function(name)
      if name == "other acct" then
        return { name = name, aws = { profile = "q" } }
      elseif name == "plain" then
        return { name = name }
      end
    end
    local function run(conn, spec)
      local got
      secrets.resolve(conn, { { name = "pw", spec = spec } }, function(lit, raw, err)
        got = { lit, raw, err }
      end)
      return got
    end
    local ok = run({ name = "c", aws = { profile = "p" } }, "a via other acct")
    -- the cell's own connection needs no aws block when its secrets name another
    local local_conn = run({ name = "local" }, "a via other acct")
    local missing = run({ name = "c", aws = { profile = "p" } }, "a via nope")
    local no_aws = run({ name = "c", aws = { profile = "p" } }, "a via plain")
    aws.secret_json, connections.get = orig, orig_get
    H.eq(ok[1].pw, "'pw'")
    H.eq(local_conn[1].pw, "'pw'")
    H.eq(used, { "q:a", "q:a" })
    H.matches(missing[3], "no connection named 'nope'")
    H.matches(no_aws[3], "plain has none")
  end)
end)
