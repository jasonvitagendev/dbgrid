# dbgrid.nvim

SQL notebooks for Neovim. Queries live in cells on one side, results on the
other, and the notebook is saved per project with tags so you can find it
again. PostgreSQL and SQLite ship; other databases plug in through a small
adapter interface.

```
 ▸ q1 first users │ ✓ 6 rows · 43 ms │ grid          │ ⛁ local-dev │ #billing #users │ Overdue invoices  3 cells │ ✦ claude
 id │ email             │ plan_id │ balance │ created_at   │▎ ▸ first users  ✓ 6 rows · 43 ms · just now
────┼───────────────────┼─────────┼─────────┼──────────────│▎ select id, email, plan_id, balance, created_at
  1 │ user1@example.com │       2 │    1.50 │ 2026-09-26 … │▎ from users
  2 │ user2@example.com │       3 │    3.00 │ 2026-09-26 … │▎ where id <= :max
  3 │ user3@example.com │       1 │    4.50 │ 2026-09-26 … │▎ order by id
  4 │ user4@example.com │       2 │    6.00 │ 2026-09-26 … │▎
  5 │ user5@example.com │       3 │    7.50 │ 2026-09-26 … │  ─────────────────────────────────────────────────
  6 │ user6@example.com │       1 │    9.00 │ 2026-09-26 … │  ▸ big scan  ⚠ seq scan ✓ 500 rows · 50 ms · 2m ago
                                                           │  -- ? users whose balance is above 5, newest first
 6 rows · 43 ms (server 1 ms) · LIMIT 500 added · 06:54:25 │  select * from users where balance > 5
 with :max = 6                                             │
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
- **Parameters.** `:since` or `{{since}}` in a query is filled from a
  `-- @param since = '2026-01-01'` line, from a value the notebook remembers,
  or from a prompt the first time it runs.
- **Cross-cell references.** `{{overdue-invoices}}` inlines another cell as a
  subquery; `-- @depends setup` runs a cell first when its result is stale, and
  `run all` follows the dependency order.
- **Formatting.** `\=` formats the cell (built in, or through conform.nvim /
  pg_format / sql-formatter / sqlfluff); `format.on_save = true` does it on
  every write. Headers, prompts and directives are never touched.
- **Tags and per-project storage.** Notebooks are stored per repository and
  carry tags; pick them by name or by tag from anywhere.
- **Safety rails.** `SELECT`s without a `LIMIT` get `LIMIT 500`. Writes ask
  first, and an `UPDATE`/`DELETE` without `WHERE` is called out. Connections
  can be marked read-only (enforced server side). Cancel goes to the client
  and, when that is ignored, to the server (`pg_cancel_backend`).
- **Index warnings.** Before running, the planner is asked for the plan; a
  sequential scan (or an index scan that only serves `ORDER BY`) on a big
  table is flagged with a suggested index. Optionally ask for confirmation.
- **EXPLAIN ANALYZE findings.** `\E` compares the planner's estimates with
  what actually happened: row estimates that are 10× off, sorts and hashes
  that spilled to disk, filters that discard almost everything, scans repeated
  inside nested loops, and where the time went — each with a suggestion.
- **Schema, three ways.** `K` describes the table or column under the cursor,
  `\S` picks a table with a preview, and `\b` opens the schema as a foldable,
  searchable document (every table one fold: columns, indexes, foreign keys).
- **Schema-aware completion** for blink.cmp, nvim-cmp or plain omnifunc:
  tables, the columns of the tables in the current statement, aliases,
  keywords, `{{cell}}` references and `:parameters`.
- **Prompt to SQL.** Write `-- ? users who never logged in` in a cell and press
  `<CR>` (or `\g`): the schema and the prompt go to `claude`, `kimi` or
  `codex`, the SQL comes back into the cell for review. Switch the agent with
  `\a`, `:Dbgrid agent kimi` or `-- @agent codex` in a cell.
- **Rails aware.** A Rails project needs no configuration: the databases in
  `config/database.yml` (development, test, multi-database setups) appear as
  connections, and the agent is told about Rails conventions.
- **Extensible.** Everything database-specific sits behind a small adapter
  interface; PostgreSQL and SQLite ship, others plug in.

## Requirements

- Neovim 0.10+
- `psql` on `PATH` for PostgreSQL (macOS: `brew install libpq`, then put its
  `bin` on `PATH`), `sqlite3` for SQLite
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for pickers
  with previews (falls back to `vim.ui.select`), the `claude` / `kimi` /
  `codex` CLI for prompt-to-SQL, a SQL formatter (see Formatting).

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
      { name = "fizzy", url = "sqlite:storage/development.sqlite3" },
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

A connection is a name plus a URL. They come from four places, in this order:

1. `setup({ connections = { ... } })` — `$VAR` / `${VAR}` in the URL are
   expanded from the environment.
2. Connections saved with `:Dbgrid connections` → `+ add connection`, either
   for the current project only or for every project.
3. `DATABASE_URL` (also `DB_URL`, `POSTGRES_URL`, `PG_URL`) from the
   environment and from `.env`, `.env.local`, `.env.development` in the
   project root.
4. `config/database.yml` of a Rails project: `development`, `test` and every
   database of a multi-database setup become `rails:development`,
   `rails:development.cable`, `rails:test`, … (`rails.environments` chooses
   the environments; `rails.enabled = false` turns it off). ERB such as
   `<%= ENV.fetch("DB_HOST", "localhost") %>` is evaluated against the
   environment.

URLs:

| database | url |
|---|---|
| PostgreSQL | `postgres://user:pass@host:5432/db` (`postgresql://` too) |
| SQLite | `sqlite:storage/development.sqlite3`, `sqlite:///abs/path.db`, `~/data.db`, or a bare path ending in `.sqlite3` / `.sqlite` / `.db`; relative paths are resolved against the project root |

