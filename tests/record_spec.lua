-- Tests for `-- @record`: every run of the cell appends its first result set
-- to a CSV next to the notebook. The unit tests inject results; the last one
-- runs a cell against sqlite to cover the hook in the runner.
local H = _G.H
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local conn = { name = "record-test", url = "sqlite:" .. tmp .. "/record.db" }
require("dbgrid").setup({
  storage = { data_dir = tmp .. "/data", mode = "data" },
  connections = { conn },
  default_connection = "record-test",
  query = { confirm_writes = false },
})
local notebook = require("dbgrid.notebook")
local record = require("dbgrid.record")
local util = require("dbgrid.util")

local function result(columns, rows, ran_at)
  return {
    ok = true,
    ran_at = ran_at,
    statements = { { sets = { { columns = columns, rows = rows, row_count = #rows } } } },
  }
end

local function lines(path)
  return vim.split(util.read_file(path) or "", "\n", { trimempty = true })
end

H.describe("record", function()
  local nb = notebook.create("recorded", {})
  local cell = { id = "ab12", title = "slot lag", lines = { "-- @record", "select 1" } }
  local t0 = os.time({ year = 2026, month = 11, day = 10, hour = 9, min = 15, sec = 5 })

  H.it("appends a run under a header with the time in front", function()
    H.eq(record.wanted(cell), true)
    H.eq(record.wanted({ lines = { "select 1" } }), false)
    local path, created = record.append(nb, cell, result({ "slot", "lag" }, { { "a", "10" }, { "b", vim.NIL } }, t0))
    H.eq(path, nb.dir .. "/recordings/recorded/slot-lag.csv")
    H.eq(created, true)
    local _, again = record.append(nb, cell, result({ "slot", "lag" }, { { "a", "1,5" } }, t0 + 5))
    H.eq(again, false)
    H.eq(lines(path), {
      "ts,slot,lag",
      "2026-11-10T09:15:05,a,10",
      "2026-11-10T09:15:05,b,",
      '2026-11-10T09:15:10,a,"1,5"',
    })
  end)

  H.it("marks a run without rows and skips a failed one", function()
    local path = record.append(nb, cell, result({ "slot", "lag" }, {}, t0 + 10))
    H.eq(lines(path)[5], "2026-11-10T09:15:15")
    H.eq(record.append(nb, cell, { ok = false, ran_at = t0 + 15, statements = {} }), nil)
    H.eq(#lines(path), 5)
  end)

  H.it("starts a new file when the columns change and keeps the old one", function()
    local path, created = record.append(nb, cell, result({ "slot", "lag", "active" }, { { "a", "0", "t" } }, t0 + 20))
    H.eq(created, true)
    H.eq(lines(path), { "ts,slot,lag,active", "2026-11-10T09:15:25,a,0,t" })
    local all = record.list(nb)
    H.eq(#all, 2)
    local old = vim.tbl_filter(function(r)
      return r.path ~= path
    end, all)[1]
    H.matches(old.name, "^slot%-lag%.%d+%-%d+$")
    H.eq(old.lines, 4)
  end)

  H.it("names the file after the directive's value, else the cell id", function()
    local named = { id = "cd34", title = "whatever", lines = { "-- @record Lag On Source.csv", "select 1" } }
    H.eq(vim.fn.fnamemodify(record.path(nb, named), ":t"), "lag-on-source.csv")
    H.eq(vim.fn.fnamemodify(record.path(nb, { id = "ef56", title = "", lines = { "-- @record" } }), ":t"), "ef56.csv")
  end)

  H.it("is ignored by git in a project store", function()
    local root = tmp .. "/proj"
    vim.fn.mkdir(root, "p")
    require("dbgrid.config").setup({ storage = { data_dir = tmp .. "/data", mode = "project" } })
    local pnb = notebook.create("in repo", { root = root })
    record.append(pnb, cell, result({ "a" }, { { "1" } }, t0))
    H.truthy(util.exists(root .. "/.dbgrid/recordings/in-repo/slot-lag.csv"))
    H.truthy(vim.tbl_contains(lines(root .. "/.dbgrid/.gitignore"), "recordings/"))
    require("dbgrid.config").setup({
      storage = { data_dir = tmp .. "/data", mode = "data" },
      connections = { conn },
      default_connection = "record-test",
      query = { confirm_writes = false },
    })
  end)
end)

H.describe("record from the runner", function()
  if vim.fn.executable("sqlite3") == 0 then
    io.write("  skip (no sqlite3)\n")
    return
  end
  -- the adapter does not create a missing database
  vim.fn.system({ "sqlite3", tmp .. "/record.db", "create table t (n integer)" })
  local layout = require("dbgrid.ui.layout")
  local runner = require("dbgrid.runner")
  local cells = require("dbgrid.cells")
  local nb = notebook.create("recorded runs", { connection = "record-test" })
  local s = layout.open(nb)
  local function run_and_wait(idx)
    local done
    runner.run_cell(s, cells.parse(s.buf)[idx], {
      cb = function(r)
        done = r
      end,
    })
    H.truthy(
      H.wait(15000, function()
        return done ~= nil
      end),
      "run timed out"
    )
    H.eq(done.ok, true, vim.inspect(done.error or done))
    return done
  end

  H.it("records each run of a cell with @record and no other cell", function()
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, {
      "-- %% [r1] numbers",
      "-- @record",
      "select 1 as n, 'x' as label union all select 2, 'y'",
      "",
      "-- %% [r2] quiet",
      "select 3 as n",
    })
    vim.b[s.buf].dbgrid_cells_cache = nil
    run_and_wait(1)
    run_and_wait(1)
    run_and_wait(2)
    local all = record.list(nb)
    H.eq(#all, 1)
    H.eq(all[1].name, "numbers")
    local got = lines(all[1].path)
    H.eq(got[1], "ts,n,label")
    H.eq(#got, 5)
    H.matches(got[2], "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d,1,x$")
    H.matches(got[5], ",2,y$")
  end)

  H.it("records the ticks of a live cell", function()
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, {
      "-- %% [r3] ticking",
      "-- @every 1s",
      "-- @record",
      "select 7 as n",
    })
    vim.b[s.buf].dbgrid_cells_cache = nil
    run_and_wait(1)
    local path = record.path(nb, cells.parse(s.buf)[1])
    H.truthy(
      H.wait(8000, function()
        return #lines(path) >= 3
      end),
      "no live tick was recorded"
    )
    runner.stop_all_live(s, "cancelled")
    H.eq(lines(path)[1], "ts,n")
    H.matches(lines(path)[3], ",7$")
  end)

  require("dbgrid").close()
end)
