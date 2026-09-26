local H = _G.H
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("dbgrid").setup({ storage = { data_dir = tmp .. "/data", mode = "data" } })
local notebook = require("dbgrid.notebook")

H.describe("notebook storage", function()
  H.it("creates, lists, tags, renames and deletes", function()
    local nb = notebook.create("Overdue Invoices", { tags = { "billing" } })
    H.matches(nb.path, "overdue%-invoices%.sql$")
    H.truthy(vim.fn.filereadable(nb.path) == 1)
    local text = require("dbgrid.util").read_file(nb.path)
    H.matches(text, "^%-%- %%%% %[%w+%]\n")
    local nb2 = notebook.create("Overdue Invoices")
    H.eq(nb2.name, "overdue-invoices-2")
    local list = notebook.list()
    H.eq(#list, 2)
    notebook.set_tags(nb, { "billing", "#users", "billing", "" })
    H.eq(notebook.load(nb.name).meta.tags, { "billing", "users" })
    local counts, names = notebook.all_tags()
    H.eq(names, { "billing", "users" })
    H.eq(counts.billing, 1)
    H.truthy(notebook.rename(nb, "Late payers"))
    H.eq(nb.name, "late-payers")
    H.truthy(notebook.load("late-payers"))
    H.eq(notebook.load("overdue-invoices"), nil)
    notebook.delete(nb2)
    H.eq(#notebook.list(), 1)
    H.truthy(notebook.from_path(nb.path))
    H.eq(notebook.from_path("/tmp/random.sql"), nil)
  end)

  H.it("caches results per cell and prunes", function()
    local nb = notebook.create("cache test")
    local cell = { id = "abcd", title = "t", lines = { "select 1" }, first = 2, last = 2 }
    notebook.set_result(nb, cell, {
      ok = true,
      ran_at = os.time(),
      elapsed_ms = 3,
      sql_hash = "x",
      statements = {
        {
          sql = "select 1",
          kind = "select",
          class = "read",
          sets = { { columns = { "a" }, rows = { { "1" } }, row_count = 1 } },
          tags = {},
        },
      },
      notices = {},
      warnings = {},
    })
    H.eq(nb.meta.cells.abcd.row_count, 1)
    H.eq(notebook.result_of(nb, "abcd").statements[1].sets[1].rows, { { "1" } })
    H.truthy(H.wait(2000, function()
      return vim.fn.filereadable(nb.cache_path) == 1
    end))
    local reloaded = notebook.load(nb.name)
    H.eq(reloaded.meta.cells.abcd.status, "ok")
    H.eq(notebook.result_of(reloaded, "abcd").statements[1].sets[1].rows, { { "1" } })
    notebook.prune(reloaded, { "other" })
    H.eq(reloaded.meta.cells.abcd, nil)
    H.eq(notebook.result_of(reloaded, "abcd"), nil)
  end)
end)

H.describe("connections", function()
  local connections = require("dbgrid.connections")
  H.it("parses dotenv files", function()
    local p = tmp .. "/.env"
    require("dbgrid.util").write_file(
      p,
      "# comment\nexport DATABASE_URL=\"postgres://u:p@h/db\"\nOTHER='x' \nPG_URL=postgres://a@b/c # trailing\n"
    )
    local vars = connections.parse_env_file(p)
    H.eq(vars.DATABASE_URL, "postgres://u:p@h/db")
    H.eq(vars.OTHER, "x")
    H.eq(vars.PG_URL, "postgres://a@b/c")
    local found = connections.discovered(tmp)
    H.eq(#found, 2)
    H.eq(found[1].name, "DATABASE_URL (.env)")
  end)
  H.it("saves and lists connections", function()
    connections.save({ name = "saved-one", url = "postgres://x@y/z", readonly = true }, "global")
    local c = connections.get("saved-one")
    H.truthy(c)
    H.eq(c.readonly, true)
    H.matches(connections.describe(c), "%[ro%]")
    H.truthy(connections.remove("saved-one"))
    H.eq(connections.get("saved-one"), nil)
  end)
end)

H.describe("ai", function()
  local ai = require("dbgrid.ai")
  H.it("cleans agent output", function()
    H.eq(ai.clean_output("Here you go:\n```sql\nselect 1;\n```\nthanks"), "select 1;")
    H.eq(ai.clean_output("  select * from users where x = 1  \n"), "select * from users where x = 1")
    local sql, err = ai.clean_output("I cannot do that.")
    H.eq(sql, nil)
    H.matches(err, "did not return SQL")
    H.eq(select(2, ai.clean_output("")), "the agent returned nothing")
  end)
  H.it("builds a prompt with the relevant schema", function()
    local data = {
      schemas = { "public" },
      enums = { { name = "plan_kind", values = { "free", "pro" } } },
      functions = {},
      tables = {
        {
          schema = "public",
          name = "users",
          rows = 100,
          columns = {
            { name = "id", type = "bigint", notnull = true },
            { name = "email", type = "text", notnull = true },
            { name = "plan_id", type = "int" },
          },
          indexes = { { name = "users_email_key", unique = true, primary = false, columns = { "email" } } },
          constraints = {
            { type = "p", columns = { "id" } },
            { type = "f", columns = { "plan_id" }, ref_table = "public.plans", ref_columns = { "id" } },
          },
        },
        {
          schema = "public",
          name = "plans",
          rows = 3,
          columns = { { name = "id", type = "int", notnull = true }, { name = "name", type = "text" } },
          indexes = {},
          constraints = { { type = "p", columns = { "id" } } },
        },
        {
          schema = "public",
          name = "unrelated",
          rows = 5,
          columns = { { name = "id", type = "int" } },
          indexes = {},
          constraints = {},
        },
      },
    }
    data.by_name = {}
    for _, t in ipairs(data.tables) do
      data.by_name[t.name] = t
      data.by_name["public." .. t.name] = t
    end
    local text =
      ai.build_prompt({ prompt = "users on the pro plan", schema = data, max_tables = 2, existing_sql = "select 1" })
    H.matches(text, "## Request\nusers on the pro plan")
    H.matches(text, "users%(id bigint PK, email text NOT NULL, plan_id int FK%->plans%.id%)")
    H.matches(text, "indexes: %(email%) unique")
    H.matches(text, "plan_kind%(free, pro%)")
    H.matches(text, "Existing SQL")
    H.falsy(text:find("unrelated", 1, true), "unrelated table should be left out")
  end)
  H.it("writes sql under the prompt lines", function()
    local cells = require("dbgrid.cells")
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(
      b,
      0,
      -1,
      false,
      { "-- %% [a1] t", "-- ? give me users", "-- @nolimit", "select old", "", "-- %% [b2]" }
    )
    local cell = cells.parse(b)[1]
    ai.write_sql(b, cell, "select new\nfrom users;")
    H.eq(
      vim.api.nvim_buf_get_lines(b, 0, -1, false),
      { "-- %% [a1] t", "-- ? give me users", "-- @nolimit", "select new", "from users;", "", "-- %% [b2]" }
    )
  end)
end)

H.describe("completion", function()
  local completion = require("dbgrid.completion")
  H.it("derives context from the line and cell", function()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "-- %% [a1]", "select u.em from users u where u." })
    local ctx = completion.context(b, 2, 11)
    H.eq(ctx.qualifier, "u")
    H.eq(ctx.word, "em")
    H.eq(ctx.start_col, 9)
    H.eq(ctx.refs, { { name = "users", alias = "u" } })
    local ctx2 = completion.context(b, 2, 22)
    H.eq(ctx2.qualifier, nil)
    H.eq(ctx2.word, "users")
    local items = completion.items(b, 2, 22)
    H.truthy(#items > 0) -- keywords still come without a schema
  end)
end)