Options per connection:

| key | meaning |
|---|---|
| `readonly = true` | psql runs with `default_transaction_read_only=on` (sqlite3 with `-readonly`); writes fail on the server |
| `index_check = "confirm"` | override the global mode for this connection |
| `statement_timeout_ms` | server-side statement timeout (PostgreSQL) |
| `password_cmd` | shell command whose output becomes `PGPASSWORD` (1Password, `pass`, …) |
| `env` | extra environment for the client process |
| `adapter` | force `"postgres"` or `"sqlite"` instead of deriving it from the url |

`~/.pgpass` and `~/.pg_service.conf` work as usual because the real `psql`
does the connecting.

## Notebooks

A notebook is a `.sql` file plus a small `.json` (title, tags, connection,
agent, parameter values, per-cell run info) and a `.cache.json` (last results,
disposable). They live per project:

- `~/.local/share/nvim/dbgrid/projects/<repo>-<hash>/` by default
- `<repo>/.dbgrid/` when that directory exists (or with
  `storage.mode = "project"`); a `.gitignore` for the cache is created, so the
  `.sql` and `.json` files can be committed and shared.

The project is the git root of the current working directory.

The file format is deliberately plain:

```sql
-- %% [k3x9] overdue invoices
-- ? invoices unpaid for more than :days days, with the customer email
-- @param days = 30
select i.id, c.email, i.due_on
from invoices i
join customers c on c.id = i.customer_id
where i.paid_at is null and i.due_on < now() - make_interval(days => :days);

-- %% [p2m7] overdue per customer
select c.email, count(*)
from {{overdue-invoices}} o
join customers c on c.id = o.customer_id
group by c.email;

-- %% [q8r1]
-- @nolimit
-- @conn analytics
-- @agent kimi
select count(*) from events;
```

- `-- %% [id] title` starts a cell. The id is generated for you and hidden in
  the buffer; type `-- %%` and it is filled in. The title is optional; cells
  are referenced by their title (`overdue-invoices` for "overdue invoices"),
  their id, or `q3` for the third cell.
