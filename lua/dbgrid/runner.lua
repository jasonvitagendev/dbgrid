-- Runs cells: cell references and parameters, dependencies, LIMIT injection,
-- write confirmation (with row counts and DDL warnings), dry runs, index
-- pre-flight, execution, live loops, plan analysis, caching and hand-off to
-- the UI.
local util = require("dbgrid.util")
local config = require("dbgrid.config")
local cells = require("dbgrid.cells")
local sqlmod = require("dbgrid.sql")
local adapters = require("dbgrid.adapters")
local connections = require("dbgrid.connections")
local schema = require("dbgrid.schema")
local explain = require("dbgrid.explain")
local notebook = require("dbgrid.notebook")
local expand = require("dbgrid.expand")

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

---Adapter for a connection, or nil after reporting why.
---@param conn dbgrid.Connection
---@return dbgrid.Adapter?
local function adapter_for(conn)
  local adapter, err = adapters.for_connection(conn)
  if not adapter then
    util.error(err or "no adapter")
    return nil
  end
  if vim.fn.executable(adapter.executable) ~= 1 then
    util.error("'" .. adapter.executable .. "' is not on PATH")
    return nil
  end
  return adapter
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
      for _, w in
        ipairs(sqlmod.ddl_warnings(st, {
          min_rows = cfg.index_check.min_rows,
          lock_timeout = conn.lock_timeout_ms ~= nil,
          table_rows = function(name)
            local t = sch and schema.find_table(sch, name)
            return t and t.rows or nil
          end,
        }) or {})
      do
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
  -- what a DELETE / TRUNCATE reaches through foreign keys (from the schema cache)
  local cascades, notes = require("dbgrid.relations").write_warnings(schema.loaded(conn), stmts)
  vim.list_extend(dangers, cascades)
  local function ask(counts)
    local what = table.concat(kinds, ", ")
    local msg = string.format("%s %s on %s?", opts.dry_run and "Dry-run (rolled back)" or "Run", what, conn.name)
    if counts and #counts > 0 then
      msg = msg .. "\n\n" .. table.concat(counts, "\n")
    end
    if #dangers > 0 then
      msg = msg .. "\n\n" .. table.concat(dangers, "\n")
    end
    if #notes > 0 then
      msg = msg .. "\n\n" .. table.concat(notes, "\n")
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

---Is the cell's cached result current (it ran fine with the SQL it has now)?
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@return boolean
function M.is_fresh(state, cell)
  local meta = cell.id and state.nb.meta.cells[cell.id]
  return meta ~= nil and meta.status == "ok" and meta.sql_hash == cells.hash(cell)
end

