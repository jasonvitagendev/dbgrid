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
- **Plan analysis.** `\a` runs `EXPLAIN ANALYZE` (rolled back), applies a few
  rules (estimates off, sorts spilling to disk, the hot node) and asks the
  agent what is slow, why, and for the fix as SQL you can insert as a cell.
  `\A` explains the last error the same way. `\i` tries the suggested index
  hypothetically with hypopg and shows the cost before and after.
- **AWS RDS and Aurora.** A connection can be a profile plus a cluster: the
  plugin resolves the writer and reader endpoints, opens an SSM port forward
  through a bastion, fetches the password from Secrets Manager (or an IAM
  token) and hands psql a localhost URL. Expired credentials run your login
  command. Generic ssh / command tunnels work for everything else.
- **Diagnostics notebooks.** `:Dbgrid new --template diagnostics` gives you
  cells for active queries, blocking, top statements, bloat, unused indexes,
  replica lag and more; `blue-green` watches an RDS blue/green deployment.
- **Live cells and diffs.** `-- @every 5s` re-runs a cell and highlights what
  changed; `\d` diffs two runs of a cell (or the same cell on two connections);
  `:Dbgrid schema diff a b` and `:Dbgrid settings diff a b` compare servers.
- **Safety for writes.** The confirmation says how many rows an UPDATE or
  DELETE touches, `-- @dryrun` runs a write with RETURNING * inside a rolled
  back transaction, and DDL that takes heavy locks is called out.
- **Parameters, history, export.** `:name` placeholders with `-- @param`,
  every statement logged to a per-project history, notebooks exported as
  markdown with their results.
- **Extensible.** Everything database-specific sits behind a small adapter
  interface; PostgreSQL ships, others plug in.

## Requirements

- Neovim 0.10+
- `psql` on `PATH` (macOS: `brew install libpq`, then put its `bin` on `PATH`)
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for pickers
  with previews (falls back to `vim.ui.select`), the `claude` / `kimi` /
  `codex` CLI for prompt-to-SQL and plan analysis, the `aws` CLI v2 plus the
  Session Manager plugin for RDS connections, the `hypopg` extension on the
  server for `\i`.

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
| `lock_timeout_ms` | server-side `lock_timeout`; recommended on any connection you run DDL on |
| `password_cmd` | shell command whose output becomes `PGPASSWORD` (1Password, `pass`, …) |
| `env` | extra environment for the client process |
| `aws` | RDS / Aurora block, see below |
| `tunnel` | `{ kind = "ssh" | "cmd" | "ssm", ... }`, see below |
| `ssl`, `sslrootcert` | `sslmode` used through a tunnel (`"require"`, or `"verify-full"` with the CA bundle) |
| `ai = false` | never send this connection's SQL, plans or schema to an agent |

`~/.pgpass` and `~/.pg_service.conf` work as usual because the real `psql`
does the connecting. When you paste a URL with a password into `+ add
connection`, the plugin offers to move the password to `~/.pgpass` instead of
keeping it in its own JSON.

Every run goes through a resolve step: the declared connection becomes an
effective one (endpoints looked up, tunnel started or re-probed, credentials
fetched, `password_cmd` run asynchronously). The result is cached per name for
the session; `:Dbgrid aws refresh` or a failed run drops it.

### AWS RDS and Aurora

```lua
{
  name = "prod",
  aws = {
    profile = "prod",
    region  = "ap-southeast-1",
    cluster = "app-prod",             -- Aurora cluster id
    -- instance = "app-prod",         -- plain RDS instance id instead of cluster
    bastion = "i-0123456789abcdef0",  -- SSM target that can reach the database port
    secret  = "prod/db",              -- Secrets Manager id or ARN; optional when RDS manages the master password
    login_cmd = { "company-aws-login", "--profile", "{profile}" },  -- default: aws sso login
    -- auth = "iam", user = "app",    -- IAM database authentication instead of a secret
    -- database = "app",              -- only when the secret does not carry dbname
  },
  index_check = "confirm",
}
```

One entry becomes two in the picker, `prod/writer` and `prod/reader` (one per
replica on plain RDS: `prod/reader`, `prod/reader-2`, …). Readers are
read-only. `-- @conn prod/reader` works per cell, and `prod` alone means the
writer.

