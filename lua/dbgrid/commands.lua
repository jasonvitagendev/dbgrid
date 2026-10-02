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
    require("dbgrid").new(#args > 0 and table.concat(args, " ") or nil)
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
          require("dbgrid.schema").describe_lines(t, sch),
          "",
          { border = "rounded", title = " " .. args[1] .. " " }
        )
      end)
    end)
  end,
  relations = function(args)
    local s = current_or_warn()
    if not s then
      return
    end
    require("dbgrid.ui.query").relations(s, args[1])
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
    if args[1] == "json" then
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
    candidates = { "refresh", "tables" }
  elseif sub == "describe" or sub == "relations" then
    local s = require("dbgrid.state").current()
    local conn = s and s.nb.meta.connection and require("dbgrid.connections").get(s.nb.meta.connection)
    local sch = conn and require("dbgrid.schema").loaded(conn)
    for _, t in ipairs(sch and sch.tables or {}) do
      candidates[#candidates + 1] = require("dbgrid.schema").display_name(t)
    end
  elseif sub == "tag" then
    candidates = { "add", "remove" }
  elseif sub == "export" then
    candidates = { "csv", "json" }
  end
  return vim.tbl_filter(function(x)
    return x:find(arglead, 1, true) == 1
  end, candidates)
end

return M
