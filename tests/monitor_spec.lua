-- Tests for what a monitored run is built from: `-- @rate`, `-- @alert`,
-- marks, the recordings report, `-- @metrics` cells and `live all`. The unit
-- tests inject results; the runner tests go through sqlite and the fake aws
-- CLI, so nothing here needs a database server.
local H = _G.H
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local fake = root .. "/tests/fixtures/fake-aws"
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local conn = { name = "monitor-test", url = "sqlite:" .. tmp .. "/monitor.db" }
local prod = {
  name = "monitor-prod",
  url = "aws://prod/app-prod",
  aws = { profile = "prod", region = "ap-southeast-1", cluster = "app-prod" },
}
local function setup()
  require("dbgrid").setup({
    storage = { data_dir = tmp .. "/data", mode = "data" },
    connections = { conn, prod },
    default_connection = "monitor-test",
    query = { confirm_writes = false },
    index_check = { mode = "off" },
    live = { max_cells = 1 },
    aws = { cli = fake },
  })
end
setup()
local notebook = require("dbgrid.notebook")
local record = require("dbgrid.record")
local rate = require("dbgrid.rate")
local alert = require("dbgrid.alert")
local report = require("dbgrid.report")
local util = require("dbgrid.util")

local function result(columns, rows, ran_at)
  return {
    ok = true,
    ran_at = ran_at,
    statements = { { sets = { { columns = columns, rows = rows, row_count = #rows } } } },
  }
end

local function set_of(res)
  return res.statements[1].sets[1]
end

local function lines(path)
  return vim.split(util.read_file(path) or "", "\n", { trimempty = true })
end

local T0 = os.time({ year = 2026, month = 11, day = 10, hour = 9, min = 0, sec = 0 })

H.describe("rate", function()
  H.it("adds a per-second column next to each named counter", function()
    local state = {}
    local cell = { id = "ra01", title = "throughput", lines = { "-- @rate commits, wal", "select 1" } }
    local first = result({ "commits", "blks", "wal" }, { { "100", "7", "1000" } })
    rate.apply(state, cell, first, 10)
    H.eq(set_of(first).columns, { "commits", "commits_per_s", "blks", "wal", "wal_per_s" })
    H.eq(set_of(first).rows, { { "100", vim.NIL, "7", "1000", vim.NIL } })
    local second = result({ "commits", "blks", "wal" }, { { "150", "9", "1001" } })
    rate.apply(state, cell, second, 15)
    H.eq(set_of(second).rows, { { "150", "10", "9", "1001", "0.20" } })
    -- a counter that went down was reset: no rate for that run
    local third = result({ "commits", "blks", "wal" }, { { "3", "9", "2001" } })
    rate.apply(state, cell, third, 20)
    H.eq(set_of(third).rows, { { "3", vim.NIL, "9", "2001", "200" } })
  end)

  H.it("takes every numeric column without names and matches rows by their label", function()
    local state = {}
    local cell = { id = "ra02", title = "per slot", lines = { "-- @rate", "select 1" } }
    rate.apply(state, cell, result({ "slot", "bytes" }, { { "a", "10" }, { "b", "100" } }), 0)
    local second = result({ "slot", "bytes" }, { { "b", "300" }, { "c", "5" }, { "a", "20" } })
    rate.apply(state, cell, second, 10)
    H.eq(set_of(second).columns, { "slot", "bytes", "bytes_per_s" })
    H.eq(set_of(second).rows, { { "b", "300", "20" }, { "c", "5", vim.NIL }, { "a", "20", "1" } })
  end)

  H.it("leaves a cell without the directive and a failed run alone", function()
    local res = result({ "n" }, { { "1" } })
    rate.apply({}, { id = "ra03", title = "x", lines = { "select 1" } }, res, 0)
    H.eq(set_of(res).columns, { "n" })
    rate.apply({}, { id = "ra04", title = "x", lines = { "-- @rate" } }, { ok = false, statements = {} }, 0)
  end)
end)

H.describe("alert", function()
  H.it("parses conditions and says which parts are none", function()
    local conds, bad = alert.parse("lag_bytes > 1000, wal_status = 'lost', active != t, nonsense, n<=5")
    H.eq(#conds, 4)
    H.eq(conds[1], { column = "lag_bytes", op = ">", value = "1000", text = "lag_bytes > 1000" })
    H.eq(conds[2].value, "lost")
    H.eq(conds[3].op, "!=")
    H.eq(conds[4], { column = "n", op = "<=", value = "5", text = "n<=5" })
    H.eq(bad, { "nonsense" })
  end)

  H.it("compares numbers as numbers and never matches NULL", function()
    local gt = alert.parse("n > 9")[1]
    H.eq(alert.test(gt, "10"), true)
    H.eq(alert.test(gt, "9"), false)
    H.eq(alert.test(gt, vim.NIL), false)
    H.eq(alert.test(gt, "many"), false)
    H.eq(alert.test(alert.parse("n = 1")[1], "1.0"), true)
    H.eq(alert.test(alert.parse("s = lost")[1], "lost"), true)
    H.eq(alert.test(alert.parse("s != lost")[1], "reserved"), true)
  end)

  H.it("raises once, stays quiet while it lasts, clears, and marks a recorded cell", function()
    local nb = notebook.create("alerting", {})
    local state = { nb = nb }
    local cell = {
      id = "al01",
      title = "slot lag",
      lines = { "-- @record", "-- @alert lag > 100, status = lost", "select 1" },
    }
    H.eq(alert.check(state, cell, result({ "slot", "lag", "status" }, { { "a", "5", "ok" } }, T0)), false)
    H.eq(#record.marks(nb), 0)
    local res = result({ "slot", "lag", "status" }, { { "a", "5", "ok" }, { "b", "500", "lost" } }, T0 + 5)
    H.eq(alert.check(state, cell, res), true)
    H.eq(state.alerts.al01.text, "lag = 500 (lag > 100) on b +1 more")
    H.eq(alert.check(state, cell, res), true)
    H.eq(#record.marks(nb), 1)
    H.eq(alert.check(state, cell, result({ "slot", "lag", "status" }, { { "a", "5", "ok" } }, T0 + 10)), false)
    local marks = record.marks(nb)
    H.eq(#marks, 2)
    H.eq(
      marks[1],
      { ts = "2026-11-10T09:00:05", kind = "alert", text = "slot lag: lag = 500 (lag > 100) on b +1 more" }
    )
    H.eq(marks[2].text, "slot lag: cleared")
    -- no directive: nothing is tracked
    H.eq(alert.check(state, { id = "al02", title = "x", lines = { "select 1" } }, res), nil)
  end)
end)

H.describe("marks and csv", function()
  H.it("keeps marks next to the recordings, apart from them", function()
    local nb = notebook.create("marked", {})
    record.mark(nb, 'copy "done", all tables', nil, T0 + 60)
    record.mark(nb, "subscription created", nil, T0)
    H.eq(record.marks(nb), {
      { ts = "2026-11-10T09:00:00", kind = "mark", text = "subscription created" },
      { ts = "2026-11-10T09:01:00", kind = "mark", text = 'copy "done", all tables' },
    })
    H.eq(record.list(nb), {})
  end)

  H.it("reads quoted fields with commas, quotes and line breaks", function()
    H.eq(record.parse_csv('a,b\n1,"x, ""y""\nz"\n2,\n3'), { { "a", "b" }, { "1", 'x, "y"\nz' }, { "2", "" }, { "3" } })
  end)
end)

H.describe("report", function()
  H.it("formats numbers and draws sparklines", function()
    H.eq(report.fmt(1234567), "1,234,567")
    H.eq(report.fmt(-12345.5), "-12,345.5")
    H.eq(report.fmt(1234), "1234")
    H.eq(report.fmt(0.5), "0.50")
    H.eq(report.spark({ 1, 2, 3, 8 }), "▁▂▃█")
    H.eq(report.spark({ 5, 5 }), "▁▁")
    H.eq(vim.fn.strchars(report.spark(vim.fn.range(1, 1000), 40)), 40)
  end)

  H.it("summarises single-row and several-row recordings, by phase when there are marks", function()
    local nb = notebook.create("migration run", {})
    H.eq(report.markdown(nb), nil)
    local load = { id = "rp01", title = "load on source", lines = { "-- @record" } }
    local slots = { id = "rp02", title = "slots", lines = { "-- @record" } }
    for i = 0, 5 do
      record.append(nb, load, result({ "sessions", "note" }, { { tostring(10 + i * 2), "ok" } }, T0 + i * 5))
      record.append(
        nb,
        slots,
        result({ "slot_name", "lag_bytes" }, { { "main", tostring(i * 100) }, { "sync_1", "7" } }, T0 + i * 5)
      )
    end
    record.append(nb, load, result({ "sessions", "note" }, {}, T0 + 30))
    record.mark(nb, "subscription created", nil, T0 + 15)
    record.mark(nb, "load on source: sessions = 20 (sessions > 15)", "alert", T0 + 25)
    local text = report.markdown(nb)
    H.matches(text, "^# Recordings · migration run\n")
    H.matches(text, "2026%-11%-10 09:00:00 → 09:00:30 %(30s%) · 2 recordings · 1 mark · 1 alert event")
    H.matches(text, "| 09:00:15 | mark | subscription created |")
    H.matches(text, "| 09:00:25 | alert | load on source: sessions = 20")
    H.matches(text, "## load%-on%-source\n\n7 runs · 09:00:00 → 09:00:30 · every ~5s")
    H.matches(text, "| sessions | 10 | 15 | 20 | 20 | ▁▂▄▅▇█ |")
    H.matches(text, "States: `note` ok ×6")
    H.matches(text, "| column | start | subscription created |")
    H.matches(text, "| sessions | 12 %(14%) | 18 %(20%) |")
    H.matches(text, "### slot_name = main %(6 rows%)")
    H.matches(text, "| lag_bytes | 0 | 250 | 500 | 500 |")
    H.matches(text, "### slot_name = sync_1 %(6 rows%)")
  end)
end)

if vim.fn.executable("sqlite3") == 0 then
  io.write("  skip the runner tests (no sqlite3)\n")
  return
end
-- the adapter does not create a missing database
vim.fn.system({ "sqlite3", tmp .. "/monitor.db", "create table t (n integer)" })

H.describe("monitoring through the runner", function()
  local layout = require("dbgrid.ui.layout")
  local runner = require("dbgrid.runner")
  local cells = require("dbgrid.cells")
  local nb = notebook.create("monitored", { connection = "monitor-test" })
  local s = layout.open(nb)
  local function set_cells(text)
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, text)
    vim.b[s.buf].dbgrid_cells_cache = nil
  end
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
    return done
  end

  H.it("puts the rate columns into the result and the recording", function()
    set_cells({ "-- %% [m1] counter", "-- @record", "-- @rate n", "select 40 as n, 'x' as label" })
    local first = run_and_wait(1)
    H.eq(first.ok, true, vim.inspect(first.error))
    H.eq(set_of(first).columns, { "n", "n_per_s", "label" })
    H.eq(set_of(first).rows[1][2], vim.NIL)
    local second = run_and_wait(1)
    H.eq(set_of(second).rows[1], { "40", "0", "x" })
    local got = lines(record.path(nb, cells.parse(s.buf)[1]))
    H.eq(got[1], "ts,n,n_per_s,label")
    H.matches(got[2], ",40,,x$")
    H.matches(got[3], ",40,0,x$")
  end)

  H.it("raises an alert from a run and shows it on the cell", function()
    set_cells({ "-- %% [m2] too many", "-- @alert n > 3", "select 5 as n" })
    H.eq(run_and_wait(1).ok, true)
    H.eq(s.alerts.m2.firing, true)
    H.eq(s.alerts.m2.text, "n = 5 (n > 3)")
    local chunks = require("dbgrid.ui.query").status_chunks(s, cells.parse(s.buf)[1])
    local text = table.concat(vim.tbl_map(function(c)
      return c[1]
    end, chunks))
    H.matches(text, "alert: n = 5 %(n > 3%)")
    set_cells({ "-- %% [m2] too many", "-- @alert n > 30", "select 5 as n" })
    H.eq(run_and_wait(1).ok, true)
    H.eq(s.alerts.m2.firing, false)
  end)

  H.it("runs a @metrics cell against CloudWatch instead of the database", function()
    set_cells({
      "-- %% [m3] cloudwatch",
      "-- @conn monitor-prod",
      "-- @record",
      "-- @alert CPUUtilization > 10",
      "-- @metrics CPUUtilization, FreeableMemory, ReadLatency, NoSuchMetric",
      "-- no sql in this cell",
    })
    local res = run_and_wait(1)
    H.eq(res.ok, true, vim.inspect(res.error))
    H.matches(res.connection, "^monitor%-prod")
    H.eq(
      set_of(res).columns,
      { "datapoint_utc", "CPUUtilization", "FreeableMemory_MiB", "ReadLatency_ms", "NoSuchMetric" }
    )
    H.eq(set_of(res).rows, { { "2026-09-27 00:04:00", "12.50", "8192", vim.NIL, vim.NIL } })
    H.eq(s.alerts.m3.firing, true)
    local got = lines(record.path(nb, cells.parse(s.buf)[1]))
    H.eq(got[1], "ts,datapoint_utc,CPUUtilization,FreeableMemory_MiB,ReadLatency_ms,NoSuchMetric")
    H.matches(got[2], ",2026%-09%-27 00:04:00,12%.50,8192,,$")
    -- a connection without an aws block is an error of the cell, not a crash
    set_cells({ "-- %% [m4] cloudwatch", "-- @metrics" })
    local bad = run_and_wait(1)
    H.eq(bad.ok, false)
    H.matches(bad.error.message, "has no aws block")
  end)

  H.it("starts every @every cell past live.max_cells and pins the recorded ones", function()
    set_cells({
      "-- %% [l1] one",
      "-- @every 1s",
      "-- @record",
      "select 1 as n",
      "",
      "-- %% [l2] two",
      "-- @every 1s",
      "select 2 as n",
      "",
      "-- %% [l3] three",
      "-- @every 1s",
      "select 3 as n",
      "",
      "-- %% [l4] not live",
      "select 4 as n",
    })
    local started, failed
    H.eq(
      runner.live_all(s, {
        pin = true,
        cb = function(a, b)
          started, failed = a, b
        end,
      }),
      3
    )
    H.truthy(
      H.wait(15000, function()
        return started ~= nil
      end),
      "live all never finished"
    )
    H.eq({ started, failed }, { 3, 0 })
    H.truthy(s.live.l1 and s.live.l2 and s.live.l3)
    H.eq(s.live.l4, nil)
    H.truthy(s.pins and s.pins.l1)
    H.eq(s.pins.l2, nil)
    -- nothing left to start
    H.eq(runner.live_all(s), 0)
    runner.stop_all_live(s, "cancelled")
    H.eq(next(s.live), nil)
  end)

  H.it("writes the report and the marks from the commands", function()
    local commands = require("dbgrid.commands")
    commands.subcommands.mark({ "copy", "finished" })
    local marks = record.marks(nb)
    H.eq(marks[#marks].text, "copy finished")
    local out = tmp .. "/report.md"
    commands.subcommands.recordings({ "report", out })
    local text = util.read_file(out)
    H.matches(text, "^# Recordings · monitored\n")
    H.matches(text, "## counter")
    H.matches(text, "| mark | copy finished |")
    vim.cmd("bwipeout")
  end)

  require("dbgrid").close()
end)
