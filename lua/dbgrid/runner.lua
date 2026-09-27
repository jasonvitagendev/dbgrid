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
  local function resolved(conn)
    connections.resolve(conn, function(eff, err)
      if not eff then
        return util.error("connection " .. conn.name .. ": " .. tostring(err))
      end
      cb(eff)
    end)
  end
  local name = override or state.nb.meta.connection
  if name then
    local conn = connections.get(name)
    if conn then
      return resolved(conn)
    end
    util.warn("connection '" .. name .. "' is not configured; pick another one")
  end
  local default = connections.default()
  if default and not override then
    notebook.set_connection(state.nb, default.name)
    ui_query().refresh_winbar(state)
    return resolved(default)
  end
  require("dbgrid.ui.picker").connection(function(conn)
    if not conn then
      return
    end
    if not override then
      notebook.set_connection(state.nb, conn.name)
      ui_query().refresh_winbar(state)
    end
    resolved(conn)
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

---Lines describing why a write is dangerous, plus DDL lock warnings.
---@param conn dbgrid.Connection
---@param stmts dbgrid.Statement[]
---@return string[] kinds, string[] dangers
local function write_dangers(conn, stmts)
  local cfg = config.get()
  local kinds, dangers = {}, {}
  local sch = schema.loaded(conn)
  for _, st in ipairs(stmts) do
    if st.class == "write" or st.class == "ddl" then
      kinds[#kinds + 1] = st.kind:upper()
      local d = sqlmod.danger(st)
      if d then
        dangers[#dangers + 1] = d
      end
    end
    if cfg.query.ddl_warnings and sqlmod.ddl_warnings then
      for _, w in ipairs(sqlmod.ddl_warnings(st, {
        min_rows = cfg.index_check.min_rows,
        lock_timeout = conn.lock_timeout_ms ~= nil,
        table_rows = function(name)
          local t = sch and schema.find_table(sch, name)
          return t and t.rows or nil
        end,
      }) or {}) do
        dangers[#dangers + 1] = w
      end
    end
  end
  return util.uniq(kinds), util.uniq(dangers)
end

---Ask the user to confirm writes. Calls back with true to proceed.
---@param conn dbgrid.Connection
---@param adapter dbgrid.Adapter
---@param stmts dbgrid.Statement[]
---@param opts { dry_run?: boolean }
---@param cb fun(ok: boolean)
local function confirm_writes(conn, adapter, stmts, opts, cb)
  local cfg = config.get()
  local kinds, dangers = write_dangers(conn, stmts)
  if #kinds == 0 then
    return cb(true)
  end
  local function ask(counts)
    local what = table.concat(kinds, ", ")
    local msg = string.format("%s %s on %s?", opts.dry_run and "Dry-run (rolled back)" or "Run", what, conn.name)
    if counts and #counts > 0 then
      msg = msg .. "\n\n" .. table.concat(counts, "\n")
    end
    if #dangers > 0 then
      msg = msg .. "\n\n" .. table.concat(dangers, "\n")
    end
    local choice = vim.fn.confirm(msg, #dangers > 0 and "&Cancel\n&Run" or "&Run\n&Cancel", 1, "Warning")
    if #dangers > 0 then
      return cb(choice == 2)
    end
    cb(choice == 1)
  end
  -- count the rows an UPDATE / DELETE would touch
  local previews = {}
  if cfg.query.preview_writes and sqlmod.preview_count then
    for i, st in ipairs(stmts) do
      local count_sql = sqlmod.preview_count(st)
      if count_sql then
        previews[#previews + 1] = { i = i, stmt = st, sql = count_sql }
      end
    end
  end
  if #previews == 0 then
    return ask()
  end
  local run_stmts = {}
  for k, p in ipairs(previews) do
    run_stmts[k] = { sql = p.sql, kind = "select", class = "read", line = 1 }
  end
  adapter.run(conn, run_stmts, { timeout_ms = 15000 }, function(res)
    local counts = {}
    for k, p in ipairs(previews) do
      local st = res.statements[k]
      local n = st and st.sets[1] and st.sets[1].rows[1] and st.sets[1].rows[1][1]
      if n and n ~= vim.NIL then
        counts[#counts + 1] = string.format(
          "%s touches %s %s",
          p.stmt.kind:upper(),
          util.fmt_int(tonumber(n) or 0),
          tonumber(n) == 1 and "row" or "rows"
        )
      elseif res.error and #counts == 0 then
        counts[#counts + 1] = "(row count unavailable: " .. tostring(res.error.message) .. ")"
      end
    end
    ask(counts)
  end)
end

---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param status string
local function set_runtime(state, cell, status, extra)
  local rt = vim.tbl_extend("force", state.runtime[cell.id] or {}, extra or {})
  rt.status = status
  state.runtime[cell.id] = rt
  ui_query().render(state)
end

---Fill `:name` parameters of a cell: cell defaults, remembered values, then prompts.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param text string
---@param opts { silent?: boolean }
---@param cb fun(text?: string, values?: table<string,string>)
local function resolve_params(state, cell, text, opts, cb)
  if not sqlmod.params then
    return cb(text, {})
  end
  local names = sqlmod.params(text)
  if #names == 0 then
    return cb(text, {})
  end
  local defaults = {}
  for _, p in ipairs(cells.params(cell)) do
    defaults[p.name] = p.default
  end
  local remembered = notebook.params(state.nb)
  local values, missing = {}, {}
  for _, name in ipairs(names) do
    local v = defaults[name]
    if v == nil then
      v = remembered[name]
    end
    if v == nil then
      missing[#missing + 1] = name
    else
      values[name] = v
    end
  end
  local function finish()
    local out = sqlmod.substitute_params(text, values)
    cb(out, values)
  end
  local function prompt_next()
    local name = table.remove(missing, 1)
    if not name then
      return finish()
    end
    if opts.silent then
      return cb(nil)
    end
    vim.ui.input({ prompt = "Value for :" .. name .. ": ", default = remembered[name] or "" }, function(input)
      if input == nil then
        util.notify("cancelled (no value for :" .. name .. ")")
        return cb(nil)
      end
      values[name] = input
      notebook.set_param(state.nb, name, input)
      prompt_next()
    end)
  end
  prompt_next()
end

---Re-prompt every parameter used by a cell (`params` keymap).
---@param state dbgrid.State
---@param cell dbgrid.Cell
function M.edit_params(state, cell)
  if not sqlmod.params then
    return
  end
  local names = sqlmod.params(cells.sql_text(cell))
  if #names == 0 then
    return util.notify("this cell has no :parameters")
  end
  local remembered = notebook.params(state.nb)
  local i = 0
  local function nxt()
    i = i + 1
    local name = names[i]
    if not name then
      return util.notify("parameters updated")
    end
    vim.ui.input({ prompt = "Value for :" .. name .. ": ", default = remembered[name] or "" }, function(input)
      if input == nil then
        return
      end
      notebook.set_param(state.nb, name, input)
      nxt()
    end)
  end
  nxt()
end

---Cells changed between two results (keyed by the new row tables).
---@param before table?
---@param after table
---@return table<table, table<integer, boolean>> changed, integer count
local function changed_cells(before, after)
  local changed, count = {}, 0
  if not before or not before.statements then
    return changed, 0
  end
  for i, st in ipairs(after.statements or {}) do
    local pst = before.statements[i]
    for j, set in ipairs(st.sets or {}) do
      local pset = pst and pst.sets and pst.sets[j]
      if pset and #pset.columns == #set.columns then
        for r, row in ipairs(set.rows) do
          local prow = pset.rows[r]
          if prow then
            for c = 1, #set.columns do
              if row[c] ~= prow[c] then
                changed[row] = changed[row] or {}
                changed[row][c] = true
                count = count + 1
              end
            end
          else
            changed[row] = changed[row] or {}
            changed[row][0] = true
            count = count + 1
          end
        end
      end
    end
  end
  return changed, count
end

---Append the run to the project history.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param conn dbgrid.Connection
---@param result table
---@param sql string
local function log_history(state, cell, conn, result, sql)
  local rows
  for _, st in ipairs(result.statements or {}) do
    for _, set in ipairs(st.sets or {}) do
      rows = (rows or 0) + (set.row_count or #set.rows)
    end
  end
  pcall(require("dbgrid.history").append, {
    ts = util.epoch(),
    connection = conn.name,
    notebook = state.nb.name,
    cell = cells.label(cell, 60),
    sql = sql,
    ok = result.ok,
    rows = rows,
    elapsed_ms = result.elapsed_ms,
    error = result.error and result.error.message or nil,
  })
end

---Execute the prepared statements.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param conn dbgrid.Connection
---@param adapter dbgrid.Adapter
---@param run_stmts dbgrid.RunStatement[]
---@param extra { warnings: table[], plans: table[], transaction: boolean, dry_run?: boolean, live?: boolean,
---  sql: string, params?: table }
local function execute(state, cell, conn, adapter, run_stmts, extra, cb)
  local cfg = config.get()
  local started = util.now()
  state.running[cell.id] = { started = started, kind = "run", adapter = adapter }
  set_runtime(state, cell, "running")
  ui_query().start_spinner(state)
  local job = adapter.run(conn, run_stmts, {
    transaction = extra.transaction,
    rollback = extra.dry_run,
    read_write = extra.dry_run and conn.readonly or nil,
    timeout_ms = cfg.query.timeout_ms,
  }, function(res)
    state.running[cell.id] = nil
    if not vim.api.nvim_buf_is_valid(state.buf) then
      return
    end
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
    local previous = notebook.result_of(state.nb, fresh.id)
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
      dry_run = extra.dry_run or nil,
      params = extra.params,
    }
    local live = state.live and state.live[fresh.id]
    if extra.live and live then
      -- live tick: keep the previous result for the change highlight, stay off the disk
      live.changed, live.changed_count = changed_cells(previous, result)
      live.ticks = (live.ticks or 0) + 1
      live.last_tick = util.epoch()
      local hist = live.history
      local first = result.statements[1] and result.statements[1].sets[1]
      hist[#hist + 1] = { ts = result.ran_at, rows = first and first.rows or {}, columns = first and first.columns }
      while #hist > (cfg.live.history or 60) do
        table.remove(hist, 1)
      end
      notebook.set_result_memory(state.nb, fresh, result)
    else
      if previous and previous ~= vim.NIL then
        state.previous = state.previous or {}
        state.previous[fresh.id] = previous
      end
      notebook.set_result(state.nb, fresh, result)
      log_history(state, fresh, conn, result, extra.sql)
    end
    state.runtime[fresh.id] = { status = res.ok and "ok" or "error" }
    M.clear_diagnostics(state, fresh)
    if not res.ok and res.error then
      set_error_diagnostic(state, fresh, res.error)
    end
    if not extra.live then
      state.active_cell = fresh.id
    end
    ui_query().render(state)
    if not extra.live or state.view.cell_id == fresh.id then
      ui_results().show(state, fresh.id)
    end
    if not res.ok and live then
      M.stop_live(state, fresh.id, "error")
    end
    if cb then
      cb(result)
    end
  end)
  state.running[cell.id].job = job
end

---Run one cell.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param opts? { cb?: fun(result: table), silent?: boolean, live?: boolean, dry_run?: boolean }
function M.run_cell(state, cell, opts)
  opts = opts or {}
  local cfg = config.get()
  if cells.ensure_ids(state.buf) then
    cell = cells.parse(state.buf)[cell.index] or cell
  end
  if state.running[cell.id] then
    if not opts.live then
      util.warn("cell is already running (cancel with " .. tostring(cfg.keymaps.query.cancel) .. ")")
    end
    return
  end
  local raw = cells.sql_text(cell)
  if not sqlmod.has_statements(raw) then
    if cells.prompt(cell) then
      return require("dbgrid.ai").generate(state, cell)
    end
    util.warn("nothing to run in this cell")
    return
  end
  local directives = cells.directives(cell)
  resolve_params(state, cell, raw, { silent = opts.silent or opts.live }, function(text, params)
    if not text then
      return
    end
    local stmts = sqlmod.split(text)
    if #stmts == 0 then
      util.warn("nothing to run in this cell")
      return
    end
    local every = cells.interval_ms(directives.every)
    if directives.every and not every and not opts.live then
      util.warn("bad @every value '" .. tostring(directives.every) .. "' (use 5s, 2m, 500ms)")
    end
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
      local dry_run = opts.dry_run or directives.dryrun ~= nil or cfg.query.dry_run
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
          if dry_run and st.class == "write" and sqlmod.ensure_returning then
            sql = sqlmod.ensure_returning(st)
          end
        end
        run_stmts[i] = {
          sql = sql,
          kind = st.kind,
          class = st.class,
          line = st.line,
          limit_applied = applied and cfg.query.limit or nil,
        }
      end
      dry_run = dry_run and has_write
      if has_write and conn.readonly and not dry_run then
        util.error("connection '" .. conn.name .. "' is read-only")
        return
      end
      if every and has_write then
        util.error("@every only applies to read-only cells")
        return
      end
      if opts.live and has_write then
        return
      end
      local function after_confirm()
        local transaction = (cfg.query.transaction_per_cell and #stmts > 1 and not has_tx and not directives.notx)
          or (dry_run and not has_tx)
        local mode = conn.index_check or cfg.index_check.mode or "warn"
        local explainable = {}
        for i, st in ipairs(stmts) do
          if sqlmod.is_explainable(st) then
            explainable[#explainable + 1] = { i = i, stmt = run_stmts[i] }
          end
        end
        local extra = {
          warnings = {},
          plans = {},
          transaction = transaction,
          dry_run = dry_run,
          live = opts.live,
          sql = text,
          params = next(params or {}) and params or nil,
        }
        local function go()
          execute(state, cell, conn, adapter, run_stmts, extra, function(result)
            if every and result.ok and not opts.live and not state.live[cell.id] then
              M.start_live(state, cell, every)
            end
            if opts.cb then
              opts.cb(result)
            end
          end)
        end
        if mode == "off" or #explainable == 0 or opts.live then
          return go()
        end
        -- pre-flight EXPLAIN for the index check
        set_runtime(state, cell, "planning")
        state.running[cell.id] = { started = util.now(), kind = "explain", adapter = adapter }
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
          extra.warnings = warnings
          extra.plans = by_index
          go()
        end)
      end
      if has_write and cfg.query.confirm_writes and not opts.silent then
        confirm_writes(conn, adapter, stmts, { dry_run = dry_run }, function(ok)
          if ok then
            after_confirm()
          end
        end)
      else
        after_confirm()
      end
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

-- ---------------------------------------------------------------------------
-- Live cells (`-- @every 5s`)
-- ---------------------------------------------------------------------------

---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param interval_ms integer
function M.start_live(state, cell, interval_ms)
  local cfg = config.get().live
  state.live = state.live or {}
  if state.live[cell.id] then
    return
  end
  local n = 0
  for _ in pairs(state.live) do
    n = n + 1
  end
  if n >= (cfg.max_cells or 4) then
    return util.warn("already " .. n .. " live cells in this notebook (live.max_cells)")
  end
  interval_ms = math.max(interval_ms, cfg.min_interval_ms or 1000)
  local uv = vim.uv or vim.loop
  local live = {
    timer = uv.new_timer(),
    interval = interval_ms,
    ticks = 0,
    history = {},
    hash = cells.hash(cell),
    started = util.epoch(),
    changed = {},
  }
  state.live[cell.id] = live
  live.timer:start(interval_ms, interval_ms, function()
    vim.schedule(function()
      M.live_tick(state, cell.id)
    end)
  end)
  util.notify(
    string.format(
      "live: %s every %s (cancel with %s)",
      cells.label(cell, 30),
      util.fmt_ms(interval_ms),
      tostring(config.get().keymaps.query.cancel)
    )
  )
  ui_query().render(state)
  ui_query().refresh_winbar(state)
end

---@param state dbgrid.State
---@param cell_id string
function M.live_tick(state, cell_id)
  local live = state.live and state.live[cell_id]
  if not live then
    return
  end
  if not vim.api.nvim_buf_is_valid(state.buf) then
    return M.stop_live(state, cell_id, "closed")
  end
  local fresh = cells.by_id(state.buf, cell_id)
  if not fresh then
    return M.stop_live(state, cell_id, "deleted")
  end
  if cells.hash(fresh) ~= live.hash then
    return M.stop_live(state, cell_id, "edited")
  end
  if state.running[cell_id] then
    return -- previous tick still in flight
  end
  M.run_cell(state, fresh, { live = true, silent = true })
end

---@param state dbgrid.State
---@param cell_id string
---@param reason? string
function M.stop_live(state, cell_id, reason)
  local live = state.live and state.live[cell_id]
  if not live then
    return
  end
  state.live[cell_id] = nil
  if live.timer then
    pcall(live.timer.stop, live.timer)
    pcall(live.timer.close, live.timer)
  end
  -- persist the last tick
  local cell = vim.api.nvim_buf_is_valid(state.buf) and cells.by_id(state.buf, cell_id)
  local result = cell and notebook.result_of(state.nb, cell_id)
  if cell and result and result ~= vim.NIL then
    notebook.set_result(state.nb, cell, result)
  end
  if reason ~= "closed" and vim.api.nvim_buf_is_valid(state.buf) then
    util.notify(string.format("live stopped (%s) after %d ticks", reason or "cancelled", live.ticks or 0))
    ui_query().render(state)
    ui_query().refresh_winbar(state)
    if state.view.cell_id == cell_id then
      ui_results().render(state)
    end
  end
end

---@param state dbgrid.State
function M.stop_all_live(state, reason)
  for id in pairs(state.live or {}) do
    M.stop_live(state, id, reason)
  end
end

---Called when a cell's text changed (stops its live loop).
---@param state dbgrid.State
---@param cell dbgrid.Cell
function M.on_cell_edited(state, cell)
  local live = state.live and state.live[cell.id]
  if live and cells.hash(cell) ~= live.hash then
    M.stop_live(state, cell.id, "edited")
  end
end

-- ---------------------------------------------------------------------------
-- Explain / analyze
-- ---------------------------------------------------------------------------

---First statement of a cell, or nil with a warning.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@return dbgrid.Statement?, dbgrid.Cell
local function first_statement(state, cell)
  cells.ensure_ids(state.buf)
  cell = cells.parse(state.buf)[cell.index] or cell
  local text = cells.sql_text(cell)
  if sqlmod.substitute_params then
    text = sqlmod.substitute_params(text, notebook.params(state.nb))
  end
  local stmts = sqlmod.split(text)
  if #stmts == 0 then
    util.warn("nothing to explain")
    return nil, cell
  end
  return stmts[1], cell
end

---EXPLAIN (optionally ANALYZE) the first statement of a cell and show the plan.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param analyze boolean
function M.explain_cell(state, cell, analyze)
  local st
  st, cell = first_statement(state, cell)
  if not st then
    return
  end
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
    state.running[cell.id] = { started = util.now(), kind = "explain", adapter = adapter }
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

---Ask the agent to read the plan of a cell (`:Dbgrid analyze`).
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param opts? { silent?: boolean, cb?: fun(text?: string, err?: string) }
function M.analyze_cell(state, cell, opts)
  opts = opts or {}
  local cfg = config.get()
  local st
  st, cell = first_statement(state, cell)
  if not st then
    return
  end
  if not sqlmod.is_explainable(st) then
    return util.warn("cannot analyze a " .. st.kind:upper() .. " statement")
  end
  if state.running[cell.id] then
    return util.warn("cell is busy")
  end
  local directives = cells.directives(cell)
  M.with_connection(state, type(directives.conn) == "string" and directives.conn or nil, function(conn)
    if conn.ai == false then
      return util.error("connection '" .. conn.name .. "' has ai = false")
    end
    local adapter, err = adapters.for_connection(conn)
    if not adapter or not adapter.explain_json then
      return util.error(err or "the adapter cannot produce JSON plans")
    end
    local analyze = (cfg.ai.analyze.mode or "analyze") == "analyze"
    if analyze and st.class == "write" and conn.readonly then
      analyze = false
    end
    if analyze and st.class == "write" and not opts.silent then
      local choice = vim.fn.confirm(
        "EXPLAIN ANALYZE executes this " .. st.kind:upper() .. " inside a transaction that is rolled back. Continue?",
        "&Analyze\n&Estimate only\n&Cancel",
        1,
        "Question"
      )
      if choice == 3 then
        return
      end
      analyze = choice == 1
    end
    local ai = require("dbgrid.ai")
    state.running[cell.id] = { started = util.now(), kind = "analyze", adapter = adapter }
    set_runtime(state, cell, "analyzing")
    ui_query().start_spinner(state)
    local function fail(e)
      state.running[cell.id] = nil
      set_runtime(state, cell, nil)
      util.error("analyze: " .. tostring(e))
      if opts.cb then
        opts.cb(nil, e)
      end
    end
    state.running[cell.id].job = adapter.explain_json(conn, st.sql, {
      analyze = analyze,
      buffers = true,
      verbose = false,
      settings = true,
      timeout_ms = cfg.query.timeout_ms,
    }, function(plan, e)
      if not plan then
        return fail(e)
      end
      schema.get(conn, function(sch)
        local rules = cfg.analyze_rules or {}
        local findings = {}
        for _, w in ipairs(explain.warnings(plan, sch, { min_rows = cfg.index_check.min_rows })) do
          findings[#findings + 1] = w.message
        end
        if explain.analyze_findings then
          for _, f in ipairs(explain.analyze_findings(plan, rules)) do
            findings[#findings + 1] = f.message
          end
        end
        local relations = explain.relations and explain.relations(plan) or {}
        if #relations == 0 then
          for _, r in ipairs(sqlmod.referenced_tables(st.sql)) do
            relations[#relations + 1] = { name = r.name }
          end
        end
        local tables = {}
        for _, r in ipairs(relations) do
          local t = sch and schema.find_table(sch, r.name, r.schema)
          if t then
            tables[#tables + 1] = t
          end
        end
        local function build(stats_rows)
          local plan_lines = explain.to_lines(plan, { analyze = analyze })
          local prompt = ai.build_analyze_prompt({
            sql = st.sql,
            plan_lines = plan_lines,
            summary = explain.summary and explain.summary(plan) or nil,
            findings = findings,
            tables = tables,
            stats = stats_rows,
            version = sch and sch.version or nil,
            analyzed = analyze,
          })
          state.running[cell.id].job = ai.ask_text(prompt, function(text, aerr)
            state.running[cell.id] = nil
            set_runtime(state, cell, nil, { plan_text = nil })
            if not text then
              util.error("analyze: " .. tostring(aerr))
              if opts.cb then
                opts.cb(nil, aerr)
              end
              return
            end
            notebook.set_analysis(state.nb, cell.id, text, analyze and "EXPLAIN ANALYZE" or "EXPLAIN")
            state.runtime[cell.id].plan_text = plan_lines
            state.runtime[cell.id].plan_kind = analyze and "EXPLAIN ANALYZE" or "EXPLAIN"
            require("dbgrid.ui.analysis").show(state, {
              title = "analysis of " .. cells.label(cell, 40),
              text = text,
              cell_id = cell.id,
            })
            if opts.cb then
              opts.cb(text)
            end
          end, { connection = conn })
        end
        if cfg.ai.analyze.include_stats ~= false and #tables > 0 then
          local names = {}
          for _, t in ipairs(tables) do
            names[#names + 1] = util.sql_literal(t.name)
          end
          local stats_sql = "select relname, n_live_tup, n_dead_tup, seq_scan, idx_scan, last_analyze, last_autoanalyze"
            .. " from pg_stat_user_tables where relname in ("
            .. table.concat(names, ", ")
            .. ")"
          adapter.run(conn, { { sql = stats_sql, kind = "select", class = "read", line = 1 } }, {}, function(res)
            local set = res.ok and res.statements[1] and res.statements[1].sets[1]
            build(set and { columns = set.columns, rows = set.rows } or nil)
          end)
        else
          build(nil)
        end
      end)
    end)
  end)
end

---Ask the agent to explain the last error of a cell.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param opts? { cb?: fun(text?: string, err?: string) }
function M.explain_error(state, cell, opts)
  opts = opts or {}
  cells.ensure_ids(state.buf)
  cell = cells.parse(state.buf)[cell.index] or cell
  local result = notebook.result_of(state.nb, cell.id)
  if not result or not result.error then
    return util.notify("this cell has no error to explain")
  end
  if state.running[cell.id] then
    return util.warn("cell is busy")
  end
  local directives = cells.directives(cell)
  M.with_connection(state, type(directives.conn) == "string" and directives.conn or nil, function(conn)
    if conn.ai == false then
      return util.error("connection '" .. conn.name .. "' has ai = false")
    end
    local ai = require("dbgrid.ai")
    state.running[cell.id] = { started = util.now(), kind = "analyze" }
    set_runtime(state, cell, "analyzing")
    ui_query().start_spinner(state)
    schema.get(conn, function(sch)
      local text = cells.sql_text(cell)
      local tables = {}
      for _, r in ipairs(sqlmod.referenced_tables(text)) do
        local t = sch and schema.find_table(sch, r.name)
        if t then
          tables[#tables + 1] = t
        end
      end
      local prompt = ai.build_error_prompt({
        sql = text,
        error = result.error,
        tables = tables,
        version = sch and sch.version or nil,
        schema = sch,
      })
      state.running[cell.id].job = ai.ask_text(prompt, function(answer, err)
        state.running[cell.id] = nil
        set_runtime(state, cell, nil)
        if not answer then
          util.error("explain error: " .. tostring(err))
          return opts.cb and opts.cb(nil, err)
        end
        notebook.set_analysis(state.nb, cell.id, answer, "error")
        require("dbgrid.ui.analysis").show(state, {
          title = "error in " .. cells.label(cell, 40),
          text = answer,
          cell_id = cell.id,
        })
        if opts.cb then
          opts.cb(answer)
        end
      end, { connection = conn })
    end)
  end)
end

---Test the suggested index hypothetically (hypopg) and compare plan costs.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param index_sql? string  CREATE INDEX statement; defaults to the first suggestion of the last run
---@param opts? { cb?: fun(delta?: table, err?: string) }
function M.try_index(state, cell, index_sql, opts)
  opts = opts or {}
  local st
  st, cell = first_statement(state, cell)
  if not st then
    return
  end
  if not sqlmod.is_explainable(st) then
    return util.warn("cannot explain a " .. st.kind:upper() .. " statement")
  end
  local function go(idx)
    idx = sqlmod.strip_semicolon(util.trim(idx))
    local directives = cells.directives(cell)
    M.with_connection(state, type(directives.conn) == "string" and directives.conn or nil, function(conn)
      local adapter, err = adapters.for_connection(conn)
      if not adapter then
        return util.error(err or "no adapter")
      end
      local script = explain.hypopg_script and explain.hypopg_script(idx, st.sql) or {}
      local run_stmts = {
        { sql = "EXPLAIN (FORMAT JSON) " .. st.sql, kind = "explain", class = "read", line = 1 },
      }
      for _, sql in ipairs(script) do
        run_stmts[#run_stmts + 1] = { sql = sql, kind = "select", class = "read", line = 1 }
      end
      state.running[cell.id] = { started = util.now(), kind = "explain", adapter = adapter }
      set_runtime(state, cell, "planning")
      ui_query().start_spinner(state)
      state.running[cell.id].job = adapter.run(conn, run_stmts, { timeout_ms = 30000 }, function(res)
        state.running[cell.id] = nil
        set_runtime(state, cell, nil)
        if not res.ok then
          local msg = res.error and res.error.message or "failed"
          if msg:find("hypopg", 1, true) then
            msg = msg .. " — install the extension first: CREATE EXTENSION hypopg;"
          end
          util.error("try index: " .. msg)
          return opts.cb and opts.cb(nil, msg)
        end
        local function plan_of(i)
          local set = res.statements[i] and res.statements[i].sets[1]
          local text = set and set.rows[1] and set.rows[1][1]
          local ok, decoded = pcall(vim.json.decode, type(text) == "string" and text or "")
          return ok and decoded or nil
        end
        local before, after = plan_of(1), plan_of(#run_stmts)
        if not before or not after then
          util.error("try index: could not read the plans")
          return opts.cb and opts.cb(nil, "no plans")
        end
        local delta = explain.cost_delta and explain.cost_delta(before, after)
          or { before = explain.total_cost(before), after = explain.total_cost(after) }
        local lines = {
          string.format(" hypothetical: %s", idx),
          string.format(
            " estimated cost %s → %s%s%s",
            tostring(delta.before),
            tostring(delta.after),
            delta.pct and string.format(" (%+.0f%%)", delta.pct) or "",
            delta.used == false and "  · the planner did not use it" or ""
          ),
          "",
        }
        for _, l in ipairs(explain.to_lines(after)) do
          lines[#lines + 1] = l
        end
        state.runtime[cell.id] = state.runtime[cell.id] or {}
        state.runtime[cell.id].plan_text = lines
        state.runtime[cell.id].plan_kind = "EXPLAIN with hypothetical index"
        state.active_cell = cell.id
        ui_query().render(state)
        ui_results().show(state, cell.id, { view = "plan" })
        util.notify(
          string.format(
            "cost %s → %s%s",
            tostring(delta.before),
            tostring(delta.after),
            delta.used == false and " (index not used)" or ""
          )
        )
        if opts.cb then
          opts.cb(delta)
        end
      end)
    end)
  end
  if index_sql and index_sql ~= "" then
    return go(index_sql)
  end
  local result = notebook.result_of(state.nb, cell.id)
  local suggestion
  for _, w in ipairs(result and result.warnings or {}) do
    if type(w) == "table" and w.suggestion then
      suggestion = w.suggestion
      break
    end
  end
  vim.ui.input({ prompt = "Index to try: ", default = suggestion or "CREATE INDEX ON " }, function(input)
    if input and util.trim(input) ~= "" then
      go(input)
    end
  end)
end

---Run the first statement of a cell on another connection and diff the rows.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param conn_name string
---@param cb? fun(diff?: table, err?: string)
function M.diff_on(state, cell, conn_name, cb)
  cells.ensure_ids(state.buf)
  cell = cells.parse(state.buf)[cell.index] or cell
  local base = notebook.result_of(state.nb, cell.id)
  if not base or base == vim.NIL or not base.ok then
    util.warn("run the cell first")
    return cb and cb(nil, "no result")
  end
  local other = connections.get(conn_name)
  if not other then
    util.error("no connection named " .. conn_name)
    return cb and cb(nil, "no connection")
  end
  connections.resolve(other, function(conn, err)
    if not conn then
      util.error(tostring(err))
      return cb and cb(nil, err)
    end
    local adapter = adapters.for_connection(conn)
    local run_stmts = {}
    for i, st in ipairs(base.statements) do
      run_stmts[i] = { sql = st.sql, kind = st.kind, class = st.class, line = st.line or 1 }
    end
    state.running[cell.id] = { started = util.now(), kind = "run", adapter = adapter }
    set_runtime(state, cell, "running")
    ui_query().start_spinner(state)
    state.running[cell.id].job = adapter.run(conn, run_stmts, {}, function(res)
      state.running[cell.id] = nil
      set_runtime(state, cell, nil)
      if not res.ok then
        util.error("diff: " .. tostring(res.error and res.error.message))
        return cb and cb(nil, res.error and res.error.message)
      end
      require("dbgrid.ui.results").show_diff(state, cell.id, base, {
        statements = res.statements,
        connection = conn.name,
      }, { a_name = base.connection or "before", b_name = conn.name })
      if cb then
        cb(res)
      end
    end)
  end)
end

---Cancel whatever is running for a cell (or the whole notebook), including live loops.
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
  local stopped = 0
  for id in pairs(state.live or {}) do
    if not cell or cell.id == id then
      M.stop_live(state, id, "cancelled")
      stopped = stopped + 1
    end
  end
  if n == 0 and stopped == 0 then
    util.notify("nothing is running")
  elseif n > 0 then
    util.notify("cancelling " .. n .. " job(s)")
  end
end

return M
