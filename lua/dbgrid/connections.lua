-- Connection registry: setup() connections, saved connections (data dir),
-- and DATABASE_URL-style variables found in the project's .env files.
--
-- A declared connection is what the user wrote (a url, or an `aws` / `tunnel`
-- block). `resolve()` turns it into an effective connection the adapter can
-- use: endpoints looked up, tunnel started, credentials fetched, password_cmd
-- run. Everything that spawns a client goes through resolve().
local util = require("dbgrid.util")
local config = require("dbgrid.config")
local project = require("dbgrid.project")
local adapters = require("dbgrid.adapters")

local M = {}

local function saved_path()
  return project.data_dir() .. "/connections.json"
end

---Path of the JSON file holding the saved connections.
---@return string
function M.saved_path()
  return saved_path()
end

---@return dbgrid.Connection[]
local function saved()
  local data = util.read_json(saved_path())
  return data and data.connections or {}
end

---@param list dbgrid.Connection[]
local function write_saved(list)
  util.write_json(saved_path(), { connections = list })
end

---Parse a dotenv file into a table.
---@param path string
---@return table<string,string>
function M.parse_env_file(path)
  local out = {}
  local text = util.read_file(path)
  if not text then
    return out
  end
  for _, line in ipairs(util.lines(text)) do
    line = line:gsub("^%s*export%s+", "")
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k and not line:match("^%s*#") then
      if v:match('^".*"$') then
        v = v:sub(2, -2):gsub("\\n", "\n")
      elseif v:match("^'.*'$") then
        v = v:sub(2, -2)
      else
        v = v:gsub("%s+#.*$", "")
      end
      out[k] = v
    end
  end
  return out
end

