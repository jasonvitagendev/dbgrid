-- Tests for pinned results: a pin keeps a cell's result in its own window
-- while the results pane follows the cursor and new runs. No database: the
-- results are injected straight into the notebook cache.
local H = _G.H
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("dbgrid").setup({ storage = { data_dir = tmp .. "/data", mode = "data" } })
local notebook = require("dbgrid.notebook")
local layout = require("dbgrid.ui.layout")
local results = require("dbgrid.ui.results")
local pins = require("dbgrid.ui.pins")
local cells = require("dbgrid.cells")

local function set_cells(s, lines)
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.b[s.buf].dbgrid_cells_cache = nil
end

local function fake_result(pairs_of_rows)
  return {
    ok = true,
    ran_at = os.time(),
    elapsed_ms = 3,
    sql_hash = "x",
    statements = {
      {
        sql = "select 1",
        kind = "select",
        class = "read",
        sets = { { columns = { "a", "b" }, rows = pairs_of_rows, row_count = #pairs_of_rows } },
        tags = {},
      },
    },
    notices = {},
    warnings = {},
  }
end

local function pin_text(pin)
  return table.concat(vim.api.nvim_buf_get_lines(pin.buf, 0, -1, false), "\n")
end

H.describe("pinned results", function()
  local nb = notebook.create("pin test")
  local s = layout.open(nb)
  set_cells(s, { "-- %% [c1] one", "select 1", "", "-- %% [c2] two", "select 2" })
  local c1 = cells.by_id(s.buf, "c1")
  local c2 = cells.by_id(s.buf, "c2")
  notebook.set_result(nb, c1, fake_result({ { "1", "alpha" } }))
  notebook.set_result(nb, c2, fake_result({ { "2", "beta" } }))

  H.it("pins the shown result in its own window", function()
    results.show(s, "c1")
    pins.toggle(s)
    local pin = s.pins.c1
    H.truthy(pin)
    H.truthy(pin.win and vim.api.nvim_win_is_valid(pin.win))
    H.eq(vim.api.nvim_win_get_buf(pin.win), pin.buf)
    H.matches(pin_text(pin), "alpha")
    H.matches(pin_text(pin), "1 row")
    H.matches(pins.winbar(pin.buf), "q1")
  end)

  H.it("keeps the pin while the results pane moves to another cell", function()
    local pin = s.pins.c1
    results.show(s, "c2")
    H.eq(s.view.cell_id, "c2")
    H.truthy(vim.api.nvim_win_is_valid(pin.win))
    H.matches(pin_text(pin), "alpha")
    H.falsy(pin_text(pin):find("beta", 1, true))
  end)

  H.it("re-renders the pin when its cell's result changes", function()
    notebook.set_result(nb, c1, fake_result({ { "9", "gamma" } }))
    pins.refresh(s, "c1")
    H.matches(pin_text(s.pins.c1), "gamma")
    H.falsy(pin_text(s.pins.c1):find("alpha", 1, true))
  end)

  H.it("refuses to pin a cell without a result", function()
    pins.toggle(s, "c9")
    H.falsy(s.pins.c9)
  end)

  H.it("unpins on a second toggle", function()
    local pin = s.pins.c1
    pins.toggle(s, "c1")
    H.falsy(s.pins.c1)
    H.falsy(vim.api.nvim_win_is_valid(pin.win))
    H.falsy(vim.api.nvim_buf_is_valid(pin.buf))
  end)

  H.it("closes pins with the notebook", function()
    results.show(s, "c2")
    pins.toggle(s, "c2")
    local pin = s.pins.c2
    H.truthy(pin)
    layout.close(s)
    H.falsy(s.pins.c2)
    H.falsy(vim.api.nvim_win_is_valid(pin.win))
  end)
end)
