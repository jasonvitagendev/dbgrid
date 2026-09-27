# dbgrid.nvim

SQL notebooks for Neovim. Queries live in cells on one side, results on the
other, and the notebook is saved per project with tags so you can find it
again. Built for PostgreSQL first, with an adapter interface for other
databases.

```
 ▸ q1 first users │ ✓ 6 rows · 43 ms │ grid          │ ⛁ local-dev │ #billing #users │ Overdue invoices  3 cells
 id │ email             │ plan_id │ balance │ created_at   │▎ ▸ first users  ✓ 6 rows · 43 ms · just now
────┼───────────────────┼─────────┼─────────┼──────────────│▎ select id, email, plan_id, balance, created_at
  1 │ user1@example.com │       2 │    1.50 │ 2026-09-26 … │▎ from users
  2 │ user2@example.com │       3 │    3.00 │ 2026-09-26 … │▎ where id <= 6
  3 │ user3@example.com │       1 │    4.50 │ 2026-09-26 … │▎ order by id
  4 │ user4@example.com │       2 │    6.00 │ 2026-09-26 … │▎
  5 │ user5@example.com │       3 │    7.50 │ 2026-09-26 … │  ─────────────────────────────────────────────────
  6 │ user6@example.com │       1 │    9.00 │ 2026-09-26 … │  ▸ big scan  ⚠ seq scan ✓ 500 rows · 50 ms · 2m ago
                                                           │  -- ? users whose balance is above 5, newest first
 6 rows · 43 ms (server 1 ms) · LIMIT 500 added · 06:54:25 │  select * from users where balance > 5
                                                           │
                                                           │  ─────────────────────────────────────────────────
                                                           │  ▸ still to write  ? prompt — run to generate SQL
                                                           │  -- ? count of users per plan, with the plan name
```

The right pane is a plain `.sql` file. Every `-- %%` line starts a cell. The
left pane shows the last result of the cell the cursor is in, straight from
the cache, so moving between cells never re-runs anything.

## What it does

- **Cells, not files.** `]c` / `[c` jump between queries. `<CR>` runs the one
  under the cursor. Each cell remembers its last result, timing, row count and
  whether it was edited since.
- **Results grid** with aligned columns, right-aligned numbers, dimmed NULLs,
  a record view for wide rows, sort/filter without re-querying, value inspection
  (pretty-printed JSON), yank as CSV / JSON / INSERT.
- **Tags and per-project storage.** Notebooks are stored per repository and
  carry tags; pick them by name or by tag from anywhere.
- **Safety rails.** `SELECT`s without a `LIMIT` get `LIMIT 500`. Writes ask
  first, and an `UPDATE`/`DELETE` without `WHERE` is called out. Connections
  can be marked read-only (enforced server side).
- **Index warnings.** Before running, the planner is asked for the plan; a
  sequential scan (or an index scan that only serves `ORDER BY`) on a big
  table is flagged with a suggested index. Optionally ask for confirmation.
- **Schema-aware completion** for blink.cmp, nvim-cmp or plain omnifunc:
  tables, the columns of the tables in the current statement, aliases,
  keywords. `K` describes the table or column under the cursor.
- **Prompt to SQL.** Write `-- ? users who never logged in` in a cell and press
  `<CR>` (or `<localleader>g`): the schema and the prompt go to `claude`,
  `kimi` or `codex`, the SQL comes back into the cell for review.
- **Ask about a result.** `<localleader>a` sends the cell's SQL together with
  what came back (rows, error, notices, the plan when there is one) to the
  agent with your question — "which of these is blocking?", "why is this
  slow?" — and shows the answer next to the grid. Follow-ups keep the context.
- **Extensible.** Everything database-specific sits behind a small adapter
  interface; PostgreSQL ships, others plug in.

## Requirements

- Neovim 0.10+
- `psql` on `PATH` (macOS: `brew install libpq`, then put its `bin` on `PATH`)
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for pickers
  with previews (falls back to `vim.ui.select`), the `claude` / `kimi` /
  `codex` CLI for prompt-to-SQL.

## Install

lazy.nvim:

