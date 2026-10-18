-- PostgreSQL adapter, built on the `psql` client so there is nothing to compile.
--
-- Output is requested in unaligned mode with ASCII unit/record separators, so
-- values containing newlines, commas or quotes never need un-escaping. Each
-- statement is fenced with `\echo` markers carrying a per-run nonce.
local util = require("dbgrid.util")

local M = {
  name = "postgres",
  schemes = { postgres = true, postgresql = true },
  executable = "psql",
  dialect = "PostgreSQL",
  -- what `explain_text(..., analyze = true)` does
  analyze = true,
}

M.FS = "\31" -- field separator
M.RS = "\30" -- record separator
M.NULL = "\1NULL\1"

---@class dbgrid.RunStatement
---@field sql string          text to execute (already limited / rewritten)
---@field kind string
---@field class string
---@field line integer        1-based line of the statement within the cell body
---@field limit_applied? integer

---@class dbgrid.ResultSet
---@field columns string[]
---@field rows any[][]        vim.NIL for NULL
---@field row_count integer

---@class dbgrid.StatementResult
---@field sql string
---@field kind string
---@field class string
---@field sets dbgrid.ResultSet[]
---@field tags string[]       command tags such as "UPDATE 5"
---@field server_ms number
---@field limit_applied? integer

---@class dbgrid.RunError
---@field message string
---@field hint? string
---@field detail? string
---@field context? string
---@field stmt_index? integer
---@field line? integer       1-based line within the cell body
---@field col? integer        1-based column
---@field raw string

---@class dbgrid.RunResult
---@field ok boolean
---@field statements dbgrid.StatementResult[]
---@field notices string[]
---@field error? dbgrid.RunError
---@field elapsed_ms number
---@field server_ms number
---@field cancelled? boolean