On the first run the plugin calls `describe-db-clusters` (or
`describe-db-instances`) and caches the endpoints for a day, starts
`aws ssm start-session` with the `AWS-StartPortForwardingSessionToRemoteHost`
document to a local port, reads the secret and passes the password to psql
through the environment only. The URL psql gets keeps the real host name with
`hostaddr=127.0.0.1&port=<local>`, so `sslmode=verify-full` and `~/.pgpass`
keep working. Before every run the local port is probed; a dead tunnel (SSM
idle timeout is 20 minutes by default) is restarted. Tunnels die with Neovim.

Expired credentials are recognised from the CLI's stderr; the plugin runs
`aws.login_cmd` (global, `{profile}` substituted; a company CLI goes here or
per connection in `aws.login_cmd`) in a terminal split, waits for it, and
retries. Without `bastion` the plugin connects directly. `aws.document` and
`aws.parameters` cover custom SSM documents.

Commands: `:Dbgrid aws add` (interactive: profile, region, cluster, bastion,
secret), `aws login`, `aws refresh` (drop the endpoint cache), `aws tunnels`
(list / kill), `aws status` (instance status, engine version, pending
maintenance, five CloudWatch metrics over the last five minutes), `aws events`
(last day of RDS events), `aws bluegreen` (blue/green deployments and their
switchover status). `:checkhealth dbgrid` reports the CLI, the Session
Manager plugin, the caller identity per profile and every tunnel.

### Tunnels

```lua
{ name = "staging", url = "postgres://app@db.internal:5432/app",
  tunnel = { kind = "ssh", host = "bastion.example.com" } }             -- ssh -N -L <local>:db.internal:5432 bastion
{ name = "odd", url = "postgres://app@localhost/app",
  tunnel = { kind = "cmd", cmd = { "my-tunnel", "--local-port", "{port}" } } }
```

`remote` defaults to the URL's host and port; `local_port` fixes the local port
(otherwise a stable one derived from the connection name, or a free one).

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
  connection; `-- @dryrun` runs a write inside a rolled back transaction;
  `-- @every 5s` makes the cell live; `-- @param name = value` declares a
  parameter (see below).

### Templates

`:Dbgrid new --template diagnostics` copies a bundled notebook into the
project store; `:Dbgrid templates` picks one. Two ship:

- **diagnostics**: active queries, blocking tree, idle-in-transaction, long
  transactions, top statements by time / calls / buffers
  (`pg_stat_statements`), sequential scans by table, dead tuples and vacuum,
  unused and redundant indexes, cache hit ratio, table sizes, connections,
  wraparound age, temp files and deadlocks, replica lag (plain and Aurora),
  replication on the primary, the settings that matter, extensions, locks on a
  table, cancel a backend. Cells that need an extension say so in a comment.
- **blue-green**: for an RDS blue/green deployment (logical replication from
  blue to green). You are asked which connections are blue and green; the
  cells cover slot lag, sender and subscription state, writes in flight, rows
  written since the last tick, application sessions, long transactions,
  tables without replica identity, row counts and sequence values on both
  sides, whether green accepts writes, and a write cell that makes blue
  read-only before switchover. `:Dbgrid schema diff blue green` covers the
  DDL gap, since logical replication carries none.

Your own templates go in `templates.dir`; a template is a notebook file with
a `-- template-name:` / `-- template-tags:` / `-- template-description:` /
`-- template-connections:` header.

### Parameters

```sql
-- %% locks on a table
-- @param table = 'users'
select * from pg_locks l join pg_class c on c.oid = l.relation where c.relname = :table;
```

`:name` inside a statement is a parameter. A value comes from a `-- @param`
line in the cell, else from the value remembered for the notebook, else you
are prompted (and the answer is remembered). Values are inserted verbatim, so
quote literals (`'users'`) and leave identifiers bare (`users`). `\P`
re-prompts the parameters of a cell; `:Dbgrid params name value` sets one,
`:Dbgrid params clear` forgets them all. The footer shows the values used.

### Live cells

