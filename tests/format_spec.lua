local H = _G.H
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("dbgrid").setup({ storage = { data_dir = tmp .. "/data", mode = "data" }, format = { formatter = "builtin" } })
local format = require("dbgrid.format")
local cells = require("dbgrid.cells")
local config = require("dbgrid.config")

H.describe("format.builtin", function()
  H.it("lays out clauses, joins and conditions", function()
    local out = format.builtin(
      "SELECT u.id, p.name AS plan FROM users u JOIN plans p ON p.id = u.plan_id WHERE u.balance > :min AND (u.x = 1 OR u.y = 2) ORDER BY u.id LIMIT 10",
      { keyword_case = "lower" }
    )
    H.eq(
      out,
      table.concat({
        "select u.id, p.name as plan",
        "from users u",
        "join plans p on p.id = u.plan_id",
        "where u.balance > :min",
        "  and (u.x = 1 or u.y = 2)",
        "order by u.id",
        "limit 10",
      }, "\n")
    )
  end)
  H.it("indents subqueries and CTEs, keeps function calls and comments", function()
    local out = format.builtin(
      "with o as (select id from invoices where paid_at is null) select count(*), coalesce(a, b) from {{overdue-invoices}} x where id in (select id from o) -- trailing\n-- own\nand y = 1e-5"
    )
    H.eq(
      out,
      table.concat({
        "with o as (",
        "  select id",
        "  from invoices",
        "  where paid_at is null",
        ")",
        "select count(*), coalesce(a, b)",
        "from {{overdue-invoices}} x",
        "where id in (",
        "  select id",
        "  from o",
        ")  -- trailing",
        "-- own",
        "  and y = 1e-5",
      }, "\n")
    )
  end)
  H.it("upper-cases keywords on request and never changes meaning", function()
    local out = format.builtin("select id from users where email = 'X'", { keyword_case = "upper" })
    H.eq(out, "SELECT id\nFROM users\nWHERE email = 'X'")
    local sql = require("dbgrid.sql")
    for _, text in ipairs({
      "insert into users (email, plan_id) values ('a@b', 1), ('c@d', 2) on conflict (email) do nothing returning id",
      "update users set note = 'x', balance = balance - 1 where id = 1",
      "select case when a > 1 then 'big' else 'small' end as size, arr[1], -x from t",
      "select distinct on (user_id) user_id, amount from invoices order by user_id, amount desc",
      "select exists (select 1 from t where x in (1, 2)) as e, count(*) filter (where a) from t",
      "select * from t where a between 1 and 2 and b = 3",
    }) do
      H.eq(sql.normalize(format.builtin(text)), sql.normalize(text), text)
    end
  end)
end)

H.describe("format.format_sql", function()
  H.it("formats several statements and keeps comments with their statement", function()
    local out = format.format_sql("select 1;\n\n-- second\nselect 2 from t where x=1;")
    H.eq(out, "select 1;\n\n-- second\nselect 2\nfrom t\nwhere x = 1;")
  end)
  H.it("refuses output that changes the SQL", function()
    config.get().format.formatter = { cmd = { "sh", "-c", "echo 'select 2'" } }
    local out, err = format.format_sql("select 1")
    H.eq(out, nil)
    H.matches(err, "changed the meaning")
    config.get().format.formatter = { cmd = { "sh", "-c", "cat" } }
    H.eq(format.format_sql("select 1"), "select 1")
    config.get().format.formatter = "builtin"
  end)
end)

H.describe("format.cell", function()
  local nb = require("dbgrid.notebook").create("format test")
  local s = require("dbgrid.ui.layout").open(nb)
  local function set(lines)
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
    vim.b[s.buf].dbgrid_cells_cache = nil
  end
  H.it("keeps headers, prompts and directives and formats the SQL below", function()
    set({
      "-- %% [f1] first",
      "-- ? users please",
      "-- @nolimit",
      "select  id,email from users where x=1",
      "",
      "-- %% [f2] second",
      "select 2",
    })
    local cell = cells.parse(s.buf)[1]
    local before = cells.hash(cell)
    H.eq(format.cell(s, cell), true)
    H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 5, false), {
      "-- %% [f1] first",
      "-- ? users please",
      "-- @nolimit",
      "select id, email",
      "from users",
    })
    local after = cells.parse(s.buf)[1]
    H.eq(cells.hash(after), before, "formatting must not change the hash")
    H.eq(format.cell(s, after), false)
    H.eq(format.buffer(s), 0)
  end)
  H.it("formats on save when asked", function()
    set({ "-- %% [f3]", "select  a,b from   t where a=1", "", "-- %% [f4]", "select   9" })
    config.get().format.on_save = true
    vim.api.nvim_buf_call(s.buf, function()
      vim.cmd("silent write!")
    end)
    config.get().format.on_save = false
    H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), {
      "-- %% [f3]",
      "select a, b",
      "from t",
      "where a = 1",
      "",
      "-- %% [f4]",
      "select 9",
    })
    require("dbgrid.ui.layout").close(s)
  end)
end)
