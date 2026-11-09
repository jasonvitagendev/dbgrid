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

  H.it("keeps parameter values in the cache file, never in the shareable json", function()
    local util = require("dbgrid.util")
    local nb = notebook.create("params test")
    notebook.set_param(nb, "since", "'2026-01-01'")
    notebook.set_param(nb, "customer", "'alice@example.com'")
    -- written straight away, and only to the cache
    H.eq(util.read_json(nb.cache_path)._params, { since = "'2026-01-01'", customer = "'alice@example.com'" })
    H.eq(util.read_json(nb.meta_path).params, nil)
    H.falsy(util.read_file(nb.meta_path):find("alice", 1, true))
    local reloaded = notebook.load(nb.name)
    H.eq(notebook.params(reloaded).customer, "'alice@example.com'")
    notebook.set_param(reloaded, "customer", nil)
    H.eq(notebook.params(notebook.load(nb.name)), { since = "'2026-01-01'" })
    -- pruning cells leaves the values alone; a result for a cell still works
    notebook.prune(reloaded, {})
    H.eq(notebook.params(reloaded), { since = "'2026-01-01'" })
    H.eq(notebook.result_of(reloaded, "_params"), { since = "'2026-01-01'" })
  end)

  H.it("moves parameter values out of an old notebook's json", function()
    local util = require("dbgrid.util")
    local nb = notebook.create("old params")
    local meta = util.read_json(nb.meta_path)
    meta.params = { top = "5", secret = "'s3cr3t'" }
    util.write_json(nb.meta_path, meta)
    util.write_json(nb.cache_path, { _params = { top = "9" } })
    local old = notebook.load(nb.name)
    H.eq(old.meta.params, { top = "5", secret = "'s3cr3t'" }, "still in the meta until the cache is touched")
    H.eq(notebook.params(old), { top = "9", secret = "'s3cr3t'" }, "cache values win")
    H.eq(old.meta.params, nil)
    H.eq(util.read_json(nb.meta_path).params, nil, "the json was rewritten without them")
    H.truthy(H.wait(2000, function()
      local c = util.read_json(nb.cache_path)
      return c and c._params and c._params.secret == "'s3cr3t'"
    end))
  end)

  H.it("writes parameter values even when results are not cached on disk", function()
    local util = require("dbgrid.util")
    require("dbgrid.config").setup({ storage = { data_dir = tmp .. "/data", mode = "data", cache_rows = 0 } })
    local nb = notebook.create("no cache")
    local cell = { id = "abcd", title = "t", lines = { "select 1" }, first = 2, last = 2 }
    notebook.set_result(nb, cell, {
      ok = true,
      ran_at = os.time(),
      sql_hash = "x",
      statements = {
        { sql = "select 1", kind = "select", class = "read", sets = { { columns = { "a" }, rows = { { "1" } } } } },
      },
    })
    notebook.set_param(nb, "n", "1")
    H.eq(util.read_json(nb.cache_path), { _params = { n = "1" } })
    require("dbgrid.config").setup({ storage = { data_dir = tmp .. "/data", mode = "data" } })
  end)
end)

