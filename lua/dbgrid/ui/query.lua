-- The query pane: cell headers, status, active-cell tracking, keymaps.
local config = require("dbgrid.config")
local cells = require("dbgrid.cells")
local util = require("dbgrid.util")
local notebook = require("dbgrid.notebook")
local state_mod = require("dbgrid.state")

local M = {}

M.ns = vim.api.nvim_create_namespace("dbgrid.cells")
M.ns_active = vim.api.nvim_create_namespace("dbgrid.active")

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local RUNNING_LABEL = {
  run = "running",
  explain = "planning",
  analyze = "asking the agent",
  ai = "generating",
  review = "asking",
  undo = "reading rows for undo",
}

---What a running job is doing, for status lines.
---@param running { kind?: string }
---@return string
function M.running_label(running)
  return RUNNING_LABEL[running.kind] or running.kind or "running"
end

---Map keys (string or list) to a function, buffer-locally.
---@param buf integer
---@param modes string|string[]
---@param keys string|string[]|false
---@param fn function|string
---@param desc string
---@param opts? table
local function map(buf, modes, keys, fn, desc, opts)
  if not keys then
    return
  end
  if type(keys) == "string" then
    keys = { keys }
  end
  for _, k in ipairs(keys) do
    vim.keymap.set(
      modes,
      k,
      fn,
      vim.tbl_extend("force", { buffer = buf, desc = "dbgrid: " .. desc, silent = true, nowait = true }, opts or {})
    )
  end
end

---Cell under the cursor of the query window.
---@param s dbgrid.State
---@return dbgrid.Cell?
function M.current_cell(s)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= s.buf then
    win = s.query_win
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local cell = cells.cell_at(s.buf, lnum)
  if not cell then
    -- cursor above the first marker: use the first cell
    cell = cells.parse(s.buf)[1]
  end
  return cell
end

