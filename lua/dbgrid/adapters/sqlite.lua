-- SQLite adapter, built on the `sqlite3` command line shell.
--
-- The shell runs in quote mode with ASCII unit/record separators: every value
-- is printed as an SQL literal ('text', 42, NULL, X'00ff'), so BLOBs (binary
-- UUIDs and the like) come out as hex instead of raw bytes that could contain
-- the separators, and every statement is fenced with `.print` markers carrying
-- a per-run nonce (the same scheme as the Postgres adapter).
local util = require("dbgrid.util")

local M = {
  name = "sqlite",
  schemes = { sqlite = true, sqlite3 = true },
  executable = "sqlite3",
  dialect = "SQLite",
  -- SQLite has no EXPLAIN ANALYZE; explain_text always shows the query plan
  analyze = false,
}

M.FS = "\31"
M.RS = "\30"

---Database file of a connection. Accepts `sqlite:path`, `sqlite:///abs/path`,
---`sqlite://rel/path`, a bare path ending in .sqlite3/.sqlite/.db, `~/...`
---and `:memory:`. Relative paths are resolved against the project root.
---@param conn dbgrid.Connection
---@return string?
function M.path(conn)
  local p = (conn.url or ""):gsub("^sqlite3?:", "")
  if p:sub(1, 3) == "///" then
    p = p:sub(3)
  elseif p:sub(1, 2) == "//" then
    p = p:sub(3)
  end
  if p == "" then
    return nil
  end
  if p == ":memory:" then
    return p
  end
  p = p:gsub("^~", vim.env.HOME or "~")
  if not p:match("^/") then
    p = require("dbgrid.project").root() .. "/" .. p
  end
  return p
end