H.describe("project store .gitignore", function()
  local util = require("dbgrid.util")
  local project = require("dbgrid.project")
  local function lines(path)
    return vim.split(util.read_file(path) or "", "\n", { trimempty = true })
  end

  H.it("ignores result caches and the history in a new store", function()
    local root = tmp .. "/proj-new"
    vim.fn.mkdir(root, "p")
    require("dbgrid.config").setup({ storage = { data_dir = tmp .. "/data", mode = "project" } })
    local nb = notebook.create("in repo", { root = root })
    H.eq(vim.fs.dirname(nb.path), root .. "/.dbgrid")
    H.eq(lines(root .. "/.dbgrid/.gitignore"), { "*.cache.json", "history.jsonl", "recordings/" })
  end)

  H.it("adds the history line to a store that only ignored the cache", function()
    local root = tmp .. "/proj-old"
    vim.fn.mkdir(root .. "/.dbgrid", "p")
    util.write_file(root .. "/.dbgrid/.gitignore", "*.cache.json")
    util.write_file(root .. "/.dbgrid/notes.sql", "-- %% [ab12]\nselect 1\n")
    project.ensure_ignores(root)
    H.eq(lines(root .. "/.dbgrid/.gitignore"), { "*.cache.json", "history.jsonl", "recordings/" })
    -- idempotent, and a user's own lines are kept
    util.write_file(root .. "/.dbgrid/.gitignore", "scratch/\n*.cache.json\nhistory.jsonl\nrecordings/\n")
    project.ensure_ignores(root)
    H.eq(lines(root .. "/.dbgrid/.gitignore"), { "scratch/", "*.cache.json", "history.jsonl", "recordings/" })
  end)

  H.it("is written by the history logger too, and never in the data directory", function()
    local root = tmp .. "/proj-hist"
    vim.fn.mkdir(root, "p")
    local cwd = vim.fn.getcwd()
    vim.cmd.cd(root)
    require("dbgrid.history").append({
      ts = 1,
      connection = "c",
      notebook = "n",
      cell = "x",
      sql = "select 1",
      ok = true,
    })
    vim.cmd.cd(cwd)
    H.eq(lines(root .. "/.dbgrid/.gitignore"), { "*.cache.json", "history.jsonl", "recordings/" })
    H.matches(util.read_file(root .. "/.dbgrid/history.jsonl"), "select 1")

    require("dbgrid.config").setup({ storage = { data_dir = tmp .. "/data", mode = "data" } })
    local nb = notebook.create("in data dir", { root = tmp .. "/proj-data" })
    H.eq(util.exists(vim.fs.dirname(nb.path) .. "/.gitignore"), false)
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

H.describe("saved connection edit / remove", function()
  local connections = require("dbgrid.connections")
  local util = require("dbgrid.util")
  local saved_file = tmp .. "/data/connections.json"

  ---Run fn with vim.ui.input / vim.ui.select answered by the given functions.
  ---@param inputs fun(prompt: string, default?: string): string?
  ---@param selects fun(items: any[], prompt: string): integer?
  local function with_ui(inputs, selects, fn)
    local orig_input, orig_select = vim.ui.input, vim.ui.select
    vim.ui.input = function(opts, on_confirm)
      vim.schedule(function()
        on_confirm(inputs(opts.prompt, opts.default))
      end)
    end
    vim.ui.select = function(items, opts, on_choice)
      local idx = selects(items, opts.prompt)
      vim.schedule(function()
        on_choice(idx and items[idx] or nil, idx)
      end)
    end
    local ok, err = pcall(fn)
    vim.ui.input, vim.ui.select = orig_input, orig_select
    if not ok then
      error(err, 0)
    end
  end

  local function sync(fn)
    local out
    fn(function(...)
      out = { ... }
    end)
    H.truthy(
      H.wait(5000, function()
        return out ~= nil
      end),
      "callback never called"
    )
    return unpack(out, 1, 2)
  end

  local function saved_names()
    return vim.tbl_map(function(c)
      return c.name
    end, util.read_json(saved_file).connections)
  end

  H.it("finds the saved entry behind a picker connection", function()
    connections.save({ name = "edit-me", url = "postgres://u@h/d" }, "global")
    connections.save({ name = "here-only", url = "sqlite:local.db" }, "project")
    local e, scope = connections.saved_entry("edit-me")
    H.eq(e.url, "postgres://u@h/d")
    H.eq(scope, "global")
    local e2, scope2 = connections.saved_entry("here-only")
    H.eq(scope2, "project")
    H.eq(e2.project, require("dbgrid.project").root())
    H.eq(connections.saved_entry("nope"), nil)
    H.eq(connections.get("edit-me").source, "saved")
    H.eq(connections.get("here-only").source, "project")
    H.matches(connections.origin({ name = "x", source = "setup" }), "^x comes from setup%(%)")
    local from_env_file = connections.origin({ name = "DATABASE_URL (.env)", source = ".env" })
    H.matches(from_env_file, "comes from %.env: change it there")
    H.matches(connections.origin({ name = "DATABASE_URL", source = "env" }), "environment variable DATABASE_URL")
    H.matches(connections.origin({ name = "rails:test", source = "config/database.yml" }), "database%.yml")
    H.matches(connections.origin({ name = "prod/reader", parent = "prod", source = "setup" }), "^prod comes from")
  end)

  H.it("edits name, url, read-only and scope with prefilled prompts", function()
    local defaults, choices = {}, nil
    with_ui(function(prompt, default)
      defaults[#defaults + 1] = default
      return prompt:find("name") and "edited" or "postgres://u@h2/d2"
    end, function(items, prompt)
      H.eq(prompt, "Save connection")
      choices = items
      return 4 -- read-only, everywhere
    end, function()
      local conn = sync(function(cb)
        connections.edit_interactive(connections.get("edit-me"), cb)
      end)
      H.truthy(conn, "the edited connection is returned")
      H.eq(conn.name, "edited")
      H.eq(conn.url, "postgres://u@h2/d2")
      H.eq(conn.readonly, true)
      H.eq(conn.source, "saved")
    end)
    H.eq(defaults, { "edit-me", "postgres://u@h/d" })
    H.eq(choices[2], "everywhere  (current)")
    H.eq(connections.get("edit-me"), nil, "the old name is gone")
    H.eq(saved_names(), { "here-only", "edited" })
  end)

  H.it("refuses a rename onto an existing connection and a bad url", function()
    with_ui(function()
      return "here-only"
    end, function()
      return 2
    end, function()
      H.eq(
        sync(function(cb)
          connections.edit_interactive(connections.get("edited"), cb)
        end),
        nil
      )
    end)
    with_ui(function(prompt)
      return prompt:find("name") and "edited" or "nonsense"
    end, function()
      return 2
    end, function()
      H.eq(
        sync(function(cb)
          connections.edit_interactive(connections.get("edited"), cb)
        end),
        nil
      )
    end)
    H.eq(connections.get("edited").url, "postgres://u@h2/d2", "nothing changed")
    H.eq(saved_names(), { "here-only", "edited" })
  end)

  H.it("moves a connection between scopes and follows renames in open notebooks", function()
    local nb = notebook.create("Uses edited")
    notebook.set_connection(nb, "edited")
    local buf = vim.api.nvim_create_buf(false, true)
    local s = require("dbgrid.state").attach(buf, nb)
    with_ui(function(prompt, default)
      return prompt:find("name") and "renamed" or default
    end, function()
      return 1 -- this project only, writable
    end, function()
      local conn = sync(function(cb)
        connections.edit_interactive(connections.get("edited"), cb)
      end)
      H.eq(conn.name, "renamed")
      H.eq(conn.readonly, nil)
      H.eq(conn.source, "project")
    end)
    H.eq(s.nb.meta.connection, "renamed")
    H.eq(notebook.load(nb.name).meta.connection, "renamed", "the rename is written to the notebook")
    local entry, scope = connections.saved_entry("renamed")
    H.eq(scope, "project")
    H.eq(entry.url, "postgres://u@h2/d2")
    require("dbgrid.state").detach(buf)
  end)

  H.it("cannot edit connections that come from elsewhere", function()
    require("dbgrid.config").setup({
      storage = { data_dir = tmp .. "/data", mode = "data" },
      connections = { { name = "fixed", url = "postgres://x@y/z" } },
    })
    local called = false
    with_ui(function()
      called = true
      return "x"
    end, function()
      called = true
      return 1
    end, function()
      H.eq(
        sync(function(cb)
          connections.edit_interactive(connections.get("fixed"), cb)
        end),
        nil
      )
      H.eq(
        sync(function(cb)
          connections.remove_interactive(connections.get("fixed"), cb)
        end),
        false
      )
    end)
    H.falsy(called, "no prompt for a setup() connection")
    require("dbgrid.config").setup({ storage = { data_dir = tmp .. "/data", mode = "data" } })
  end)

  H.it("removes after confirmation and leaves other projects alone", function()
    local data = util.read_json(saved_file)
    data.connections[#data.connections + 1] =
      { name = "here-only", url = "sqlite:elsewhere.db", project = "/elsewhere" }
    util.write_json(saved_file, data)
    local orig_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 2
    end
    local removed = sync(function(cb)
      connections.remove_interactive(connections.get("here-only"), cb)
    end)
    H.eq(removed, false, "cancelled")
    H.truthy(connections.get("here-only"))
    vim.fn.confirm = function()
      return 1
    end
    removed = sync(function(cb)
      connections.remove_interactive(connections.get("here-only"), cb)
    end)
    vim.fn.confirm = orig_confirm
    H.eq(removed, true)
    H.eq(connections.get("here-only"), nil)
    H.eq(saved_names(), { "renamed", "here-only" }, "the entry of the other project survives")
    H.eq(util.read_json(saved_file).connections[2].project, "/elsewhere")
    H.truthy(connections.remove("renamed"))
    H.falsy(connections.remove("renamed"))
    H.eq(saved_names(), { "here-only" })
  end)

  H.it("opens the json file and forgets resolved connections when it is written", function()
    connections.save({ name = "plain", url = "postgres://u@h/d" }, "global")
    local first
    connections.resolve(connections.get("plain"), function(c)
      first = c
    end)
    H.truthy(first and first._resolved)
    local again
    connections.resolve(connections.get("plain"), function(c)
      again = c
    end)
    H.eq(again, first, "cached")
    connections.open_file()
    -- resolve both: on macOS the temp dir sits behind the /var -> /private/var symlink
    H.eq(vim.fn.resolve(vim.api.nvim_buf_get_name(0)), vim.fn.resolve(saved_file))
    vim.cmd("silent write")
    local fresh
    connections.resolve(connections.get("plain"), function(c)
      fresh = c
    end)
    H.truthy(fresh._resolved)
    H.falsy(fresh == first, "the resolved form was dropped by the write")
    H.eq(saved_names(), { "here-only", "plain" }, "writing the buffer keeps the file intact")
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
    local job = ai.run_agent("hello\nworld", function(text, e)
      answer, err = text, e
    end, { agent = "echo" })
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
    ai.run_agent("x", function(_, e)
      err = e
    end, { agent = "nope" })
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

  H.it("completes enum values in comparison strings", function()
    require("dbgrid.config").setup({
      connections = { { name = "enumtest", url = "postgres://localhost:5499/enumtest" } },
    })
    local conn = require("dbgrid.connections").get("enumtest")
    H.truthy(conn)
    local schema = require("dbgrid.schema")
    local dir = require("dbgrid.project").data_dir() .. "/schema"
    vim.fn.mkdir(dir, "p")
    require("dbgrid.util").write_json(dir .. "/" .. schema.key(conn) .. ".json", {
      schemas = { "public" },
      tables = {
        {
          schema = "public",
          name = "orders",
          kind = "r",
          rows = 10,
          columns = {
            { name = "id", type = "integer" },
            { name = "status", type = "order_status" },
            { name = "note", type = "text" },
          },
        },
        {
          schema = "public",
          name = "tickets",
          kind = "r",
          rows = 5,
          columns = {
            { name = "id", type = "integer" },
            { name = "status", type = "ticket_status" },
          },
        },
      },
      enums = {
        { name = "order_status", values = { "pending", "paid", "shipped" } },
        { name = "ticket_status", values = { "open", "closed" } },
      },
    })
    H.truthy(schema.loaded(conn))
    local state = require("dbgrid.state")
    local b = vim.api.nvim_create_buf(false, true)
    state.attach(b, { name = "enum-nb", meta = { connection = "enumtest", cells = {}, params = {} } })
    local function items(sql)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "-- %% [e1]", sql })
      vim.b[b].dbgrid_cells_cache = nil
      return completion.items(b, 2, #sql)
    end
    local function value_map(list)
      local m = {}
      for _, it in ipairs(list) do
        if it.kind_name == "value" then
          m[it.label] = it.detail
        end
      end
      return m
    end
    local order_values = { pending = "order_status", paid = "order_status", shipped = "order_status" }
    -- unqualified column, partially typed value: only the enum's values
    local list = items("select * from orders where status = 'p")
    H.eq(value_map(list), order_values)
    H.eq(#list, 3)
    -- alias-qualified column, IN list, UPDATE target
    H.eq(value_map(items("select * from orders o where o.status = '")), order_values)
    H.eq(value_map(items("select * from orders where status in ('paid', '")), order_values)
    H.eq(value_map(items("update orders set status = '")), order_values)
    -- unambiguous column name used by two referenced tables: union of both enums
    H.eq(value_map(items("select * from orders join tickets on tickets.id = orders.id where status = '")), {
      pending = "order_status",
      paid = "order_status",
      shipped = "order_status",
      open = "ticket_status",
      closed = "ticket_status",
    })
    -- an escaped quote does not close the string
    H.eq(value_map(items("select * from orders where status = 'it''s")), order_values)
    -- a text column keeps the ordinary items, and a closed string offers no values
    list = items("select * from orders where note = 'n")
    H.eq(next(value_map(list)), nil)
    H.truthy(#list > 0)
    H.eq(next(value_map(items("select * from orders where status = 'paid'"))), nil)
    state.detach(b)
  end)
end)

H.describe("notebook delete", function()
  H.it("deletes several notebooks after one confirmation", function()
    require("dbgrid.config").setup({ storage = { data_dir = tmp .. "/data", mode = "data" } })
    local before = #notebook.list()
    local a = notebook.create("Bulk A")
    local b = notebook.create("Bulk B")
    local c = notebook.create("Bulk C")
    local prompts = {}
    local orig_confirm = vim.fn.confirm
    vim.fn.confirm = function(msg)
      prompts[#prompts + 1] = msg
      return 2
    end
    require("dbgrid").delete({ a, b })
    H.eq(#notebook.list(), before + 3, "cancelled: nothing deleted")
    vim.fn.confirm = function(msg)
      prompts[#prompts + 1] = msg
      return 1
    end
    require("dbgrid").delete({ a, b })
    require("dbgrid").delete(c)
    vim.fn.confirm = orig_confirm
    H.eq(#prompts, 3, "one prompt per call")
    H.matches(prompts[1], "^Delete 2 notebooks")
    H.matches(prompts[1], "\n  Bulk A\n  Bulk B$")
    H.matches(prompts[3], "^Delete notebook 'Bulk C'")
    H.eq(#notebook.list(), before)
    H.eq(notebook.load("bulk-a"), nil)
    H.eq(notebook.load("bulk-c"), nil)
  end)
end)