- `-- ? text` is a prompt for the agent (several lines are joined).
- `-- @param name = value` gives a parameter a value for this cell (`value`
  is SQL: `'2026-01-01'`, `42`, `now()`); `-- @param name` alone declares it.
- `-- @depends a, b` runs cells `a` and `b` first when their result is stale.
- `-- @nolimit` skips the automatic `LIMIT`; `-- @notx` skips the transaction
  wrapper for multi-statement cells; `-- @conn name` runs the cell on another
  connection; `-- @agent name` sends the cell's prompt to another agent.
- `{{name}}` inside the SQL inlines the named cell as a subquery; `:name` (or
  `{{name}}` when no cell is called that) is a parameter.

Open a notebook file by hand (`:e`) and the plugin attaches too.

## Keymaps

All keymaps are buffer-local and configurable (`keymaps` in setup; set one to
`false` to skip it). `<localleader>` is `\` by default.

Query pane:

| key | action |
|---|---|
| `<CR>`, `\r` | run the cell (or generate SQL when the cell is only a prompt) |
| `\R` | run every cell, dependencies first (stops at the first error) |
| `\e` / `\E` | `EXPLAIN` / `EXPLAIN ANALYZE` with findings (analyze runs inside a rolled-back transaction) |
| `\x` | cancel the running query or generation |
| `]c` / `[c` / `]C` / `[C` | next / previous / last / first cell |
| `\n` / `\o` / `\O` | new cell at the end / below / above |
| `\d` | delete the cell and its cached result |
| `\y` | yank the cell body |
| `\m` | rename the cell |
| `\=` | format the cell's SQL |
| `\p` | edit parameter values |
| `\g` | generate SQL from the `-- ?` prompt (asks for one when missing) |
| `\a` | pick the coding agent for this notebook |
| `\t` | edit tags |
| `\c` | pick the connection |
| `\s` / `\S` | refresh the schema cache / pick a table (inserts the name) |
| `\b` | browse the schema document in the results pane |
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
| `\b` | toggle the schema document |
| `\w` | toggle column truncation |
| `\s` | sort by the column under the cursor (asc → desc → off) |
| `\f` | filter rows by text |
| `\yc` / `\yr` / `\ya` / `\yi` | yank value / row as JSON / result as CSV / row as INSERT |
| `<Tab>` / `<S-Tab>` | next / previous column (next / previous row in record view) |
| `]c` / `[c` | next / previous cell |
| `\<Tab>` | focus the query pane |
| `q` | close the notebook |

In the schema document `<CR>` folds and unfolds a table, `K` describes it,
`<Tab>` / `<S-Tab>` jump between tables, `\f` filters tables by name, `\yc`
yanks the table or column name, and `/`, `zo`, `zc`, `zR`, `zM` work as they
do everywhere.

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
| `run` / `run all` | run the current cell / all cells (dependencies first) |
| `explain [analyze]` | plan of the current cell |
| `format [all]` | format the current cell / every cell |
| `param [name [value]]` / `params` | show or set a parameter value / edit them all |
| `agent [name\|default]` | pick or set the coding agent of this notebook |
| `ask <prompt>` | add a prompt to the current cell and generate |
| `schema refresh` / `schema tables` / `schema view` | refresh the cache / pick a table / toggle the schema document |
| `describe <table>` | describe a table |
| `rename <title>` / `delete` / `close` | notebook management |
| `export csv|json [path]` | current result to the clipboard or a file |
| `cancel` | stop what is running |

## Running queries

Each run spawns the database client (`psql -f -`, `sqlite3`) with the cell's
statements. A cell with several statements runs in one transaction (unless it
already contains `BEGIN`, or `-- @notx` is present), so a failure rolls
everything back. Errors are shown with the offending line and set as a
diagnostic in the query buffer. Notices (`RAISE NOTICE`) show above the grid.

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
  index would change it. On SQLite the same check reads `EXPLAIN QUERY PLAN`
  (`SCAN t` without an index). Mode `"warn"` runs anyway, `"confirm"` asks,
  `"off"` skips the check. The plan is kept with the result (`\p` in the
  results pane).
- **Cancel:** `\x` sends `SIGINT` to the client, which asks the server to
  cancel. Sessions behind proxies or tunnels sometimes never see that cancel
  request; after `query.cancel_grace_ms` (1.5 s) dbgrid opens a second
  connection and runs `pg_cancel_backend` on the run's own backend (every run
  has a unique `application_name`), then kills the client as a last resort.
  `query.server_cancel = false` keeps the client-only behaviour.

### Parameters

```sql
-- %% [a1] recent signups
-- @param since = '2026-01-01'
select id, email from users where created_at >= :since and plan = {{plan}};
```

`:since` (psql and sqlite style) and `{{plan}}` are placeholders, recognised
outside strings, comments and `::casts`. When a cell runs, each one is
replaced by, in order: the value given by the cell's own `-- @param` line, a
value the notebook remembers (from an earlier prompt or `:Dbgrid param`), or
a value you are asked for right then (remembered afterwards). Values are SQL
text, so quote strings yourself: `'2026-01-01'`, `42`, `now() - interval '1
day'`. The footer of the result shows which values were used; `\p` in the
query pane lists every parameter of the notebook with its value and the cells
that use it. Parameters are substituted before the statement is sent, so
error positions still match the cell.

### Cross-cell references

`{{name}}` inlines another cell as a parenthesised subquery, comments
stripped, so a cell that selects overdue invoices can be reused as
`from {{overdue-invoices}} o` without repeating it. The referenced cell must
be a single read-only statement; cycles are reported. Parameters declared in
the inlined cell keep their values. `name` is the cell's title slug, its id,
or `q<n>` for the n-th cell; the footer lists what was inlined and completion
offers cell names after `{{`.

`-- @depends setup, seed` is for side effects: when a cell runs, the cells it
depends on run first (in order, transitively) unless their last run succeeded
with the SQL they have now. `run all` (`\R`) orders the whole notebook the
same way.

### Formatting

`\=` (`:Dbgrid format`, `:Dbgrid format all`) reformats the SQL of a cell.
The header, `-- ?` prompt and `-- @` directive lines above the SQL are kept
exactly; comments inside the SQL travel with their statement. The result is
checked to be the same statement token for token (case of keywords aside)
before it replaces the cell, so a misbehaving formatter can never change what
a query does — the cell is left alone and you get a warning. Formatting never
marks a cell as edited: the "edited" indicator compares statements, not
whitespace.

`format.formatter = "auto"` tries, in order: conform.nvim when it has a
formatter for the `sql` filetype; `pg_format`, `sql-formatter`, `sqlfluff` or
`sqlformat` when one is on `PATH` (`format.commands` holds their argument
lists, `{dialect}` becomes `postgresql` or `sqlite`); and finally the
built-in formatter: one clause per line, `AND`/`OR` indented under `WHERE`,
subqueries and CTE bodies indented, select lists on one line when they fit
in `format.width`, keywords left as typed (`format.keyword_case = "upper"`
or `"lower"` to normalise them). `format.on_save = true` formats every cell
whenever the notebook is written.

### EXPLAIN ANALYZE findings

`\E` runs `EXPLAIN (ANALYZE, BUFFERS)` inside a rolled-back transaction (so
even an `UPDATE` can be analysed) and shows the plan with actual rows and
times next to the estimates. Above the plan, findings summarise what is worth
a look:

- a node whose estimated rows were 10× too high or too low (`⚠ Seq Scan on
  users: planner expected 400 rows, got 40,000 (100× under-estimated;
  statistics may be stale) → ANALYZE users;`) — for joins, a hint towards
  `CREATE STATISTICS`;
- a sort or hash that spilled to disk (`work_mem`), a hash join that needed
  several batches, a hash aggregate that hit the disk;
- a scan that reads far more rows than it keeps (a missing index, with the
  suggested `CREATE INDEX`);
- a sequential scan repeated for every row of a nested loop;
- the node most of the time is spent in, and temp blocks written.

Estimates that are off by 10× are also marked inline in the plan. SQLite has
no `EXPLAIN ANALYZE`; `\E` shows its query plan instead.

## Prompt to SQL

```sql
-- %% [a1b2]
-- ? customers with more than 3 unpaid invoices, most overdue first
```

Press `<CR>` on that cell (it has no SQL yet) or `\g` anywhere in a cell. The
plugin builds a prompt with the request, the most relevant tables of the
schema (matched by name against the prompt, plus tables already used in the
notebook, plus their foreign-key neighbours), enum types, the notebook's
parameters and the other cells as context, then runs the agent CLI. When the
cell already contains SQL the prompt is treated as an edit request ("also
show the plan name"). The answer replaces the SQL under the prompt lines and
the cell is marked *generated, not run* until you run it.

Which agent answers is decided per cell (`-- @agent kimi`), then per
notebook (`\a` or `:Dbgrid agent kimi`, remembered in the notebook and shown
in the winbar), then by `ai.agent`. Agents are plain commands:

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
differ. In a Rails project the agent is also told about Rails conventions
(plural tables, `id`, `created_at`, `<singular>_id`), and the Rails
bookkeeping tables are left out of the schema it sees.

## Schema, indexes, completion

The schema (tables, columns with types, primary/foreign keys, indexes, enums)
is fetched once per connection with one catalog query, cached on disk and
refreshed after `schema.ttl_seconds` or with `\s`.

Three ways to look at it, from quick to thorough:

- `K` on `users`, `u.email` or a bare column name opens a float with the
  columns, defaults, foreign keys and indexes of that table.
- `\S` opens a table picker; the preview is the same description, and
  choosing a table inserts its name.
- `\b` turns the results pane into a schema document: every table is one fold
  showing its columns (type, `PK`, `→ plans(id)`, `not null`, defaults),
  its indexes (`⌗ users_email_key (email) UNIQUE`) and comments. Tables the
  current cell refers to start unfolded, the rest folded, so a big database
  reads like a tree; `/` searches through everything (folds open on a match),
  `\f` narrows the list by table name. The document stays while you move
  between cells; `\b` again brings the grid back.

This is deliberately not a tree widget: a flat, foldable document is
searchable with the keys you already have, shows a whole table at once, and
needs no expand-this-then-that clicking.

Completion uses the statement around the cursor: after `u.` you get the
columns of whatever `u` aliases, otherwise the columns of the tables in the
statement first, then all tables, schemas, keywords and functions of the
connection's dialect. After `{{` it offers cell names and parameters, after
`:` parameters.

## Configuration

Defaults (`require("dbgrid").setup({...})` deep-merges):

```lua
{
  connections = {},
  default_connection = nil,
  env_files = { ".env", ".env.local", ".env.development", ".env.development.local" },
  env_vars = { "DATABASE_URL", "DB_URL", "POSTGRES_URL", "PG_URL" },
  rails = { enabled = true, environments = { "development", "test" } },
  storage = { mode = "auto", project_dir = ".dbgrid", data_dir = vim.fn.stdpath("data") .. "/dbgrid", cache_rows = 500 },
  layout = { results = "left", size = 0.5, tab = true },   -- results: "left" | "right" | "bottom"
  query = { limit = 500, confirm_writes = true, transaction_per_cell = true, timeout_ms = nil,
            server_cancel = true, cancel_grace_ms = 1500 },
  format = { on_save = false, formatter = "auto", keyword_case = "keep", width = 100, indent = 2,
             order = { "pg_format", "sql-formatter", "sqlfluff", "sqlformat" }, commands = { ... } },
  index_check = { mode = "warn", min_rows = 10000 },        -- "off" | "warn" | "confirm"
  results = { max_col_width = 40, null_text = "NULL", newline = "↵", align_numbers = true, max_render_rows = 2000 },
  ai = { agent = "claude", agents = { ... }, max_tables = 40, timeout_ms = 180000, instructions = "", dialect = "PostgreSQL 18" },
  schema = { ttl_seconds = 3600, exclude = {} },
  completion = { omnifunc = true, keywords = true },
  keymaps = { query = { ... }, results = { ... } },          -- see lua/dbgrid/config.lua
  icons = { ... },
}
```

Highlight groups (`DbgridCellHeader`, `DbgridCellHeaderActive`, `DbgridNull`,
`DbgridNumber`, `DbgridCurrentColumn`, `DbgridWarn`, `DbgridSchemaTable`,
`DbgridSchemaIndex`, `DbgridFindingWarn`, …) link to standard groups and can
be overridden.

## Other databases

SQLite ships next to PostgreSQL: point a connection at the file
(`sqlite:storage/development.sqlite3`) and everything above works with the
`sqlite3` shell — results, errors with line and column, the index check on
`EXPLAIN QUERY PLAN`, the schema document (indexes, foreign keys, row counts),
completion with SQLite's functions, read-only connections. `EXPLAIN ANALYZE`
is not available there; `\E` shows the query plan.

An adapter is a Lua table with these functions (see
`lua/dbgrid/adapters/postgres.lua` and `sqlite.lua`):

```lua
require("dbgrid").register_adapter({
  name = "mysql",
  schemes = { mysql = true },
  executable = "mysql",
  dialect = "MySQL",                                            -- shown to the agent, used by formatters
  analyze = true,                                               -- explain_text supports analyze
  run = function(conn, statements, opts, cb) ... end,          -- cb(dbgrid.RunResult)
  explain = function(conn, statements, cb) ... end,            -- cb(plans) (may be empty)
  explain_text = function(conn, sql, analyze, cb) ... end,     -- cb(lines, err, { plan, marks, findings })
  schema = function(conn, cb) ... end,                         -- cb(schema_json, err)
  test = function(conn, cb) ... end,                           -- cb(ok, message)
  cancel = function(job, conn) ... end,
  keywords = { ... }, functions = { ... },
})
```

`run` receives statements that are already split, limited, parameter-substituted
and classified (`kind`, `class`) and returns per-statement result sets
(`columns`, `rows` with `vim.NIL` for NULL, `row_count`), command tags,
notices and an error with `stmt_index` / `line` / `col`. The schema document
is the same shape the Postgres adapter produces
(`tables[].columns/indexes/constraints`, `schemas`, `enums`, `functions`).
The statement splitter, LIMIT injection, parameters, cell references and
write detection are generic SQL; the index check reacts to plan trees in
Postgres' JSON shape and to `{ sqlite = true, nodes = { { depth, detail } } }`
trees.

## Development

```sh
tests/run.sh                                        # unit tests (plus SQLite when sqlite3 is on PATH)
DBGRID_TEST_URL=postgres://user:pass@localhost/db tests/run.sh   # plus Postgres integration tests
DBGRID_TEST_URL=... nvim -u tests/minimal_init.lua -c 'luafile tests/demo.lua'   # try the UI
```

The Postgres tests expect tables `users(id, email, plan_id, balance,
created_at, note)` with a few thousand rows, `plans(id, name)` and
`invoices(id, user_id, amount, paid_at, due_on)`.

## Ideas not built yet

- Result history per cell (diff two runs), pinned results
- Result view in a floating window for one-off peeks from any buffer (`:Dbgrid run` on a visual selection)
- Column statistics popup (distinct count, min/max) on demand
- Django awareness: read `settings.py` for connections
- Adapters for MySQL (`mysql`), DuckDB