---@param conn dbgrid.Connection
---@param opts { readonly?: boolean, bail?: boolean }
local function argv(conn, opts)
  local args = { M.executable }
  if opts.bail ~= false then
    args[#args + 1] = "-bail"
  end
  if conn.readonly or opts.readonly then
    args[#args + 1] = "-readonly"
  end
  vim.list_extend(args, {
    "-batch",
    "-header",
    "-quote",
    "-separator",
    M.FS,
    "-newline",
    M.RS,
    M.path(conn) or ":memory:",
  })
  return args
end

local function marker(nonce, i)
  return "__DBGRID_" .. nonce .. "__ " .. i
end

---Build the shell script. Returns the script and, per statement, the script
---line range it occupies (for mapping "near line N" errors back).
---@param statements dbgrid.RunStatement[]
---@param nonce string
---@param opts { transaction?: boolean, timing?: boolean, changes?: boolean, wrap?: fun(sql: string, i: integer): string }
---@return string script, {first: integer, last: integer}[] ranges
local function build_script(statements, nonce, opts)
  local lines, ranges = {}, {}
  if opts.timing ~= false then
    lines[#lines + 1] = ".timer on"
  end
  if opts.changes ~= false then
    lines[#lines + 1] = ".changes on"
  end
  if opts.transaction then
    lines[#lines + 1] = "BEGIN;"
  end
  for i, st in ipairs(statements) do
    lines[#lines + 1] = ".print " .. marker(nonce, i)
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
  lines[#lines + 1] = ".print " .. marker(nonce, #statements + 1)
  return table.concat(lines, "\n") .. "\n", ranges
end

---Evaluate the escaping functions newer shells wrap around strings with
---control characters: replace(..., '\n', char(10)), char(n, ...) and
---unistr('\u000a').
---@param name string
---@param args any[]
---@return any
local function call(name, args)
  name = name:lower()
  if name == "char" then
    local parts = {}
    for _, a in ipairs(args) do
      parts[#parts + 1] = vim.fn.nr2char(tonumber(a) or 0)
    end
    return table.concat(parts)
  elseif name == "replace" and #args == 3 and type(args[1]) == "string" and type(args[2]) == "string" then
    return (args[1]:gsub(vim.pesc(args[2]), (tostring(args[3]):gsub("%%", "%%%%"))))
  elseif name == "unistr" and type(args[1]) == "string" then
    return (
      args[1]
        :gsub("\\\\", "\0")
        :gsub("\\u(%x%x%x%x)", function(h)
          return vim.fn.nr2char(tonumber(h, 16))
        end)
        :gsub("\\%+(%x%x%x%x%x%x)", function(h)
          return vim.fn.nr2char(tonumber(h, 16))
        end)
        :gsub("\\U(%x%x%x%x%x%x%x%x)", function(h)
          return vim.fn.nr2char(tonumber(h, 16))
        end)
        :gsub("%z", "\\")
    )
  end
  return name .. "(" .. table.concat(vim.tbl_map(tostring, args), ", ") .. ")"
end

---Read one SQL literal as printed by quote mode, starting at `pos`.
---Text is unquoted, BLOBs stay as their X'..' literal, NULL becomes vim.NIL
---and numbers are returned as printed.
---@param s string
---@param pos integer
---@param stop string pattern of the characters that end a bare token
---@return any value, integer next
local function read_value(s, pos, stop)
  local c = s:sub(pos, pos)
  if c == "'" then
    local parts, i = {}, pos + 1
    while true do
      local q = s:find("'", i, true)
      if not q then
        parts[#parts + 1] = s:sub(i)
        return table.concat(parts), #s + 1
      end
      parts[#parts + 1] = s:sub(i, q - 1)
      if s:sub(q + 1, q + 1) == "'" then
        parts[#parts + 1] = "'"
        i = q + 2
      else
        return table.concat(parts), q + 1
      end
    end
  end
  local blob = s:match("^[xX]'%x*'", pos)
  if blob then
    return blob, pos + #blob
  end
  local fn = s:match("^([%a_][%w_]*)%(", pos)
  if fn then
    local args, i = {}, pos + #fn + 1
    while i <= #s and s:sub(i, i) ~= ")" do
      i = s:find("[^%s,]", i) or #s + 1
      if s:sub(i, i) == ")" then
        break
      end
      local v
      v, i = read_value(s, i, "[,)]")
      args[#args + 1] = v
    end
    return call(fn, args), i + 1
  end
  local e = s:find(stop, pos) or #s + 1
  local token = vim.trim(s:sub(pos, e - 1))
  if token == "NULL" then
    return vim.NIL, e
  end
  return token, e
end

---Split quote-mode output into records of values.
---@param block string
---@return any[][]
local function parse_records(block)
  local records, rec, pos = {}, {}, 1
  local stop = "[" .. M.FS .. M.RS .. "]"
  while pos <= #block do
    local c = block:sub(pos, pos)
    if c == M.RS then
      records[#records + 1] = rec
      rec, pos = {}, pos + 1
    elseif c == M.FS then
      pos = pos + 1
    elseif #rec == 0 and c:match("%s") then
      pos = pos + 1
    else
      local v
      v, pos = read_value(block, pos, stop)
      rec[#rec + 1] = v
    end
  end
  if #rec > 0 then
    records[#records + 1] = rec
  end
  return records
end

---Parse one output block (everything a single statement printed).
---@param block string
---@return dbgrid.ResultSet[] sets, integer? changes, number server_ms
local function parse_block(block)
  local sets, changes, server_ms = {}, nil, 0
  block = block:gsub("Run Time: real ([%d%.]+) user [%d%.]+ sys [%d%.]+\n?", function(secs)
    server_ms = server_ms + tonumber(secs) * 1000
    return ""
  end)
  block = block:gsub("changes: (%d+)%s+total_changes: %d+\n?", function(n)
    changes = tonumber(n)
    return ""
  end)
  local records = parse_records(block)
  if #records == 0 then
    return sets, changes, server_ms
  end
  local set = { columns = records[1], rows = {} }
  for i = 2, #records do
    set.rows[#set.rows + 1] = records[i]
  end
  set.row_count = #set.rows
  for _, row in ipairs(set.rows) do
    for k = #row + 1, #set.columns do
      row[k] = vim.NIL
    end
  end
  sets[1] = set
  return sets, changes, server_ms
end

---Split stdout into per-statement blocks using the markers.
---@param stdout string
---@param nonce string
---@param n integer
---@return string[] blocks
local function split_blocks(stdout, nonce, n)
  local blocks, positions = {}, {}
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

---Parse the shell's stderr into an error.
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
    local script_line, msg = l:match("^%a+ error near line (%d+): (.*)$")
    if not msg then
      msg = l:match("^Error: (.*)$") or l:match("^Parse error: (.*)$") or l:match("^Runtime error: (.*)$")
    end
    if msg and not err then
      msg = msg:gsub("%s*%(%d+%)$", ""):gsub("^in prepare, ", ""):gsub("^stepping, ", "")
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
          for idx = #ranges, 1, -1 do
            if n >= ranges[idx].first then
              err.stmt_index = idx
              break
            end
          end
        end
        local st = err.stmt_index and statements[err.stmt_index]
        if st then
          local r = ranges[err.stmt_index]
          err.stmt_line = n - r.first + 1
          err.line = st.line + math.max(0, math.min(n, r.last) - r.first)
        end
      end
      -- the shell echoes the statement on one line (newlines become spaces,
      -- indented by two) and points at the error: "^--- error here" or
      -- "error here ---^"; the caret's column is an offset into the statement
      i = i + 1
      while i <= #lines do
        local nl = lines[i]
        local caret_pos = nl:find("error here", 1, true) and nl:find("%^")
        if caret_pos then
          local offset = caret_pos - 3 -- 0-based offset into the statement text
          local st = err.stmt_index and statements[err.stmt_index]
          if st and offset >= 0 then
            local before = st.sql:sub(1, offset)
            local _, newlines = before:gsub("\n", "")
            local last_nl = before:match(".*()\n")
            err.line = st.line + newlines
            err.col = last_nl and (#before - last_nl + 1) or (#before + 1)
          end
          i = i + 1
          break
        elseif nl:match("^  ") then
          i = i + 1
        else
          break
        end
      end
    else
      i = i + 1
    end
  end
  return notices, err
end

---Spawn the shell with a script on stdin.
---@param conn dbgrid.Connection
---@param script string
---@param opts { bail?: boolean, timeout_ms?: integer, readonly?: boolean }
---@param cb fun(out: vim.SystemCompleted)
---@return dbgrid.Job
local function spawn(conn, script, opts, cb)
  local path = M.path(conn)
  if path and path ~= ":memory:" and not util.exists(path) and not opts.create then
    vim.schedule(function()
      cb({
        code = 1,
        signal = 0,
        stdout = "",
        stderr = 'Error: unable to open database "' .. path .. '": no such file',
      })
    end)
    return {
      kill = function() end,
      is_done = function()
        return true
      end,
    }
  end
  local done = false
  local ok, proc = pcall(vim.system, argv(conn, opts), {
    stdin = script,
    text = true,
    timeout = opts.timeout_ms,
  }, function(out)
    done = true
    vim.schedule(function()
      cb(out)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ code = 127, signal = 0, stdout = "", stderr = "sqlite3 could not be started: " .. tostring(proc) })
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
    conn = conn,
    kill = function(_, signal)
      return proc:kill(signal)
    end,
    is_done = function()
      return done
    end,
  }
end

---@param st dbgrid.RunStatement
---@param changes integer?
local function tag_for(st, changes)
  if st.class == "write" then
    return string.format("%s %d", st.kind:upper(), changes or 0)
  end
  local a, b = st.sql:match("^%s*(%a+)%s+(%a+)")
  if st.class == "ddl" and a and b then
    return (a .. " " .. b):upper()
  end
  return st.kind:upper()
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
  return spawn(conn, script, { bail = true, timeout_ms = opts.timeout_ms, create = opts.create }, function(out)
    local elapsed = (util.now() - started) * 1000
    local blocks = split_blocks(out.stdout or "", nonce, #statements)
    local results, server_ms = {}, 0
    local notices, err = parse_stderr(out.stderr or "", ranges, statements)
    for i, st in ipairs(statements) do
      local sets, changes, ms = {}, nil, 0
      local ran = blocks[i] ~= nil and not (err and err.stmt_index and err.stmt_index <= i and blocks[i] == "")
      if blocks[i] then
        sets, changes, ms = parse_block(blocks[i])
      end
      server_ms = server_ms + ms
      local tags = {}
      if ran and #sets == 0 and st.class ~= "read" and not (err and err.stmt_index == i) then
        tags[1] = tag_for(st, changes)
      end
      results[i] = {
        sql = st.sql,
        kind = st.kind,
        class = st.class,
        line = st.line,
        limit_applied = st.limit_applied,
        sets = sets,
        tags = tags,
        server_ms = ms,
        ran = ran,
      }
    end
    if err and err.stmt_index then
      for i = err.stmt_index, #statements do
        results[i].ran = false
        results[i].tags = {}
      end
    end
    local cancelled = out.signal == 2 or out.signal == 15 or out.code == 124
    if (out.code ~= 0 or (out.signal or 0) ~= 0) and not err then
      err = {
        message = cancelled and "cancelled" or ("sqlite3 exited with code " .. tostring(out.code)),
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

---Parse the shell's rendering of EXPLAIN QUERY PLAN into a tree.
---@param text string
---@return { sqlite: boolean, nodes: { depth: integer, detail: string }[] }?
function M.parse_plan(text)
  local nodes = {}
  for _, line in ipairs(util.lines(text)) do
    line = line:gsub(M.RS, ""):gsub("\r", "")
    if line ~= "" and line ~= "QUERY PLAN" then
      local depth, rest = 0, line
      while true do
        local head = rest:sub(1, 3)
        if head == "|--" or head == "`--" then
          depth = depth + 1
          rest = rest:sub(4)
          break
        elseif head == "|  " or head == "   " then
          depth = depth + 1
          rest = rest:sub(4)
        else
          break
        end
      end
      if rest:match("%S") then
        nodes[#nodes + 1] = { depth = math.max(0, depth - 1), detail = util.trim(rest) }
      end
    end
  end
  if #nodes == 0 then
    return nil
  end
  return { sqlite = true, nodes = nodes }
end

---EXPLAIN QUERY PLAN for every statement; failures yield nil plans.
---@param conn dbgrid.Connection
---@param statements dbgrid.RunStatement[]
---@param cb fun(plans: table[], err?: string)
---@return dbgrid.Job
function M.explain(conn, statements, cb)
  local nonce = util.short_id(6)
  local script = build_script(statements, nonce, {
    timing = false,
    changes = false,
    wrap = function(sql)
      return "EXPLAIN QUERY PLAN " .. sql
    end,
  })
  return spawn(conn, script, { bail = false, timeout_ms = 30000 }, function(out)
    local blocks = split_blocks(out.stdout or "", nonce, #statements)
    local plans = {}
    for i = 1, #statements do
      if blocks[i] then
        plans[i] = M.parse_plan(blocks[i])
      end
    end
    local err
    if out.code ~= 0 and vim.tbl_isempty(plans) then
      err = util.trim(out.stderr or "")
    end
    cb(plans, err)
  end)
end

---Query plan as text. `analyze` is accepted for interface parity; SQLite has
---no EXPLAIN ANALYZE, so the plan is what is shown.
---@param conn dbgrid.Connection
---@param sql string
---@param analyze boolean
---@param cb fun(lines: string[], err?: string, info?: table)
---@return dbgrid.Job
function M.explain_text(conn, sql, analyze, cb)
  local statements = { { sql = sql, kind = "select", class = "read", line = 1 } }
  return M.explain(conn, statements, function(plans, err)
    local plan = plans[1]
    if not plan then
      cb({}, err or "no plan returned")
      return
    end
    local explain = require("dbgrid.explain")
    local lines, marks = explain.to_lines(plan)
    if analyze then
      table.insert(lines, 1, "")
      table.insert(
        lines,
        1,
        "SQLite has no EXPLAIN ANALYZE; this is the query plan (SCAN = full table scan, SEARCH = index lookup)."
      )
      local shifted = {}
      for k, v in pairs(marks) do
        shifted[k + 2] = v
      end
      marks = shifted
    end
    cb(lines, nil, { plan = plan, marks = marks, findings = {} })
  end)
end

M.SCHEMA_SQL = [[
select json_object(
  'version', 'SQLite ' || sqlite_version(),
  'tables', (select json_group_array(json_object(
      'name', m.name,
      'kind', m.type,
      'columns', (select json_group_array(json_object(
                    'name', p.name, 'type', p.type, 'notnull', p."notnull", 'default', p.dflt_value, 'pk', p.pk))
                  from pragma_table_info(m.name) p),
      'indexes', (select json_group_array(json_object(
                    'name', il.name, 'unique', il."unique", 'origin', il.origin,
                    'columns', (select json_group_array(ii.name) from pragma_index_info(il.name) ii)))
                  from pragma_index_list(m.name) il),
      'fks', (select json_group_array(json_object('id', fk.id, 'from', fk."from", 'table', fk."table", 'to', fk."to", 'seq', fk.seq))
              from pragma_foreign_key_list(m.name) fk)))
    from sqlite_master m where m.type in ('table', 'view') and m.name not like 'sqlite_%' order by m.name)
)]]

---Normalise the JSON document into the shape the Postgres adapter produces.
---@param raw table
---@return table
function M.normalise_schema(raw)
  local function nn(v)
    if v == vim.NIL then
      return nil
    end
    return v
  end
  local tables = {}
  for _, t in ipairs(nn(raw.tables) or {}) do
    local columns, pk = {}, {}
    for _, c in ipairs(nn(t.columns) or {}) do
      columns[#columns + 1] = {
        name = c.name,
        type = (nn(c.type) or ""):lower() ~= "" and nn(c.type) or "any",
        notnull = c.notnull == 1 or c.notnull == true,
        default = nn(c.default),
      }
      if (tonumber(c.pk) or 0) > 0 then
        pk[#pk + 1] = { name = c.name, order = tonumber(c.pk) }
      end
    end
    table.sort(pk, function(a, b)
      return a.order < b.order
    end)
    local pk_cols = vim.tbl_map(function(x)
      return x.name
    end, pk)
    local indexes, has_pk_index = {}, false
    for _, ix in ipairs(nn(t.indexes) or {}) do
      local primary = ix.origin == "pk"
      has_pk_index = has_pk_index or primary
      indexes[#indexes + 1] = {
        name = ix.name,
        unique = ix.unique == 1 or ix.unique == true,
        primary = primary,
        def = "",
        columns = nn(ix.columns) or {},
      }
    end
    if #pk_cols > 0 and not has_pk_index and t.kind == "table" then
      -- rowid tables: the INTEGER PRIMARY KEY is the row id, no index is listed for it
      table.insert(indexes, 1, { name = "(rowid)", unique = true, primary = true, def = "", columns = pk_cols })
    end
    local constraints = {}
    if #pk_cols > 0 then
      constraints[#constraints + 1] = { name = t.name .. "_pkey", type = "p", def = "", columns = pk_cols }
    end
    local fks = {}
    for _, fk in ipairs(nn(t.fks) or {}) do
      local key = tostring(fk.id)
      if not fks[key] then
        fks[key] =
          { name = "fk_" .. key, type = "f", def = "", columns = {}, ref_table = "main." .. fk.table, ref_columns = {} }
        constraints[#constraints + 1] = fks[key]
      end
      fks[key].columns[#fks[key].columns + 1] = fk.from
      fks[key].ref_columns[#fks[key].ref_columns + 1] = nn(fk.to) or "id"
    end
    tables[#tables + 1] = {
      schema = "main",
      name = t.name,
      kind = t.kind == "view" and "v" or "r",
      rows = 0,
      columns = columns,
      indexes = indexes,
      constraints = constraints,
    }
  end
  return { version = nn(raw.version) or "SQLite", schemas = { "main" }, tables = tables, enums = {}, functions = {} }
end

---Fetch the schema: one JSON document, then row counts for the tables.
---@param conn dbgrid.Connection
---@param cb fun(schema?: table, err?: string)
---@return dbgrid.Job
function M.schema(conn, cb)
  local nonce = util.short_id(6)
  local statements = { { sql = M.SCHEMA_SQL, kind = "select", class = "read", line = 1 } }
  local script = build_script(statements, nonce, { timing = false, changes = false })
  return spawn(conn, script, { bail = true, timeout_ms = 60000 }, function(out)
    if out.code ~= 0 then
      local _, e = parse_stderr(out.stderr or "", { { first = 1, last = 1e9 } }, statements)
      cb(nil, e and e.message or util.trim(out.stderr or ("sqlite3 exited with " .. tostring(out.code))))
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
    local data = M.normalise_schema(decoded)
    -- row counts (tables only; views may be expensive)
    local parts, by_name = {}, {}
    for _, t in ipairs(data.tables) do
      by_name[t.name] = t
      if t.kind == "r" and #parts < 500 then
        parts[#parts + 1] =
          string.format("select '%s' as t, count(*) as n from \"%s\"", t.name:gsub("'", "''"), t.name:gsub('"', '""'))
      end
    end
    if #parts == 0 then
      return cb(data)
    end
    local count_stmt = { { sql = table.concat(parts, "\nunion all\n"), kind = "select", class = "read", line = 1 } }
    local nonce2 = util.short_id(6)
    local script2 = build_script(count_stmt, nonce2, { timing = false, changes = false })
    spawn(conn, script2, { bail = true, timeout_ms = 60000 }, function(out2)
      if out2.code == 0 then
        local b2 = split_blocks(out2.stdout or "", nonce2, 1)
        local sets2 = b2[1] and parse_block(b2[1]) or {}
        for _, row in ipairs(sets2[1] and sets2[1].rows or {}) do
          local t = by_name[row[1]]
          if t then
            t.rows = tonumber(row[2]) or 0
          end
        end
      end
      cb(data)
    end)
  end)
end

---@param conn dbgrid.Connection
---@param cb fun(ok: boolean, message: string)
function M.test(conn, cb)
  local statements = { { sql = "select 'SQLite ' || sqlite_version()", kind = "select", class = "read", line = 1 } }
  return M.run(conn, statements, {}, function(res)
    if res.ok then
      local v = res.statements[1].sets[1] and res.statements[1].sets[1].rows[1] and res.statements[1].sets[1].rows[1][1]
      cb(true, tostring(v))
    else
      cb(false, res.error and res.error.message or "failed")
    end
  end)
end

---Cancel a running job: SIGINT interrupts the running statement, SIGTERM
---kills the shell when that did not help.
---@param job dbgrid.Job
function M.cancel(job)
  if not job or not job.kill then
    return
  end
  pcall(job.kill, job, 2)
  vim.defer_fn(function()
    if not (job.is_done and job.is_done()) then
      pcall(job.kill, job, 15)
    end
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
  "natural",
  "group",
  "by",
  "order",
  "having",
  "limit",
  "offset",
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
  "trigger",
  "virtual",
  "alter",
  "drop",
  "begin",
  "commit",
  "rollback",
  "explain",
  "query",
  "plan",
  "exists",
  "between",
  "like",
  "glob",
  "regexp",
  "match",
  "asc",
  "desc",
  "nulls",
  "first",
  "last",
  "over",
  "partition",
  "window",
  "filter",
  "true",
  "false",
  "cast",
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
  "replace",
  "conflict",
  "do",
  "nothing",
  "excluded",
  "pragma",
  "vacuum",
  "analyze",
  "reindex",
  "attach",
  "detach",
  "indexed",
  "without",
  "rowid",
  "strict",
  "autoincrement",
  "collate",
  "escape",
  "isnull",
  "notnull",
  "current_date",
  "current_time",
  "current_timestamp",
  "coalesce",
  "nullif",
}

M.functions = {
  "count",
  "sum",
  "avg",
  "min",
  "max",
  "total",
  "group_concat",
  "string_agg",
  "json_group_array",
  "json_group_object",
  "coalesce",
  "nullif",
  "ifnull",
  "iif",
  "abs",
  "round",
  "length",
  "lower",
  "upper",
  "trim",
  "ltrim",
  "rtrim",
  "substr",
  "substring",
  "instr",
  "replace",
  "printf",
  "format",
  "hex",
  "unhex",
  "quote",
  "typeof",
  "random",
  "randomblob",
  "zeroblob",
  "date",
  "time",
  "datetime",
  "julianday",
  "unixepoch",
  "strftime",
  "timediff",
  "json",
  "json_extract",
  "json_array",
  "json_object",
  "json_array_length",
  "json_type",
  "json_valid",
  "json_each",
  "json_tree",
  "json_set",
  "json_insert",
  "json_replace",
  "json_remove",
  "json_patch",
  "row_number",
  "rank",
  "dense_rank",
  "ntile",
  "lag",
  "lead",
  "first_value",
  "last_value",
  "nth_value",
  "cume_dist",
  "percent_rank",
  "changes",
  "total_changes",
  "last_insert_rowid",
  "sqlite_version",
  "likelihood",
  "likely",
  "unlikely",
  "char",
  "unicode",
  "sign",
  "ceil",
  "floor",
  "power",
  "sqrt",
  "mod",
  "pi",
  "exp",
  "ln",
  "log",
  "log2",
  "log10",
}

-- exposed for tests
M._parse_block = parse_block
M._parse_records = parse_records
M._split_blocks = split_blocks
M._parse_stderr = parse_stderr
M._build_script = build_script

return M
