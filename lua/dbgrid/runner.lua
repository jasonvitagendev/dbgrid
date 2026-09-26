-- Runs cells: LIMIT injection, write confirmation, index pre-flight, execution,
-- caching and hand-off to the UI.
local util = require("dbgrid.util")
local config = require("dbgrid.config")
local cells = require("dbgrid.cells")
local sqlmod = require("dbgrid.sql")
local adapters = require("dbgrid.adapters")
local connections = require("dbgrid.connections")
local schema = require("dbgrid.schema")
local explain = require("dbgrid.explain")
local notebook = require("dbgrid.notebook")

local M = {}

M.diag_ns = vim.api.nvim_create_namespace("dbgrid.diagnostics")

local function ui_query()
  return require("dbgrid.ui.query")
end

local function ui_results()
  return require("dbgrid.ui.results")
end

---Resolve the connection for a notebook (optionally overridden per cell) and
---call back with it, prompting when nothing is configured.
---@param state dbgrid.State
---@param override? string
---@param cb fun(conn: dbgrid.Connection)
function M.with_connection(state, override, cb)
  local name = override or state.nb.meta.connection
  if name then
    local conn = connections.get(name)
    if conn then
      return cb(conn)
    end
    util.warn("connection '" .. name .. "' is not configured; pick another one")
  end
  local default = connections.default()
  if default and not override then
    notebook.set_connection(state.nb, default.name)
    ui_query().refresh_winbar(state)
    return cb(default)
  end
  require("dbgrid.ui.picker").connection(function(conn)
    if not conn then
      return
    end
    if not override then
      notebook.set_connection(state.nb, conn.name)
      ui_query().refresh_winbar(state)
    end
    cb(conn)
  end)
end

