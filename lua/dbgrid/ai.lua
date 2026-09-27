-- Prompt-to-SQL through a coding agent CLI (claude, kimi, codex, ...).
local config = require("dbgrid.config")
local util = require("dbgrid.util")
local cells = require("dbgrid.cells")
local schema = require("dbgrid.schema")
local sqlmod = require("dbgrid.sql")

local M = {}

---Agents known to the configuration, sorted, with whether they are installed.
---@return { name: string, installed: boolean }[]
function M.agents()
  local cfg = config.get().ai
  local names = vim.tbl_keys(cfg.agents or {})
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local agent = cfg.agents[name]
    out[#out + 1] = { name = name, installed = agent and agent.cmd and vim.fn.executable(agent.cmd[1]) == 1 }
  end
  return out
end

---The agent a cell's prompt goes to: `-- @agent name` in the cell, then the
---notebook's choice (:Dbgrid agent), then `ai.agent`.
---@param s? dbgrid.State
---@param cell? dbgrid.Cell
---@return string
function M.agent_name(s, cell)
  local d = cell and cells.directives(cell) or {}
  if type(d.agent) == "string" and d.agent ~= "" then
    return d.agent
  end
  if s and s.nb and s.nb.meta.agent and s.nb.meta.agent ~= "" then
    return s.nb.meta.agent
  end
  return config.get().ai.agent
end

---Switch the notebook's agent (nil = back to the configured default).
---@param s dbgrid.State
---@param name string?
---@return boolean ok
function M.set_agent(s, name)
  local cfg = config.get().ai
  if name and not cfg.agents[name] then
    util.error("unknown agent '" .. name .. "' (configure ai.agents)")
    return false
  end
  require("dbgrid.notebook").set_agent(s.nb, name)
  require("dbgrid.ui.query").refresh_winbar(s)
  util.notify("agent: " .. M.agent_name(s))
  return true
end

---Pick the agent for the notebook.
---@param s dbgrid.State
---@param cb? fun(name?: string)
function M.pick_agent(s, cb)
  local current = M.agent_name(s)
  local items = {}
  for _, a in ipairs(M.agents()) do
    local cfg_agent = config.get().ai.agents[a.name]
    items[#items + 1] = {
      text = string.format(
        "%s%s%s",
        a.name,
        a.name == current and "  (current)" or "",
        a.installed and "" or "  (not on PATH)"
      ),
      data = a.name,
      preview = { table.concat(cfg_agent.cmd or {}, " ") },
    }
  end
  items[#items + 1] = { text = "use the configured default (" .. config.get().ai.agent .. ")", data = false }
  require("dbgrid.ui.picker").pick(items, {
    prompt = "Coding agent for prompts",
    preview = false,
    on_select = function(item)
      if not item then
        return cb and cb(nil)
      end
      local name = item.data or nil
      if M.set_agent(s, name) and cb then
        cb(M.agent_name(s))
      end
    end,
  })
end

---Build the text handed to the agent.
---@param opts { prompt: string, existing_sql?: string, schema?: dbgrid.SchemaData, context_sql?: string[], dialect?: string, instructions?: string, max_tables?: integer, framework?: string, params?: string[] }
---@return string
function M.build_prompt(opts)
  local cfg = config.get().ai
  local parts = {}
  parts[#parts + 1] = string.format(
    "You write %s queries for a developer working inside a SQL notebook.\n"
      .. "Reply with SQL only: no prose, no markdown fences, no explanation. End the statement with a semicolon.\n"
      .. "Prefer readable SQL: one clause per line, explicit JOIN ... ON, explicit column lists. "
      .. "Do not add a LIMIT unless the request asks for one (the notebook adds one). "
      .. "Only use tables and columns from the schema below; if something is missing, make the closest reasonable guess and add a `-- note:` comment line.",
    opts.dialect or cfg.dialect or "PostgreSQL"
  )
  if (opts.instructions or cfg.instructions or "") ~= "" then
    parts[#parts + 1] = opts.instructions or cfg.instructions
  end
  if opts.framework == "rails" then
    parts[#parts + 1] = require("dbgrid.rails").AGENT_HINT
  end
  if opts.params and #opts.params > 0 then
    parts[#parts + 1] = "Parameters available as `:name` placeholders (keep them as placeholders, do not invent values): :"
      .. table.concat(opts.params, ", :")
  end
  parts[#parts + 1] = "## Request\n" .. opts.prompt
  if opts.existing_sql and util.trim(opts.existing_sql) ~= "" then
    parts[#parts + 1] = "## Existing SQL in this cell (modify it according to the request, keep its intent)\n"
      .. opts.existing_sql
  end
  if opts.schema then
    local max = opts.max_tables or cfg.max_tables or 40
    local tables = schema.relevant_tables(
      opts.schema,
      opts.prompt,
      (opts.existing_sql or "") .. "\n" .. table.concat(opts.context_sql or {}, "\n"),
      max
    )
    if opts.framework == "rails" then
      local system = require("dbgrid.rails").SYSTEM_TABLES
      tables = vim.tbl_filter(function(t)
        return not system[t.name]
      end, tables)
    end
    local lines = {}
    for _, t in ipairs(tables) do
      lines[#lines + 1] = schema.format_table_for_ai(t)
    end
    parts[#parts + 1] = string.format(
      "## Schema (%d of %d tables; format: table(column type flags, ...))\n%s",
      #tables,
      #opts.schema.tables,
      table.concat(lines, "\n")
    )
    if #opts.schema.enums > 0 then
      local enums = {}
      for _, e in ipairs(opts.schema.enums) do
        enums[#enums + 1] = e.name .. "(" .. table.concat(e.values or {}, ", ") .. ")"
      end
      parts[#parts + 1] = "## Enum types\n" .. table.concat(enums, "\n")
    end
  end
  if opts.context_sql and #opts.context_sql > 0 then
    parts[#parts + 1] = "## Other queries in this notebook (context only)\n" .. table.concat(opts.context_sql, "\n\n")
  end
  return table.concat(parts, "\n\n") .. "\n"
end

---Turn agent output into SQL text.
---@param out string
---@return string? sql, string? err
function M.clean_output(out)
  out = out or ""
  local fenced = out:match("```%s*[%w]*%s*\n(.-)```")
  if fenced then
    out = fenced
  end
  out = util.trim(out:gsub("\r\n", "\n"))
  if out == "" then
    return nil, "the agent returned nothing"
  end
  local stmts = sqlmod.split(out)
  if #stmts == 0 or not sqlmod.looks_like_sql(stmts[1]) then
    return nil, "the agent did not return SQL: " .. util.truncate(out:gsub("\n", " "), 120)
  end
  return out
end

---Agent command with placeholders substituted.
---@param agent { cmd: string[], stdin?: boolean }
---@param prompt string
---@param output_path string
---@return string[] argv, boolean uses_output
local function build_argv(agent, prompt, output_path)
  local argv, uses_output = {}, false
  for _, a in ipairs(agent.cmd) do
    if a == "{prompt}" then
      argv[#argv + 1] = prompt
    elseif a == "{output}" then
      argv[#argv + 1] = output_path
      uses_output = true
    else
      argv[#argv + 1] = (a:gsub("{prompt}", prompt):gsub("{output}", output_path))
    end
  end
  return argv, uses_output
end

---Replace string and numeric literals so production values never leave the machine.
---@param text string
---@return string
function M.redact(text)
  if not text then
    return text
  end
  local out = text:gsub("'[^']*'", "'?'"):gsub("(%W)%-?%d+%.?%d*", "%1?")
  return out
end

---The `dbgrid-query` helper the agent may call when `ai.investigate` is on:
---a script bound to one connection, read-only, with a statement timeout.
---@param conn dbgrid.Connection
---@return string dir, table<string,string> env
local function investigate_helper(conn)
  local dir = vim.fn.tempname()
  util.mkdirp(dir)
  local script = table.concat({
    "#!/bin/sh",
    "# dbgrid-query: run one read-only statement on the connection the notebook analyzes.",
    'if [ -z "$1" ]; then echo "usage: dbgrid-query \'<sql>\'" >&2; exit 2; fi',
    'exec psql "$DBGRID_QUERY_URL" -X -v ON_ERROR_STOP=1 -c "$1"',
  }, "\n") .. "\n"
  util.write_file(dir .. "/dbgrid-query", script)
  pcall(vim.uv.fs_chmod, dir .. "/dbgrid-query", 493) -- 0755
  local env = {
    DBGRID_QUERY_URL = conn.url,
    PGOPTIONS = "-c default_transaction_read_only=on -c statement_timeout=15000",
    PATH = dir .. ":" .. (vim.env.PATH or ""),
  }
  for k, v in pairs(conn.env or {}) do
    env[k] = v
  end
  return dir, env
end

---Argv of an agent with the investigation tool allowed (claude: Bash(dbgrid-query:*)).
---@param agent table
---@return table agent
local function investigate_agent(agent)
  local copy = vim.deepcopy(agent)
  if copy.investigate_cmd then
    copy.cmd = copy.investigate_cmd
    return copy
  end
  local cmd = copy.cmd
  for i, a in ipairs(cmd) do
    if a == "--disallowedTools" and cmd[i + 1] then
      cmd[i + 1] = table.concat(
        vim.tbl_filter(function(t)
          return t ~= "Bash"
        end, vim.split(cmd[i + 1], ",", { trimempty = true })),
        ","
      )
      cmd[#cmd + 1] = "--allowedTools"
      cmd[#cmd + 1] = "Bash(dbgrid-query:*)"
      break
    end
  end
  return copy
end

---Run the agent with a prompt and hand back the raw answer.
---@param prompt string
---@param cb fun(text?: string, err?: string)
---@param opts? { agent?: string, connection?: dbgrid.Connection }
---@return dbgrid.Job?
function M.run_agent(prompt, cb, opts)
  opts = opts or {}
  local cfg = config.get().ai
  local agent_name = opts.agent or cfg.agent
  local agent = cfg.agents[agent_name]
  if not agent then
    cb(nil, "unknown agent '" .. tostring(agent_name) .. "' (configure ai.agents)")
    return nil
  end
  if vim.fn.executable(agent.cmd[1]) ~= 1 then
    cb(nil, "'" .. agent.cmd[1] .. "' is not on PATH")
    return nil
  end
  local env, helper_dir
  if cfg.investigate and opts.connection and opts.connection.ai ~= false then
    helper_dir, env = investigate_helper(opts.connection)
    agent = investigate_agent(agent)
    prompt = prompt
      .. "\n## Tool\nYou may run read-only SQL against the same database with the shell command"
      .. " `dbgrid-query '<sql>'` (one statement per call, 15 s timeout). Use it to check table statistics,"
      .. " row counts, existing indexes or alternative EXPLAIN plans before answering.\n"
  end
  local output_path = vim.fn.tempname()
  local argv, uses_output = build_argv(agent, prompt, output_path)
  local ok, job = pcall(vim.system, argv, {
    stdin = agent.stdin and prompt or nil,
    text = true,
    timeout = cfg.timeout_ms,
    cwd = require("dbgrid.project").root(),
    env = env,
  }, function(out)
    vim.schedule(function()
      local text = out.stdout or ""
      if uses_output then
        text = util.read_file(output_path) or ""
        pcall(os.remove, output_path)
      end
      if helper_dir then
        pcall(vim.fn.delete, helper_dir, "rf")
      end
      if out.code ~= 0 and util.trim(text) == "" then
        cb(
          nil,
          string.format("%s exited with %d: %s", agent_name, out.code, util.truncate(util.trim(out.stderr or ""), 200))
        )
        return
      end
      cb(text)
    end)
  end)
  if not ok then
    cb(nil, "could not start " .. agent_name .. ": " .. tostring(job))
    return nil
  end
  return job
end

---Run the agent with a prompt; the answer must be SQL.
---@param prompt string
---@param cb fun(sql?: string, err?: string)
---@param agent_name? string
---@return dbgrid.Job?
function M.ask(prompt, cb, agent_name)
  return M.run_agent(prompt, function(text, err)
    if not text then
      return cb(nil, err)
    end
    cb(M.clean_output(text))
  end, { agent = agent_name })
end

---Run the agent with a prompt; the answer is free text (markdown).
---@param prompt string
---@param cb fun(text?: string, err?: string)
---@param opts? { agent?: string, connection?: dbgrid.Connection }
---@return dbgrid.Job?
function M.ask_text(prompt, cb, opts)
  return M.run_agent(prompt, function(text, err)
    if not text then
      return cb(nil, err)
    end
    text = util.trim((text or ""):gsub("\r\n", "\n"))
    if text == "" then
      return cb(nil, "the agent returned nothing")
    end
    cb(text)
  end, opts)
end

---@param tables dbgrid.SchemaTable[]
---@return string
local function describe_tables(tables)
  local schema_mod = require("dbgrid.schema")
  local parts = {}
  for _, t in ipairs(tables or {}) do
    parts[#parts + 1] = table.concat(schema_mod.describe_lines(t), "\n")
  end
  return table.concat(parts, "\n\n")
end

---@param stats { columns: string[], rows: any[][] }?
---@return string?
local function format_stats(stats)
  if not stats or #stats.rows == 0 then
    return nil
  end
  local lines = { table.concat(stats.columns, " | ") }
  for _, row in ipairs(stats.rows) do
    local vals = {}
    for j = 1, #stats.columns do
      local v = row[j]
      vals[j] = (v == vim.NIL or v == nil) and "null" or tostring(v)
    end
    lines[#lines + 1] = table.concat(vals, " | ")
  end
  return table.concat(lines, "\n")
end

---Prompt for `:Dbgrid analyze`.
---@param opts { sql: string, plan_lines: string[], summary?: table, findings?: string[], tables?: dbgrid.SchemaTable[],
---  stats?: table, version?: string, analyzed?: boolean }
---@return string
function M.build_analyze_prompt(opts)
  local cfg = config.get().ai
  local redact = cfg.redact_literals and M.redact or function(t)
    return t
  end
  local parts = {}
  parts[#parts + 1] = string.format(
    "You are a %s performance expert reading a query plan for a developer who is not a database specialist.\n"
      .. "Answer in markdown with exactly these four sections, each short and concrete:\n"
      .. "## What is slow\n## Why\n## Fix\n## Verify\n"
      .. "In Fix, give the SQL to run (an index, a rewrite of the query, a setting) in ```sql fences,"
      .. " one statement per fence,"
      .. " and say what it costs (lock, disk, time). In Verify, say what to measure after the change."
      .. " Refer to plan nodes by name. Do not repeat the plan. Do not invent tables or columns.",
    opts.version and opts.version:match("^PostgreSQL [%d%.]+") or cfg.dialect or "PostgreSQL"
  )
  if (cfg.instructions or "") ~= "" then
    parts[#parts + 1] = cfg.instructions
  end
  parts[#parts + 1] = "## Query\n```sql\n" .. redact(opts.sql) .. "\n```"
  local head = opts.analyzed and "## Plan (EXPLAIN ANALYZE, BUFFERS)" or "## Plan (EXPLAIN, estimates only)"
  if opts.summary then
    local bits = {}
    if opts.summary.execution_ms then
      bits[#bits + 1] = string.format("execution %.1f ms", opts.summary.execution_ms)
    end
    if opts.summary.planning_ms then
      bits[#bits + 1] = string.format("planning %.1f ms", opts.summary.planning_ms)
    end
    if opts.summary.total_cost then
      bits[#bits + 1] = "total cost " .. tostring(opts.summary.total_cost)
    end
    if #bits > 0 then
      head = head .. " · " .. table.concat(bits, ", ")
    end
  end
  parts[#parts + 1] = head .. "\n```\n" .. redact(table.concat(opts.plan_lines or {}, "\n")) .. "\n```"
  if opts.findings and #opts.findings > 0 then
    parts[#parts + 1] = "## Rule-based findings (verify them)\n- " .. table.concat(opts.findings, "\n- ")
  end
  if opts.tables and #opts.tables > 0 then
    parts[#parts + 1] = "## Tables involved (columns, indexes)\n" .. describe_tables(opts.tables)
  end
  local stats = format_stats(opts.stats)
  if stats then
    parts[#parts + 1] = "## Table statistics (pg_stat_user_tables)\n" .. stats
  end
  return table.concat(parts, "\n\n") .. "\n"
end

---Prompt for "explain this error".
---@param opts { sql: string, error: dbgrid.RunError, tables?: dbgrid.SchemaTable[], version?: string,
---  schema?: dbgrid.SchemaData }
---@return string
function M.build_error_prompt(opts)
  local cfg = config.get().ai
  local redact = cfg.redact_literals and M.redact or function(t)
    return t
  end
  local parts = {}
  parts[#parts + 1] = string.format(
    "You help a developer fix a failing %s statement inside a SQL notebook.\n"
      .. "Answer in markdown with two sections: ## Cause (one or two sentences) and ## Fix (the corrected SQL in a"
      .. " ```sql fence, then one sentence on why it works). If the error is about data or permissions rather than"
      .. " the SQL, say what to check instead. Only use tables and columns from the schema below.",
    opts.version and opts.version:match("^PostgreSQL [%d%.]+") or cfg.dialect or "PostgreSQL"
  )
  if (cfg.instructions or "") ~= "" then
    parts[#parts + 1] = cfg.instructions
  end
  parts[#parts + 1] = "## Statement\n```sql\n" .. redact(opts.sql) .. "\n```"
  local e = opts.error
  local err = { "ERROR: " .. tostring(e.message) }
  if e.line then
    err[#err + 1] = "at line " .. e.line .. (e.col and (", column " .. e.col) or "") .. " of the statement"
  end
  if e.detail then
    err[#err + 1] = "DETAIL: " .. e.detail
  end
  if e.hint then
    err[#err + 1] = "HINT: " .. e.hint
  end
  if e.context then
    err[#err + 1] = "CONTEXT: " .. e.context
  end
  parts[#parts + 1] = "## Error\n" .. redact(table.concat(err, "\n"))
  local tables = opts.tables or {}
  if #tables == 0 and opts.schema then
    tables = require("dbgrid.schema").relevant_tables(opts.schema, opts.sql .. " " .. tostring(e.message), opts.sql, 10)
  end
  if #tables > 0 then
    parts[#parts + 1] = "## Tables\n" .. describe_tables(tables)
  end
  return table.concat(parts, "\n\n") .. "\n"
end

---Fenced SQL blocks of a markdown answer.
---@param text string
---@return string[]
function M.sql_blocks(text)
  local out = {}
  for block in (text or ""):gmatch("```sql%s*\n(.-)```") do
    block = util.trim(block)
    if block ~= "" then
      out[#out + 1] = block
    end
  end
  return out
end

---Replace the SQL of a cell, keeping prompt and directive lines on top.
---@param buf integer
---@param cell dbgrid.Cell
---@param sql string
---@return dbgrid.Cell
function M.write_sql(buf, cell, sql)
  local keep = {}
  for _, l in ipairs(cell.lines) do
    if l:match(cells.PROMPT) or l:match(cells.DIRECTIVE) then
      keep[#keep + 1] = l
    end
  end
  local new = vim.deepcopy(keep)
  for _, l in ipairs(util.lines(sql)) do
    new[#new + 1] = l
  end
  new[#new + 1] = ""
  local first = cell.first - 1
  local last = math.max(cell.last, cell.first - 1)
  vim.api.nvim_buf_set_lines(buf, first, last, false, new)
  vim.b[buf].dbgrid_cells_cache = nil
  return cells.by_id(buf, cell.id) or cell
end

---Generate SQL for a cell from its `-- ?` prompt (asks for one if missing).
---@param s dbgrid.State
---@param cell dbgrid.Cell
function M.generate(s, cell)
  cells.ensure_ids(s.buf)
  cell = cells.by_id(s.buf, cell.id) or cells.parse(s.buf)[cell.index] or cell
  local prompt = cells.prompt(cell)
  if not prompt then
    vim.ui.input({ prompt = "Describe the query: " }, function(input)
      if not input or util.trim(input) == "" then
        return
      end
      vim.api.nvim_buf_set_lines(s.buf, cell.first - 1, cell.first - 1, false, { "-- ? " .. input })
      vim.b[s.buf].dbgrid_cells_cache = nil
      local fresh = cells.by_id(s.buf, cell.id)
      if fresh then
        M.generate(s, fresh)
      end
    end)
    return
  end
  if s.running[cell.id] then
    return util.warn("cell is busy")
  end
  local query_ui = require("dbgrid.ui.query")
  require("dbgrid.runner").with_connection(s, nil, function(conn)
    s.runtime[cell.id] = vim.tbl_extend("force", s.runtime[cell.id] or {}, { status = "generating" })
    query_ui.render(s)
    require("dbgrid.ui.results").render(s)
    schema.get(conn, function(sch, err)
      if err then
        util.warn("schema unavailable, generating without it: " .. err)
      end
      local context = {}
      for _, other in ipairs(cells.parse(s.buf)) do
        if other.id ~= cell.id and cells.has_sql(other) and #context < 5 then
          context[#context + 1] = "-- q"
            .. other.index
            .. ": "
            .. cells.label(other, 60)
            .. "\n"
            .. util.truncate(cells.body_text(other), 400)
        end
      end
      local existing = {}
      for _, l in ipairs(cell.lines) do
        if not l:match(cells.PROMPT) and not l:match(cells.DIRECTIVE) then
          existing[#existing + 1] = l
        end
      end
      local existing_sql = util.trim(table.concat(existing, "\n"))
      local params = {}
      for _, p in ipairs(require("dbgrid.expand").notebook_params(s)) do
        params[#params + 1] = p.name
      end
      local adapter = require("dbgrid.adapters").for_connection(conn)
      local text = M.build_prompt({
        prompt = prompt,
        existing_sql = existing_sql ~= "" and existing_sql or nil,
        schema = sch,
        context_sql = context,
        framework = require("dbgrid.project").framework(),
        params = params,
        dialect = (adapter and adapter.name ~= "postgres" and adapter.dialect) or nil,
      })
      local agent_name = M.agent_name(s, cell)
      util.notify("asking " .. agent_name .. "…")
      local started = util.now()
      s.running[cell.id] = { started = started, kind = "ai" }
      query_ui.start_spinner(s)
      local job = M.ask(text, function(sql, e)
        s.running[cell.id] = nil
        if not vim.api.nvim_buf_is_valid(s.buf) then
          return
        end
        local fresh = cells.by_id(s.buf, cell.id)
        if not fresh then
          return
        end
        if not sql then
          s.runtime[fresh.id] = { status = nil }
          query_ui.render(s)
          require("dbgrid.ui.results").render(s)
          return util.error("generation failed: " .. tostring(e))
        end
        local updated = M.write_sql(s.buf, fresh, sql)
        s.runtime[updated.id] = { status = "generated", generated_hash = cells.hash(updated) }
        query_ui.render(s)
        require("dbgrid.ui.results").render(s)
        util.notify(string.format("generated in %s — review, then run", util.fmt_ms((util.now() - started) * 1000)))
      end, agent_name)
      if job then
        s.running[cell.id].job = job
      else
        s.running[cell.id] = nil
      end
    end)
  end)
end

---Cancel a running generation.
---@param s dbgrid.State
---@param cell? dbgrid.Cell
function M.cancel(s, cell)
  for id, r in pairs(s.running) do
    if r.kind == "ai" and (not cell or cell.id == id) and r.job then
      pcall(r.job.kill, r.job, 15)
    end
  end
end

return M
