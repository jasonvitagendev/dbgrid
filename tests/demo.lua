-- Opens a demo notebook against $DBGRID_TEST_URL and runs its first cell.
-- Try it:  DBGRID_TEST_URL=postgres://... nvim -u tests/minimal_init.lua -c 'luafile tests/demo.lua'
local url = os.getenv("DBGRID_TEST_URL")
assert(url, "set DBGRID_TEST_URL")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("dbgrid").setup({
  storage = { data_dir = tmp .. "/data", mode = "data" },
  connections = { { name = "local-dev", url = url } },
  default_connection = "local-dev",
  index_check = { mode = "warn", min_rows = 1000 },
})
local nb =
  require("dbgrid.notebook").create("Overdue invoices", { tags = { "billing", "users" }, connection = "local-dev" })
require("dbgrid.util").write_file(
  nb.path,
  table.concat({
    "-- %% [a1b2] first users",
    "select id, email, plan_id, balance, created_at",
    "from users",
    "where id <= 6",
    "order by id",
    "",
    "-- %% [c3d4] big scan",
    "-- ? users whose balance is above 5, newest first",
    "select * from users where balance > 5 order by created_at desc",
    "",
    "-- %% [e5f6] still to write",
    "-- ? count of users per plan, with the plan name",
    "",
  }, "\n")
)
local s = require("dbgrid.ui.layout").open(nb)
vim.api.nvim_win_set_cursor(s.query_win, { 2, 0 })
require("dbgrid.runner").run_cell(s, require("dbgrid.cells").parse(s.buf)[1])