---Cells named by `-- @depends` that have to run before `cell`, transitively
---and in order, leaving out the ones whose result is still current.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param opts? { all?: boolean }  include fresh cells too
---@return dbgrid.Cell[]? deps, string? err
function M.pending_dependencies(state, cell, opts)
  local list = cells.parse(state.buf)
  local order, seen, err = {}, {}, nil
  local function visit(c, stack)
    for _, name in ipairs(cells.depends(c)) do
      if err then
        return
      end
      local dep = cells.find(list, name)
      if not dep then
        err = string.format("unknown cell '%s' in -- @depends of %s", name, cells.ref_name(c))
        return
      end
      if dep.id ~= c.id then
        if stack[dep.id] then
          err = "dependency cycle through " .. name
          return
        end
        if not seen[dep.id] then
          seen[dep.id] = true
          visit(dep, vim.tbl_extend("force", stack, { [dep.id] = true }))
          if (opts and opts.all) or not M.is_fresh(state, dep) then
            order[#order + 1] = dep
          end
        end
      end
    end
  end
  visit(cell, { [cell.id or ""] = true })
  if err then
    return nil, err
  end
  return order
end

---Every cell of the notebook in an order that respects `-- @depends`
---(document order otherwise).
---@param state dbgrid.State
---@return dbgrid.Cell[] order, string? err
function M.run_order(state)
  local list = cells.parse(state.buf)
  local out, seen, err = {}, {}, nil
  local function visit(c, stack)
    if seen[c.id] or err then
      return
    end
    for _, name in ipairs(cells.depends(c)) do
      local dep = cells.find(list, name)
      if dep and dep.id ~= c.id then
        if stack[dep.id] then
          err = "dependency cycle through " .. name
          return
        end
        visit(dep, vim.tbl_extend("force", stack, { [dep.id] = true }))
      end
    end
    if not seen[c.id] then
      seen[c.id] = true
      out[#out + 1] = c
    end
  end
  for _, c in ipairs(list) do
    visit(c, { [c.id] = true })
  end
  return out, err
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

local execute_done, run_metrics

---Execute the prepared statements.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param conn dbgrid.Connection
---@param adapter dbgrid.Adapter
---@param run_stmts dbgrid.RunStatement[]
---@param extra { warnings: table[], plans: table[], transaction: boolean, dry_run?: boolean, live?: boolean,
---  sql: string, params?: table, refs?: string[], undo?: dbgrid.UndoEntry[], undo_skipped?: string,
---  redact?: string[] }
local function execute(state, cell, conn, adapter, run_stmts, extra, cb)
  local cfg = config.get()
  local started = util.now()
  state.running[cell.id] = { started = started, kind = "run", conn = conn, adapter = adapter }
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
    if not extra.retried and conn.tunnel_key and adapter.connection_failed and adapter.connection_failed(res) then
      -- the tunnel took the connection but nothing came back (a dead SSM session
      -- keeps its local port open): rebuild it and run the cell once more
      require("dbgrid.tunnel").kill(conn.tunnel_key)
      connections.forget(conn.name)
      util.warn("tunnel to " .. conn.name .. " was stale; reconnecting")
      local declared = connections.get(conn.name) or conn
      declared._resolved = nil
      local again = vim.tbl_extend("force", extra, { retried = true })
      return connections.resolve(declared, function(eff, err)
        if eff then
          return execute(state, cell, eff, adapter, run_stmts, again, cb)
        end
        res.error.message = res.error.message .. " (reconnect failed: " .. tostring(err) .. ")"
        execute_done(state, cell, conn, run_stmts, again, res, cb)
      end)
    end
    execute_done(state, cell, conn, run_stmts, extra, res, cb)
  end)
  if state.running[cell.id] then
    state.running[cell.id].job = job
  end
end

---Store, render and report the result of a run.
function execute_done(state, cell, conn, run_stmts, extra, res, cb)
  local cfg = config.get()
  local fresh = cells.by_id(state.buf, cell.id) or cell
  if extra.redact and #extra.redact > 0 then
    -- a `-- @secret` value must not reach the cache, the history or the screen through an error line
    require("dbgrid.secrets").redact_table(res, extra.redact)
  end
  local truncated = false
  for i, st in ipairs(res.statements) do
    st.plan = extra.plans[i]
    st.unlimited = run_stmts[i] and run_stmts[i].unlimited or nil
    st.more = nil
    for _, set in ipairs(st.sets) do
      if st.limit_applied and (set.row_count or #set.rows) >= st.limit_applied then
        truncated = true
        st.more = true
      end
    end
  end
  local previous = notebook.result_of(state.nb, fresh.id)
  if res.ok then
    -- `-- @rate`: the per-second columns belong to the result everything below sees
    pcall(require("dbgrid.rate").apply, state, fresh, res)
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
    dry_run = extra.dry_run or nil,
    params = extra.params,
    refs = extra.refs,
    undo = require("dbgrid.undo").applied(extra.undo, res, extra.transaction),
    undo_skipped = extra.undo_skipped,
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
  local record = require("dbgrid.record")
  if res.ok and record.wanted(fresh) then
    local ok, path, created = pcall(record.append, state.nb, fresh, result)
    if not ok then
      util.warn("@record: " .. tostring(path))
    elseif created then
      util.notify("recording " .. cells.label(fresh, 30) .. " to " .. path)
    end
  end
  pcall(require("dbgrid.alert").check, state, fresh, result)
  state.runtime[fresh.id] = { status = res.ok and "ok" or "error" }
  M.clear_diagnostics(state, fresh)
  if not res.ok and res.error then
    set_error_diagnostic(state, fresh, res.error)
  end
  if not extra.live then
    state.active_cell = fresh.id
  end
  ui_query().render(state)
  if not extra.live then
    -- a run the user asked for replaces whatever the pane shows, the schema
    -- document included; a live tick only refreshes a result already shown
    ui_results().show(state, fresh.id, { ran = true })
  elseif state.view.cell_id == fresh.id then
    ui_results().show(state, fresh.id)
  end
  require("dbgrid.ui.pins").refresh(state, fresh.id)
  if not res.ok and live then
    M.stop_live(state, fresh.id, "error")
  end
  if cb then
    cb(result)
  end
end

---Run SQL that belongs to no cell (a followed foreign key, a backend
---signal, a peek after an import) on the notebook's connection and hand back
---a result shaped like a cell's. `opts.limit = false` skips the LIMIT
---injection; `opts.id` registers the job under that id so the spinner and
---cancel see it.
---@param state dbgrid.State
---@param sql string
---@param opts? { connection?: string, limit?: boolean, id?: string, title?: string }
---@param cb fun(result?: table, err?: string)
function M.run_sql(state, sql, opts, cb)
  opts = opts or {}
  local cfg = config.get()
  local stmts = sqlmod.split(sql)
  if #stmts == 0 then
    return cb(nil, "nothing to run")
  end
  M.with_connection(state, opts.connection, function(conn)
    local adapter = adapter_for(conn)
    if not adapter then
      return cb(nil, "no adapter")
    end
    local run_stmts = {}
    local has_write = false
    for i, st in ipairs(stmts) do
      local text, applied = st.sql, false
      if opts.limit ~= false and cfg.query.limit then
        text, applied = sqlmod.ensure_limit(st, cfg.query.limit)
      end
      if st.class == "write" or st.class == "ddl" then
        has_write = true
      end
      run_stmts[i] = {
        sql = text,
        kind = st.kind,
        class = st.class,
        line = st.line,
        limit_applied = applied and cfg.query.limit or nil,
        unlimited = applied and st.sql or nil,
      }
    end
    if has_write and conn.readonly then
      return cb(nil, "connection '" .. conn.name .. "' is read-only")
    end
    local id = opts.id
    if id then
      state.running[id] = { started = util.now(), kind = "run", conn = conn, adapter = adapter }
      ui_query().start_spinner(state)
    end
    local job = adapter.run(conn, run_stmts, { timeout_ms = cfg.query.timeout_ms }, function(res)
      if id then
        state.running[id] = nil
      end
      local truncated = false
      for i, st in ipairs(res.statements) do
        st.unlimited = run_stmts[i] and run_stmts[i].unlimited or nil
        for _, set in ipairs(st.sets) do
          if st.limit_applied and (set.row_count or #set.rows) >= st.limit_applied then
            truncated = true
            st.more = true
          end
        end
      end
      cb({
        ok = res.ok,
        statements = res.statements,
        notices = res.notices,
        error = res.error,
        elapsed_ms = res.elapsed_ms,
        server_ms = res.server_ms,
        cancelled = res.cancelled,
        ran_at = util.epoch(),
        connection = conn.name,
        warnings = {},
        truncated = truncated,
        title = opts.title,
      }, res.ok and nil or (res.error and res.error.message or "failed"))
    end)
    if id and state.running[id] then
      state.running[id].job = job
    end
  end)
end

---Fetch the next page of a statement whose LIMIT dbgrid added, and append
---the rows to the cell's result (`\m` in the results pane).
---@param state dbgrid.State
---@param cell_id string
---@param stmt_index? integer   the statement to page; the first truncated one when nil
---@param cb? fun(result?: table, err?: string)
function M.load_more(state, cell_id, stmt_index, cb)
  local function fail(msg)
    util.notify(msg)
    if cb then
      cb(nil, msg)
    end
  end
  local result = notebook.result_of(state.nb, cell_id)
  if not result or not result.ok then
    return fail("no result to extend: run the cell first")
  end
  local idx, st
  for i, candidate in ipairs(result.statements or {}) do
    if candidate.limit_applied and (not stmt_index or i == stmt_index) then
      idx, st = i, candidate
      break
    end
  end
  if not st then
    return fail("this result has no LIMIT added by dbgrid: it is complete, or has its own LIMIT")
  end
  if not st.more then
    return fail("every row is already here (" .. util.fmt_int(#(st.sets[1] or {}).rows) .. " rows)")
  end
  local set = st.sets[1]
  local n = st.limit_applied
  local base = st.unlimited or sqlmod.strip_limit(st.sql, n)
  local stmt = base and sqlmod.split(base)[1]
  if not stmt then
    return fail("the statement could not be paged")
  end
  local fetched = #set.rows
  local sql, applied = sqlmod.ensure_limit(stmt, n, fetched)
  if not applied then
    return fail("the statement could not be paged")
  end
  local cell = cells.by_id(state.buf, cell_id)
  M.with_connection(state, result.connection, function(conn)
    local adapter = adapter_for(conn)
    if not adapter then
      return fail("no adapter")
    end
    if state.running[cell_id] then
      return fail("the cell is busy")
    end
    state.running[cell_id] = { started = util.now(), kind = "run", conn = conn, adapter = adapter }
    if cell then
      set_runtime(state, cell, "running")
    end
    ui_query().start_spinner(state)
    local run_stmts = { { sql = sql, kind = stmt.kind, class = stmt.class, line = 1 } }
    state.running[cell_id].job = adapter.run(
      conn,
      run_stmts,
      { timeout_ms = config.get().query.timeout_ms },
      function(res)
        state.running[cell_id] = nil
        if cell then
          state.runtime[cell.id] = { status = res.ok and "ok" or "error" }
        end
        if not res.ok then
          ui_query().render(state)
          return fail("page: " .. tostring(res.error and res.error.message or "failed"))
        end
        local page = res.statements[1] and res.statements[1].sets[1]
        local got = page and #page.rows or 0
        for _, row in ipairs(page and page.rows or {}) do
          set.rows[#set.rows + 1] = row
        end
        set.row_count = #set.rows
        set.evicted = nil
        st.more = got >= n
        st.pages = (st.pages or 1) + 1
        result.elapsed_ms = (result.elapsed_ms or 0) + (res.elapsed_ms or 0)
        result.server_ms = (result.server_ms or 0) + (res.server_ms or 0)
        local truncated = false
        for _, other in ipairs(result.statements) do
          truncated = truncated or other.more == true
        end
        result.truncated = truncated
        if cell then
          notebook.set_result(state.nb, cell, result)
        else
          notebook.set_result_memory(state.nb, { id = cell_id }, result)
        end
        ui_query().render(state)
        if state.view.cell_id == cell_id then
          ui_results().render(state)
        end
        require("dbgrid.ui.pins").refresh(state, cell_id)
        util.notify(
          got == 0 and "no more rows"
            or string.format(
              "%s more %s (%s so far)",
              util.fmt_int(got),
              got == 1 and "row" or "rows",
              util.fmt_int(#set.rows)
            )
        )
        if cb then
          cb(result)
        end
      end
    )
  end)
end

---Cancel the query of a backend, or terminate its session (PostgreSQL).
---@param state dbgrid.State
---@param pid integer
---@param action "cancel"|"terminate"
---@param opts? { connection?: string }
---@param cb fun(ok: boolean, message: string)
function M.signal_backend(state, pid, action, opts, cb)
  opts = opts or {}
  M.with_connection(state, opts.connection, function(conn)
    local adapter = adapter_for(conn)
    if not adapter then
      return cb(false, "no adapter")
    end
    if adapter.name ~= "postgres" then
      return cb(false, "backend signals need PostgreSQL (" .. (adapter.dialect or adapter.name) .. " has none)")
    end
    local fn = action == "terminate" and "pg_terminate_backend" or "pg_cancel_backend"
    local sql = string.format("select %s(%d)", fn, pid)
    adapter.run(conn, { { sql = sql, kind = "select", class = "read", line = 1 } }, {}, function(res)
      if not res.ok then
        return cb(false, tostring(res.error and res.error.message or "failed"))
      end
      local set = res.statements[1] and res.statements[1].sets[1]
      local v = set and set.rows[1] and set.rows[1][1]
      if v == "t" or v == "true" then
        cb(
          true,
          (action == "terminate" and "terminated the session of backend " or "cancelled the query of backend ") .. pid
        )
      else
        cb(false, "no backend with pid " .. pid .. " (already gone?)")
      end
    end)
  end)
end

---Run a `-- @metrics` cell: no SQL, the newest CloudWatch datapoints of the
---cell's connection as a one-row result. It goes through the same end as a
---query, so `-- @every`, `-- @record`, `-- @alert` and pins work on it.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param opts table   as for run_cell
function run_metrics(state, cell, opts)
  local directives = cells.directives(cell)
  local name = type(directives.conn) == "string" and directives.conn or state.nb.meta.connection
  local conn = name and connections.get(name)
  if not conn then
    if not opts.live then
      util.error("@metrics: " .. (name and ("connection '" .. name .. "' is not configured") or "no connection"))
    end
    return
  end
  local every = cells.interval_ms(directives.every)
  if every then
    -- CloudWatch has one datapoint a minute: asking more often only repeats it
    every = math.max(every, 60000)
  end
  local names = type(directives.metrics) == "string" and vim.split(directives.metrics, "[,%s]+", { trimempty = true })
    or nil
  local started = util.now()
  state.running[cell.id] = { started = started, kind = "run", conn = conn }
  set_runtime(state, cell, "running")
  ui_query().start_spinner(state)
  local what = "cloudwatch " .. (names and table.concat(names, ", ") or "metrics") .. " of " .. conn.name
  require("dbgrid.aws").metrics(conn, names, function(set, err)
    if not vim.api.nvim_buf_is_valid(state.buf) then
      return
    end
    state.running[cell.id] = nil
    local res = {
      ok = set ~= nil,
      statements = {
        { sql = what, kind = "select", class = "read", sets = set and { set } or {}, tags = {} },
      },
      notices = {},
      error = not set and { message = tostring(err or "no metrics") } or nil,
      elapsed_ms = math.floor((util.now() - started) * 1000),
    }
    local extra = { warnings = {}, plans = {}, live = opts.live, sql = "-- " .. what }
    execute_done(state, cell, conn, {}, extra, res, function(result)
      if every and result.ok and not opts.live and not state.live[cell.id] then
        M.start_live(state, cell, every, opts.live_opts)
      end
      if opts.cb then
        opts.cb(result)
      end
    end)
  end)
end

---Run one cell: dependencies first (when their result is stale), then the
---cell with its references inlined and parameters filled in.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param opts? { cb?: fun(result: table), silent?: boolean, live?: boolean, dry_run?: boolean, no_deps?: boolean,
---  values?: table<string,string> }
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
  if cells.directives(cell).metrics ~= nil then
    return run_metrics(state, cell, opts)
  end
  if #sqlmod.split(cells.sql_text(cell)) == 0 then
    if cells.prompt(cell) then
      return require("dbgrid.ai").generate(state, cell)
    end
    util.warn("nothing to run in this cell")
    return
  end
  if not opts.no_deps and not opts.live then
    local deps, err = M.pending_dependencies(state, cell)
    if not deps then
      return util.error(err or "dependencies could not be resolved")
    end
    if #deps > 0 then
      local names = vim.tbl_map(cells.ref_name, deps)
      util.notify("running " .. table.concat(names, ", ") .. " first")
      local i = 0
      local function next_dep()
        i = i + 1
        local dep = deps[i]
        if not dep then
          local fresh = cells.by_id(state.buf, cell.id) or cell
          return M.run_cell(state, fresh, vim.tbl_extend("force", opts, { no_deps = true }))
        end
        local fresh_dep = cells.by_id(state.buf, dep.id) or dep
        M.run_cell(state, fresh_dep, {
          no_deps = true,
          silent = opts.silent,
          cb = function(result)
            if result.ok then
              next_dep()
            else
              util.warn("stopped: dependency " .. cells.ref_name(dep) .. " failed")
              if opts.cb then
                opts.cb(result)
              end
            end
          end,
        })
      end
      return next_dep()
    end
  end
  local directives = cells.directives(cell)
  local secretsmod = require("dbgrid.secrets")
  local secret_decls = secretsmod.declared(cell)
  local conn_override = type(directives.conn) == "string" and directives.conn or nil
  -- `-- @secret` values come from Secrets Manager through the cell's connection, so that
  -- connection is resolved first; the values only ever live in `exp.text` and the psql stdin
  local function resolve_secrets(cb)
    if #secret_decls == 0 then
      return cb(nil, nil)
    end
    M.with_connection(state, conn_override, function(conn)
      secretsmod.resolve(conn, secret_decls, function(literals, raw, serr)
        if not literals then
          if not opts.live then
            util.error("cannot run: " .. tostring(serr))
          end
          return
        end
        cb(literals, raw)
      end)
    end)
  end
  resolve_secrets(function(secret_literals, secret_raw)
    expand.prepare(
      state,
      cell,
      { values = opts.values, silent = opts.silent or opts.live, secrets = secret_literals },
      function(exp, err)
        if not exp then
          if not opts.live then
            util.error("cannot run: " .. tostring(err))
          end
          return
        end
        local text, params = exp.text, exp.params
        local stmts = sqlmod.split(text)
        if #stmts == 0 then
          util.warn("nothing to run in this cell")
          return
        end
        local every = cells.interval_ms(directives.every)
        if directives.every and not every and not opts.live then
          util.warn("bad @every value '" .. tostring(directives.every) .. "' (use 5s, 2m, 500ms)")
        end
        M.with_connection(state, conn_override, function(conn)
          local adapter = adapter_for(conn)
          if not adapter then
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
              unlimited = applied and st.sql or nil,
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
            -- CREATE SUBSCRIPTION, VACUUM, CREATE INDEX CONCURRENTLY ... refuse a transaction block
            local blocker
            for _, st in ipairs(stmts) do
              blocker = blocker or sqlmod.no_transaction(st)
            end
            if transaction and blocker then
              if dry_run then
                util.error(blocker .. " cannot run inside a transaction block, so it cannot be dry-run")
                return
              end
              transaction = false
              if not opts.live and not opts.silent then
                util.notify(blocker .. " cannot run inside a transaction block: the cell runs without one")
              end
            end
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
              sql = exp.safe_text or text,
              params = next(params or {}) and params or nil,
              refs = exp.cells,
              redact = secret_raw,
            }
            local function run_now()
              execute(state, cell, conn, adapter, run_stmts, extra, function(result)
                if every and result.ok and not opts.live and not state.live[cell.id] then
                  M.start_live(state, cell, every, opts.live_opts)
                end
                if opts.cb then
                  opts.cb(result)
                end
              end)
            end
            local function go()
              -- keep the rows an UPDATE / DELETE is about to touch, so the undo can be written later
              if not has_write or dry_run or opts.live or (cfg.query.undo_rows or 0) <= 0 then
                return run_now()
              end
              local undo = require("dbgrid.undo")
              schema.get(conn, function(sch)
                if not vim.api.nvim_buf_is_valid(state.buf) then
                  return
                end
                state.running[cell.id] = { started = util.now(), kind = "undo", conn = conn, adapter = adapter }
                ui_query().start_spinner(state)
                local job = undo.capture(conn, adapter, sch, stmts, function(entries, note, cancelled)
                  state.running[cell.id] = nil
                  if cancelled then
                    -- `\x` while the rows were being read: the write does not run either
                    set_runtime(state, cell, "idle")
                    ui_query().render(state)
                    util.notify("cancelled before the write ran")
                    return
                  end
                  extra.undo = entries
                  extra.undo_skipped = note
                  run_now()
                end)
                if job and state.running[cell.id] then
                  state.running[cell.id].job = job
                end
              end)
            end
            if mode == "off" or #explainable == 0 or opts.live then
              return go()
            end
            -- pre-flight EXPLAIN for the index check
            set_runtime(state, cell, "planning")
            state.running[cell.id] = { started = util.now(), kind = "explain", conn = conn, adapter = adapter }
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
                  local ws = explain.warnings(plan, sch, { min_rows = cfg.index_check.min_rows, sql = e.stmt.sql })
                  for _, w in ipairs(ws) do
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
      end
    )
  end)
end

---Run every cell of the notebook, dependencies first, document order otherwise.
---@param state dbgrid.State
function M.run_all(state)
  cells.ensure_ids(state.buf)
  local list, err = M.run_order(state)
  if err then
    return util.error(err)
  end
  local i, ran = 0, 0
  local function next_cell()
    i = i + 1
    local cell = list[i]
    if not cell then
      util.notify("ran " .. ran .. " cells")
      return
    end
    local fresh = cells.by_id(state.buf, cell.id)
    if not fresh or not cells.has_sql(fresh) then
      return next_cell()
    end
    M.run_cell(state, fresh, {
      no_deps = true,
      cb = function(result)
        ran = ran + 1
        if result.ok then
          next_cell()
        else
          util.warn("stopped at " .. cells.ref_name(fresh) .. ": " .. tostring(result.error and result.error.message))
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
---@param opts? { force?: boolean, quiet?: boolean }  `live all`: past `live.max_cells`, without a message per cell
function M.start_live(state, cell, interval_ms, opts)
  opts = opts or {}
  local cfg = config.get().live
  state.live = state.live or {}
  if state.live[cell.id] then
    return
  end
  local n = 0
  for _ in pairs(state.live) do
    n = n + 1
  end
  if n >= (cfg.max_cells or 4) and not opts.force then
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
  if not opts.quiet then
    util.notify(
      string.format(
        "live: %s every %s (cancel with %s)",
        cells.label(cell, 30),
        util.fmt_ms(interval_ms),
        tostring(config.get().keymaps.query.cancel)
      )
    )
  end
  ui_query().render(state)
  ui_query().refresh_winbar(state)
end

---Start every `-- @every` cell of the notebook that is not live yet. Asking
---for all of them is explicit, so `live.max_cells` does not apply.
---@param state dbgrid.State
---@param opts? { pin?: boolean, cb?: fun(started: integer, failed: integer) }  pin: also pin each recorded cell
---@return integer n  cells being started
function M.live_all(state, opts)
  opts = opts or {}
  cells.ensure_ids(state.buf)
  local todo = {}
  for _, cell in ipairs(cells.parse(state.buf)) do
    if cells.interval_ms(cells.directives(cell).every) and not state.live[cell.id] then
      todo[#todo + 1] = cell
    end
  end
  if #todo == 0 then
    util.notify("no cell to start: every `-- @every` cell is live already, or there is none")
    return 0
  end
  local left, started, failed = #todo, 0, 0
  util.notify(
    string.format("live: starting %d cell%s (stop them with :Dbgrid live stop)", #todo, #todo == 1 and "" or "s")
  )
  for _, cell in ipairs(todo) do
    M.run_cell(state, cell, {
      silent = true,
      no_deps = true,
      live_opts = { force = true, quiet = true },
      cb = function(result)
        left = left - 1
        if result.ok and state.live[cell.id] then
          started = started + 1
          if opts.pin and require("dbgrid.record").wanted(cell) and not (state.pins or {})[cell.id] then
            pcall(require("dbgrid.ui.pins").open, state, cell.id)
          end
        else
          failed = failed + 1
          util.warn(
            "live: "
              .. cells.label(cell, 30)
              .. " did not start: "
              .. tostring(result.error and result.error.message or "the run failed")
          )
        end
        if left == 0 and opts.cb then
          opts.cb(started, failed)
        end
      end,
    })
  end
  return #todo
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

---The first statement of a cell after cell references and parameters were
---expanded (asks for missing values), or nil after a warning.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param cb fun(st?: dbgrid.Statement, cell: dbgrid.Cell, exp?: dbgrid.Expansion)
local function prepared_statement(state, cell, cb)
  cells.ensure_ids(state.buf)
  cell = cells.parse(state.buf)[cell.index] or cell
  if #sqlmod.split(cells.sql_text(cell)) == 0 then
    util.warn("nothing to explain")
    return cb(nil, cell)
  end
  expand.prepare(state, cell, {}, function(exp, err)
    if not exp then
      util.error("cannot explain: " .. tostring(err))
      return cb(nil, cell)
    end
    local st = sqlmod.split(exp.text)[1]
    if not st then
      util.warn("nothing to explain")
      return cb(nil, cell)
    end
    cb(st, cell, exp)
  end)
end

---EXPLAIN (optionally ANALYZE) the first statement of a cell and show the plan.
---@param state dbgrid.State
---@param cell dbgrid.Cell
---@param analyze boolean
function M.explain_cell(state, cell, analyze)
  cells.ensure_ids(state.buf)
  cell = cells.parse(state.buf)[cell.index] or cell
  if #sqlmod.split(cells.sql_text(cell)) == 0 then
    util.warn("nothing to explain")
    return
  end
  local directives = cells.directives(cell)
  expand.prepare(state, cell, {}, function(exp, err)
    if not exp then
      return util.error("cannot explain: " .. tostring(err))
    end
    local stmts = sqlmod.split(exp.text)
    local st = stmts[1]
    if not st or not sqlmod.is_explainable(st) then
      util.warn("cannot EXPLAIN a " .. (st and st.kind:upper() or "empty") .. " statement")
      return
    end
    M.with_connection(state, type(directives.conn) == "string" and directives.conn or nil, function(conn)
      local adapter = adapter_for(conn)
      if not adapter then
        return
      end
      if analyze and (st.class == "write") and conn.readonly then
        return util.error("connection is read-only")
      end
      state.running[cell.id] = { started = util.now(), kind = "explain", conn = conn, adapter = adapter }
      set_runtime(state, cell, "planning")
      ui_query().start_spinner(state)
      state.running[cell.id].job = adapter.explain_text(conn, st.sql, analyze, function(lines, e, info)
        state.running[cell.id] = nil
        state.runtime[cell.id] = state.runtime[cell.id] or {}
        state.runtime[cell.id].status = nil
        if e then
          state.runtime[cell.id].plan_text = { "ERROR: " .. e }
          state.runtime[cell.id].plan_info = nil
        else
          state.runtime[cell.id].plan_text = lines
          state.runtime[cell.id].plan_info = info
        end
        state.runtime[cell.id].plan_kind = (analyze and adapter.analyze ~= false) and "EXPLAIN ANALYZE" or "EXPLAIN"
        state.runtime[cell.id].plan_params = exp.params
        state.active_cell = cell.id
        ui_query().render(state)
        ui_results().show(state, cell.id, { view = "plan" })
        local findings = info and info.findings or {}
        if #findings > 0 then
          local warn = 0
          for _, f in ipairs(findings) do
            if f.severity == "warn" then
              warn = warn + 1
            end
          end
          util.notify(string.format("EXPLAIN ANALYZE: %d finding(s), %d worth a look", #findings, warn))
        end
      end)
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
  if state.running[cell.id] then
    return util.warn("cell is busy")
  end
  prepared_statement(state, cell, function(st, fresh_cell, exp)
    cell = fresh_cell
    if not st then
      return
    end
    if not sqlmod.is_explainable(st) then
      return util.warn("cannot analyze a " .. st.kind:upper() .. " statement")
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
      state.running[cell.id] = { started = util.now(), kind = "analyze", conn = conn, adapter = adapter }
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
          for _, w in ipairs(explain.warnings(plan, sch, { min_rows = cfg.index_check.min_rows, sql = st.sql })) do
            findings[#findings + 1] = w.message
          end
          local rule_findings = explain.analyze_findings(plan, {
            estimate_ratio = rules.estimate_ratio,
            min_rows = rules.min_rows,
            schema = sch,
          })
          for _, f in ipairs(rule_findings) do
            findings[#findings + 1] = f.message .. (f.suggestion and (" → " .. f.suggestion) or "")
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
            local plan_lines, plan_marks = explain.to_lines(plan)
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
              state.runtime[cell.id].plan_info = { plan = plan, marks = plan_marks, findings = rule_findings }
              state.runtime[cell.id].plan_params = exp and exp.params or nil
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
  prepared_statement(state, cell, function(st, fresh_cell)
    cell = fresh_cell
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
        state.running[cell.id] = { started = util.now(), kind = "explain", conn = conn, adapter = adapter }
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
    state.running[cell.id] = { started = util.now(), kind = "run", conn = conn, adapter = adapter }
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
          a.cancel(r.job, r.conn)
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
