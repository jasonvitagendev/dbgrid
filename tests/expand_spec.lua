local H = _G.H
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("dbgrid").setup({ storage = { data_dir = tmp .. "/data", mode = "data" } })
local expand = require("dbgrid.expand")
local cells = require("dbgrid.cells")
local notebook = require("dbgrid.notebook")

local function state_with(lines)
  local nb = notebook.create("expand " .. require("dbgrid.util").short_id(3))
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return require("dbgrid.state").attach(b, nb), b
end

H.describe("expand", function()
  H.it("inlines referenced cells as subqueries and keeps their parameters", function()
    local s, b = state_with({
      "-- %% [aa11] overdue invoices",
      "-- @param days = 30",
      "select id, user_id from invoices -- comment",
      "where paid_at is null and due_on < now() - make_interval(days => :days)",
      "",
      "-- %% [bb22] count",
      "select count(*) from {{overdue-invoices}} o where o.user_id = :uid",
    })
    local list = cells.parse(b)
    local exp, err
    expand.prepare(s, list[2], { values = { uid = "7" } }, function(e, er)
      exp, err = e, er
    end)
    H.eq(err, nil)
    H.eq(
      exp.text,
      "select count(*) from (select id, user_id from invoices where paid_at is null and due_on < now() - make_interval(days => 30)) o where o.user_id = 7"
    )
    H.eq(exp.params, { uid = "7", days = "30" })
    H.eq(exp.cells, { "aa11" })
    H.eq(exp.param_source.days, "cell")
  end)

  H.it("detects cycles and rejects multi-statement or writing cells", function()
    local s, b = state_with({
      "-- %% [c1] a",
      "select * from {{b}}",
      "-- %% [c2] b",
      "select * from {{a}}",
      "-- %% [c3] two",
      "select 1; select 2",
      "-- %% [c4] uses two",
      "select * from {{two}}",
      "-- %% [c5] w",
      "delete from t",
      "-- %% [c6] uses w",
      "select * from {{w}}",
    })
    local list = cells.parse(b)
    local err
    expand.prepare(s, list[1], { silent = true }, function(_, e)
      err = e
    end)
    H.matches(err, "cycle")
    expand.prepare(s, list[4], { silent = true }, function(_, e)
      err = e
    end)
    H.matches(err, "exactly one statement")
    expand.prepare(s, list[6], { silent = true }, function(_, e)
      err = e
    end)
    H.matches(err, "DELETE")
  end)

  H.it("takes values from the notebook, then asks and remembers", function()
    local s, b = state_with({ "-- %% [v1]", "select * from t where a = :a and b = {{b}} and c = :a" })
    local list = cells.parse(b)
    notebook.set_param(s.nb, "a", "'x'")
    local err
    expand.prepare(s, list[1], { silent = true }, function(_, e)
      err = e
    end)
    H.matches(err, "missing value for :b")
    local asked = {}
    local orig = vim.ui.input
    vim.ui.input = function(opts, cb)
      asked[#asked + 1] = opts.prompt
      cb("42")
    end
    local exp
    expand.prepare(s, list[1], {}, function(e)
      exp = e
    end)
    vim.ui.input = orig
    H.eq(#asked, 1)
    H.matches(asked[1], ":b")
    H.eq(exp.text, "select * from t where a = 'x' and b = 42 and c = 'x'")
    H.eq(exp.param_source, { a = "notebook", b = "prompt" })
    H.eq(notebook.params(notebook.load(s.nb.name)).b, "42")
    local all = expand.notebook_params(s)
    H.eq(#all, 2)
    H.eq(all[1].name, "a")
    H.eq(all[1].value, "'x'")
    H.eq(all[2].value, "42")
  end)
end)
