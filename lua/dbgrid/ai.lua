-- Talking to a coding agent CLI (claude, kimi, codex, ...): prompt-to-SQL for
-- `-- ?` cells, and questions about a query and its result.
local config = require("dbgrid.config")
local util = require("dbgrid.util")
local cells = require("dbgrid.cells")
local schema = require("dbgrid.schema")
local sqlmod = require("dbgrid.sql")

local M = {}

-- Asked when the user leaves the question empty.
M.DEFAULT_QUESTION = "What does this result show? Point out anything unusual, wrong or worth attention."

---Build the text handed to the agent.
---@param opts { prompt: string, existing_sql?: string, schema?: dbgrid.SchemaData, context_sql?: string[], dialect?: string, instructions?: string, max_tables?: integer }
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

---Run the agent with a prompt and hand back its raw answer.
---@param prompt string
---@param cb fun(text?: string, err?: string)
---@param agent_name? string
---@return dbgrid.Job?
function M.run(prompt, cb, agent_name)
  local cfg = config.get().ai
  agent_name = agent_name or cfg.agent
  local agent = cfg.agents[agent_name]
  if not agent then
    cb(nil, "unknown agent '" .. tostring(agent_name) .. "' (configure ai.agents)")
    return nil
  end
  if vim.fn.executable(agent.cmd[1]) ~= 1 then
    cb(nil, "'" .. agent.cmd[1] .. "' is not on PATH")
    return nil
  end
  local output_path = vim.fn.tempname()
  local argv, uses_output = build_argv(agent, prompt, output_path)
  local ok, job = pcall(vim.system, argv, {
    stdin = agent.stdin and prompt or nil,
    text = true,
    timeout = cfg.timeout_ms,
    cwd = require("dbgrid.project").root(),
  }, function(out)
    vim.schedule(function()
      local text = out.stdout or ""
      if uses_output then
        text = util.read_file(output_path) or ""
        pcall(os.remove, output_path)
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

---Run the agent with a prompt that expects SQL back.
---@param prompt string
---@param cb fun(sql?: string, err?: string)
---@param agent_name? string
---@return dbgrid.Job?
function M.ask(prompt, cb, agent_name)
  return M.run(prompt, function(text, err)
    if not text then
      return cb(nil, err)
    end
    cb(M.clean_output(text))
  end, agent_name)
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
      local text = M.build_prompt({
        prompt = prompt,
        existing_sql = existing_sql ~= "" and existing_sql or nil,
        schema = sch,
        context_sql = context,
      })
      local agent_name = config.get().ai.agent
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
      end)
      if job then
        s.running[cell.id].job = job
      else
        s.running[cell.id] = nil
      end
    end)
  end)
end

---One value as the agent sees it: NULL spelled out, newlines folded, long text cut.
---@param v any
---@param max integer
---@return string
local function value_text(v, max)
  if v == vim.NIL or v == nil then
    return "NULL"
  end
  return util.truncate((tostring(v):gsub("%s*\r?\n%s*", " ")), max)
end

---@class dbgrid.ReviewPromptOpts
---@field question string
---@field sql string                  the SQL as it ran
---@field sql_edited? boolean         the cell changed after this run
---@field cell_label? string
---@field result? table               cached result of the cell
---@field rows_of? fun(entry: { set: dbgrid.ResultSet, stmt: dbgrid.StatementResult, stmt_index: integer }): any[][]
---@field rows_note? string           how the rows differ from the raw result (filter, sort)
---@field plan? string[]              plan lines
---@field plan_kind? string           what kind of plan (EXPLAIN, EXPLAIN ANALYZE, estimated)
---@field tables? dbgrid.SchemaTable[]
---@field history? { question: string, answer: string }[]   earlier turns about the same result
---@field dialect? string
---@field max_rows? integer