```lua
{
  "jasonvitagendev/dbgrid",
  cmd = "Dbgrid",
  keys = {
    { "<leader>DD", "<cmd>Dbgrid<cr>",             desc = "dbgrid: open notebook" },
    { "<leader>Dn", "<cmd>Dbgrid new<cr>",         desc = "dbgrid: new notebook" },
    { "<leader>Dt", "<cmd>Dbgrid tags<cr>",        desc = "dbgrid: notebooks by tag" },
    { "<leader>Dl", "<cmd>Dbgrid last<cr>",        desc = "dbgrid: last notebook" },
    { "<leader>Dc", "<cmd>Dbgrid connections<cr>", desc = "dbgrid: connections" },
  },
  opts = {
    connections = {
      { name = "local", url = "postgres://localhost/app_development" },
      { name = "prod-ro", url = "$PROD_DATABASE_URL", readonly = true, index_check = "confirm" },
    },
  },
}
```

Completion with blink.cmp (LazyVim users: put this in a plugin spec):

```lua
{
  "saghen/blink.cmp",
  opts = function(_, opts)
    table.insert(opts.sources.default, "dbgrid")
    opts.sources.providers.dbgrid = { name = "dbgrid", module = "dbgrid.completion.blink", score_offset = 10 }
  end,
}
```

nvim-cmp:

```lua
require("cmp").register_source("dbgrid", require("dbgrid.completion.cmp").new())
-- then add { name = "dbgrid" } to your sources
```

Run `:checkhealth dbgrid` to see what is reachable.

## Connections

A connection is a name plus a URL. They come from three places, in this order:

1. `setup({ connections = { ... } })` — `$VAR` / `${VAR}` in the URL are
   expanded from the environment.
2. Connections saved with `:Dbgrid connections` → `+ add connection`, either
   for the current project only or for every project.
3. `DATABASE_URL` (also `DB_URL`, `POSTGRES_URL`, `PG_URL`) from the
   environment and from `.env`, `.env.local`, `.env.development` in the
   project root.

Options per connection:

| key | meaning |
|---|---|
| `readonly = true` | psql runs with `default_transaction_read_only=on`; writes fail on the server |
| `index_check = "confirm"` | override the global mode for this connection |
| `statement_timeout_ms` | server-side statement timeout |
| `password_cmd` | shell command whose output becomes `PGPASSWORD` (1Password, `pass`, …) |
| `env` | extra environment for the client process |

`~/.pgpass` and `~/.pg_service.conf` work as usual because the real `psql`
does the connecting.

## Notebooks

A notebook is a `.sql` file plus a small `.json` (title, tags, connection,
per-cell run info) and a `.cache.json` (last results, disposable). They live
per project:

- `~/.local/share/nvim/dbgrid/projects/<repo>-<hash>/` by default
- `<repo>/.dbgrid/` when that directory exists (or with
  `storage.mode = "project"`); a `.gitignore` for the cache is created, so the
  `.sql` and `.json` files can be committed and shared.

The project is the git root of the current working directory.

The file format is deliberately plain:

```sql
-- %% [k3x9] overdue invoices
-- ? invoices unpaid for more than 30 days, with the customer email
select i.id, c.email, i.due_on
from invoices i
join customers c on c.id = i.customer_id
where i.paid_at is null and i.due_on < now() - interval '30 days';

-- %% [p2m7]
-- @nolimit
-- @conn analytics
select count(*) from events;
```

- `-- %% [id] title` starts a cell. The id is generated for you and hidden in
  the buffer; type `-- %%` and it is filled in. The title is optional.
- `-- ? text` is a prompt for the agent (several lines are joined).
- `-- @nolimit` skips the automatic `LIMIT`; `-- @notx` skips the transaction
  wrapper for multi-statement cells; `-- @conn name` runs the cell on another
  connection.

Open a notebook file by hand (`:e`) and the plugin attaches too.

## Keymaps