---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param err dbgrid.RunError
local function set_error_diagnostic(state, cell, err)
  if not err or not err.line then
    return
  end
  local lnum = cell.first + err.line - 2 -- 0-based
  if lnum < cell.first - 1 or lnum > math.max(cell.last - 1, cell.first - 1) then
    lnum = cell.first - 1
  end
  local message = err.message
  if err.hint then
    message = message .. "\nHINT: " .. err.hint
  end
  local existing = vim.diagnostic.get(state.buf, { namespace = M.diag_ns })
  local list = {}
  for _, d in ipairs(existing) do
    if d.lnum < cell.first - 1 or d.lnum > cell.last - 1 then
      list[#list + 1] = d
    end
  end
  list[#list + 1] = {
    lnum = lnum,
    col = math.max(0, (err.col or 1) - 1),
    message = message,
    severity = vim.diagnostic.severity.ERROR,
    source = "dbgrid",
  }
  pcall(vim.diagnostic.set, M.diag_ns, state.buf, list)
end

---@param state dbgrid.State
---@param cell? dbgrid.Cell  nil clears everything
function M.clear_diagnostics(state, cell)
  if not cell then
    pcall(vim.diagnostic.reset, M.diag_ns, state.buf)
    return
  end
  local keep = {}
  for _, d in ipairs(vim.diagnostic.get(state.buf, { namespace = M.diag_ns })) do
    if d.lnum < cell.first - 1 or d.lnum > cell.last - 1 then
      keep[#keep + 1] = d
    end
  end
  pcall(vim.diagnostic.set, M.diag_ns, state.buf, keep)
end

---Ask the user to confirm writes. Returns true to proceed.
---@param conn dbgrid.Connection
---@param stmts dbgrid.Statement[]
---@return boolean
local function confirm_writes(conn, stmts)
  local kinds, dangers = {}, {}
  for _, st in ipairs(stmts) do
    if st.class == "write" or st.class == "ddl" then
      kinds[#kinds + 1] = st.kind:upper()
      local d = sqlmod.danger(st)
      if d then
        dangers[#dangers + 1] = d
      end
    end
  end
  if #kinds == 0 then
    return true
  end
  local msg = string.format("Run %s on %s?", table.concat(util.uniq(kinds), ", "), conn.name)
  if #dangers > 0 then
    msg = msg .. "\n\n" .. table.concat(dangers, "\n")
  end
  local choice = vim.fn.confirm(msg, #dangers > 0 and "&Cancel\n&Run" or "&Run\n&Cancel", 1, "Warning")
  if #dangers > 0 then
    return choice == 2
  end
  return choice == 1
end

---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param status string
local function set_runtime(state, cell, status, extra)
  state.runtime[cell.id] = vim.tbl_extend("force", state.runtime[cell.id] or {}, { status = status }, extra or {})
  ui_query().render(state)
end

---Execute the prepared statements.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param conn dbgrid.Connection
---@param adapter dbgrid.Adapter
---@param run_stmts dbgrid.RunStatement[]
---@param extra { warnings: table[], plans: table[], transaction: boolean }
local function execute(state, cell, conn, adapter, run_stmts, extra, cb)
  local cfg = config.get()
  local started = util.now()
  state.running[cell.id] = { started = started, kind = "run" }
  set_runtime(state, cell, "running")
  ui_query().start_spinner(state)
  local job = adapter.run(conn, run_stmts, {
    transaction = extra.transaction,
    timeout_ms = cfg.query.timeout_ms,
  }, function(res)
    state.running[cell.id] = nil
    local fresh = cells.by_id(state.buf, cell.id) or cell
    local truncated = false
    for i, st in ipairs(res.statements) do
      st.plan = extra.plans[i]
      for _, set in ipairs(st.sets) do
        if st.limit_applied and (set.row_count or #set.rows) >= st.limit_applied then
          truncated = true
        end
      end
    end
    local result = {
      ok = res.ok,
      statements = res.statements,
      notices = res.notices,
      error = res.error,
      elapsed_ms = res.elapsed_ms,
      server_ms = res.server_ms,
      cancelled = res.cancelled,
      ran_at = util.epoch(),
      connection = conn.name,
      warnings = extra.warnings,
      sql_hash = cells.hash(fresh),
      truncated = truncated,
    }
    notebook.set_result(state.nb, fresh, result)
    state.runtime[fresh.id] = { status = res.ok and "ok" or "error" }
    M.clear_diagnostics(state, fresh)
    if not res.ok and res.error then
      set_error_diagnostic(state, fresh, res.error)
    end
    state.active_cell = fresh.id
    ui_query().render(state)
    ui_results().show(state, fresh.id)
    if cb then
      cb(result)
    end
  end)
  state.running[cell.id].job = job
end

---Run one cell.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param opts? { cb?: fun(result: table), silent?: boolean }
function M.run_cell(state, cell, opts)
  opts = opts or {}
  local cfg = config.get()
  if cells.ensure_ids(state.buf) then
    cell = cells.parse(state.buf)[cell.index] or cell
  end
  if state.running[cell.id] then
    util.warn("cell is already running (cancel with " .. tostring(cfg.keymaps.query.cancel) .. ")")
    return
  end
  local text = cells.sql_text(cell)
  local stmts = sqlmod.split(text)
  if #stmts == 0 then
    if cells.prompt(cell) then
      return require("dbgrid.ai").generate(state, cell)
    end
    util.warn("nothing to run in this cell")
    return
  end
  local directives = cells.directives(cell)
  M.with_connection(state, type(directives.conn) == "string" and directives.conn or nil, function(conn)
    local adapter, err = adapters.for_connection(conn)
    if not adapter then
      util.error(err or "no adapter")
      return
    end
    if vim.fn.executable(adapter.executable) ~= 1 then
      util.error("'" .. adapter.executable .. "' is not on PATH")
      return
    end
    -- prepare statements
    local run_stmts = {}
    local has_tx, has_write = false, false
    for i, st in ipairs(stmts) do
      local sql, applied = st.sql, false
      if not directives.nolimit and cfg.query.limit then
        sql, applied = sqlmod.ensure_limit(st, cfg.query.limit)
      end
      if st.class == "tx" then
        has_tx = true
      end
      if st.class == "write" or st.class == "ddl" then
        has_write = true
      end
      run_stmts[i] = {
        sql = sql,
        kind = st.kind,
        class = st.class,
        line = st.line,
        limit_applied = applied and cfg.query.limit or nil,
      }
    end
    if has_write and conn.readonly then
      util.error("connection '" .. conn.name .. "' is read-only")
      return
    end
    if has_write and cfg.query.confirm_writes and not opts.silent then
      if not confirm_writes(conn, stmts) then
        return
      end
    end
    local transaction = cfg.query.transaction_per_cell and #stmts > 1 and not has_tx and not directives.notx
    local mode = conn.index_check or cfg.index_check.mode or "warn"
    local explainable = {}
    for i, st in ipairs(stmts) do
      if sqlmod.is_explainable(st) then
        explainable[#explainable + 1] = { i = i, stmt = run_stmts[i] }
      end
    end
    if mode == "off" or #explainable == 0 then
      return execute(
        state,
        cell,
        conn,
        adapter,
        run_stmts,
        { warnings = {}, plans = {}, transaction = transaction },
        opts.cb
      )
    end
    -- pre-flight EXPLAIN for the index check
    set_runtime(state, cell, "planning")
    state.running[cell.id] = { started = util.now(), kind = "explain" }
    ui_query().start_spinner(state)
    local list = vim.tbl_map(function(e)
      return e.stmt
    end, explainable)
    state.running[cell.id].job = adapter.explain(conn, list, function(plans)
      state.running[cell.id] = nil
      local sch = schema.loaded(conn)
      local warnings, by_index = {}, {}
      for k, e in ipairs(explainable) do
        local plan = plans[k]
        if plan then
          by_index[e.i] = plan
          for _, w in ipairs(explain.warnings(plan, sch, { min_rows = cfg.index_check.min_rows })) do
            warnings[#warnings + 1] = w
          end
        end
      end
      if #warnings > 0 and mode == "confirm" and not opts.silent then
        local lines = vim.tbl_map(function(w)
          return "• " .. w.message
        end, warnings)
        local choice = vim.fn.confirm(
          "The planner will scan without an index:\n\n" .. table.concat(lines, "\n") .. "\n\nRun anyway?",
          "&Run\n&Cancel",
          2,
          "Warning"
        )
        if choice ~= 1 then
          set_runtime(state, cell, "idle", { warnings = warnings })
          return
        end
      elseif #warnings > 0 and not opts.silent then
        util.warn(warnings[1].message .. (#warnings > 1 and (" (+" .. (#warnings - 1) .. " more)") or ""))
      end
      execute(
        state,
        cell,
        conn,
        adapter,
        run_stmts,
        { warnings = warnings, plans = by_index, transaction = transaction },
        opts.cb
      )
    end)
  end)
end

---Run every cell of the notebook, top to bottom.
---@param state dbgrid.State
function M.run_all(state)
  cells.ensure_ids(state.buf)
  local list = cells.parse(state.buf)
  local i = 0
  local function next_cell()
    i = i + 1
    local cell = list[i]
    if not cell then
      util.notify("ran " .. (i - 1) .. " cells")
      return
    end
    local fresh = cells.by_id(state.buf, cell.id)
    if not fresh or not cells.has_sql(fresh) then
      return next_cell()
    end
    M.run_cell(state, fresh, {
      cb = function(result)
        if result.ok then
          next_cell()
        else
          util.warn("stopped at cell " .. i .. ": " .. tostring(result.error and result.error.message))
        end
      end,
    })
  end
  next_cell()
end

---EXPLAIN (optionally ANALYZE) the first statement of a cell and show the plan.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param analyze boolean
function M.explain_cell(state, cell, analyze)
  cells.ensure_ids(state.buf)
  cell = cells.parse(state.buf)[cell.index] or cell
  local stmts = sqlmod.split(cells.sql_text(cell))
  if #stmts == 0 then
    util.warn("nothing to explain")
    return
  end
  local st = stmts[1]
  if not sqlmod.is_explainable(st) then
    util.warn("cannot EXPLAIN a " .. st.kind:upper() .. " statement")
    return
  end
  local directives = cells.directives(cell)
  M.with_connection(state, type(directives.conn) == "string" and directives.conn or nil, function(conn)
    local adapter, err = adapters.for_connection(conn)
    if not adapter then
      return util.error(err or "no adapter")
    end
    if analyze and (st.class == "write") and conn.readonly then
      return util.error("connection is read-only")
    end
    state.running[cell.id] = { started = util.now(), kind = "explain" }
    set_runtime(state, cell, "planning")
    ui_query().start_spinner(state)
    state.running[cell.id].job = adapter.explain_text(conn, st.sql, analyze, function(lines, e)
      state.running[cell.id] = nil
      state.runtime[cell.id] = state.runtime[cell.id] or {}
      state.runtime[cell.id].status = nil
      if e then
        state.runtime[cell.id].plan_text = { "ERROR: " .. e }
      else
        state.runtime[cell.id].plan_text = lines
      end
      state.runtime[cell.id].plan_kind = analyze and "EXPLAIN ANALYZE" or "EXPLAIN"
      state.active_cell = cell.id
      ui_query().render(state)
      ui_results().show(state, cell.id, { view = "plan" })
    end)
  end)
end

---Cancel whatever is running for a cell (or the whole notebook).
---@param state dbgrid.State
---@param cell? dbgrid.Cell
function M.cancel(state, cell)
  local n = 0
  for id, r in pairs(state.running) do
    if not cell or cell.id == id then
      if r.job then
        local a = r.adapter or adapters.get("postgres")
        if a and a.cancel then
          a.cancel(r.job)
        elseif r.job.kill then
          pcall(r.job.kill, r.job, 15)
        end
      end
      n = n + 1
    end
  end
  if n == 0 then
    util.notify("nothing is running")
  else
    util.notify("cancelling " .. n .. " job(s)")
  end
end

return M