---Connections discovered from the environment and .env files.
---@param root string
---@return dbgrid.Connection[]
function M.discovered(root)
  local cfg = config.get()
  local out = {}
  local seen = {}
  for _, var in ipairs(cfg.env_vars or {}) do
    local v = os.getenv(var)
    if v and adapters.scheme(v) and not seen[v] then
      seen[v] = true
      out[#out + 1] = { name = var, url = v, source = "env" }
    end
  end
  for _, f in ipairs(cfg.env_files or {}) do
    local vars = M.parse_env_file(root .. "/" .. f)
    for _, var in ipairs(cfg.env_vars or {}) do
      local v = vars[var]
      if v then
        v = util.expand_env(v, vars)
        if adapters.scheme(v) and not seen[v] then
          seen[v] = true
          out[#out + 1] = { name = var .. " (" .. f .. ")", url = v, source = f }
        end
      end
    end
  end
  -- Rails: config/database.yml
  if not cfg.rails or cfg.rails.enabled ~= false then
    for _, c in ipairs(require("dbgrid.rails").connections(root, cfg.rails and cfg.rails.environments)) do
      if not seen[c.url] then
        seen[c.url] = true
        out[#out + 1] = c
      end
    end
  end
  return out
end

---Expand a declared connection into picker entries: an `aws` block becomes a
---writer and one or more readers; everything else is itself.
---@param c dbgrid.Connection
---@return dbgrid.Connection[]
local endpoint_memo = {} ---@type table<string, { at: number, info: table? }>

local function expand(c)
  if c.aws then
    local ok, aws = pcall(require, "dbgrid.aws")
    if ok then
      -- all() runs on every winbar redraw: read the endpoint cache at most every few seconds
      local key = table.concat({ c.aws.profile or "", c.aws.region or "", c.aws.cluster or c.aws.instance or "" }, "|")
      local memo = endpoint_memo[key]
      if not memo or util.now() - memo.at > 5 then
        memo = { at = util.now(), info = aws.cached_endpoints and aws.cached_endpoints(c.aws) or nil }
        endpoint_memo[key] = memo
      end
      local list = aws.expand(c, memo.info)
      if list and #list > 0 then
        return list
      end
    end
  end
  return { c }
end

---Every connection available to the project, in priority order.
---@param root? string
---@return dbgrid.Connection[]
function M.all(root)
  root = root or project.root()
  local out = {}
  local names = {}
  local function add(c, source)
    if c.name and (c.url or c.aws) and not names[c.name] then
      local copy = vim.deepcopy(c)
      if copy.url then
        copy.url = util.expand_env(copy.url)
      end
      copy.source = copy.source or source
      for _, e in ipairs(expand(copy)) do
        if not names[e.name] then
          names[e.name] = true
          out[#out + 1] = e
        end
      end
    end
  end
  for _, c in ipairs(config.get().connections or {}) do
    add(c, "setup")
  end
  for _, c in ipairs(saved()) do
    if not c.project or c.project == root then
      add(c, c.project and "project" or "saved")
    end
  end
  for _, c in ipairs(M.discovered(root)) do
    add(c, c.source)
  end
  return out
end

---@param name string
---@return dbgrid.Connection?
function M.get(name)
  if not name then
    return nil
  end
  for _, c in ipairs(M.all()) do
    if c.name == name then
      return c
    end
  end
  -- "prod" for an aws connection means its writer
  for _, c in ipairs(M.all()) do
    if c.parent == name and c.aws_role == "writer" then
      return c
    end
  end
end

---The connection new notebooks should use, if it can be decided without asking.
---@return dbgrid.Connection?
function M.default()
  local cfg = config.get()
  if cfg.default_connection then
    local c = M.get(cfg.default_connection)
    if c then
      return c
    end
  end
  local all = M.all()
  if #all == 1 then
    return all[1]
  end
  return nil
end

local SAVED_FIELDS = {
  "name",
  "url",
  "readonly",
  "index_check",
  "statement_timeout_ms",
  "lock_timeout_ms",
  "password_cmd",
  "adapter",
  "aws",
  "tunnel",
  "ssl",
  "sslrootcert",
  "ai",
  "env",
}

---Persist a connection (global, or bound to the current project).
---@param conn dbgrid.Connection
---@param scope "global"|"project"
function M.save(conn, scope)
  local list = saved()
  local copy = {}
  for _, k in ipairs(SAVED_FIELDS) do
    if conn[k] ~= nil and conn[k] ~= false then
      copy[k] = vim.deepcopy(conn[k])
    end
  end
  if conn.ai == false then
    copy.ai = false
  end
  copy.project = scope == "project" and project.root() or nil
  for i, c in ipairs(list) do
    if c.name == conn.name and (c.project or "") == (copy.project or "") then
      list[i] = copy
      write_saved(list)
      return
    end
  end
  list[#list + 1] = copy
  write_saved(list)
end

---Drop the saved entries with this name that are visible from the current
---project (global ones, and ones bound to this project), and the cached
---resolved form.
---@param name string
---@return boolean removed
function M.remove(name)
  local root = project.root()
  local list = saved()
  local out = {}
  local removed
  for _, c in ipairs(list) do
    if c.name == name and (not c.project or c.project == root) then
      removed = c
    else
      out[#out + 1] = c
    end
  end
  if removed then
    write_saved(out)
    M.refresh(removed)
  end
  return removed ~= nil
end

---The saved entry a connection name refers to, as stored (no `$VAR` expansion,
---no aws writer/reader expansion), plus its scope.
---@param name string
---@return dbgrid.Connection? entry, "global"|"project"? scope
function M.saved_entry(name)
  local root = project.root()
  for _, c in ipairs(saved()) do
    if c.name == name and (not c.project or c.project == root) then
      return c, c.project and "project" or "global"
    end
  end
  return nil
end

---Where a connection that cannot be edited here comes from, as a sentence.
---@param conn dbgrid.Connection
---@return string
function M.origin(conn)
  local name = conn.parent or conn.name
  local src = conn.source
  if src == "setup" then
    return name .. " comes from setup(): change it in your Neovim config"
  elseif src == "env" then
    return name .. " comes from the environment variable " .. name .. ": change it in your shell"
  elseif src == "config/database.yml" then
    return name .. " comes from config/database.yml: change it there"
  elseif src and src:match("^%.env") then
    return name .. " comes from " .. src .. ": change it there"
  end
  return name .. " is not a saved connection"
end

---Ask what to do with a password typed into a url: keep it, or move it to
---~/.pgpass and strip it from the url. Calls back with the url to store.
---@param url string
---@param cb fun(url: string)
local function offer_pgpass(url, cb)
  local user, pass, host, port, db = M.parse_url(util.expand_env(url))
  if not (pass and pass ~= "" and user and db) then
    return cb(url)
  end
  vim.ui.select({ "move it to ~/.pgpass", "keep it in the url" }, {
    prompt = "The url contains a password.",
  }, function(_, idx)
    if idx == 1 then
      M.save_pgpass(host or "*", port or "*", db, user, pass)
      util.notify("password written to ~/.pgpass")
      return cb((url:gsub("(://[^:/@]+):[^@]*@", "%1@", 1)))
    end
    cb(url)
  end)
end

local SCOPE_CHOICES = { "this project only", "everywhere", "read-only, this project only", "read-only, everywhere" }

---@param idx integer  index into SCOPE_CHOICES
---@return boolean readonly, "global"|"project" scope
local function scope_choice(idx)
  return idx >= 3, (idx == 1 or idx == 3) and "project" or "global"
end

---Point every open notebook that used `old` (or one of its aws roles) at `new`.
---@param old string
---@param new string
local function rename_in_notebooks(old, new)
  if old == new then
    return
  end
  for _, s in pairs(require("dbgrid.state").by_buf) do
    local cur = s.nb.meta.connection
    if cur == old or (cur and cur:sub(1, #old + 1) == old .. "/") then
      require("dbgrid.notebook").set_connection(s.nb, new .. cur:sub(#old + 1))
      require("dbgrid.ui.query").refresh_winbar(s)
    end
  end
end

---Interactive edit of a saved connection with every prompt prefilled: name,
---url (or, for an aws entry, bastion and secret), read-only and scope. A
---renamed connection is followed by the open notebooks that used it.
---@param conn dbgrid.Connection   a picker entry or a saved entry
---@param cb? fun(conn?: dbgrid.Connection)
function M.edit_interactive(conn, cb)
  cb = cb or function() end
  local name = conn.parent or conn.name
  local entry, scope = M.saved_entry(name)
  if not entry then
    util.warn(M.origin(conn))
    return cb(nil)
  end
  local draft = vim.deepcopy(entry)
  draft.project = nil
  local function finish()
    local choices = vim.deepcopy(SCOPE_CHOICES)
    local current = (entry.readonly and 2 or 0) + (scope == "project" and 1 or 2)
    choices[current] = choices[current] .. "  (current)"
    vim.ui.select(choices, { prompt = "Save connection" }, function(choice, idx)
      if not choice then
        return cb(nil)
      end
      local readonly, new_scope = scope_choice(idx)
      draft.readonly = readonly or nil
      -- drop the old entry first: the name or the scope may have changed
      local list = saved()
      for i, c in ipairs(list) do
        if c.name == entry.name and (c.project or "") == (entry.project or "") then
          table.remove(list, i)
          break
        end
      end
      write_saved(list)
      M.save(draft, new_scope)
      M.refresh(entry)
      M.refresh(draft)
      rename_in_notebooks(entry.name, draft.name)
      util.notify("saved connection " .. draft.name)
      cb(M.get(draft.name))
    end)
  end
  vim.ui.input({ prompt = "Connection name: ", default = entry.name }, function(new_name)
    if not new_name or util.trim(new_name) == "" then
      return cb(nil)
    end
    draft.name = util.trim(new_name)
    if draft.name ~= entry.name and M.get(draft.name) then
      util.error("a connection named " .. draft.name .. " already exists")
      return cb(nil)
    end
    if draft.aws then
      return require("dbgrid.aws").edit_interactive(draft, function(ok)
        if not ok then
          return cb(nil)
        end
        finish()
      end)
    end
    local url_prompt = "URL (postgres://user:pass@host:5432/db, sqlite:path/to.db or $DATABASE_URL): "
    vim.ui.input({ prompt = url_prompt, default = entry.url }, function(url)
      if not url or util.trim(url) == "" then
        return cb(nil)
      end
      url = util.trim(url)
      local a, err = adapters.for_connection({ name = draft.name, url = util.expand_env(url), adapter = draft.adapter })
      if not a then
        util.error(err or "unsupported url")
        return cb(nil)
      end
      offer_pgpass(url, function(stored)
        draft.url = stored
        finish()
      end)
    end)
  end)
end

---Ask, then remove a saved connection.
---@param conn dbgrid.Connection
---@param cb? fun(removed: boolean)
function M.remove_interactive(conn, cb)
  cb = cb or function() end
  local name = conn.parent or conn.name
  local entry = M.saved_entry(name)
  if not entry then
    util.warn(M.origin(conn))
    return cb(false)
  end
  local choice = vim.fn.confirm("Remove saved connection '" .. name .. "'?", "&Remove\n&Cancel", 2, "Warning")
  if choice ~= 1 then
    return cb(false)
  end
  M.remove(name)
  util.notify("removed connection " .. name)
  cb(true)
end

---Open connections.json in a buffer; saving it drops every cached resolved
---connection and the aws caches so the edits take effect on the next run.
function M.open_file()
  local path = saved_path()
  if not util.exists(path) then
    write_saved({})
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = buf,
    desc = "dbgrid: forget resolved connections after editing connections.json",
    callback = function()
      M.refresh()
    end,
  })
end

---Interactive add: name, url, scope.
---@param cb? fun(conn?: dbgrid.Connection)
function M.add_interactive(cb)
  vim.ui.input({ prompt = "Connection name: " }, function(name)
    if not name or name == "" then
      return cb and cb(nil)
    end
    local url_prompt = "URL (postgres://user:pass@host:5432/db, sqlite:path/to.db or $DATABASE_URL): "
    vim.ui.input({ prompt = url_prompt }, function(url)
      if not url or url == "" then
        return cb and cb(nil)
      end
      local conn = { name = name, url = url }
      local a, err = adapters.for_connection({ name = name, url = util.expand_env(url) })
      if not a then
        util.error(err or "unsupported url")
        return cb and cb(nil)
      end
      -- a password typed into the url is offered a home in ~/.pgpass instead
      offer_pgpass(url, function(stored)
        conn.url = stored
        vim.ui.select(SCOPE_CHOICES, { prompt = "Save connection" }, function(choice, idx)
          if not choice then
            return cb and cb(nil)
          end
          local readonly, scope = scope_choice(idx)
          conn.readonly = readonly or nil
          M.save(conn, scope)
          util.notify("saved connection " .. name)
          if cb then
            cb(M.get(name))
          end
        end)
      end)
    end)
  end)
end

---Split a postgres url into its parts (all optional).
---@param url string
---@return string? user, string? password, string? host, string? port, string? db, string? query
function M.parse_url(url)
  if type(url) ~= "string" then
    return nil
  end
  local rest = url:match("^[%w+]+://(.*)$")
  if not rest then
    return nil
  end
  local query
  rest, query = rest:match("^([^?]*)%??(.*)$")
  local auth, hostpart = rest:match("^(.-)@(.*)$")
  if not auth then
    auth, hostpart = nil, rest
  end
  local user, password
  if auth then
    user, password = auth:match("^([^:]*):?(.*)$")
    if password == "" then
      password = nil
    end
    user = user ~= "" and vim.uri_decode(user) or nil
    if password then
      password = vim.uri_decode(password)
    end
  end
  local hostport, db = hostpart:match("^([^/]*)/?(.*)$")
  local host, port = hostport:match("^%[?([^%]:]*)%]?:?(%d*)$")
  if host == "" then
    host = nil
  end
  if port == "" then
    port = nil
  end
  if db == "" then
    db = nil
  end
  return user, password, host, port, db, query ~= "" and query or nil
end

---Append a line to ~/.pgpass (mode 600).
function M.save_pgpass(host, port, db, user, password)
  local path = os.getenv("PGPASSFILE") or (vim.env.HOME .. "/.pgpass")
  local function esc(s)
    return (tostring(s):gsub("[\\:]", "\\%0"))
  end
  local line = table.concat({ esc(host), esc(port), esc(db), esc(user), esc(password) }, ":")
  local existing = util.read_file(path) or ""
  if existing ~= "" and not existing:match("\n$") then
    existing = existing .. "\n"
  end
  util.write_file(path, existing .. line .. "\n")
  pcall(vim.uv.fs_chmod, path, 384) -- 0600
end

---Rewrite a url so the client connects to a local tunnel port while keeping
---the real host name for TLS verification and ~/.pgpass lookups.
---@param url string
---@param local_port integer
---@param opts? { ssl?: string, sslrootcert?: string }
---@return string
function M.tunnelled_url(url, local_port, opts)
  opts = opts or {}
  local base, query = url:match("^([^?]*)%??(.*)$")
  local params = {}
  if query and query ~= "" then
    for kv in query:gmatch("[^&]+") do
      local k, v = kv:match("^([^=]*)=?(.*)$")
      params[k] = v
    end
  end
  params.hostaddr = "127.0.0.1"
  params.port = tostring(local_port)
  if not params.sslmode then
    params.sslmode = opts.ssl or config.get().aws.ssl or "require"
  end
  if opts.sslrootcert and not params.sslrootcert then
    params.sslrootcert = opts.sslrootcert
  end
  local keys = vim.tbl_keys(params)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. params[k]
  end
  return base .. "?" .. table.concat(parts, "&")
end

local resolved = {} ---@type table<string, dbgrid.Connection>
local inflight = {} ---@type table<string, fun(conn?: dbgrid.Connection, err?: string)[]>

---Forget the effective form of a connection (after a failure, or when its
---declaration changed). An aws name covers its roles (name/writer, name/reader).
---@param name? string  nil = everything
function M.forget(name)
  endpoint_memo = {}
  if not name then
    resolved = {}
    return
  end
  resolved[name] = nil
  for key in pairs(resolved) do
    if key:sub(1, #name + 1) == name .. "/" then
      resolved[key] = nil
    end
  end
end

---What `:Dbgrid aws refresh` does: forget the resolved form and, for an aws
---entry, the described endpoints, the looked-up bastion and the credentials.
---Runs by itself when a saved connection is edited, removed or the JSON saved.
---@param conn? dbgrid.Connection  a declared or expanded entry; nil = every connection
function M.refresh(conn)
  M.forget(conn and (conn.parent or conn.name) or nil)
  local aws = require("dbgrid.aws")
  for _, c in ipairs(conn and { conn } or M.all()) do
    if type(c.aws) == "table" then
      aws.forget_endpoints(c.aws)
      aws.forget_credentials(c.aws)
    end
  end
end

---@param conn dbgrid.Connection
---@param cb fun(conn?: dbgrid.Connection, err?: string)
local function run_password_cmd(conn, cb)
  if not conn.password_cmd or conn.password_cmd == "" or (conn.env and conn.env.PGPASSWORD) then
    return cb(conn)
  end
  local ok, job = pcall(vim.system, { "sh", "-c", conn.password_cmd }, { text = true, timeout = 30000 }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        return cb(nil, "password_cmd failed for " .. conn.name .. ": " .. util.trim(out.stderr or ""))
      end
      conn.env = conn.env or {}
      conn.env.PGPASSWORD = util.trim(out.stdout or "")
      cb(conn)
    end)
  end)
  if not ok then
    cb(nil, "password_cmd could not start: " .. tostring(job))
  end
end

---Build the tunnel spec of a generic `tunnel` block.
---@param conn dbgrid.Connection
---@return table spec
local function tunnel_spec(conn)
  local t = vim.deepcopy(conn.tunnel)
  t.kind = t.kind or (t.cmd and "cmd") or (t.host and "ssh") or "cmd"
  if t.kind == "ssh" and not t.remote then
    local _, _, host, port = M.parse_url(conn.url or "")
    t.remote = (host or "localhost") .. ":" .. (port or "5432")
  end
  t.key = t.key or (t.kind .. "|" .. conn.name .. "|" .. (t.remote or table.concat(t.cmd or {}, " ")))
  if t.handshake == nil and adapters.for_connection(conn) == adapters.get("postgres") then
    t.handshake = "postgres"
  end
  return t
end

---Turn a declared connection into an effective one: aws / tunnel / password_cmd.
---The result is cached per name; a cached tunnel is probed before reuse.
---@param conn dbgrid.Connection
---@param cb fun(conn?: dbgrid.Connection, err?: string)
function M.resolve(conn, cb)
  if conn._resolved then
    return cb(conn)
  end
  local key = conn.name
  local cached = resolved[key]
  local function finish(eff, err)
    if eff then
      eff._resolved = true
      eff.declared_url = eff.declared_url or conn.url
      resolved[key] = eff
    else
      resolved[key] = nil
    end
    local cbs = inflight[key] or {}
    inflight[key] = nil
    for _, f in ipairs(cbs) do
      pcall(f, eff, err)
    end
  end
  local function start()
    local eff = vim.deepcopy(conn)
    eff.env = vim.deepcopy(conn.env or {})
    if conn.aws then
      require("dbgrid.aws").resolve(eff, function(res, err)
        if not res then
          return finish(nil, err)
        end
        eff.url = res.url
        for k, v in pairs(res.env or {}) do
          eff.env[k] = v
        end
        eff.local_port = res.local_port
        eff.tunnel_key = res.tunnel_key
        eff.aws_role = res.role or eff.aws_role
        run_password_cmd(eff, finish)
      end)
    elseif conn.tunnel then
      local spec = tunnel_spec(conn)
      require("dbgrid.tunnel").ensure(spec, function(port, err)
        if not port then
          return finish(nil, err)
        end
        eff.url = M.tunnelled_url(eff.url, port, { ssl = conn.ssl, sslrootcert = conn.sslrootcert })
        eff.local_port = port
        eff.tunnel_key = spec.key
        run_password_cmd(eff, finish)
      end)
    else
      run_password_cmd(eff, finish)
    end
  end
  if inflight[key] then
    inflight[key][#inflight[key] + 1] = cb
    return
  end
  if cached then
    if cached.local_port then
      -- a tunnel may have died (SSM idle timeout): probe before reuse
      local tunnel = require("dbgrid.tunnel")
      local function reuse(ok)
        if ok then
          return cb(cached)
        end
        resolved[key] = nil
        inflight[key] = { cb }
        start()
      end
      if cached.tunnel_key then
        tunnel.check(cached.tunnel_key, reuse)
      else
        tunnel.probe(cached.local_port, config.get().aws.probe_ms or 500, reuse)
      end
      return
    end
    return cb(cached)
  end
  inflight[key] = { cb }
  start()
end

---Test a connection.
---@param conn dbgrid.Connection
---@param cb fun(ok: boolean, message: string)
function M.test(conn, cb)
  local a, err = adapters.for_connection(conn)
  if not a then
    return cb(false, err or "no adapter")
  end
  M.resolve(conn, function(eff, rerr)
    if not eff then
      return cb(false, rerr or "could not resolve the connection")
    end
    a.test(eff, cb)
  end)
end

---One line describing a connection for pickers.
---@param conn dbgrid.Connection
function M.describe(conn)
  local parts = { conn.name }
  if conn.readonly then
    parts[#parts + 1] = "[ro]"
  end
  if conn.aws then
    local a = conn.aws
    parts[#parts + 1] = string.format(
      "aws %s %s%s",
      a.profile or "default",
      a.cluster or a.instance or a.host or (a.secret and ("secret " .. a.secret)) or "?",
      a.bastion and (" via " .. a.bastion) or ""
    )
  else
    parts[#parts + 1] = util.redact_url(conn.url or "")
    if conn.tunnel then
      parts[#parts + 1] = "(" .. (conn.tunnel.kind or "tunnel") .. ")"
    end
  end
  if conn.source then
    parts[#parts + 1] = "(" .. conn.source .. ")"
  end
  return table.concat(parts, "  ")
end

return M