---Environment for the psql process.
---@param conn dbgrid.Connection
---@param appname? string   application_name, unique per run so the session can be found server side
---@return table<string,string>
local function build_env(conn, appname)
  local env = {
    PGAPPNAME = appname or "dbgrid.nvim",
    PGCONNECT_TIMEOUT = "10",
  }
  local options = {}
  if conn.readonly then
    options[#options + 1] = "-c default_transaction_read_only=on"
  end
  if conn.statement_timeout_ms then
    options[#options + 1] = "-c statement_timeout=" .. tostring(conn.statement_timeout_ms)
  end
  if conn.lock_timeout_ms then
    options[#options + 1] = "-c lock_timeout=" .. tostring(conn.lock_timeout_ms)
  end
  if #options > 0 then
    env.PGOPTIONS = table.concat(options, " ")
  end
  -- connections.resolve() runs password_cmd asynchronously and puts the result in
  -- conn.env; the synchronous call below only serves callers that skipped it.
  if not conn._resolved and conn.password_cmd and conn.password_cmd ~= "" then
    local out = vim.fn.system(conn.password_cmd)
    if vim.v.shell_error == 0 then
      env.PGPASSWORD = util.trim(out)
    else
      util.warn("password_cmd failed for connection " .. conn.name)
    end
  end
  for k, v in pairs(conn.env or {}) do
    env[k] = v
  end
  -- vim.system replaces the environment when `env` is given unless clear_env=false;
  -- merge the parent's so PATH/HOME/PGPASSFILE survive.
  for k, v in pairs(vim.fn.environ()) do
    if env[k] == nil then
      env[k] = v
    end
  end
  return env
end

---@param conn dbgrid.Connection
---@param stop_on_error boolean
local function argv(conn, stop_on_error)
  return {
    M.executable,
    conn.url,
    "-X", -- no psqlrc
    "-v",
    "ON_ERROR_STOP=" .. (stop_on_error and "1" or "0"),
    "-A",
    "-F",
    M.FS,
    "-R",
    M.RS,
    "-P",
    "null=" .. M.NULL,
    "-P",
    "footer=on",
    "-f",
    "-",
  }
end

---@param nonce string
---@param i integer
local function marker(nonce, i)
  return "__DBGRID_" .. nonce .. "__ " .. i
end

---Build the psql script. Returns the script and, per statement, the script
---line range it occupies (for mapping `psql:<stdin>:N` back to a statement).
---@param statements dbgrid.RunStatement[]
---@param nonce string
---@param opts { transaction?: boolean, rollback?: boolean, read_write?: boolean, timing?: boolean, wrap?: fun(sql: string, i: integer): string, prelude?: string[] }
---@return string script, {first: integer, last: integer}[] ranges
local function build_script(statements, nonce, opts)
  local lines = {}
  local ranges = {}
  if opts.timing ~= false then
    lines[#lines + 1] = "\\timing on"
  end
  for _, l in ipairs(opts.prelude or {}) do
    lines[#lines + 1] = l
  end
  if opts.transaction then
    lines[#lines + 1] = "BEGIN;"
    if opts.read_write then
      -- a dry run on a read-only connection: the transaction is rolled back anyway
      lines[#lines + 1] = "SET TRANSACTION READ WRITE;"
    end
  end
  for i, st in ipairs(statements) do
    lines[#lines + 1] = "\\echo " .. marker(nonce, i)
    local sql = opts.wrap and opts.wrap(st.sql, i) or st.sql
    local first = #lines + 1
    for _, l in ipairs(util.lines(sql)) do
      lines[#lines + 1] = l
    end
    lines[#lines] = lines[#lines] .. ";"
    ranges[i] = { first = first, last = #lines }
  end
  if opts.transaction then
    lines[#lines + 1] = opts.rollback and "ROLLBACK;" or "COMMIT;"
  end
  lines[#lines + 1] = "\\echo " .. marker(nonce, #statements + 1)
  return table.concat(lines, "\n") .. "\n", ranges
end

---Parse one output block (everything a single statement printed).
---@param block string
---@return dbgrid.ResultSet[] sets, string[] tags, number server_ms
local function parse_block(block)
  local sets, tags, server_ms = {}, {}, 0
  -- timing lines are printed on their own line after each statement
  block = block:gsub("Time: ([%d%.]+) ms\n", function(ms)
    server_ms = server_ms + tonumber(ms)
    return ""
  end)
  if block == "" then
    return sets, tags, server_ms
  end
  if not block:find(M.RS, 1, true) then
    for _, l in ipairs(util.lines(block)) do
      if l ~= "" and l ~= "Timing is on." then
        tags[#tags + 1] = l
      end
    end
    return sets, tags, server_ms
  end
  local records = vim.split(block, M.RS, { plain = true })
  local current -- { columns=, rows= }
  local function parse_values(rec)
    local vals = vim.split(rec, M.FS, { plain = true })
    for k, v in ipairs(vals) do
      if v == M.NULL then
        vals[k] = vim.NIL
      end
    end
    return vals
  end
  local i = 1
  while i <= #records do
    local rec = records[i]
    if not current then
      -- header of a new set; anything after a footer newline belongs here too
      current = { columns = parse_values(rec), rows = {} }
    else
      local count, rest = rec:match("^%((%d+) rows?%)\n?(.*)$")
      if count then
        current.row_count = tonumber(count)
        sets[#sets + 1] = current
        current = nil
        rest = rest or ""
        if rest ~= "" then
          -- text after a footer: command tag(s) and/or another header
          if rest:find(M.FS, 1, true) or (records[i + 1] ~= nil) then
            current = { columns = parse_values(rest), rows = {} }
          else
            for _, l in ipairs(util.lines(rest)) do
              if l ~= "" then
                tags[#tags + 1] = l
              end
            end
          end
        end
      else
        current.rows[#current.rows + 1] = parse_values(rec)
      end
    end
    i = i + 1
  end
  if current then
    -- no footer (should not happen with footer=on); keep what we have
    current.row_count = #current.rows
    sets[#sets + 1] = current
  end
  for _, set in ipairs(sets) do
    -- guard against a NUL-less first column when the header is a single value
    for _, row in ipairs(set.rows) do
      for k = #row + 1, #set.columns do
        row[k] = vim.NIL
      end
    end
  end
  return sets, tags, server_ms
end

---Split stdout into per-statement blocks using the markers.
---@param stdout string
---@param nonce string
---@param n integer
---@return string[] blocks (1..n, missing when the statement never ran)
local function split_blocks(stdout, nonce, n)
  local blocks = {}
  local positions = {}
  for i = 1, n + 1 do
    local m = marker(nonce, i)
    local s, e = stdout:find(m .. "\n", 1, true)
    if not s then
      s, e = stdout:find(m .. "$", 1, true)
    end
    positions[i] = s and { s = s, e = e } or nil
  end
  for i = 1, n do
    local p = positions[i]
    if p then
      local next_pos
      for j = i + 1, n + 1 do
        if positions[j] then
          next_pos = positions[j].s
          break
        end
      end
      blocks[i] = stdout:sub(p.e + 1, (next_pos or (#stdout + 1)) - 1)
    end
  end
  return blocks
end

---Parse psql's stderr into notices and an error.
---@param stderr string
---@param ranges {first:integer,last:integer}[]
---@param statements dbgrid.RunStatement[]
---@return string[] notices, dbgrid.RunError? err
local function parse_stderr(stderr, ranges, statements)
  local notices, err = {}, nil
  local lines = util.lines(stderr)
  local i = 1
  while i <= #lines do
    local l = lines[i]
    local script_line, msg = l:match("^psql:<stdin>:(%d+): ERROR:%s*(.*)$")
    if not msg then
      msg = l:match("^ERROR:%s*(.*)$")
    end
    if msg and not err then
      err = { message = msg, raw = l }
      if script_line then
        local n = tonumber(script_line)
        for idx, r in ipairs(ranges) do
          if n >= r.first and n <= r.last then
            err.stmt_index = idx
            break
          end
        end
        if not err.stmt_index then
          -- psql reports the line where the statement was completed; pick the closest earlier statement
          for idx = #ranges, 1, -1 do
            if n >= ranges[idx].first then
              err.stmt_index = idx
              break
            end
          end
        end
      end
      -- following lines: LINE n: text / caret / HINT / DETAIL / CONTEXT
      i = i + 1
      while i <= #lines do
        local nl = lines[i]
        local ln, text = nl:match("^LINE (%d+): (.*)$")
        if ln then
          local st = err.stmt_index and statements[err.stmt_index]
          err.stmt_line = tonumber(ln)
          if st then
            err.line = st.line + tonumber(ln) - 1
          end
          local caret = lines[i + 1]
          if caret and caret:match("^%s*%^%s*$") then
            local prefix = #("LINE " .. ln .. ": ")
            local col = #caret:match("^(%s*)") - prefix + 1
            if col > 0 then
              -- psql truncates long lines with "..." at the front
              if text:match("^%.%.%.") then
                col = nil
              end
              err.col = col
            end
            i = i + 1
          end
        elseif nl:match("^HINT:") then
          err.hint = nl:gsub("^HINT:%s*", "")
        elseif nl:match("^DETAIL:") then
          err.detail = nl:gsub("^DETAIL:%s*", "")
        elseif nl:match("^CONTEXT:") then
          err.context = nl:gsub("^CONTEXT:%s*", "")
        elseif nl:match("^psql:") or nl:match("^[A-Z]+:") then
          break
        elseif nl ~= "" then
          err.raw = err.raw .. "\n" .. nl
        end
        i = i + 1
      end
      err.raw = err.raw or l
    else
      local fatal = l:match("^psql: error: (.*)$") or l:match("^psql: (.*)$")
      if fatal and not err then
        err = { message = fatal, raw = l }
        i = i + 1
      elseif l:match("^psql:<stdin>:%d+: ") then
        notices[#notices + 1] = l:gsub("^psql:<stdin>:%d+: ", "")
        i = i + 1
      elseif l:match("^%u+:") then
        notices[#notices + 1] = l
        i = i + 1
      elseif l ~= "" and #notices > 0 then
        notices[#notices] = notices[#notices] .. "\n" .. l
        i = i + 1
      else
        i = i + 1
      end
    end
  end
  return notices, err
end

-- ---------------------------------------------------------------------------
-- Persistent sessions (query.session = true): one psql per connection kept
-- alive across runs, so temp tables and SET carry over and a tunnel handshake
-- is paid once. psql flushes its output after every command, so each script
-- is fenced with an END marker and collected as it streams in.
-- ---------------------------------------------------------------------------
local sessions = {} ---@type table<string, table>

---@param conn dbgrid.Connection
local function session_key(conn)
  return conn.name .. "|" .. (conn.url or "")
end

---End a session and fail whatever it still owed.
---@param sess table
---@param reason string
local function session_close(sess, reason)
  if sessions[sess.key] == sess then
    sessions[sess.key] = nil
  end
  if sess.job and not sess.dead then
    pcall(sess.job.kill, sess.job, 15)
  end
  sess.dead = true
  local pending = sess.pending
  sess.pending = nil
  if pending then
    if pending.timer then
      pending.timer:stop()
      pending.timer:close()
    end
    vim.schedule(function()
      pending.cb({ code = 1, signal = 0, stdout = pending.stdout, stderr = pending.stderr .. "\npsql: " .. reason })
    end)
  end
  for _, q in ipairs(sess.queue or {}) do
    vim.schedule(function()
      q.cb({ code = 1, signal = 0, stdout = "", stderr = "psql: " .. reason })
    end)
  end
  sess.queue = {}
end

---Hand the next queued script to the session.
---@param sess table
local function session_next(sess)
  if sess.pending or sess.dead then
    return
  end
  local item = table.remove(sess.queue, 1)
  if not item then
    return
  end
  local nonce = util.short_id(6)
  local end_marker = "__DBGRID_" .. nonce .. "__ END"
  local script = item.script .. "\\echo " .. end_marker .. "\n"
  local n_lines = select(2, script:gsub("\n", "")) -- lines psql will count for this script
  item.stdout, item.stderr = {}, {}
  item.end_marker = end_marker
  item.line_offset = sess.lines_sent
  sess.lines_sent = sess.lines_sent + n_lines
  sess.pending = item
  if item.timeout_ms then
    local uv = vim.uv or vim.loop
    item.timer = uv.new_timer()
    item.timer:start(item.timeout_ms, 0, function()
      vim.schedule(function()
        if sess.pending == item then
          session_close(sess, "statement timed out; the session was restarted")
        end
      end)
    end)
  end
  sess.job:write(script)
end

---Complete the pending script once its END marker arrived.
---@param sess table
local function session_finish(sess)
  local item = sess.pending
  if not item then
    return
  end
  sess.pending = nil
  if item.timer then
    item.timer:stop()
    item.timer:close()
  end
  -- stderr may trail stdout by a moment: give it a tick
  vim.defer_fn(function()
    local stdout = table.concat(item.stdout)
    local stderr = table.concat(item.stderr)
    -- psql numbers <stdin> lines across the whole session; make them relative
    stderr = stderr:gsub("psql:<stdin>:(%d+):", function(n)
      return "psql:<stdin>:" .. (tonumber(n) - item.line_offset) .. ":"
    end)
    -- an error while the session's ON_ERROR_STOP is off does not exit psql;
    -- report a failing exit code when an ERROR was printed so callers behave
    -- exactly as with a one-shot process
    local code = stderr:find("ERROR:", 1, true) and 3 or 0
    item.cb({ code = code, signal = 0, stdout = stdout, stderr = stderr })
    session_next(sess)
  end, 20)
end

---@param sess table
---@param data string
local function session_on_stdout(sess, data)
  local item = sess.pending
  if not item then
    return
  end
  item.stdout[#item.stdout + 1] = data
  if data:find(item.end_marker, 1, true) then
    -- strip the END marker line
    local all = table.concat(item.stdout)
    local at = all:find(item.end_marker, 1, true)
    item.stdout = { all:sub(1, at - 1) }
    session_finish(sess)
  end
end

---@param conn dbgrid.Connection
---@return table sess
local function session_get(conn)
  local key = session_key(conn)
  local sess = sessions[key]
  if sess and not sess.dead then
    return sess
  end
  sess = { key = key, queue = {}, lines_sent = 0, stderr_tail = {} }
  local args = argv(conn, false)
  sess.job = vim.system(args, {
    stdin = true,
    env = build_env(conn),
    clear_env = true,
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          session_on_stdout(sess, data)
        end)
      end
    end,
    stderr = function(_, data)
      if data then
        vim.schedule(function()
          if sess.pending then
            sess.pending.stderr[#sess.pending.stderr + 1] = data
          else
            sess.stderr_tail[#sess.stderr_tail + 1] = data
            if #sess.stderr_tail > 20 then
              table.remove(sess.stderr_tail, 1)
            end
          end
        end)
      end
    end,
  }, function(out)
    vim.schedule(function()
      sess.dead = true
      local tail = table.concat(sess.stderr_tail)
      if sess.pending then
        sess.pending.stderr[#sess.pending.stderr + 1] = tail
        local item = sess.pending
        sess.pending = nil
        if item.timer then
          item.timer:stop()
          item.timer:close()
        end
        item.cb({
          code = out.code ~= 0 and out.code or 1,
          signal = out.signal,
          stdout = table.concat(item.stdout),
          stderr = table.concat(item.stderr),
        })
      end
      local why = "session exited with code " .. tostring(out.code)
      if tail ~= "" then
        why = why .. ": " .. util.trim(tail)
      end
      session_close(sess, why)
    end)
  end)
  sess.pid = sess.job.pid
  sessions[key] = sess
  return sess
end

---Run a script through the persistent session of a connection.
---@param conn dbgrid.Connection
---@param script string
---@param opts { timeout_ms?: integer }
---@param cb fun(out: vim.SystemCompleted)
---@return dbgrid.Job
local function session_spawn(conn, script, opts, cb)
  local ok, sess = pcall(session_get, conn)
  if not ok then
    vim.schedule(function()
      cb({ code = 127, signal = 0, stdout = "", stderr = "psql could not be started: " .. tostring(sess) })
    end)
    return { kill = function() end }
  end
  local item = { script = script, timeout_ms = opts.timeout_ms, cb = cb }
  sess.queue[#sess.queue + 1] = item
  session_next(sess)
  return {
    pid = sess.pid,
    conn = conn,
    is_done = function()
      return sess.pending ~= item and not vim.tbl_contains(sess.queue, item)
    end,
    kill = function(_, signal)
      -- SIGINT makes psql cancel the query; it then stops reading its input and
      -- exits, which ends the session (a new one starts on the next run)
      if sess.job and not sess.dead then
        pcall(sess.job.kill, sess.job, signal or 2)
      end
    end,
  }
end

---Close the persistent session of a connection (or all of them).
---@param conn? dbgrid.Connection
function M.close_session(conn)
  if conn then
    local sess = sessions[session_key(conn)]
    if sess then
      session_close(sess, "closed")
    end
    return
  end
  for _, key in ipairs(vim.tbl_keys(sessions)) do
    local live = sessions[key]
    if live then
      session_close(live, "closed")
    end
  end
end

---@return { key: string, pid: integer?, busy: boolean }[]
function M.sessions()
  local out = {}
  for key, sess in pairs(sessions) do
    out[#out + 1] = { key = key, pid = sess.pid, busy = sess.pending ~= nil }
  end
  return out
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("dbgrid_postgres_sessions", { clear = true }),
  callback = function()
    for _, sess in pairs(sessions) do
      if sess.job and not sess.dead then
        pcall(sess.job.kill, sess.job, 15)
      end
    end
  end,
})

---Spawn psql with a script on stdin (or hand it to the persistent session).
---@param conn dbgrid.Connection
---@param script string
---@param opts { stop_on_error?: boolean, timeout_ms?: integer, appname?: string }
---@param cb fun(out: vim.SystemCompleted)
---@return dbgrid.Job
local function spawn(conn, script, opts, cb)
  local use_session = conn.session
  if use_session == nil then
    local cfg = require("dbgrid.config").get()
    use_session = cfg.query and cfg.query.session
  end
  if use_session then
    return session_spawn(conn, script, opts, cb)
  end
  local appname = opts.appname or ("dbgrid.nvim:" .. util.short_id(8))
  local done = false
  local ok, proc = pcall(vim.system, argv(conn, opts.stop_on_error ~= false), {
    stdin = script,
    env = build_env(conn, appname),
    clear_env = true,
    timeout = opts.timeout_ms,
    text = true,
  }, function(out)
    done = true
    vim.schedule(function()
      cb(out)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ code = 127, signal = 0, stdout = "", stderr = "psql could not be started: " .. tostring(proc) })
    end)
    return {
      kill = function() end,
      is_done = function()
        return true
      end,
    }
  end
  return {
    pid = proc.pid,
    appname = appname,
    conn = conn,
    kill = function(_, signal)
      return proc:kill(signal)
    end,
    is_done = function()
      return done
    end,
    wait = function(_, ms)
      return proc:wait(ms)
    end,
  }
end

---Ask the server to cancel every backend of this connection whose
---application_name matches (a run's psql session), through a fresh
---connection. Works where the client's cancel request never arrives
---(proxies, some tunnels).
---@param conn dbgrid.Connection
---@param appname string
---@param cb? fun(ok: boolean, message: string)
function M.server_cancel(conn, appname, cb)
  if not appname or not appname:match("^[%w%.:_%-]+$") then
    if cb then
      cb(false, "invalid application name")
    end
    return
  end
  local sql = string.format(
    "select count(pg_cancel_backend(pid)) from pg_stat_activity where application_name = '%s' and pid <> pg_backend_pid()",
    appname
  )
  local statements = { { sql = sql, kind = "select", class = "read", line = 1 } }
  local script = build_script(statements, "cancel", { timing = false })
  local fresh = vim.deepcopy(conn)
  fresh.session = false
  spawn(fresh, script, { stop_on_error = true, timeout_ms = 10000, appname = "dbgrid.nvim:cancel" }, function(out)
    if out.code ~= 0 then
      if cb then
        cb(false, util.trim(out.stderr or ""))
      end
      return
    end
    local blocks = split_blocks(out.stdout or "", "cancel", 1)
    local sets = blocks[1] and parse_block(blocks[1]) or {}
    local n = sets[1] and sets[1].rows[1] and sets[1].rows[1][1]
    if cb then
      cb(true, tostring(n or "0") .. " backend(s) cancelled")
    end
  end)
end

---@param conn dbgrid.Connection
---@param statements dbgrid.RunStatement[]
---@param opts { transaction?: boolean, rollback?: boolean, read_write?: boolean, timeout_ms?: integer,
---  prelude?: string[] }
---@param cb fun(result: dbgrid.RunResult)
---@return dbgrid.Job
function M.run(conn, statements, opts, cb)
  local nonce = util.short_id(6)
  local script, ranges = build_script(statements, nonce, {
    transaction = opts.transaction or opts.rollback,
    rollback = opts.rollback,
    read_write = opts.rollback and opts.read_write,
    prelude = opts.prelude,
  })
  local started = util.now()
  return spawn(conn, script, { stop_on_error = true, timeout_ms = opts.timeout_ms }, function(out)
    local elapsed = (util.now() - started) * 1000
    local blocks = split_blocks(out.stdout or "", nonce, #statements)
    local results = {}
    local server_ms = 0
    for i, st in ipairs(statements) do
      local sets, tags, ms = {}, {}, 0
      if blocks[i] then
        sets, tags, ms = parse_block(blocks[i])
      end
      server_ms = server_ms + ms
      results[i] = {
        sql = st.sql,
        kind = st.kind,
        class = st.class,
        line = st.line,
        limit_applied = st.limit_applied,
        sets = sets,
        tags = tags,
        server_ms = ms,
        ran = blocks[i] ~= nil,
      }
    end
    local notices, err = parse_stderr(out.stderr or "", ranges, statements)
    local cancelled = out.signal == 2 or out.signal == 15 or out.code == 124
    -- a process killed by a signal reports code 0 and the signal
    if (out.code ~= 0 or (out.signal or 0) ~= 0) and not err then
      err = {
        message = cancelled and "cancelled" or ("psql exited with code " .. tostring(out.code)),
        raw = out.stderr or "",
      }
    end
    cb({
      ok = err == nil,
      statements = results,
      notices = notices,
      error = err,
      elapsed_ms = elapsed,
      server_ms = server_ms,
      cancelled = cancelled,
    })
  end)
end

---Load a delimited file into a table with `\copy`: the file is read by psql
---on this machine, so it needs no access from the server. A CREATE TABLE
---(`opts.create_sql`) runs first, in the same transaction.
---@param conn dbgrid.Connection
---@param opts { path: string, table: string, columns: string[], delimiter: string, header?: boolean,
---  create_sql?: string, timeout_ms?: integer }
---@param cb fun(ok: boolean, message: string, rows?: integer)
---@return dbgrid.Job
function M.import(conn, opts, cb)
  local lines = { "BEGIN;" }
  if opts.create_sql then
    lines[#lines + 1] = opts.create_sql
  end
  local cols = ""
  if #(opts.columns or {}) > 0 then
    cols = " (" .. table.concat(vim.tbl_map(util.sql_ident, opts.columns), ", ") .. ")"
  end
  local delim = opts.delimiter == "\t" and "E'\\t'" or util.sql_literal(opts.delimiter or ",")
  lines[#lines + 1] = string.format(
    "\\copy %s%s from %s with (format csv, header %s, delimiter %s)",
    opts.table,
    cols,
    util.sql_literal(opts.path),
    opts.header ~= false and "true" or "false",
    delim
  )
  lines[#lines + 1] = "COMMIT;"
  local fresh = vim.deepcopy(conn)
  fresh.session = false
  return spawn(
    fresh,
    table.concat(lines, "\n") .. "\n",
    { stop_on_error = true, timeout_ms = opts.timeout_ms or 600000, appname = "dbgrid.nvim:import" },
    function(out)
      local rows = tonumber((out.stdout or ""):match("COPY (%d+)"))
      if out.code ~= 0 or not rows then
        local _, err = parse_stderr(out.stderr or "", {}, {})
        cb(
          false,
          err and err.message
            or util.trim(out.stderr ~= "" and out.stderr or ("psql exited with " .. tostring(out.code)))
        )
        return
      end
      cb(true, "COPY " .. rows, rows)
    end
  )
end

---Did the run fail before reaching the server? True for libpq's connection
---errors when no statement produced output, so the run can be repeated safely.
---@param res table   result handed to M.run's callback
---@return boolean
function M.connection_failed(res)
  local msg = res.error and res.error.message or ""
  if
    not (
      msg:find("^connection to server")
      or msg:find("^could not connect to server")
      or msg:find("^server closed the connection unexpectedly")
    )
  then
    return false
  end
  for _, st in ipairs(res.statements or {}) do
    if st.ran then
      return false
    end
  end
  return true
end

---EXPLAIN (FORMAT JSON) for every statement; failures yield nil plans.
---@param conn dbgrid.Connection
---@param statements dbgrid.RunStatement[]
---@param cb fun(plans: table[], err?: string)
---@return dbgrid.Job
function M.explain(conn, statements, cb)
  local nonce = util.short_id(6)
  local script = build_script(statements, nonce, {
    timing = false,
    wrap = function(sql)
      return "EXPLAIN (FORMAT JSON) " .. sql
    end,
  })
  return spawn(conn, script, { stop_on_error = false, timeout_ms = 30000 }, function(out)
    local blocks = split_blocks(out.stdout or "", nonce, #statements)
    local plans = {}
    for i = 1, #statements do
      if blocks[i] then
        local sets = parse_block(blocks[i])
        local set = sets[1]
        local text = set and set.rows[1] and set.rows[1][1]
        if type(text) == "string" then
          local ok, decoded = pcall(vim.json.decode, text)
          if ok then
            plans[i] = decoded
          end
        end
      end
    end
    local err
    if out.code ~= 0 and out.code ~= 3 and vim.tbl_isempty(plans) then
      err = util.trim(out.stderr or "")
    end
    cb(plans, err)
  end)
end

---EXPLAIN (optionally ANALYZE inside a rolled-back transaction) rendered as
---text. The third callback value carries the JSON plan, per-line highlight
---marks and, for ANALYZE, the findings (bad row estimates, disk sorts, ...).
---@param conn dbgrid.Connection
---@param sql string
---@param analyze boolean
---@param cb fun(lines: string[], err?: string, info?: { plan: table, marks: table<integer,string>, findings: dbgrid.PlanFinding[] })
---@return dbgrid.Job
function M.explain_text(conn, sql, analyze, cb)
  local nonce = util.short_id(6)
  local options = analyze and "ANALYZE, BUFFERS, FORMAT JSON" or "FORMAT JSON"
  local statements = { { sql = "EXPLAIN (" .. options .. ") " .. sql, kind = "explain", class = "read", line = 1 } }
  local script = build_script(statements, nonce, { timing = false, transaction = analyze })
  if analyze then
    script = script:gsub("COMMIT;", "ROLLBACK;")
  end
  return spawn(conn, script, { stop_on_error = true, timeout_ms = nil }, function(out)
    local blocks = split_blocks(out.stdout or "", nonce, 1)
    local plan
    if blocks[1] then
      local sets = parse_block(blocks[1])
      local set = sets[1]
      local text = set and set.rows[1] and set.rows[1][1]
      if type(text) == "string" then
        local ok, decoded = pcall(vim.json.decode, text)
        if ok then
          plan = decoded
        end
      end
    end
    local err
    if out.code ~= 0 then
      local _, e = parse_stderr(out.stderr or "", { { first = 1, last = 1e9 } }, statements)
      err = e and e.message or util.trim(out.stderr or "")
    end
    if not plan then
      cb({}, err or "no plan returned")
      return
    end
    local explain = require("dbgrid.explain")
    local lines, marks = explain.to_lines(plan)
    local findings = analyze and explain.analyze_findings(plan, { schema = require("dbgrid.schema").loaded(conn) })
      or {}
    cb(lines, err, { plan = plan, marks = marks, findings = findings })
  end)
end

---EXPLAIN (FORMAT JSON) of one statement with options; ANALYZE runs inside a
---transaction that is rolled back.
---@param conn dbgrid.Connection
---@param sql string
---@param opts { analyze?: boolean, buffers?: boolean, verbose?: boolean, settings?: boolean, timeout_ms?: integer }
---@param cb fun(plan?: table, err?: string)
---@return dbgrid.Job
function M.explain_json(conn, sql, opts, cb)
  opts = opts or {}
  local nonce = util.short_id(6)
  local options = { "FORMAT JSON" }
  if opts.analyze then
    table.insert(options, 1, "ANALYZE")
    if opts.buffers ~= false then
      table.insert(options, 2, "BUFFERS")
    end
  end
  if opts.verbose then
    options[#options + 1] = "VERBOSE"
  end
  if opts.settings then
    options[#options + 1] = "SETTINGS"
  end
  local statements = {
    { sql = "EXPLAIN (" .. table.concat(options, ", ") .. ") " .. sql, kind = "explain", class = "read", line = 1 },
  }
  local script =
    build_script(statements, nonce, { timing = false, transaction = opts.analyze, rollback = opts.analyze })
  return spawn(conn, script, { stop_on_error = true, timeout_ms = opts.timeout_ms }, function(out)
    local blocks = split_blocks(out.stdout or "", nonce, 1)
    local plan
    if blocks[1] then
      local sets = parse_block(blocks[1])
      local set = sets[1]
      local text = {}
      for _, row in ipairs(set and set.rows or {}) do
        text[#text + 1] = row[1] ~= vim.NIL and row[1] or ""
      end
      local ok, decoded = pcall(vim.json.decode, table.concat(text, "\n"))
      if ok then
        plan = decoded
      end
    end
    if out.code ~= 0 or not plan then
      local _, e = parse_stderr(out.stderr or "", { { first = 1, last = 1e9 } }, statements)
      cb(nil, e and e.message or util.trim(out.stderr or ("psql exited with " .. tostring(out.code))))
      return
    end
    cb(plan)
  end)
end

M.SCHEMA_SQL = [[
select json_build_object(
  'version', version(),
  'schemas', (select coalesce(json_agg(nspname order by nspname), '[]') from pg_namespace
              where nspname not in ('pg_catalog','information_schema') and nspname not like 'pg_toast%' and nspname not like 'pg_temp%'),
  'tables', (select coalesce(json_agg(t order by t.schema, t.name), '[]') from (
    select n.nspname as schema, c.relname as name, c.relkind as kind, greatest(c.reltuples, 0)::bigint as rows,
           obj_description(c.oid, 'pg_class') as comment,
           (select coalesce(json_agg(json_build_object(
                     'name', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'notnull', a.attnotnull,
                     'default', pg_get_expr(d.adbin, d.adrelid), 'comment', col_description(c.oid, a.attnum)) order by a.attnum), '[]')
              from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
              where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped) as columns,
           (select coalesce(json_agg(json_build_object(
                     'name', i.relname, 'unique', x.indisunique, 'primary', x.indisprimary, 'def', pg_get_indexdef(x.indexrelid),
                     'columns', (select json_agg(pg_get_indexdef(x.indexrelid, k, true) order by k) from generate_series(1, x.indnatts) k))), '[]')
              from pg_index x join pg_class i on i.oid = x.indexrelid where x.indrelid = c.oid) as indexes,
           (select coalesce(json_agg(json_build_object(
                     'name', con.conname, 'type', con.contype, 'def', pg_get_constraintdef(con.oid),
                     'columns', (select json_agg(a.attname order by a.attnum) from pg_attribute a where a.attrelid = con.conrelid and a.attnum = any(con.conkey)),
                     'ref_table', (select n2.nspname || '.' || c2.relname from pg_class c2 join pg_namespace n2 on n2.oid = c2.relnamespace where c2.oid = con.confrelid),
                     'ref_columns', (select json_agg(a.attname) from pg_attribute a where a.attrelid = con.confrelid and a.attnum = any(con.confkey)))), '[]')
              from pg_constraint con where con.conrelid = c.oid and con.contype in ('p','f','u')) as constraints
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('r','v','m','p','f') and n.nspname not in ('pg_catalog','information_schema') and n.nspname not like 'pg_toast%' and n.nspname not like 'pg_temp%'
  ) t),
  'enums', (select coalesce(json_agg(json_build_object('name', t.typname,
              'values', (select json_agg(e.enumlabel order by e.enumsortorder) from pg_enum e where e.enumtypid = t.oid))), '[]')
            from pg_type t where t.typtype = 'e'),
  'functions', (select coalesce(json_agg(distinct p.proname), '[]') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname not in ('pg_catalog','information_schema'))
)]]

---Fetch the schema as one JSON document.
---@param conn dbgrid.Connection
---@param cb fun(schema?: table, err?: string)
---@return dbgrid.Job
function M.schema(conn, cb)
  local nonce = util.short_id(6)
  local statements = { { sql = M.SCHEMA_SQL, kind = "select", class = "read", line = 1 } }
  local script = build_script(statements, nonce, { timing = false })
  return spawn(conn, script, { stop_on_error = true, timeout_ms = 60000 }, function(out)
    if out.code ~= 0 then
      local _, e = parse_stderr(out.stderr or "", { { first = 1, last = 1e9 } }, statements)
      cb(nil, e and e.message or util.trim(out.stderr or ("psql exited with " .. tostring(out.code))))
      return
    end
    local blocks = split_blocks(out.stdout or "", nonce, 1)
    local sets = blocks[1] and parse_block(blocks[1]) or {}
    local text = sets[1] and sets[1].rows[1] and sets[1].rows[1][1]
    if type(text) ~= "string" then
      cb(nil, "schema query returned nothing")
      return
    end
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok then
      cb(nil, "schema JSON could not be decoded")
      return
    end
    cb(decoded)
  end)
end

---@param conn dbgrid.Connection
---@param cb fun(ok: boolean, message: string)
function M.test(conn, cb)
  local statements = { { sql = "select version()", kind = "select", class = "read", line = 1 } }
  return M.run(conn, statements, {}, function(res)
    if res.ok then
      local v = res.statements[1].sets[1] and res.statements[1].sets[1].rows[1] and res.statements[1].sets[1].rows[1][1]
      cb(true, tostring(v))
    else
      cb(false, res.error and res.error.message or "failed")
    end
  end)
end

---Cancel a running job. SIGINT makes psql send a cancel request; when the
---query is still running after `query.cancel_grace_ms`, the server is asked
---directly (pg_cancel_backend by application_name) and, as a last resort,
---the client is killed.
---@param job dbgrid.Job
---@param conn? dbgrid.Connection
function M.cancel(job, conn)
  if not job or not job.kill then
    return
  end
  pcall(job.kill, job, 2)
  local cfg = require("dbgrid.config").get().query
  local grace = cfg.cancel_grace_ms or 1500
  conn = conn or job.conn
  local function still_running()
    return not (job.is_done and job.is_done())
  end
  vim.defer_fn(function()
    if not still_running() then
      return
    end
    if cfg.server_cancel ~= false and conn and job.appname then
      M.server_cancel(conn, job.appname, function(ok, msg)
        if ok then
          util.notify("asked the server to cancel: " .. msg)
        else
          util.warn("server-side cancel failed: " .. msg)
        end
      end)
    end
    vim.defer_fn(function()
      if still_running() then
        pcall(job.kill, job, 15)
      end
    end, grace + 3000)
  end, grace)
end

M.keywords = {
  "select",
  "from",
  "where",
  "and",
  "or",
  "not",
  "in",
  "is",
  "null",
  "as",
  "on",
  "join",
  "left",
  "right",
  "inner",
  "outer",
  "full",
  "cross",
  "lateral",
  "group",
  "by",
  "order",
  "having",
  "limit",
  "offset",
  "fetch",
  "first",
  "next",
  "rows",
  "only",
  "union",
  "all",
  "except",
  "intersect",
  "distinct",
  "case",
  "when",
  "then",
  "else",
  "end",
  "insert",
  "into",
  "values",
  "update",
  "set",
  "delete",
  "returning",
  "with",
  "recursive",
  "create",
  "table",
  "index",
  "view",
  "materialized",
  "alter",
  "drop",
  "truncate",
  "begin",
  "commit",
  "rollback",
  "explain",
  "analyze",
  "verbose",
  "exists",
  "between",
  "like",
  "ilike",
  "similar",
  "any",
  "some",
  "asc",
  "desc",
  "nulls",
  "over",
  "partition",
  "window",
  "filter",
  "within",
  "true",
  "false",
  "cast",
  "interval",
  "extract",
  "using",
  "default",
  "primary",
  "key",
  "references",
  "unique",
  "check",
  "constraint",
  "temporary",
  "temp",
  "if",
  "cascade",
  "restrict",
  "concurrently",
  "merge",
  "matched",
  "conflict",
  "do",
  "nothing",
  "excluded",
  "for",
  "share",
  "skip",
  "locked",
  "nowait",
  "tablesample",
  "grouping",
  "sets",
  "cube",
  "rollup",
  "collate",
  "current_date",
  "current_timestamp",
  "now",
  "coalesce",
  "nullif",
}

M.functions = {
  "count",
  "sum",
  "avg",
  "min",
  "max",
  "array_agg",
  "string_agg",
  "json_agg",
  "jsonb_agg",
  "json_build_object",
  "jsonb_build_object",
  "json_object_agg",
  "coalesce",
  "nullif",
  "greatest",
  "least",
  "now",
  "current_date",
  "date_trunc",
  "date_part",
  "extract",
  "age",
  "to_char",
  "to_date",
  "to_timestamp",
  "to_number",
  "make_interval",
  "length",
  "lower",
  "upper",
  "initcap",
  "trim",
  "ltrim",
  "rtrim",
  "substring",
  "substr",
  "position",
  "replace",
  "regexp_replace",
  "regexp_matches",
  "regexp_split_to_table",
  "split_part",
  "concat",
  "concat_ws",
  "format",
  "left",
  "right",
  "lpad",
  "rpad",
  "md5",
  "gen_random_uuid",
  "uuid_generate_v4",
  "random",
  "round",
  "floor",
  "ceil",
  "abs",
  "power",
  "sqrt",
  "mod",
  "trunc",
  "sign",
  "row_number",
  "rank",
  "dense_rank",
  "ntile",
  "lag",
  "lead",
  "first_value",
  "last_value",
  "nth_value",
  "percentile_cont",
  "percentile_disc",
  "mode",
  "stddev",
  "variance",
  "corr",
  "generate_series",
  "unnest",
  "array_length",
  "cardinality",
  "array_to_string",
  "string_to_array",
  "array_position",
  "array_remove",
  "jsonb_array_elements",
  "jsonb_each",
  "jsonb_set",
  "jsonb_extract_path",
  "jsonb_path_query",
  "jsonb_typeof",
  "json_array_length",
  "to_json",
  "to_jsonb",
  "row_to_json",
  "pg_typeof",
  "pg_sleep",
  "pg_size_pretty",
  "pg_total_relation_size",
  "pg_relation_size",
  "current_setting",
  "set_config",
  "version",
  "exists",
  "cast",
  "date",
  "time",
  "timestamp",
  "interval",
  "bool_and",
  "bool_or",
  "every",
  "width_bucket",
  "clock_timestamp",
  "statement_timestamp",
  "transaction_timestamp",
  "localtimestamp",
  "current_user",
  "session_user",
  "nextval",
  "currval",
  "setval",
  "lastval",
  "quote_ident",
  "quote_literal",
  "encode",
  "decode",
  "convert_from",
  "convert_to",
}

-- exposed for tests
M._parse_block = parse_block
M._split_blocks = split_blocks
M._parse_stderr = parse_stderr
M._build_script = build_script

return M
