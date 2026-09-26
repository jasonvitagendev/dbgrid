local H = _G.H
local cells = require("dbgrid.cells")

local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

H.describe("cells.parse", function()
  H.it("parses markers, ids and titles", function()
    local b = buf_with({
      "-- %% [ab12] first query",
      "select 1;",
      "",
      "-- %%",
      "-- ? users who never logged in",
      "-- @nolimit",
      "select * from users",
    })
    local c = cells.parse(b)
    H.eq(#c, 2)
    H.eq(c[1].id, "ab12")
    H.eq(c[1].title, "first query")
    H.eq(c[1].header, 1)
    H.eq(c[1].first, 2)
    H.eq(c[1].last, 3)
    H.eq(c[2].id, nil)
    H.eq(c[2].header, 4)
    H.eq(c[2].last, 7)
    H.eq(cells.prompt(c[2]), "users who never logged in")
    H.eq(cells.directives(c[2]), { nolimit = true })
    H.eq(cells.has_sql(c[2]), true)
    H.eq(cells.has_sql(c[1]), true)
  end)

  H.it("treats text before the first marker as an implicit cell", function()
    local b = buf_with({ "select 1", "-- %% [x1] next", "select 2" })
    local c = cells.parse(b)
    H.eq(#c, 2)
    H.eq(c[1].header, nil)
    H.eq(c[1].first, 1)
    H.eq(cells.ensure_ids(b), true)
    local after = cells.parse(b)
    H.eq(#after, 2)
    H.truthy(after[1].id)
    H.eq(after[1].header, 1)
    H.eq(vim.api.nvim_buf_get_lines(b, 1, 2, false)[1], "select 1")
  end)

  H.it("assigns ids and dedupes pasted cells", function()
    local b = buf_with({ "-- %% [dup1] a", "select 1", "-- %% [dup1] b", "select 2", "-- %% c", "select 3" })
    H.eq(cells.ensure_ids(b), true)
    local c = cells.parse(b)
    H.eq(c[1].id, "dup1")
    H.truthy(c[2].id ~= "dup1")
    H.eq(c[2].title, "b")
    H.truthy(c[3].id)
    H.eq(c[3].title, "c")
  end)

  H.it("locates cells by line and inserts new ones", function()
    local b = buf_with({ "-- %% [a1] a", "select 1", "", "-- %% [b2] b", "select 2" })
    local c, i = cells.cell_at(b, 3)
    H.eq(i, 1)
    H.eq(c.id, "a1")
    local _, lnum = cells.insert(b, "below", c)
    H.eq(lnum, 5)
    H.eq(#cells.parse(b), 3)
    local _, l2 = cells.insert(b, "end")
    local n = vim.api.nvim_buf_line_count(b)
    H.eq(l2, n - 1)
    local last = cells.parse(b)[4]
    H.eq(last.header, n - 1)
    cells.delete(b, last)
    H.eq(#cells.parse(b), 3)
  end)

  H.it("labels cells sensibly", function()
    local b = buf_with({
      "-- %% [a1]",
      "-- a comment",
      "select id, name from users where x = 1",
      "-- %% [b2] Titled",
      "",
      "-- %% [c3]",
      "-- ? give me things",
    })
    local c = cells.parse(b)
    H.eq(cells.label(c[1]), "select id, name from users where x = 1")
    H.eq(cells.label(c[2]), "Titled")
    H.eq(cells.label(c[3]), "? give me things")
  end)
end)

H.describe("util", function()
  local util = require("dbgrid.util")
  H.it("hashes to 8 hex chars, stably", function()
    for _, input in ipairs({ "", "a", "/home/user/dbgrid", string.rep("x", 1000) }) do
      local h = util.hash(input)
      H.matches(h, "^%x%x%x%x%x%x%x%x$")
      H.eq(util.hash(input), h)
    end
    H.truthy(util.hash("a") ~= util.hash("b"))
  end)
  H.it("slugs, truncates and pretty prints", function()
    H.eq(util.slug("  Overdue Invoices (Q3)! "), "overdue-invoices-q3")
    H.eq(util.slug("###"), "untitled")
    H.eq(util.truncate("héllo wörld", 6), "héllo…")
    local pretty, ok = util.pretty_json('{"b":[1,2],"a":null}')
    H.eq(ok, true)
    H.eq(pretty, '{\n  "a": null,\n  "b": [\n    1,\n    2\n  ]\n}')
    H.eq(util.redact_url("postgres://u:secret@h:5432/db"), "postgres://u:***@h:5432/db")
    H.eq(util.expand_env("x=${HOME}/y", {}), "x=" .. os.getenv("HOME") .. "/y")
  end)
end)
