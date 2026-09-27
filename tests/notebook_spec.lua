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
  H.it("builds a review prompt from the query and its result", function()
    local result = {
      ok = true,
      ran_at = 0,
      elapsed_ms = 12,
      server_ms = 3,
      connection = "test",
      truncated = true,
      statements = {
        {
          sql = "select id, note from users",
          kind = "select",
          class = "read",
          limit_applied = 2,
          sets = {
            {
              columns = { "id", "note" },
              rows = { { "1", vim.NIL }, { "2", "line one\nline two" }, { "3", "x" } },
              row_count = 3,
            },
          },
          tags = {},
        },
        { sql = "update users set note = null", kind = "update", class = "write", sets = {}, tags = { "UPDATE 1" } },
      },
      notices = { "NOTICE: hi" },
      warnings = { { message = "Seq Scan on users (~5,000 rows)" } },
    }
    local text = ai.build_review_prompt({
      question = "why so slow?",
      sql = "select id, note from users;\nupdate users set note = null;",
      sql_edited = true,
      cell_label = "q1 slow",
      result = result,
      max_rows = 2,
      rows_note = "sorted by id descending",
      plan = { "Seq Scan on users" },
      plan_kind = "EXPLAIN",
      history = { { question = "earlier?", answer = "earlier answer" } },
    })
    H.matches(text, "## Question\nwhy so slow%?")
    H.matches(text, "## Query %(cell q1 slow%)\nThe cell was edited after this run")
    H.matches(text, "select id, note from users;\nupdate users set note = null;")
    H.matches(text, "took 12 ms %(server 3 ms%)")
    H.matches(text, "as displayed in the grid: sorted by id descending")
    H.matches(text, "### Statement 1 of 2 %(SELECT%)\nThe notebook added LIMIT 2 to this statement, and it was hit")
    H.matches(text, "3 rows, first 2 shown:\nid | note\n1 | NULL\n2 | line one line two\n")
    H.falsy(text:find("3 | x", 1, true), "rows beyond max_rows should be left out")
    H.matches(text, "### Statement 2 of 2 %(UPDATE%)\nUPDATE 1")
    H.matches(text, "Notices from the server:\nNOTICE: hi")
    H.matches(text, "Index check before the run warned:\n%- Seq Scan on users")
    H.matches(text, "## Plan %(EXPLAIN%)\nSeq Scan on users")
    H.matches(text, "## Earlier questions about this same result\nQ: earlier%?\nA: earlier answer")
  end)
  H.it("puts errors and the displayed rows into the review prompt", function()
    local text = ai.build_review_prompt({
      question = "q",
      sql = "select nope",
      result = {
        ok = false,
        statements = { { sql = "select nope", kind = "select", sets = {}, tags = {} } },
        error = { message = 'column "nope" does not exist', line = 1, col = 8, hint = "Perhaps you meant note" },
      },
    })
    H.matches(
      text,
      'The query failed with an error:\nERROR: column "nope" does not exist\n'
        .. "at line 1, column 8 of the cell\nHINT: Perhaps you meant note"
    )
    H.falsy(text:find("Statement 1 of", 1, true), "a single statement needs no heading")
    local text2 = ai.build_review_prompt({
      question = "q",
      sql = "select 1",
      result = {
        statements = {
          { sql = "select 1", kind = "select", sets = { { columns = { "a" }, rows = { { "1" }, { "2" } } } } },
        },
      },
      rows_of = function(entry)
        return { entry.set.rows[2] }
      end,
    })
    H.matches(text2, "2 rows, first 1 shown:\na\n2\n")
    local text3 =
      ai.build_review_prompt({ question = "q", sql = "select 1", plan = { "Result" }, plan_kind = "EXPLAIN" })
    H.matches(text3, "The cell has not been run; only its plan is available")
    H.matches(text3, "## Plan %(EXPLAIN%)\nResult")
  end)
  H.it("runs an agent and hands back its raw answer", function()
    require("dbgrid.config").get().ai.agents.echo = { cmd = { "cat" }, stdin = true }
    local answer, err
    local job = ai.run("hello\nworld", function(text, e)
      answer, err = text, e
    end, "echo")
    H.truthy(job)
    H.truthy(H.wait(5000, function()
      return answer ~= nil or err ~= nil
    end))
    H.eq(err, nil)
    H.eq(answer, "hello\nworld")
    local sql
    ai.ask("select 1;", function(text)
      sql = text
    end, "echo")
    H.truthy(H.wait(5000, function()
      return sql ~= nil
    end))
    H.eq(sql, "select 1;")
    ai.run("x", function(_, e)
      err = e
    end, "nope")
    H.matches(err, "unknown agent")
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