`-- @every 5s` (also `500ms`, `2m`) marks a read-only cell as live. Running it
once keeps it re-running on that interval until `\x`, an edit of the cell, an
error, or closing the notebook. A tick is skipped while the previous one is
still running. Values that changed since the previous tick are highlighted,
the header shows the tick count, and `\h` in the results pane draws a text
sparkline of the numeric column under the cursor over the last `live.history`
ticks. Live results stay in memory and are written to the cache when the loop
stops.

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
| `\a` | analyze the plan with the agent (`EXPLAIN ANALYZE`, rolled back) |
| `\A` | explain the last error with the agent |
| `\i` | try the suggested index hypothetically (hypopg) |
| `\P` | re-prompt the `:parameters` of the cell |
| `\H` | query history |
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
| `\d` | diff against the previous run of the cell (toggle) |
| `\h` | sparkline of the column under the cursor across live ticks |
| `\yc` / `\yr` / `\ya` / `\yi` / `\yp` | yank value / row as JSON / result as CSV / row as INSERT / plan JSON |
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
| `new --template <name> [title]` | create one from a template (`templates` picks) |
| `analyze` / `explain-error` / `try-index [sql]` | agent analysis of the plan / of the error; hypothetical index |
| `params [name value | clear]` | edit, set or forget parameter values |
| `live [interval | stop]` | start / stop the live loop of the cell |
| `diff [connection]` | diff against the previous run, or run the cell on another connection and diff |
| `schema diff [a] [b]` / `settings diff [a] [b]` | compare two connections |
| `history` | pick a statement from the history (Enter: new cell, `<C-y>`: yank) |
| `aws add|login|refresh|tunnels|status|events|bluegreen [connection]` | the AWS layer |
| `last` | jump to the most recent notebook |
| `tags` | pick a tag, then a notebook |
| `tag add x` / `tag remove x` | change tags of the current notebook |
| `connections` / `connect [name]` | pick or set the connection |
| `run` / `run all` | run the current cell / all cells |
| `explain [analyze]` | plan of the current cell |
| `ask <prompt>` | add a prompt to the current cell and generate |
| `schema refresh` / `schema tables` | refresh the cache / browse tables |
| `describe <table>` | describe a table |
| `rename <title>` / `delete` / `close` | notebook management |
| `export csv|json|md [path]` | current result (or the whole notebook as markdown) to the clipboard or a file |
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
  `DELETE` has no `WHERE`. The prompt says how many rows an `UPDATE` /
  `DELETE` touches (the same `WHERE` as a `SELECT count(*)`,
  `query.preview_writes`). `query.confirm_writes = false` turns it off.
- **Dry run:** `-- @dryrun` (or `query.dry_run = true`) runs a write with
  `RETURNING *` inside a transaction that is rolled back, so you see the rows
  first. It is allowed on read-only connections.
- **DDL warnings:** `CREATE INDEX` / `DROP INDEX` without `CONCURRENTLY` on a
  big table, `ALTER TABLE` (with specifics for type changes, `SET NOT NULL`,
  constraints without `NOT VALID`, volatile defaults), `TRUNCATE`,
  `VACUUM FULL`, `CLUSTER` and `REINDEX` are called out in the confirmation,
  and so is a write connection with no `lock_timeout_ms`.
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

## Plan analysis, errors and hypothetical indexes

`\a` (`:Dbgrid analyze`) takes the cell under the cursor, runs
`EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)` inside a transaction that
is rolled back (`ai.analyze.mode = "estimate"` skips the ANALYZE; a write
statement asks first), collects the tables' columns, indexes and
`pg_stat_user_tables` counters, runs the rules below, and sends everything to
the agent with a fixed answer shape: what is slow, why, the fix as SQL, what
to verify. The answer opens in a markdown window under the results: `i`
inserts its `sql` blocks as new cells below the analyzed cell, `y` yanks,
`q` closes. The analysis is kept with the cell's result and shown in the plan
view (`\p`).

Rules on analyzed plans (`analyze_rules`): the planner's estimate off by more
than `estimate_ratio`, sorts and hashes spilling to disk, the node with the
highest exclusive time, and filters that discard most of what a node reads.
The plan view renders actual times, loops and buffers.

`\A` sends the SQL, the error with its hint and detail, and the tables
involved to the agent for a cause and a fix. `\i` needs the
[hypopg](https://github.com/HypoPG/hypopg) extension (available on RDS and
Aurora): it creates the suggested index hypothetically in the same session,
re-explains, and shows the estimated cost before and after.

