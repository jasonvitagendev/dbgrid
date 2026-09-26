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
---@return table<string,string>
local function build_env(conn)
  local env = {
    PGAPPNAME = "dbgrid.nvim",
    PGCONNECT_TIMEOUT = "10",
  }
  local options = {}
  if conn.readonly then
    options[#options + 1] = "-c default_transaction_read_only=on"
  end
  if conn.statement_timeout_ms then
    options[#options + 1] = "-c statement_timeout=" .. tostring(conn.statement_timeout_ms)
  end
  if #options > 0 then
    env.PGOPTIONS = table.concat(options, " ")
  end
  if conn.password_cmd and conn.password_cmd ~= "" then
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
---@param opts { transaction?: boolean, timing?: boolean, wrap?: fun(sql: string, i: integer): string }
---@return string script, {first: integer, last: integer}[] ranges
local function build_script(statements, nonce, opts)
  local lines = {}
  local ranges = {}
  if opts.timing ~= false then
    lines[#lines + 1] = "\\timing on"
  end
  if opts.transaction then
    lines[#lines + 1] = "BEGIN;"
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
    lines[#lines + 1] = "COMMIT;"
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

---Spawn psql with a script on stdin.
---@param conn dbgrid.Connection
---@param script string
---@param opts { stop_on_error?: boolean, timeout_ms?: integer }
---@param cb fun(out: vim.SystemCompleted)
---@return dbgrid.Job
local function spawn(conn, script, opts, cb)
  local ok, job = pcall(vim.system, argv(conn, opts.stop_on_error ~= false), {
    stdin = script,
    env = build_env(conn),
    clear_env = true,
    timeout = opts.timeout_ms,
    text = true,
  }, function(out)
    vim.schedule(function()
      cb(out)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ code = 127, signal = 0, stdout = "", stderr = "psql could not be started: " .. tostring(job) })
    end)
    return { kill = function() end }
  end
  return job
end

---@param conn dbgrid.Connection
---@param statements dbgrid.RunStatement[]
---@param opts { transaction?: boolean, timeout_ms?: integer }
---@param cb fun(result: dbgrid.RunResult)
---@return dbgrid.Job
function M.run(conn, statements, opts, cb)
  local nonce = util.short_id(6)
  local script, ranges = build_script(statements, nonce, { transaction = opts.transaction })
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
    if out.code ~= 0 and not err then
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

---Text EXPLAIN (optionally ANALYZE inside a rolled-back transaction).
---@param conn dbgrid.Connection
---@param sql string
---@param analyze boolean
---@param cb fun(lines: string[], err?: string)
---@return dbgrid.Job
function M.explain_text(conn, sql, analyze, cb)
  local nonce = util.short_id(6)
  local options = analyze and "ANALYZE, BUFFERS, FORMAT TEXT" or "FORMAT TEXT"
  local statements = { { sql = "EXPLAIN (" .. options .. ") " .. sql, kind = "explain", class = "read", line = 1 } }
  local script = build_script(statements, nonce, { timing = false, transaction = analyze })
  if analyze then
    script = script:gsub("COMMIT;", "ROLLBACK;")
  end
  return spawn(conn, script, { stop_on_error = true, timeout_ms = nil }, function(out)
    local blocks = split_blocks(out.stdout or "", nonce, 1)
    local lines = {}
    if blocks[1] then
      local sets = parse_block(blocks[1])
      for _, set in ipairs(sets) do
        for _, row in ipairs(set.rows) do
          lines[#lines + 1] = row[1] ~= vim.NIL and row[1] or ""
        end
      end
    end
    local err
    if out.code ~= 0 then
      local _, e = parse_stderr(out.stderr or "", { { first = 1, last = 1e9 } }, statements)
      err = e and e.message or util.trim(out.stderr or "")
    end
    cb(lines, err)
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

---Cancel a running job: SIGINT makes psql send a cancel request to the server.
---@param job dbgrid.Job
function M.cancel(job)
  if not job or not job.kill then
    return
  end
  pcall(job.kill, job, 2)
  vim.defer_fn(function()
    pcall(job.kill, job, 15)
  end, 2000)
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
