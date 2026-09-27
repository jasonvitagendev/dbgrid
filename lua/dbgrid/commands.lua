-- :Dbgrid <subcommand> [args]
local util = require("dbgrid.util")

local M = {}

local function current_or_warn()
  local s = require("dbgrid.state").current()
  if not s then
    util.warn("not inside a dbgrid notebook")
  end
  return s
end

local function current_cell(s)
  return require("dbgrid.ui.query").current_cell(s)
end

M.subcommands = {
  open = function(args)
    require("dbgrid").open(args[1])
  end,
  new = function(args)
    if args[1] == "--template" or args[1] == "-t" then
      local name = args[2]
      local title = #args > 2 and table.concat(vim.list_slice(args, 3, #args), " ") or nil
      if not name then
        return M.subcommands.templates({})
      end
      return require("dbgrid.templates").create_interactive(name, { title = title }, function(nb)
        if nb then
          require("dbgrid.ui.layout").open(nb)
        end
      end)
    end
    require("dbgrid").new(#args > 0 and table.concat(args, " ") or nil)
  end,
  templates = function(args)
    local templates = require("dbgrid.templates")
    if args[1] == "list" then
      for _, t in ipairs(templates.list()) do
        util.notify(string.format("%s — %s%s", t.name, t.description, t.builtin and "" or " (user)"))
      end
      return
    end
    templates.pick(function(tpl)
      if not tpl then
        return
      end
      templates.create_interactive(tpl, {}, function(nb)
        if nb then
          require("dbgrid.ui.layout").open(nb)
        end
      end)
    end)
  end,
  analyze = function()
    local s = current_or_warn()
    if not s then
      return
    end
    local cell = current_cell(s)
    if cell then
      require("dbgrid.runner").analyze_cell(s, cell)
    end
  end,
  ["explain-error"] = function()
    local s = current_or_warn()
    if not s then
      return
    end
    local cell = current_cell(s)
    if cell then
      require("dbgrid.runner").explain_error(s, cell)
    end
  end,
  ["try-index"] = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    local cell = current_cell(s)
    if cell then
      require("dbgrid.runner").try_index(s, cell, #args > 0 and table.concat(args, " ") or nil)
    end
  end,
  params = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    local nbmod = require("dbgrid.notebook")
    if args[1] and args[2] then
      nbmod.set_param(s.nb, (args[1]:gsub("^:", "")), table.concat(vim.list_slice(args, 2, #args), " "))
      return util.notify("set :" .. args[1]:gsub("^:", "") .. " for this notebook")
    elseif args[1] == "clear" then
      s.nb.meta.params = {}
      nbmod.save_meta(s.nb)
      return util.notify("parameters cleared")
    end
    local cell = current_cell(s)
    if cell then
      require("dbgrid.runner").edit_params(s, cell)
    end
  end,
  live = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    local runner = require("dbgrid.runner")
    if args[1] == "stop" then
      return runner.stop_all_live(s, "cancelled")
    end
    local cell = current_cell(s)
    if not cell then
      return
    end
    if s.live[cell.id] then
      return runner.stop_live(s, cell.id, "cancelled")
    end
    local ms = require("dbgrid.cells").interval_ms(args[1] or "5s")
    if not ms then
      return util.error("usage: :Dbgrid live [interval|stop]")
    end
    runner.run_cell(s, cell, {
      cb = function(r)
        if r.ok and not s.live[cell.id] then
          runner.start_live(s, cell, ms)
        end
      end,
    })
  end,
  history = function()
    local s = require("dbgrid.state").current()
    require("dbgrid.history").pick(function(entry, action)
      if not entry then
        return
      end
      if action == "yank" or not s then
        vim.fn.setreg('"', entry.sql)
        pcall(vim.fn.setreg, "+", entry.sql)
        return util.notify("yanked")
      end
      local cells = require("dbgrid.cells")
      local cell = current_cell(s)
      local id, lnum = cells.insert(s.buf, cell and "below" or "end", cell, "from history")
      local lines = require("dbgrid.util").lines(entry.sql)
      vim.api.nvim_buf_set_lines(s.buf, lnum, lnum, false, lines)
      vim.b[s.buf].dbgrid_cells_cache = nil
      require("dbgrid.ui.query").render(s)
      pcall(vim.api.nvim_win_set_cursor, s.query_win or 0, { lnum + 1, 0 })
      util.notify("inserted cell " .. id)
    end)
  end,
  diff = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    local cell = current_cell(s)
    if not cell then
      return
    end
    if not args[1] then
      return require("dbgrid.ui.results").diff_previous(s)
    end
    require("dbgrid.runner").diff_on(s, cell, args[1])
  end,
  settings = function(args)
    if args[1] ~= "diff" then
      return util.error("usage: :Dbgrid settings diff <a> <b>")
    end
    M.pair_command(args[2], args[3], function(a, b)
      require("dbgrid.compare").settings(a, b)
    end)
  end,
  aws = function(args)
    local aws = require("dbgrid.aws")
    local sub = args[1] or "status"
    local s = require("dbgrid.state").current()
    local function with_aws_conn(cb)
      local name = args[2] or (s and s.nb.meta.connection)
      local conn = name and require("dbgrid.connections").get(name)
      if not conn or not conn.aws then
        return util.error("pick an AWS connection first (:Dbgrid aws " .. sub .. " <connection>)")
      end
      cb(conn)
    end
    local function show(rows, columns, err, title)
      if err then
        return util.error("aws " .. sub .. ": " .. tostring(err))
      end
      require("dbgrid.ui.results").show_rows(s, { columns = columns, rows = rows }, { title = title })
    end
    if sub == "add" then
      return aws.add_interactive(function(conn)
        if conn then
          util.notify("saved AWS connection " .. conn.name)
        end
      end)
    elseif sub == "login" then
      return with_aws_conn(function(conn)
        aws.login(conn.aws, function(ok)
          util.notify(ok and "credentials refreshed" or "login failed")
          require("dbgrid.connections").forget(conn.name)
        end)
      end)
    elseif sub == "refresh" then
      return with_aws_conn(function(conn)
        aws.forget_endpoints(conn.aws)
        if aws.forget_credentials then
          aws.forget_credentials(conn.aws)
        end
        require("dbgrid.connections").forget(conn.name)
        util.notify("endpoint cache dropped for " .. conn.name)
      end)
    elseif sub == "tunnels" then
      local tunnel = require("dbgrid.tunnel")
      local list = tunnel.list()
      if #list == 0 then
        return util.notify("no tunnels")
      end
      local items = {}
      for _, t in ipairs(list) do
        items[#items + 1] = {
          text = string.format(
            "%s  localhost:%d  pid %s  %s",
            t.key,
            t.port or 0,
            tostring(t.pid),
            t.ok and "up" or "dead"
          ),
          data = t,
        }
      end
      return require("dbgrid.ui.picker").pick(items, {
        prompt = "Tunnels (Enter: kill)",
        preview = false,
        on_select = function(item)
          if item then
            tunnel.kill(item.data.key)
            util.notify("killed tunnel " .. item.data.key)
          end
        end,
      })
    elseif sub == "status" then
      return with_aws_conn(function(conn)
        util.notify("fetching status of " .. conn.name .. "…")
        aws.status(conn, function(rows, columns, err)
          show(rows, columns, err, "aws status · " .. conn.name)
        end)
      end)
    elseif sub == "events" then
      return with_aws_conn(function(conn)
        aws.events(conn, function(rows, columns, err)
          show(rows, columns, err, "aws events · " .. conn.name)
        end)
      end)
    elseif sub == "bluegreen" or sub == "blue-green" then
      return with_aws_conn(function(conn)
        aws.bluegreen(conn, function(rows, columns, err)
          show(rows, columns, err, "blue/green deployments")
        end)
      end)
    end
    util.error("usage: :Dbgrid aws add|login|refresh|tunnels|status|events|bluegreen [connection]")
  end,
  last = function()
    require("dbgrid").last()
  end,
  tags = function()
    require("dbgrid").tags()
  end,
  tag = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    local nb = require("dbgrid.notebook")
    if args[1] == "add" and args[2] then
      nb.add_tag(s.nb, args[2])
    elseif args[1] == "remove" and args[2] then
      nb.remove_tag(s.nb, args[2])
    else
      return require("dbgrid.ui.query").edit_tags(s)
    end
    require("dbgrid.ui.query").refresh_winbar(s)
  end,
  connections = function()
    require("dbgrid.ui.picker").connection(function(conn)
      if not conn then
        return
      end
      local s = require("dbgrid.state").current()
      if s then
        require("dbgrid.notebook").set_connection(s.nb, conn.name)
        require("dbgrid.ui.query").refresh_winbar(s)
      else
        require("dbgrid.connections").test(conn, function(ok, msg)
          util.notify((ok and "connected: " or "failed: ") .. msg)
        end)
      end
    end)
  end,
  connect = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    if not args[1] then
      return require("dbgrid.ui.query").pick_connection(s)
    end
    local conn = require("dbgrid.connections").get(args[1])
    if not conn then
      return util.error("no connection named " .. args[1])
    end
    require("dbgrid.notebook").set_connection(s.nb, conn.name)
    require("dbgrid.ui.query").refresh_winbar(s)
  end,
  run = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    if args[1] == "all" then
      return require("dbgrid.runner").run_all(s)
    end
    local cell = current_cell(s)
    if cell then
      require("dbgrid.runner").run_cell(s, cell)
    end
  end,
  explain = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    local cell = current_cell(s)
    if cell then
      require("dbgrid.runner").explain_cell(s, cell, args[1] == "analyze")
    end
  end,
  cancel = function()
    local s = current_or_warn()
    if s then
      require("dbgrid.runner").cancel(s)
      require("dbgrid.ai").cancel(s)
    end
  end,
  ask = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    local cell = current_cell(s)
    if not cell then
      return
    end
    if #args > 0 then
      vim.api.nvim_buf_set_lines(s.buf, cell.first - 1, cell.first - 1, false, { "-- ? " .. table.concat(args, " ") })
      vim.b[s.buf].dbgrid_cells_cache = nil
      cell = require("dbgrid.cells").by_id(s.buf, cell.id) or cell
    end
    require("dbgrid.ai").generate(s, cell)
  end,
  schema = function(args)
    if args[1] == "diff" then
      return M.pair_command(args[2], args[3], function(a, b)
        require("dbgrid.compare").schema(a, b)
      end)
    end
    local s = current_or_warn()
    if not s then
      return
    end
    if args[1] == "tables" then
      return require("dbgrid.ui.query").browse_tables(s)
    end
    require("dbgrid.ui.query").refresh_schema(s)
  end,
  describe = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    if not args[1] then
      return require("dbgrid.ui.query").describe_under_cursor(s)
    end
    require("dbgrid.runner").with_connection(s, nil, function(conn)
      require("dbgrid.schema").get(conn, function(sch)
        local t = sch and require("dbgrid.schema").find_table(sch, args[1])
        if not t then
          return util.warn("no table named " .. args[1])
        end
        vim.lsp.util.open_floating_preview(
          require("dbgrid.schema").describe_lines(t),
          "",
          { border = "rounded", title = " " .. args[1] .. " " }
        )
      end)
    end)
  end,
  close = function()
    require("dbgrid").close()
  end,
  rename = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    local function do_rename(title)
      local ok, err = require("dbgrid.notebook").rename(s.nb, title)
      if not ok then
        return util.error(err or "rename failed")
      end
      vim.api.nvim_buf_set_name(s.buf, s.nb.path)
      vim.api.nvim_buf_call(s.buf, function()
        pcall(vim.cmd, "silent write!")
      end)
      require("dbgrid.ui.query").refresh_winbar(s)
    end
    if #args > 0 then
      return do_rename(table.concat(args, " "))
    end
    vim.ui.input({ prompt = "New title: ", default = s.nb.meta.title }, function(t)
      if t and t ~= "" then
        do_rename(t)
      end
    end)
  end,
  delete = function()
    local s = current_or_warn()
    if s then
      require("dbgrid").delete(s.nb)
    end
  end,
  export = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    local results = require("dbgrid.ui.results")
    if args[1] == "md" or args[1] == "markdown" then
      local text = require("dbgrid.export").markdown(s)
      if args[2] then
        util.write_file(vim.fn.expand(args[2]), text)
        return util.notify("written " .. args[2])
      end
      vim.fn.setreg('"', text)
      pcall(vim.fn.setreg, "+", text)
      return util.notify("yanked the notebook as markdown")
    elseif args[1] == "json" then
      results.yank_row_json(s)
    else
      results.yank_csv(s)
    end
    if args[2] then
      local text = vim.fn.getreg('"')
      util.write_file(vim.fn.expand(args[2]), text)
      util.notify("written " .. args[2])
    end
  end,
  health = function()
    vim.cmd("checkhealth dbgrid")
  end,
}

---Resolve two connection names (asking for the missing ones) and call back.
---@param a? string
---@param b? string
---@param cb fun(a: dbgrid.Connection, b: dbgrid.Connection)
function M.pair_command(a, b, cb)
  local connections = require("dbgrid.connections")
  local picker = require("dbgrid.ui.picker")
  local s = require("dbgrid.state").current()
  local function need(name, prompt, exclude, k)
    if name then
      local c = connections.get(name)
      if not c then
        return util.error("no connection named " .. name)
      end
      return k(c)
    end
    picker.connection(function(c)
      if c then
        k(c)
      end
    end, { prompt = prompt, exclude = exclude })
  end
  need(a or (s and s.nb.meta.connection), "First connection", nil, function(ca)
    need(b, "Second connection", ca.name, function(cb2)
      cb(ca, cb2)
    end)
  end)
end

---@param opts table  command opts from nvim_create_user_command
function M.run(opts)
  local args = opts.fargs or {}
  local sub = table.remove(args, 1)
  if not sub then
    return require("dbgrid").open()
  end
  local fn = M.subcommands[sub]
  if not fn then
    return util.error("unknown subcommand: " .. sub)
  end
  fn(args)
end

---Command-line completion.
function M.complete(arglead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  local n = #words - (arglead == "" and 0 or 1)
  if n <= 1 then
    local names = vim.tbl_keys(M.subcommands)
    table.sort(names)
    return vim.tbl_filter(function(x)
      return x:find(arglead, 1, true) == 1
    end, names)
  end
  local sub = words[2]
  local candidates = {}
  if sub == "open" then
    for _, nb in ipairs(require("dbgrid.notebook").list()) do
      candidates[#candidates + 1] = nb.name
    end
  elseif sub == "connect" then
    for _, c in ipairs(require("dbgrid.connections").all()) do
      candidates[#candidates + 1] = c.name
    end
  elseif sub == "run" then
    candidates = { "all" }
  elseif sub == "explain" then
    candidates = { "analyze" }
  elseif sub == "schema" then
    candidates = { "refresh", "tables", "diff" }
  elseif sub == "settings" then
    candidates = { "diff" }
  elseif sub == "tag" then
    candidates = { "add", "remove" }
  elseif sub == "export" then
    candidates = { "csv", "json", "md" }
  elseif sub == "aws" then
    candidates = { "add", "login", "refresh", "tunnels", "status", "events", "bluegreen" }
  elseif sub == "new" then
    candidates = { "--template" }
    if words[3] == "--template" then
      candidates = {}
      for _, t in ipairs(require("dbgrid.templates").list()) do
        candidates[#candidates + 1] = t.name
      end
    end
  elseif sub == "diff" then
    for _, c in ipairs(require("dbgrid.connections").all()) do
      candidates[#candidates + 1] = c.name
    end
  elseif sub == "live" then
    candidates = { "stop", "5s", "30s", "2m" }
  elseif sub == "params" then
    candidates = { "clear" }
  elseif sub == "templates" then
    candidates = { "list" }
  end
  return vim.tbl_filter(function(x)
    return x:find(arglead, 1, true) == 1
  end, candidates)
end

return M