---Build the text handed to the agent when asking about a query and its result.
---@param opts dbgrid.ReviewPromptOpts
---@return string
function M.build_review_prompt(opts)
  local cfg = config.get().ai
  local max_rows = opts.max_rows or cfg.max_result_rows or 100
  local parts = {}
  parts[#parts + 1] = string.format(
    "A developer ran a SQL query against %s in a notebook and is looking at its result. "
      .. "Answer their question about the query and the result together: say what the rows mean, "
      .. "point out anything unusual, wrong or worth attention, and suggest a concrete next step "
      .. "(a follow-up query, an index, a setting) when it helps. "
      .. "Be concise and specific: refer to columns and values by name and do not repeat the whole result. "
      .. "Plain text with light markdown, no tables.",
    opts.dialect or cfg.dialect or "PostgreSQL"
  )
  parts[#parts + 1] = "## Question\n" .. opts.question
  local head = "## Query"
  if opts.cell_label then
    head = head .. " (cell " .. opts.cell_label .. ")"
  end
  if opts.sql_edited then
    head = head .. "\nThe cell was edited after this run; this is the SQL that produced the result."
  end
  parts[#parts + 1] = head .. "\n" .. opts.sql
  local result = opts.result
  if result then
    local lines = {}
    local summary = {}
    if result.ran_at then
      summary[#summary + 1] = "ran at " .. os.date("%Y-%m-%d %H:%M:%S", result.ran_at)
    end
    if result.connection then
      summary[#summary + 1] = "on connection " .. result.connection
    end
    if result.elapsed_ms then
      summary[#summary + 1] = "took "
        .. util.fmt_ms(result.elapsed_ms)
        .. (result.server_ms and result.server_ms > 0 and (" (server " .. util.fmt_ms(result.server_ms) .. ")") or "")
    end
    if #summary > 0 then
      lines[#lines + 1] = table.concat(summary, ", ")
    end
    if opts.rows_note then
      lines[#lines + 1] = "The rows below are as displayed in the grid: " .. opts.rows_note .. "."
    end
    local stmts = result.statements or {}
    for i, st in ipairs(stmts) do
      if #stmts > 1 then
        lines[#lines + 1] = string.format("### Statement %d of %d (%s)", i, #stmts, (st.kind or "?"):upper())
      end
      if st.limit_applied then
        lines[#lines + 1] = string.format(
          "The notebook added LIMIT %d to this statement%s.",
          st.limit_applied,
          result.truncated and ", and it was hit: there may be more rows" or ""
        )
      end
      for _, set in ipairs(st.sets or {}) do
        local entry = { set = set, stmt = st, stmt_index = i }
        local rows = opts.rows_of and opts.rows_of(entry) or set.rows
        local total = set.row_count or #set.rows
        local shown = math.min(#rows, max_rows)
        if shown == 0 then
          lines[#lines + 1] = "(no rows)"
        else
          local count = util.fmt_int(total) .. (total == 1 and " row" or " rows")
          if shown < total or shown < #rows then
            count = count .. ", first " .. shown .. " shown"
          end
          lines[#lines + 1] = count .. ":"
          lines[#lines + 1] = table.concat(set.columns, " | ")
          for r = 1, shown do
            local vals = {}
            for j = 1, #set.columns do
              vals[j] = value_text(rows[r][j], 200)
            end
            lines[#lines + 1] = table.concat(vals, " | ")
          end
        end
      end
      if #(st.sets or {}) == 0 then
        for _, tag in ipairs(st.tags or {}) do
          lines[#lines + 1] = tag
        end
      end
    end
    if result.notices and #result.notices > 0 then
      lines[#lines + 1] = "Notices from the server:"
      for _, n in ipairs(result.notices) do
        lines[#lines + 1] = tostring(n)
      end
    end
    if result.warnings and #result.warnings > 0 then
      lines[#lines + 1] = "Index check before the run warned:"
      for _, w in ipairs(result.warnings) do
        lines[#lines + 1] = "- " .. (type(w) == "table" and w.message or tostring(w))
      end
    end
    if result.error then
      local e = result.error
      if e.cancelled then
        lines[#lines + 1] = "The query was cancelled before it finished."
      else
        lines[#lines + 1] = "The query failed with an error:"
        lines[#lines + 1] = "ERROR: " .. tostring(e.message)
        if e.line then
          lines[#lines + 1] = string.format("at line %d%s of the cell", e.line, e.col and (", column " .. e.col) or "")
        end
        if e.detail then
          lines[#lines + 1] = "DETAIL: " .. e.detail
        end
        if e.hint then
          lines[#lines + 1] = "HINT: " .. e.hint
        end
        if e.context then
          lines[#lines + 1] = "CONTEXT: " .. e.context
        end
      end
    end
    parts[#parts + 1] = "## Result\n" .. table.concat(lines, "\n")
  else
    parts[#parts + 1] = "## Result\nThe cell has not been run; only its plan is available."
  end
  if opts.plan and #opts.plan > 0 then
    local max_plan = 80
    local plan = opts.plan
    if #plan > max_plan then
      plan = vim.list_slice(plan, 1, max_plan)
      plan[#plan + 1] = string.format("… (%d more lines)", #opts.plan - max_plan)
    end
    parts[#parts + 1] = "## Plan (" .. (opts.plan_kind or "EXPLAIN") .. ")\n" .. table.concat(plan, "\n")
  end
  if opts.tables and #opts.tables > 0 then
    local lines = {}
    for _, t in ipairs(opts.tables) do
      lines[#lines + 1] = schema.format_table_for_ai(t)
    end
    parts[#parts + 1] = "## Tables used (format: table(column type flags, ...))\n" .. table.concat(lines, "\n")
  end
  if opts.history and #opts.history > 0 then
    local lines = {}
    for _, turn in ipairs(opts.history) do
      lines[#lines + 1] = "Q: " .. turn.question
      lines[#lines + 1] = "A: " .. util.truncate(turn.answer, 1500)
    end
    parts[#parts + 1] = "## Earlier questions about this same result\n" .. table.concat(lines, "\n")
  end
  return table.concat(parts, "\n\n") .. "\n"
end

---Ask the agent about a cell's query and its result, then show the answer.
---Without a question one is asked for; an empty answer uses the default one.
---@param s dbgrid.State
---@param cell dbgrid.Cell
---@param question? string
function M.review(s, cell, question)
  cells.ensure_ids(s.buf)
  cell = cells.by_id(s.buf, cell.id) or cells.parse(s.buf)[cell.index] or cell
  local notebook = require("dbgrid.notebook")
  local result = notebook.result_of(s.nb, cell.id)
  local rt = s.runtime[cell.id] or {}
  if not result and not rt.plan_text then
    return util.warn("run the cell first; there is no result to ask about")
  end
  local review_ui = require("dbgrid.ui.review")
  local transcript = rt.review
  if transcript and transcript.ran_at ~= (result and result.ran_at or nil) then
    transcript = nil -- earlier questions were about another run
  end
  if not question then
    review_ui.close(s)
    local asked_before = transcript and #transcript.turns > 0
    vim.ui.input({
      prompt = asked_before and "Follow-up (empty shows the last answer): " or "Ask about the query and result: ",
    }, function(input)
      if input == nil then
        return
      end
      input = util.trim(input)
      if input ~= "" then
        M.review(s, cell, input)
      elseif asked_before then
        review_ui.open(s, cells.by_id(s.buf, cell.id) or cell)
      else
        M.review(s, cell, M.DEFAULT_QUESTION)
      end
    end)
    return
  end
  if s.running[cell.id] then
    return util.warn("cell is busy")
  end
  -- the SQL that produced the result (the cell may have changed since)
  local sql
  if result and result.statements and #result.statements > 0 then
    local stmts = {}
    for _, st in ipairs(result.statements) do
      stmts[#stmts + 1] = util.trim(st.sql or "") .. ";"
    end
    sql = table.concat(stmts, "\n")
  else
    sql = util.trim(cells.sql_text(cell))
  end
  local sql_edited = result and result.sql_hash and result.sql_hash ~= cells.hash(cell) or false
  -- rows as the grid shows them when a filter or sort is active
  local rows_of, rows_note
  local view = s.view
  if result and view.cell_id == cell.id and (view.filter or (view.sort and view.sort.col)) then
    local results_ui = require("dbgrid.ui.results")
    rows_of = function(entry)
      return results_ui.display_rows(s, entry)
    end
    local notes = {}
    if view.filter and view.filter ~= "" then
      notes[#notes + 1] = 'filtered to rows containing "' .. view.filter .. '"'
    end
    if view.sort and view.sort.col then
      local st = (result.statements or {})[view.sort.set]
      local set = st and st.sets and st.sets[1]
      local name = set and set.columns[view.sort.col] or ("column " .. view.sort.col)
      notes[#notes + 1] = "sorted by " .. name .. (view.sort.dir == "desc" and " descending" or " ascending")
    end
    rows_note = table.concat(notes, ", ")
  end
  -- the plan: an explicit EXPLAIN when there is one, else the pre-run estimate
  local plan, plan_kind
  if rt.plan_text then
    plan, plan_kind = rt.plan_text, rt.plan_kind or "EXPLAIN"
  elseif result then
    local explain = require("dbgrid.explain")
    for i, st in ipairs(result.statements or {}) do
      if st.plan then
        plan = plan or {}
        if #result.statements > 1 then
          plan[#plan + 1] = "statement " .. i .. ":"
        end
        vim.list_extend(plan, explain.to_lines(st.plan))
      end
    end
    plan_kind = plan and "estimated, from the EXPLAIN run before the query; not ANALYZE" or nil
  end
  -- the tables the query reads, from the schema cache (no fetch)
  local tables = {}
  local conn_name = result and result.connection or s.nb.meta.connection
  local conn = conn_name and require("dbgrid.connections").get(conn_name)
  local sch = conn and schema.loaded(conn)
  if sch then
    for _, ref in ipairs(sqlmod.referenced_tables(sql)) do
      local t = schema.find_table(sch, ref.name)
      if t and not vim.tbl_contains(tables, t) and #tables < 10 then
        tables[#tables + 1] = t
      end
    end
  end
  local label = "q" .. cell.index .. (cell.title ~= "" and (" " .. cell.title) or "")
  local text = M.build_review_prompt({
    question = question,
    sql = sql,
    sql_edited = sql_edited,
    cell_label = label,
    result = result,
    rows_of = rows_of,
    rows_note = rows_note,
    plan = plan,
    plan_kind = plan_kind,
    tables = tables,
    history = transcript and transcript.turns or nil,
  })
  local query_ui = require("dbgrid.ui.query")
  local agent_name = config.get().ai.agent
  util.notify("asking " .. agent_name .. " about " .. label .. "…")
  local started = util.now()
  local ran_at = result and result.ran_at or nil
  s.running[cell.id] = { started = started, kind = "review" }
  query_ui.render(s)
  query_ui.start_spinner(s)
  local job = M.run(text, function(answer, err)
    s.running[cell.id] = nil
    if not vim.api.nvim_buf_is_valid(s.buf) then
      return
    end
    query_ui.render(s)
    if not answer then
      return util.error("asking " .. agent_name .. " failed: " .. tostring(err))
    end
    s.runtime[cell.id] = s.runtime[cell.id] or {}
    local tr = s.runtime[cell.id].review
    if not tr or tr.ran_at ~= ran_at then
      tr = { ran_at = ran_at, turns = {} }
      s.runtime[cell.id].review = tr
    end
    tr.turns[#tr.turns + 1] = {
      question = question,
      answer = util.trim((answer:gsub("\r\n", "\n"))),
      agent = agent_name,
    }
    -- the float takes focus: not while typing, and not over another tab
    if vim.fn.mode():match("^[nv]") and vim.fn.bufwinid(s.buf) ~= -1 then
      review_ui.open(s, cells.by_id(s.buf, cell.id) or cell)
    else
      util.notify(agent_name .. " answered about " .. label .. " (ask again with an empty question to read it)")
    end
  end, agent_name)
  if job then
    s.running[cell.id].job = job
  else
    s.running[cell.id] = nil
    query_ui.render(s)
  end
end

---Cancel a running generation or question.
---@param s dbgrid.State
---@param cell? dbgrid.Cell
function M.cancel(s, cell)
  for id, r in pairs(s.running) do
    if (r.kind == "ai" or r.kind == "review") and (not cell or cell.id == id) and r.job then
      pcall(r.job.kill, r.job, 15)
    end
  end
end

return M