---Status chunks shown at the end of a cell header.
---@param s dbgrid.State
---@param cell dbgrid.Cell
---@return { [1]: string, [2]: string }[]
function M.status_chunks(s, cell)
  local icons = config.get().icons
  local rt = s.runtime[cell.id] or {}
  local meta = s.nb.meta.cells[cell.id]
  local running = s.running[cell.id]
  local chunks = {}
  local function add(text, hl)
    chunks[#chunks + 1] = { text, hl }
  end
  local live = s.live and s.live[cell.id]
  if running and not (live and running.kind == "run") then
    local frame = SPINNER[(s.spinner_frame or 0) % #SPINNER + 1]
    local secs = util.now() - (running.started or util.now())
    add(string.format(" %s %s %.1fs ", frame, M.running_label(running), secs), "DbgridStatusRunning")
    return chunks
  end
  if live then
    add(
      string.format(
        " %s live every %s · %d ticks%s ",
        icons.live,
        util.fmt_ms(live.interval),
        live.ticks or 0,
        (live.changed_count or 0) > 0 and (" · " .. icons.changed .. " " .. live.changed_count) or ""
      ),
      "DbgridLive"
    )
  end
  local alert = s.alerts and s.alerts[cell.id]
  if alert and alert.firing then
    add(" " .. icons.warn .. " alert: " .. util.truncate(tostring(alert.text), 60) .. " ", "DbgridStatusError")
  end
  if rt.status == "generating" then
    add(" " .. icons.generated .. " generating… ", "DbgridStatusRunning")
    return chunks
  end
  if rt.status == "analyzing" and not running then
    add(" " .. icons.generated .. " analyzing… ", "DbgridStatusRunning")
    return chunks
  end
  if rt.status == "generated" then
    add(" " .. icons.generated .. " generated, not run ", "DbgridStatusWarn")
    return chunks
  end
  if meta then
    local stale = meta.sql_hash ~= cells.hash(cell)
    if meta.status == "ok" then
      add(" " .. icons.ok .. " ", "DbgridStatusOk")
    else
      add(" " .. icons.error .. " error ", "DbgridStatusError")
    end
    if meta.status == "ok" and meta.row_count then
      add(util.fmt_int(meta.row_count) .. (meta.row_count == 1 and " row" or " rows") .. " ", "DbgridStatusDim")
    end
    if meta.elapsed_ms then
      add("· " .. util.fmt_ms(meta.elapsed_ms) .. " ", "DbgridStatusDim")
    end
    if meta.ran_at then
      add("· " .. util.ago(meta.ran_at) .. " ", "DbgridStatusDim")
    end
    if meta.warnings and #meta.warnings > 0 then
      add(icons.warn .. " seq scan ", "DbgridStatusWarn")
    end
    if meta.dry_run then
      add("dry run ", "DbgridStatusWarn")
    end
    if stale then
      add(icons.stale .. " edited ", "DbgridStatusStale")
    end
    return chunks
  end
  if rt.warnings and #rt.warnings > 0 then
    add(" " .. icons.warn .. " not run (seq scan) ", "DbgridStatusWarn")
    return chunks
  end
  if not cells.has_sql(cell) and cells.prompt(cell) then
    add(" ? prompt — run to generate SQL ", "DbgridStatusIdle")
    return chunks
  end
  add(" " .. icons.idle .. " not run ", "DbgridStatusIdle")
  return chunks
end

---Redraw all cell decorations.
---@param s dbgrid.State
function M.render(s)
  local buf = s.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local list = cells.parse(buf)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, M.ns_active, 0, -1)
  local win = s.query_win and vim.api.nvim_win_is_valid(s.query_win) and s.query_win or vim.fn.bufwinid(buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or 80
  local icons = config.get().icons
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, cell in ipairs(list) do
    local active = cell.id == s.active_cell
    if cell.header then
      local row = cell.header - 1
      local line = lines[cell.header] or ""
      local opts = {
        line_hl_group = active and "DbgridCellHeaderActive" or "DbgridCellHeader",
        virt_text = M.status_chunks(s, cell),
        virt_text_pos = "eol",
        hl_mode = "combine",
        priority = 50,
      }
      if i > 1 then
        opts.virt_lines = { { { string.rep("─", width), "DbgridCellRule" } } }
        opts.virt_lines_above = true
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, 0, opts)
      -- hide the "[id]" part
      local s_id, e_id = line:find("%[[%w_%-]+%]%s?")
      if s_id then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, s_id - 1, {
          end_col = e_id,
          conceal = "",
          hl_group = "DbgridCellId",
          priority = 60,
        })
      end
      -- replace the "-- %%" marker with an icon
      local s_m, e_m = line:find("^%s*%-%-%s*%%%%")
      if s_m then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, s_m - 1, {
          end_col = e_m,
          conceal = icons.cell,
          priority = 60,
        })
      end
    end
    if active then
      local first = (cell.header or cell.first) - 1
      local last = math.max(cell.last, cell.header or cell.first) - 1
      for row = first, last do
        pcall(vim.api.nvim_buf_set_extmark, buf, M.ns_active, row, 0, {
          sign_text = "▎",
          sign_hl_group = "DbgridActiveBar",
          priority = 5,
        })
      end
    end
  end
end

---@param s dbgrid.State
function M.refresh_winbar(s)
  if s.query_win and vim.api.nvim_win_is_valid(s.query_win) then
    vim.wo[s.query_win].winbar = "%{%v:lua.require'dbgrid.ui.layout'.winbar_query(" .. s.buf .. ")%}"
  end
  vim.cmd("redrawstatus")
end

---Keep the spinner animating while something runs.
---@param s dbgrid.State
function M.start_spinner(s)
  if s.spinner_timer then
    return
  end
  local uv = vim.uv or vim.loop
  s.spinner_timer = uv.new_timer()
  s.spinner_frame = 0
  s.spinner_timer:start(0, 100, function()
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(s.buf) or vim.tbl_isempty(s.running) then
        if s.spinner_timer then
          s.spinner_timer:stop()
          s.spinner_timer:close()
          s.spinner_timer = nil
        end
        if vim.api.nvim_buf_is_valid(s.buf) then
          M.render(s)
        end
        return
      end
      s.spinner_frame = (s.spinner_frame or 0) + 1
      M.render(s)
    end)
  end)
end

---Cursor moved: switch the results pane when the cell changed.
---@param s dbgrid.State
---@param force? boolean
function M.on_cursor(s, force)
  local cell = M.current_cell(s)
  if not cell then
    return
  end
  if cell.id and (force or cell.id ~= s.active_cell) then
    s.active_cell = cell.id
    M.render(s)
    require("dbgrid.ui.results").show(s, cell.id)
  end