`ai.redact_literals = true` replaces string and numeric literals in the SQL
and the plan before anything leaves the machine; `ai = false` on a connection
disables the agent for it entirely. `ai.investigate = true` gives the agent a
`dbgrid-query` shell helper bound to the same connection (read-only, 15 s
statement timeout) and, for the `claude` agent, allows exactly that command,
so it can check statistics or try EXPLAIN variants before answering.

## Diffs

- `\d` in the results pane diffs the current result against the previous run
  of the same cell: rows added, removed and changed, matched by the table's
  primary key when the result has it (else by an `id` column, else as whole
  rows). `:Dbgrid diff <connection>` runs the cell on another connection and
  diffs against the cached result: blue versus green row counts in one key.
- `:Dbgrid schema diff a b` compares tables, columns, indexes, constraints and
  enums of two connections in a scratch buffer (`]c` / `[c` jump between
  tables). `:Dbgrid settings diff a b` does the same for `pg_settings` that
  are not at their default.

## History and export

Every statement run is appended to `<store>/history.jsonl` (connection,
notebook, cell, SQL, rows, timing, error; `history.max_entries` caps the
file). `\H` / `:Dbgrid history` picks an entry into a new cell below the
cursor, `<C-y>` yanks it. `:Dbgrid export md [path]` writes the notebook as
markdown with every cell's SQL, its last result as a table and its analysis.

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
  query = { limit = 500, confirm_writes = true, preview_writes = true, dry_run = false, ddl_warnings = true,
            transaction_per_cell = true, timeout_ms = nil },
  index_check = { mode = "warn", min_rows = 10000 },        -- "off" | "warn" | "confirm"
  analyze_rules = { estimate_ratio = 10, spill = true, hot_node = true, min_rows = 1000 },
  live = { min_interval_ms = 1000, history = 60, max_cells = 4 },
  templates = { dir = nil },
  history = { enabled = true, max_entries = 2000 },
  aws = { cli = "aws", endpoint_ttl_seconds = 86400, tunnel_ready_ms = 15000, probe_ms = 500,
          login_cmd = { "aws", "sso", "login", "--profile", "{profile}" }, ssl = "require" },
  results = { max_col_width = 40, null_text = "NULL", newline = "↵", align_numbers = true, max_render_rows = 2000 },
  ai = { agent = "claude", agents = { ... }, max_tables = 40, timeout_ms = 180000, instructions = "", dialect = "PostgreSQL 18",
         analyze = { mode = "analyze", include_stats = true }, redact_literals = false, investigate = false },
  schema = { ttl_seconds = 3600, exclude = {} },
  completion = { omnifunc = true, keywords = true },
  keymaps = { query = { ... }, results = { ... } },          -- see lua/dbgrid/config.lua
  icons = { ... },
}
```

Highlight groups (`DbgridCellHeader`, `DbgridCellHeaderActive`, `DbgridNull`,
`DbgridNumber`, `DbgridCurrentColumn`, `DbgridWarn`, `DbgridChanged`,
`DbgridDiffAdd`, `DbgridDiffDelete`, `DbgridDiffChange`, `DbgridLive`, …) link
to standard groups and can be overridden.

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
  explain_json = function(conn, sql, opts, cb) ... end,        -- cb(plan, err); opts.analyze runs inside a rolled back tx
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

The integration tests expect `tests/seed.sql` loaded into the database and
`pg_stat_statements` available. The AWS and agent features are tested against
a fake `aws` CLI and a fake agent in `tests/fixtures`, so no account and no
model are needed.

## Ideas not built yet

- Pinned results and cross-cell references (`-- @depends q1`) with `run all` respecting them
- One long-lived psql per connection so temp tables and `SET` carry across cells, with an interactive commit / rollback
- Live query cancellation via `pg_cancel_backend` for remote sessions that ignore SIGINT
- Result view in a floating window for one-off peeks from any buffer (`:Dbgrid run` on a visual selection)
- Column statistics popup (distinct count, min/max) on demand
- Rails/Django awareness: read `config/database.yml` / `settings.py` for connections
- Adapters for SQLite (`sqlite3`), MySQL (`mysql`), DuckDB