All keymaps are buffer-local and configurable (`keymaps` in setup; set one to
`false` to skip it). `<localleader>` is `\` by default.

Query pane:

| key | action |
|---|---|
| `<CR>`, `\r` | run the cell (or generate SQL when the cell is only a prompt) |
| `\R` | run every cell, top to bottom (stops at the first error) |
| `\e` / `\E` | `EXPLAIN` / `EXPLAIN ANALYZE` (analyze runs inside a rolled-back transaction) |
| `\x` | cancel the running query or generation |
| `]c` / `[c` / `]C` / `[C` | next / previous / last / first cell |
| `\n` / `\o` / `\O` | new cell at the end / below / above |
| `\d` | delete the cell and its cached result |
| `\y` | yank the cell body |
| `\m` | rename the cell |
| `\g` | generate SQL from the `-- ?` prompt (asks for one when missing) |
| `\a` | ask the agent about the cell's query and its result |
| `\t` | edit tags |
| `\c` | pick the connection |
| `\s` / `\S` | refresh the schema cache / browse tables (inserts the name) |
| `K` | describe the table or column under the cursor |
| `\<Tab>` | focus the results pane |
| `\z` | zoom the current pane |
| `\q` | close the notebook |
| `ic` / `ac` | text objects: cell body / whole cell (`dic`, `yac`, …) |

Results pane:

| key | action |
|---|---|
| `<CR>`, `K` | inspect the value under the cursor (JSON is pretty-printed) |
| `\v` | toggle the record view of the current row |
| `\p` | toggle the plan view |
| `\w` | toggle column truncation |
| `\s` | sort by the column under the cursor (asc → desc → off) |
| `\f` | filter rows by text |
| `\yc` / `\yr` / `\ya` / `\yi` | yank value / row as JSON / result as CSV / row as INSERT |
| `\a` | ask the agent about the query and the result (again for a follow-up) |
| `<Tab>` / `<S-Tab>` | next / previous column (next / previous row in record view) |
| `]c` / `[c` | next / previous cell |
| `\<Tab>` | focus the query pane |
| `q` | close the notebook |

## Commands

`:Dbgrid` alone opens the notebook picker. Subcommands (with completion):

| command | |
|---|---|
| `open [name]` | open a notebook (picker when no name) |
| `new [title]` | create one |
| `last` | jump to the most recent notebook |
| `tags` | pick a tag, then a notebook |
| `tag add x` / `tag remove x` | change tags of the current notebook |
| `connections` / `connect [name]` | pick or set the connection |
| `run` / `run all` | run the current cell / all cells |
| `explain [analyze]` | plan of the current cell |
| `ask <prompt>` | add a prompt to the current cell and generate |
| `review [question]` | ask the agent about the current cell's query and result |
| `schema refresh` / `schema tables` | refresh the cache / browse tables |
| `describe <table>` | describe a table |
| `rename <title>` / `delete` / `close` | notebook management |
| `export csv|json [path]` | current result to the clipboard or a file |
| `cancel` | stop what is running |

## Running queries

Each run spawns `psql -f -` with the cell's statements. A cell with several
statements runs in one transaction (unless it already contains `BEGIN`, or
`-- @notx` is present), so a failure rolls everything back. Errors are shown
with the offending line and set as a diagnostic in the query buffer.
Notices (`RAISE NOTICE`) show above the grid.

- **LIMIT:** a read-only `SELECT` / `WITH` / `VALUES` / `TABLE` statement
  without a top-level `LIMIT` or `FETCH` gets `LIMIT 500` (before any `FOR
  UPDATE`). The footer says so, and warns when the limit was actually hit.
  `query.limit = nil` turns it off.
- **Writes:** `INSERT`, `UPDATE`, `DELETE`, `MERGE`, DDL and `DO`/`CALL`
  blocks ask for confirmation, with a louder prompt when an `UPDATE` or
  `DELETE` has no `WHERE`. `query.confirm_writes = false` turns it off.
- **Index check:** explainable statements are sent through `EXPLAIN (FORMAT
  JSON)` first. A `Seq Scan` on a table with at least `index_check.min_rows`
  rows (from the schema cache) produces a warning such as
  `Seq Scan on users (~1,204,331 rows) filter (email = 'x') — no index used;
  consider CREATE INDEX ON users (email);`. An `Index Scan` that has a
  `Filter` but no `Index Cond` is reported too (the index only serves the
  `ORDER BY`), and so is a filter-less `Seq Scan` inside a `Nested Loop`
  (a join column without an index). A plain full-table read (an aggregate
  over the whole table, the build side of a hash join) is not flagged: no
  index would change it. Mode `"warn"` runs anyway, `"confirm"` asks,
  `"off"` skips the check. The plan is kept with the result (`\p` in the
  results pane).
- **Cancel:** `\x` sends `SIGINT` to psql, which asks the server to cancel.

## Prompt to SQL

```sql
-- %% [a1b2]
-- ? customers with more than 3 unpaid invoices, most overdue first
```

Press `<CR>` on that cell (it has no SQL yet) or `\g` anywhere in a cell. The
plugin builds a prompt with the request, the most relevant tables of the
schema (matched by name against the prompt, plus tables already used in the
notebook, plus their foreign-key neighbours), enum types and the other cells
as context, then runs the agent CLI. When the cell already contains SQL the
prompt is treated as an edit request ("also show the plan name"). The answer
replaces the SQL under the prompt lines and the cell is marked *generated,
not run* until you run it.

Agents are plain commands:

```lua
ai = {
  agent = "claude",
  agents = {
    claude = { cmd = { "claude", "-p", "--output-format", "text", "--no-session-persistence", "--max-turns", "3",
                       "--disallowedTools", "Bash,Edit,Write,NotebookEdit,Read,Glob,Grep,Task,WebFetch,WebSearch" }, stdin = true },
    kimi   = { cmd = { "kimi", "--print", "-p", "{prompt}" }, stdin = false },
    codex  = { cmd = { "codex", "exec", "--skip-git-repo-check", "-s", "read-only", "-o", "{output}", "-" }, stdin = true },
  },
  instructions = "Use snake_case aliases. Never select *.",
  dialect = "PostgreSQL 18",
  max_tables = 40,
}
```

`{prompt}` is replaced by the prompt text, `{output}` by a temp file the agent
should write its answer to; with `stdin = true` the prompt is piped in. Add
your own agent the same way. The Claude command above keeps Claude Code from
using tools so answers come back fast; drop `Read,Glob,Grep` from the
disallowed list if you want it to read your repository (models, migrations)
for extra context. Check `kimi --help` / `codex exec --help` if your versions
differ.

## Ask about a result

Diagnostic queries (`pg_stat_activity`, lock waits, `pg_stat_user_tables`,
an `EXPLAIN ANALYZE` that does not look right) are easier to read with a
second pair of eyes. Press `\a` in the results pane (or in the query pane, on
the cell) and type a question; leave it empty for "what does this result
show, anything worth attention?". The agent gets, in one prompt:

- the SQL that produced the result (as it ran, with the added `LIMIT`; a note
  when the cell was edited since);
- the rows — as displayed, so an active filter or sort is respected — up to
  `ai.max_result_rows` (100), with `NULL`s spelled out and long values cut;
- command tags, notices, index-check warnings and the error with its line,
  `DETAIL` and `HINT` when the query failed;
- the plan: the `EXPLAIN` / `EXPLAIN ANALYZE` output when you ran one (`\e` /
  `\E`), otherwise the estimated plan the index check fetched before the run;
- the definitions of the tables the query reads, from the schema cache;
- your earlier questions about this same result, so follow-ups work.

The answer opens in a float over the grid: `q` closes it, `\a` inside it asks
a follow-up, and an empty question re-opens the last answer. The transcript
is kept per cell until the cell is run again. `\x` in the query pane (or
`:Dbgrid cancel`) stops a question that is taking too long; `:Dbgrid review
[question]` asks one from the command line.

## Completion and hover

The schema (tables, columns with types, primary/foreign keys, indexes, enums)
is fetched once per connection with one catalog query, cached on disk and
refreshed after `schema.ttl_seconds` or with `\s`. Completion uses the
statement around the cursor: after `u.` you get the columns of whatever `u`
aliases, otherwise the columns of the tables in the statement first, then all
tables, schemas, keywords and functions. `K` on `users`, `u.email` or a bare
column name opens a description with types, defaults, foreign keys and
indexes.

## Configuration

Defaults (`require("dbgrid").setup({...})` deep-merges):

```lua
{
  connections = {},
  default_connection = nil,
  env_files = { ".env", ".env.local", ".env.development", ".env.development.local" },
  env_vars = { "DATABASE_URL", "DB_URL", "POSTGRES_URL", "PG_URL" },
  storage = { mode = "auto", project_dir = ".dbgrid", data_dir = vim.fn.stdpath("data") .. "/dbgrid", cache_rows = 500 },
  layout = { results = "left", size = 0.5, tab = true },   -- results: "left" | "right" | "bottom"
  query = { limit = 500, confirm_writes = true, transaction_per_cell = true, timeout_ms = nil },
  index_check = { mode = "warn", min_rows = 10000 },        -- "off" | "warn" | "confirm"
  results = { max_col_width = 40, null_text = "NULL", newline = "↵", align_numbers = true, max_render_rows = 2000 },
  ai = { agent = "claude", agents = { ... }, max_tables = 40, max_result_rows = 100, timeout_ms = 180000, instructions = "", dialect = "PostgreSQL 18" },
  schema = { ttl_seconds = 3600, exclude = {} },
  completion = { omnifunc = true, keywords = true },
  keymaps = { query = { ... }, results = { ... } },          -- see lua/dbgrid/config.lua
  icons = { ... },
}
```

Highlight groups (`DbgridCellHeader`, `DbgridCellHeaderActive`, `DbgridNull`,
`DbgridNumber`, `DbgridCurrentColumn`, `DbgridWarn`, …) link to standard
groups and can be overridden.

## Other databases

An adapter is a Lua table with these functions (see
`lua/dbgrid/adapters/postgres.lua`):

```lua
require("dbgrid").register_adapter({
  name = "mysql",
  schemes = { mysql = true },
  executable = "mysql",
  run = function(conn, statements, opts, cb) ... end,          -- cb(dbgrid.RunResult)
  explain = function(conn, statements, cb) ... end,            -- cb(plans) (may be empty)
  explain_text = function(conn, sql, analyze, cb) ... end,     -- cb(lines, err)
  schema = function(conn, cb) ... end,                         -- cb(schema_json, err)
  test = function(conn, cb) ... end,                           -- cb(ok, message)
  cancel = function(job) ... end,
  keywords = { ... }, functions = { ... },
})
```

`run` receives statements that are already split, limited and classified
(`kind`, `class`) and returns per-statement result sets (`columns`, `rows`
with `vim.NIL` for NULL, `row_count`), command tags, notices and an error with
`stmt_index` / `line` / `col`. The schema document is the same shape the
Postgres adapter produces (`tables[].columns/indexes/constraints`, `schemas`,
`enums`, `functions`). The statement splitter, LIMIT injection and write
detection are generic SQL; the index check only reacts to plan trees in
Postgres' JSON shape.

## Development

```sh
tests/run.sh                                        # unit tests
DBGRID_TEST_URL=postgres://user:pass@localhost/db tests/run.sh   # plus integration tests
DBGRID_TEST_URL=... nvim -u tests/minimal_init.lua -c 'luafile tests/demo.lua'   # try the UI
```

## Ideas not built yet

- Result history per cell (diff two runs), pinned results
- Parameters: `-- @param since = '2026-01-01'` substituted on run, prompted when missing
- Cross-cell references (`-- @depends q1`) and `run all` respecting them
- Live query cancellation via `pg_cancel_backend` for remote sessions that ignore SIGINT
- Result view in a floating window for one-off peeks from any buffer (`:Dbgrid run` on a visual selection)
- Column statistics popup (distinct count, min/max) on demand
- `EXPLAIN ANALYZE` diff against the estimated plan, highlighting bad row estimates
- Rails/Django awareness: read `config/database.yml` / `settings.py` for connections
- Adapters for SQLite (`sqlite3`), MySQL (`mysql`), DuckDB