end

---Text changed: keep ids, restyle, clear diagnostics of edited cells.
---@param s dbgrid.State
function M.on_change(s)
  if not vim.api.nvim_buf_is_valid(s.buf) then
    return
  end
  if vim.fn.mode():match("^i") then
    return -- wait for InsertLeave; editing marker lines mid-typing is jarring
  end
  if cells.ensure_ids(s.buf) then
    vim.b[s.buf].dbgrid_cells_cache = nil
  end
  M.render(s)
  for id in pairs(s.live or {}) do
    local c = cells.by_id(s.buf, id)
    if c then
      require("dbgrid.runner").on_cell_edited(s, c)
    end
  end
  local cell = M.current_cell(s)
  if cell and cell.id then
    local meta = s.nb.meta.cells[cell.id]
    if meta and meta.status == "error" and meta.sql_hash ~= cells.hash(cell) then
      require("dbgrid.runner").clear_diagnostics(s, cell)
    end
    if
      s.runtime[cell.id]
      and s.runtime[cell.id].status == "generated"
      and cells.hash(cell) ~= s.runtime[cell.id].generated_hash
    then
      s.runtime[cell.id].status = nil
    end
  end
end

---Move the cursor to cell `idx`.
---@param s dbgrid.State
---@param idx integer
function M.goto_cell(s, idx)
  local list = cells.parse(s.buf)
  local cell = list[math.max(1, math.min(idx, #list))]
  if not cell then
    return
  end
  local lnum = cell.first
  if cell.last < cell.first then
    lnum = cell.header or cell.first
  end
  local win = s.query_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.fn.bufwinid(s.buf)
  end
  if win == -1 then
    return
  end
  lnum = math.min(lnum, vim.api.nvim_buf_line_count(s.buf))
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  if vim.api.nvim_get_current_win() == win then
    vim.cmd("normal! zz")
  end
  M.on_cursor(s)
end

---@param s dbgrid.State
---@param delta integer
function M.move(s, delta)
  local cell = M.current_cell(s)
  local idx = cell and cell.index or 1
  local n = #cells.parse(s.buf)
  local target = idx + delta
  if target < 1 or target > n then
    util.notify(delta > 0 and "last cell" or "first cell")
    return
  end
  M.goto_cell(s, target)
end

---@param s dbgrid.State
---@param where "end"|"below"|"above"
function M.new_cell(s, where)
  local cell = M.current_cell(s)
  local _, lnum = cells.insert(s.buf, where, cell)
  vim.b[s.buf].dbgrid_cells_cache = nil
  local target = math.min(lnum + 1, vim.api.nvim_buf_line_count(s.buf))
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  M.on_cursor(s, true)
  vim.cmd("startinsert")
end

---@param s dbgrid.State
function M.delete_cell(s)
  local cell = M.current_cell(s)
  if not cell then
    return
  end
  local n = #cells.parse(s.buf)
  cells.delete(s.buf, cell)
  vim.b[s.buf].dbgrid_cells_cache = nil
  if cell.id then
    notebook.clear_result(s.nb, cell.id)
    s.runtime[cell.id] = nil
  end
  if n <= 1 then
    cells.insert(s.buf, "end")
  end
  M.on_cursor(s, true)
  M.refresh_winbar(s)
end

---@param s dbgrid.State
function M.yank_cell(s)
  local cell = M.current_cell(s)
  if not cell then
    return
  end
  local text = cells.body_text(cell)
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  util.notify("yanked cell (" .. #cell.lines .. " lines)")
end

---Duplicate the cell below itself (same title, body and directives) and
---move to the copy.
---@param s dbgrid.State
---@return dbgrid.Cell? copy
function M.clone_cell(s)
  local cell = M.current_cell(s)
  if not cell then
    return
  end
  cells.ensure_ids(s.buf)
  cell = cells.parse(s.buf)[cell.index] or cell
  local copy = cells.clone(s.buf, cell)
  M.render(s)
  M.goto_cell(s, copy.index)
  M.on_cursor(s, true)
  util.notify("cloned cell as q" .. copy.index)
  return copy
end

---Lines of a cell's last error, as shown by `show_error`.
---@param result dbgrid.RunResult
---@return string[]
function M.error_lines(result)
  local e = result.error
  local lines = util.error_lines(e)
  if e.stmt_index and #(result.statements or {}) > 1 then
    lines[#lines + 1] = "in statement " .. e.stmt_index .. " of " .. #result.statements
  end
  return lines
end

---Show the cell's last error in a float: message, position, detail, hint
---and context. `y` yanks it, `q` closes.
---@param s dbgrid.State
---@return integer? win
function M.show_error(s)
  local cell = M.current_cell(s)
  if not cell or not cell.id then
    return
  end
  local result = notebook.result_of(s.nb, cell.id)
  if not result or not result.error then
    return util.notify("this cell has no error")
  end
  local lines = M.error_lines(result)
  local _, win = vim.lsp.util.open_floating_preview(lines, "", {
    border = "rounded",
    focusable = true,
    focus = true,
    title = " " .. config.get().icons.error .. " " .. cells.label(cell, 40) .. " · " .. util.ago(result.ran_at) .. " ",
    title_pos = "left",
  })
  local buf = vim.api.nvim_win_get_buf(win)
  local text = table.concat(lines, "\n")
  vim.keymap.set("n", "y", function()
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    util.notify("yanked error")
  end, { buffer = buf, nowait = true, silent = true, desc = "dbgrid: yank the error" })
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, silent = true, desc = "dbgrid: close" })
  return win
end

---@param s dbgrid.State
function M.rename_cell(s)
  local cell = M.current_cell(s)
  if not cell or not cell.header then
    return
  end
  vim.ui.input({ prompt = "Cell title: ", default = cell.title }, function(title)
    if title == nil then
      return
    end
    vim.api.nvim_buf_set_lines(s.buf, cell.header - 1, cell.header, false, { cells.header_line(cell.id, title) })
    M.render(s)
  end)
end

---@param s dbgrid.State
function M.edit_tags(s)
  vim.ui.input({ prompt = "Tags (comma separated): ", default = table.concat(s.nb.meta.tags, ", ") }, function(input)
    if input == nil then
      return
    end
    notebook.set_tags(s.nb, vim.split(input, "[,%s]+", { trimempty = true }))
    M.refresh_winbar(s)
  end)
end

---@param s dbgrid.State
function M.pick_connection(s)
  require("dbgrid.ui.picker").connection(function(conn)
    if not conn then
      return
    end
    notebook.set_connection(s.nb, conn.name)
    M.refresh_winbar(s)
    require("dbgrid.schema").get(conn, function(sch, err)
      if err then
        util.warn("schema: " .. err)
      elseif sch then
        util.notify(string.format("%s: %d tables", conn.name, #sch.tables))
      end
    end)
  end)
end

---@param s dbgrid.State
function M.refresh_schema(s)
  require("dbgrid.runner").with_connection(s, nil, function(conn)
    util.notify("refreshing schema of " .. conn.name .. "…")
    require("dbgrid.schema").refresh(conn, function(sch, err)
      if err then
        util.error("schema: " .. err)
      else
        util.notify(string.format("%s: %d tables, %d schemas", conn.name, #sch.tables, #sch.schemas))
      end
    end)
  end)
end

---Edit the notebook's parameter values.
---@param s dbgrid.State
function M.edit_params(s)
  local expand = require("dbgrid.expand")
  local list = expand.notebook_params(s)
  local items = {}
  for _, p in ipairs(list) do
    items[#items + 1] = {
      text = string.format(
        ":%s = %s%s   (%s)",
        p.name,
        p.value or "?",
        p.source == "cell" and " [-- @param]" or "",
        #p.cells > 0 and table.concat(p.cells, ", ") or "unused"
      ),
      data = p,
      preview = { p.value or "no value yet" },
    }
  end
  items[#items + 1] = { text = "+ set another parameter", data = "new", preview = { "" } }
  local function set_value(name, default)
    vim.ui.input(
      { prompt = "Value for :" .. name .. " (a SQL literal, e.g. 'text', 42): ", default = default or "" },
      function(v)
        if v == nil then
          return
        end
        v = util.trim(v)
        notebook.set_param(s.nb, name, v ~= "" and v or nil)
        util.notify(v ~= "" and (":" .. name .. " = " .. v) or ("forgot :" .. name))
      end
    )
  end
  require("dbgrid.ui.picker").pick(items, {
    prompt = "Parameters",
    preview = false,
    on_select = function(item)
      if not item then
        return
      end
      if item.data == "new" then
        vim.ui.input({ prompt = "Parameter name: " }, function(name)
          if name and name:match("^[%w_]+$") then
            set_value(name)
          end
        end)
        return
      end
      if item.data.source == "cell" then
        util.notify(":" .. item.data.name .. " is set by a -- @param line; that value wins over the one entered here")
      end
      set_value(item.data.name, item.data.value)
    end,
  })
end

---Format the SQL of the current cell.
---@param s dbgrid.State
function M.format_cell(s)
  local cell = M.current_cell(s)
  if not cell then
    return
  end
  local changed, err = require("dbgrid.format").cell(s, cell, { notify = true })
  if changed then
    util.notify("formatted " .. cells.ref_name(cell))
  elseif not err then
    util.notify("already formatted")
  end
end

---@param s dbgrid.State
function M.browse_tables(s)
  require("dbgrid.runner").with_connection(s, nil, function(conn)
    require("dbgrid.schema").get(conn, function(sch, err)
      if not sch then
        return util.error("schema: " .. tostring(err))
      end
      require("dbgrid.ui.picker").table(sch, function(tbl)
        if not tbl then
          return
        end
        local name = require("dbgrid.schema").display_name(tbl)
        vim.api.nvim_put({ name }, "c", true, true)
      end)
    end)
  end)
end

---Identifier under the cursor, with a possible "alias." qualifier.
---@return string? qualifier, string word
local function identifier_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local s_pos, e_pos = col, col
  local function idchar(c)
    return c ~= "" and c:match('[%w_%."]') ~= nil
  end
  while s_pos > 1 and idchar(line:sub(s_pos - 1, s_pos - 1)) do
    s_pos = s_pos - 1
  end
  while e_pos <= #line and idchar(line:sub(e_pos, e_pos)) do
    e_pos = e_pos + 1
  end
  local text = line:sub(s_pos, e_pos - 1)
  if text == "" then
    return nil, vim.fn.expand("<cword>")
  end
  local parts = vim.split(text, ".", { plain = true })
  -- which part is the cursor on?
  local offset = col - s_pos + 1
  local acc = 0
  for i, p in ipairs(parts) do
    acc = acc + #p + 1
    if offset <= acc - 1 or i == #parts then
      if i > 1 then
        return table.concat(vim.list_slice(parts, 1, i - 1), "."), p
      end
      return nil, p
    end
  end
  return nil, text
end

---Show a floating description of the table / column under the cursor.
---@param s dbgrid.State
function M.describe_under_cursor(s)
  local schemamod = require("dbgrid.schema")
  local qualifier, word = identifier_under_cursor()
  if not word or word == "" then
    return
  end
  local cell = M.current_cell(s)
  require("dbgrid.runner").with_connection(s, nil, function(conn)
    schemamod.get(conn, function(sch)
      if not sch then
        return util.warn("schema not loaded")
      end
      local lines
      local refs = cell and require("dbgrid.sql").referenced_tables(cells.body_text(cell)) or {}
      local function alias_table(alias)
        for _, r in ipairs(refs) do
          if (r.alias and r.alias:lower() == alias:lower()) or r.name:lower() == alias:lower() then
            return schemamod.find_table(sch, r.name)
          end
        end
        return schemamod.find_table(sch, alias)
      end
      local tbl = schemamod.find_table(sch, (qualifier and (qualifier .. ".") or "") .. word)
      if tbl then
        lines = schemamod.describe_lines(tbl, sch)
      elseif qualifier then
        local t = alias_table(qualifier)
        local col = t and schemamod.find_column(t, word)
        if col then
          lines = {
            string.format(
              "%s.%s  %s%s",
              schemamod.display_name(t),
              col.name,
              col.type,
              col.notnull and " not null" or ""
            ),
          }
          if col.default then
            lines[#lines + 1] = "default " .. col.default
          end
          if col.comment then
            lines[#lines + 1] = col.comment
          end
        end
      else
        for _, r in ipairs(refs) do
          local t = schemamod.find_table(sch, r.name)
          local col = t and schemamod.find_column(t, word)
          if col then
            lines = {
              string.format(
                "%s.%s  %s%s",
                schemamod.display_name(t),
                col.name,
                col.type,
                col.notnull and " not null" or ""
              ),
            }
            if col.default then
              lines[#lines + 1] = "default " .. col.default
            end
            break
          end
        end
      end
      if not lines then
        return util.notify("no table or column named '" .. word .. "'")
      end
      vim.lsp.util.open_floating_preview(lines, "", { border = "rounded", focusable = true, title = " dbgrid " })
    end)
  end)
end

---Resolve `name` (or the identifier under the cursor) to a table of the
---schema, following aliases of the current cell: on `u.email` or `u` it is
---whatever `u` stands for.
---@param s dbgrid.State
---@param sch dbgrid.SchemaData
---@param name? string
---@return dbgrid.SchemaTable?, string
local function table_at_cursor(s, sch, name)
  local schemamod = require("dbgrid.schema")
  if name then
    return schemamod.find_table(sch, name), name
  end
  local qualifier, word = identifier_under_cursor()
  if not word or word == "" then
    return nil, ""
  end
  local cell = M.current_cell(s)
  local refs = cell and require("dbgrid.sql").referenced_tables(cells.body_text(cell)) or {}
  local function alias_table(alias)
    for _, r in ipairs(refs) do
      if (r.alias and r.alias:lower() == alias:lower()) or r.name:lower() == alias:lower() then
        return schemamod.find_table(sch, r.name)
      end
    end
    return schemamod.find_table(sch, alias)
  end
  local full = (qualifier and (qualifier .. ".") or "") .. word
  local tbl = schemamod.find_table(sch, full)
  if tbl then
    return tbl, full
  end
  if qualifier then
    return alias_table(qualifier), qualifier
  end
  return alias_table(word), word
end

---Show the foreign-key tree of a table (`:Dbgrid relations [table]`, `\k`):
---what it references, what references it, and what a DELETE on it reaches.
---@param s dbgrid.State
---@param name? string  table name; the identifier under the cursor when nil
function M.relations(s, name)
  require("dbgrid.runner").with_connection(s, nil, function(conn)
    require("dbgrid.schema").get(conn, function(sch, err)
      if not sch then
        return util.error("schema: " .. tostring(err))
      end
      local tbl, word = table_at_cursor(s, sch, name)
      if not tbl then
        return util.notify("no table named '" .. word .. "'")
      end
      local depth = config.get().schema.relations_depth or 3
      local lines = require("dbgrid.relations").tree_lines(sch, tbl, { depth = depth })
      vim.lsp.util.open_floating_preview(lines, "", { border = "rounded", focusable = true, title = " relations " })
    end)
  end)
end

---Visual/operator text object for the cell.
---@param s dbgrid.State
---@param inner boolean
function M.textobj(s, inner)
  local cell = M.current_cell(s)
  if not cell then
    return
  end
  local first, last = cells.range(cell, inner)
  vim.cmd("normal! " .. (vim.fn.mode() == "v" and "\27" or ""))
  vim.api.nvim_win_set_cursor(0, { first, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { last, 0 })
end

---Attach decorations, keymaps and autocmds to a notebook buffer.
---@param s dbgrid.State
function M.attach(s)
  local buf = s.buf
  if vim.b[buf].dbgrid_attached then
    M.render(s)
    M.refresh_winbar(s)
    return
  end
  vim.b[buf].dbgrid_attached = true
  vim.b[buf].dbgrid = s.nb.name
  if vim.bo[buf].filetype == "" then
    vim.bo[buf].filetype = "sql"
  end
  if vim.bo[buf].commentstring == "" then
    vim.bo[buf].commentstring = "-- %s"
  end
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    if vim.wo[win].conceallevel < 1 then
      vim.wo[win].conceallevel = 2
    end
    vim.wo[win].concealcursor = "nc"
    s.query_win = win
  end
  M.refresh_winbar(s)

  local cfg = config.get()
  local k = cfg.keymaps.query
  local runner = require("dbgrid.runner")
  local layout = require("dbgrid.ui.layout")

  map(buf, "n", k.run, function()
    local cell = M.current_cell(s)
    if cell then
      runner.run_cell(s, cell)
    end
  end, "run cell")
  map(buf, "n", k.run_all, function()
    runner.run_all(s)
  end, "run all cells")
  map(buf, "n", k.explain, function()
    local cell = M.current_cell(s)
    if cell then
      runner.explain_cell(s, cell, false)
    end
  end, "explain cell")
  map(buf, "n", k.explain_analyze, function()
    local cell = M.current_cell(s)
    if cell then
      runner.explain_cell(s, cell, true)
    end
  end, "explain analyze cell (rolled back)")
  map(buf, "n", k.cancel, function()
    runner.cancel(s, M.current_cell(s))
    require("dbgrid.ai").cancel(s, M.current_cell(s))
  end, "cancel running query / generation")
  map(buf, "n", k.next_cell, function()
    M.move(s, 1)
  end, "next cell")
  map(buf, "n", k.prev_cell, function()
    M.move(s, -1)
  end, "previous cell")
  map(buf, "n", k.first_cell, function()
    M.goto_cell(s, 1)
  end, "first cell")
  map(buf, "n", k.last_cell, function()
    M.goto_cell(s, #cells.parse(buf))
  end, "last cell")
  map(buf, "n", k.new_cell, function()
    M.new_cell(s, "end")
  end, "new cell at the end")
  map(buf, "n", k.new_cell_below, function()
    M.new_cell(s, "below")
  end, "new cell below")
  map(buf, "n", k.new_cell_above, function()
    M.new_cell(s, "above")
  end, "new cell above")
  map(buf, "n", k.delete_cell, function()
    M.delete_cell(s)
  end, "delete cell")
  map(buf, "n", k.yank_cell, function()
    M.yank_cell(s)
  end, "yank cell")
  map(buf, "n", k.rename_cell, function()
    M.rename_cell(s)
  end, "rename cell")
  map(buf, "n", k.clone_cell, function()
    M.clone_cell(s)
  end, "clone the cell below itself")
  map(buf, "n", k.last_error, function()
    M.show_error(s)
  end, "show the last error")
  map(buf, "n", k.undo, function()
    require("dbgrid.undo").write_cell(s, M.current_cell(s))
  end, "write the undo of the cell's last write as a cell")
  map(buf, "n", k.generate, function()
    local cell = M.current_cell(s)
    if cell then
      require("dbgrid.ai").generate(s, cell)
    end
  end, "generate SQL from the cell prompt")
  map(buf, "n", k.ask, function()
    local cell = M.current_cell(s)
    if cell then
      require("dbgrid.ai").review(s, cell)
    end
  end, "ask the agent about the query and its result")
  map(buf, "n", k.analyze, function()
    local cell = M.current_cell(s)
    if cell then
      runner.analyze_cell(s, cell)
    end
  end, "analyze the plan with the agent")
  map(buf, "n", k.explain_error, function()
    local cell = M.current_cell(s)
    if cell then
      runner.explain_error(s, cell)
    end
  end, "explain the last error with the agent")
  map(buf, "n", k.try_index, function()
    local cell = M.current_cell(s)
    if cell then
      runner.try_index(s, cell)
    end
  end, "try the suggested index (hypopg)")
  map(buf, "n", k.history, function()
    require("dbgrid.commands").subcommands.history({})
  end, "query history")
  map(buf, "n", k.tags, function()
    M.edit_tags(s)
  end, "edit notebook tags")
  map(buf, "n", k.connection, function()
    M.pick_connection(s)
  end, "pick connection")
  map(buf, "n", k.schema_refresh, function()
    M.refresh_schema(s)
  end, "refresh schema cache")
  map(buf, "n", k.tables, function()
    M.browse_tables(s)
  end, "browse tables")
  map(buf, "n", k.schema_view, function()
    local results = require("dbgrid.ui.results")
    if s.view.mode == "schema" then
      results.toggle_schema(s)
    else
      results.toggle_schema(s)
      layout.focus_results(s)
    end
  end, "browse the schema (foldable, searchable)")
  map(buf, "n", k.format, function()
    M.format_cell(s)
  end, "format the cell's SQL")
  map(buf, "n", k.params, function()
    M.edit_params(s)
  end, "edit parameters")
  map(buf, "n", k.agent, function()
    require("dbgrid.ai").pick_agent(s)
  end, "pick the coding agent")
  map(buf, "n", k.describe, function()
    M.describe_under_cursor(s)
  end, "describe table/column under cursor")
  map(buf, "n", k.relations, function()
    M.relations(s)
  end, "foreign-key relations of the table under cursor")
  map(buf, "n", k.focus_results, function()
    layout.focus_results(s)
  end, "focus results pane")
  map(buf, "n", k.zoom, function()
    layout.zoom(s)
  end, "zoom pane")
  map(buf, "n", k.close, function()
    layout.close(s)
  end, "close notebook")
  map(buf, { "o", "x" }, k.textobj_inner, function()
    M.textobj(s, true)
  end, "inner cell")
  map(buf, { "o", "x" }, k.textobj_around, function()
    M.textobj(s, false)
  end, "around cell")
  -- <Plug> mappings for custom keys
  vim.keymap.set({ "o", "x" }, "<Plug>(dbgrid-cell-inner)", function()
    M.textobj(s, true)
  end, { buffer = buf })
  vim.keymap.set({ "o", "x" }, "<Plug>(dbgrid-cell-around)", function()
    M.textobj(s, false)
  end, { buffer = buf })

  if cfg.completion.omnifunc then
    vim.bo[buf].omnifunc = "v:lua.require'dbgrid.completion.omni'.omnifunc"
  end

  local group = vim.api.nvim_create_augroup("dbgrid_buf_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.on_cursor(s)
    end,
  })
  local on_change = util.debounce(150, function()
    M.on_change(s)
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      on_change()
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    buffer = buf,
    callback = function()
      cells.ensure_ids(buf)
      if config.get().format.on_save then
        local view = vim.fn.winsaveview()
        require("dbgrid.format").buffer(s, { notify = false })
        pcall(vim.fn.winrestview, view)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buf,
    callback = function()
      local ids = {}
      for _, c in ipairs(cells.parse(buf)) do
        ids[#ids + 1] = c.id
      end
      notebook.prune(s.nb, ids)
      notebook.save_meta(s.nb)
      M.render(s)
    end,
  })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    buffer = buf,
    callback = function()
      M.render(s) -- refreshes relative times
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      local w = vim.api.nvim_get_current_win()
      -- floats are picker previews and the like, not a query pane; the
      -- results window only shows it until reclaim_results puts the results back
      if
        vim.api.nvim_win_get_buf(w) == buf
        and vim.api.nvim_win_get_config(w).relative == ""
        and w ~= s.results_win
      then
        s.query_win = w
        s.tab = vim.api.nvim_get_current_tabpage()
        if vim.wo[w].conceallevel < 1 then
          vim.wo[w].conceallevel = 2
        end
        vim.wo[w].concealcursor = "nc"
        M.refresh_winbar(s)
        -- back from another file: bring back the pane BufWinLeave took away
        M.on_cursor(s, true)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      -- the buffer is still in the window here; check once it's been swapped out
      vim.schedule(function()
        if not s.results_win or not vim.api.nvim_win_is_valid(s.results_win) then
          return
        end
        local tab = vim.api.nvim_win_get_tabpage(s.results_win)
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
          if vim.api.nvim_win_get_buf(w) == buf then
            return -- still shown in another window of the tab
          end
        end
        -- fails (and the pane stays) when it's the last window left
        pcall(vim.api.nvim_win_close, s.results_win, true)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    buffer = buf,
    callback = function()
      M.render(s)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    buffer = buf,
    callback = function()
      require("dbgrid.runner").stop_all_live(s, "closed")
      if s.spinner_timer then
        s.spinner_timer:stop()
        s.spinner_timer:close()
        s.spinner_timer = nil
      end
      if s.results_win and vim.api.nvim_win_is_valid(s.results_win) then
        pcall(vim.api.nvim_win_close, s.results_win, true)
      end
      if s.analysis_win and vim.api.nvim_win_is_valid(s.analysis_win) then
        pcall(vim.api.nvim_win_close, s.analysis_win, true)
      end
      state_mod.detach(buf)
    end,
  })
  util.refresh_keymap_hints(buf)
  M.render(s)
end

return M
