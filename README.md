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
  first, and an `UPDATE`/`DELETE` without `WHERE` is called out. A `DELETE`
  or `TRUNCATE` says which other tables it reaches through `ON DELETE
  CASCADE` before it runs. Connections can be marked read-only (enforced
  server side). Cancel goes to the client and, when that is ignored, to the
  server (`pg_cancel_backend`).
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
  keywords, `{{cell}}` references and `:parameters`. `K` describes the table
  or column under the cursor, including which tables reference it; `\k`
  shows its foreign-key tree.
- **Prompt to SQL.** Write `-- ? users who never logged in` in a cell and press
  `<CR>` (or `\g`): the schema and the prompt go to `claude`, `kimi` or
  `codex`, the SQL comes back into the cell for review. Switch the agent with
  `\a`, `:Dbgrid agent kimi` or `-- @agent codex` in a cell.
- **Rails aware.** A Rails project needs no configuration: the databases in
  `config/database.yml` (development, test, multi-database setups) appear as
  connections, and the agent is told about Rails conventions.
- **Plan analysis.** `\A` runs `EXPLAIN ANALYZE` (rolled back), applies a few
  rules (estimates off, sorts spilling to disk, the hot node) and asks the
  agent what is slow, why, and for the fix as SQL you can insert as a cell.
  `\!` explains the last error the same way (`\l` just shows it, no agent).
  `\i` tries the suggested index hypothetically with hypopg and shows the
  cost before and after.
- **Ask about a result.** `\a` in the results pane (`\?` on a cell) sends the
  cell's SQL together with what came back (rows, error, notices, the plan
  when there is one) to the agent with your question — "which of these is
  blocking?", "why is this slow?" — and shows the answer over the grid.
  Follow-ups keep the context.
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
  interface; PostgreSQL and SQLite ship, others plug in.

## Requirements

- Neovim 0.10+
- `psql` on `PATH` for PostgreSQL (macOS: `brew install libpq`, then put its
  `bin` on `PATH`), `sqlite3` for SQLite
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for pickers
  with previews (falls back to `vim.ui.select`), the `claude` / `kimi` /
  `codex` CLI for prompt-to-SQL and plan analysis, a SQL formatter (see
  Formatting), the `aws` CLI v2 plus the Session Manager plugin for RDS
  connections, the `hypopg` extension on the server for `\i`.

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
| `lock_timeout_ms` | server-side `lock_timeout`; recommended on any connection you run DDL on |
| `password_cmd` | shell command whose output becomes `PGPASSWORD` (1Password, `pass`, …) |
| `env` | extra environment for the client process |
| `adapter` | force `"postgres"` or `"sqlite"` instead of deriving it from the url |
| `aws` | RDS / Aurora block, see below |
| `tunnel` | `{ kind = "ssh" | "cmd" | "ssm", ... }`, see below |
| `ssl`, `sslrootcert` | `sslmode` used through a tunnel (`"require"`, or `"verify-full"` with the CA bundle) |
| `ai = false` | never send this connection's SQL, plans or schema to an agent |
| `session = true` | keep one psql alive across runs (see Running queries) |

`~/.pgpass` and `~/.pg_service.conf` work as usual because the real `psql`
does the connecting. When you paste a URL with a password into `+ add
connection`, the plugin offers to move the password to `~/.pgpass` instead of
keeping it in its own JSON.

Saved connections can be changed later. In the connection picker `<C-e>`
edits the one under the cursor and `<C-x>` removes it (snacks.picker);
`:Dbgrid connections edit [name]` and `:Dbgrid connections remove [name]` do
the same anywhere. Every prompt of the edit is prefilled: name, URL (for an
AWS entry: bastion and secret), read-only and scope. Renaming a connection
updates the open notebooks that used it. `:Dbgrid connections file` opens the
JSON itself for the fields the prompts do not cover (`tunnel`, `env`,
timeouts); saving it drops the cached resolved connections. Connections from
`setup()`, the environment or `database.yml` are changed at their source.

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
    bastion = "i-0123456789abcdef0",  -- SSM target that can reach the database port: an id, a Name tag or "auto"
    secret  = "prod/db",              -- Secrets Manager id or ARN; optional when RDS manages the master password
    login_cmd = { "company-aws-login", "--profile", "{profile}" },  -- default: aws sso login
    -- auth = "iam", user = "app",    -- IAM database authentication instead of a secret
    -- database = "app",              -- default: the secret's dbname/db, else the cluster's initial database, else asked once
  },
  index_check = "confirm",
}
```

One entry becomes two in the picker, `prod/writer` and `prod/reader` (one per
replica on plain RDS: `prod/reader`, `prod/reader-2`, …). Readers are
read-only. `-- @conn prod/reader` works per cell, and `prod` alone means the
writer.

RDS-managed master secrets hold only a username and a password, so the
database comes from `aws.database`, else the secret's `dbname` (`db` and
`database` keys work too), else the cluster's initial database
(`DatabaseName`). When none of those exists you are asked once, and the
answer is saved on the connection.

On the first run the plugin calls `describe-db-clusters` (or
`describe-db-instances`) and caches the endpoints for a day, starts
`aws ssm start-session` with the `AWS-StartPortForwardingSessionToRemoteHost`
document to a local port, reads the secret and passes the password to psql
through the environment only. The URL psql gets keeps the real host name with
`hostaddr=127.0.0.1&port=<local>`, so `sslmode=verify-full` and `~/.pgpass`
keep working. Before every run the tunnel is probed with a PostgreSQL
handshake, so a dead SSM session (idle timeout is 20 minutes by default),
which still accepts connections on its local port but forwards nothing, is
replaced before psql runs. Should psql still fail to reach the server, the
tunnel is rebuilt and the cell runs once more. Tunnels die with Neovim;
`aws tunnels` lists them with their age.

The bastion is an instance id, the `Name` tag of an instance
(`bastion = "bastion-prod"`) or `"auto"`. A name or `auto` is looked up among
the account's SSM-managed instances (`ssm describe-instance-information`, plus
`ec2 describe-instances` for the tags and VPCs) when the tunnel is first
started and cached with the endpoints, so a jumpbox replaced by its autoscaling
group is found again: a tunnel that fails to start drops the cached id, and so
does `aws refresh`. `auto` takes the online instance whose name contains one
of `aws.bastion_names` (`{ "bastion", "jump" }`), preferring the database's
VPC. A role that may not call `ssm:DescribeInstanceInformation` gets the
running EC2 instances by name instead (their SSM status unknown); when
neither listing works, the instance id is asked for and the prompt says why.

Expired credentials are recognised from the CLI's stderr; the plugin runs
`aws.login_cmd` (global, `{profile}` substituted; a company CLI goes here or
per connection in `aws.login_cmd`) in a terminal split, waits for it, and
retries. Without `bastion` the plugin connects directly. `aws.document` and
`aws.parameters` cover custom SSM documents.

Commands: `:Dbgrid aws add` (interactive: profile, region, cluster, bastion,
secret; the bastion is chosen from the SSM-managed instances, and one clear
online jumpbox in the database's VPC is taken without asking; the database is
asked for only when the secret names none; when the region has no database
the other regions are searched and the hits are offered with their region,
and a listing the role may not make is reported rather than shown as empty), `aws login`,
`aws refresh` (drop the endpoint cache), `aws tunnels` (list / kill), `aws status` (instance status, engine version, pending
maintenance, five CloudWatch metrics over the last five minutes), `aws events`
(last day of RDS events), `aws bluegreen` (blue/green deployments and their
switchover status). `:checkhealth dbgrid` reports the CLI, the Session
Manager plugin, the caller identity per profile and every tunnel.

### A database reached by host (PrivateLink, another account)

```lua
{ name = "jobs", aws = { profile = "dev-privileged", region = "ap-southeast-2",
                         secret = "jobs/db", bastion = "bastion-dev" } }
```

When the RDS lives in another account and is reached through a VPC endpoint,
there is nothing to describe: leave out `cluster` / `instance` and the plugin
takes the host from the secret (`hostWrite`, `hostRead`, `port`, `db`) or from
`host` / `read_host` / `port` in the aws block, and forwards to it through the
bastion. The secret is read once per session for both the endpoints and the
credentials. Everything else works as for a cluster: the SSM tunnel, expired
credentials, `writer` and a `reader` when the read host differs, `aws
tunnels`, `:checkhealth`. `aws status`, `aws events` and `aws bluegreen` need
a describable `cluster` or `instance` and say so. `:Dbgrid aws add` offers
this as the last entry of the cluster list ("reach the database by host
name"); host and database are asked for only when the secret does not carry
them.

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
  connection; `-- @agent name` sends the cell's prompt to another agent;
  `-- @dryrun` runs a write inside a rolled back transaction; `-- @every 5s`
  makes the cell live; `-- @param name = value` declares a parameter.
- `{{name}}` inside the SQL inlines the named cell as a subquery; `:name` (or
  `{{name}}` when no cell is called that) is a parameter (see Parameters).

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
  sides, and whether green accepts writes. Every cell only reads, so the
  notebook is safe to leave running against production. `:Dbgrid schema diff
  blue green` covers the DDL gap, since logical replication carries none.

Your own templates go in `templates.dir`; a template is a notebook file with
a `-- template-name:` / `-- template-tags:` / `-- template-description:` /
`-- template-connections:` header.

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
| `\R` | run every cell, dependencies first (stops at the first error) |
| `\e` / `\E` | `EXPLAIN` / `EXPLAIN ANALYZE` with findings (analyze runs inside a rolled-back transaction) |
| `\x` | cancel the running query or generation |
| `]c` / `[c` / `]C` / `[C` | next / previous / last / first cell |
| `\n` / `\o` / `\O` | new cell at the end / below / above |
| `\d` | delete the cell and its cached result |
| `\y` | yank the cell body |
| `\m` | rename the cell |
| `\D` | clone the cell below itself |
| `\l` | show the last error (message, position, detail, hint; `y` yanks) |
| `\=` | format the cell's SQL |
| `\p` | edit parameter values |
| `\g` | generate SQL from the `-- ?` prompt (asks for one when missing) |
| `\a` | pick the coding agent for this notebook |
| `\A` | analyze the plan with the agent (`EXPLAIN ANALYZE`, rolled back) |
| `\!` | explain the last error with the agent |
| `\?` | ask the agent about the cell's query and its result |
| `\i` | try the suggested index hypothetically (hypopg) |
| `\H` | query history |
| `\t` | edit tags |
| `\c` | pick the connection |
| `\s` / `\S` | refresh the schema cache / pick a table (inserts the name) |
| `\b` | browse the schema document in the results pane |
| `K` | describe the table or column under the cursor |
| `\k` | foreign-key relations of the table under the cursor |
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
| `\d` | diff against the previous run of the cell (toggle) |
| `\h` | sparkline of the column under the cursor across live ticks |
| `\yc` / `\yr` / `\ya` / `\yi` / `\yp` | yank value / row as JSON / result as CSV / row as INSERT / plan JSON |
| `\a` | ask the agent about the query and the result (again for a follow-up) |
| `<Tab>` / `<S-Tab>` | next / previous column (next / previous row in record view) |
| `]c` / `[c` | next / previous cell |
| `\<Tab>` | focus the query pane |
| `q` | close the notebook |

In the schema document `<CR>` folds and unfolds a table, `K` describes it,
`<Tab>` / `<S-Tab>` jump between tables, `\f` filters tables by name, `\yc`
yanks the table or column name, and `/`, `zo`, `zc`, `zR`, `zM` work as they
do everywhere.

## Commands

`:Dbgrid` alone opens the notebook picker; there `<C-x>` deletes the notebook
under the cursor, or every notebook marked with `<Tab>` (snacks.picker), after
one confirmation. Subcommands (with completion):

| command | |
|---|---|
| `open [name]` | open a notebook (picker when no name) |
| `new [title]` | create one |
| `new --template <name> [title]` | create one from a template (`templates` picks) |
| `clone-cell` / `last-error` | clone the cell / show its last error |
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
| `connections [edit|remove|file] [name]` / `connect [name]` | pick, edit or remove a saved connection / set the notebook's connection |
| `run` / `run all` | run the current cell / all cells (dependencies first) |
| `explain [analyze]` | plan of the current cell |
| `format [all]` | format the current cell / every cell |
| `param [name [value]]` / `params` | show or set a parameter value / edit them all |
| `agent [name\|default]` | pick or set the coding agent of this notebook |
| `ask <prompt>` | add a prompt to the current cell and generate |
| `review [question]` | ask the agent about the current cell's query and result |
| `schema refresh` / `schema tables` / `schema view` | refresh the cache / pick a table / toggle the schema document |
| `describe <table>` | describe a table |
| `relations [table]` | foreign-key tree of a table (the one under the cursor when omitted) |
| `rename <title>` / `delete` / `close` | notebook management |
| `export csv|json|md [path]` | current result (or the whole notebook as markdown) to the clipboard or a file |
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
  `DELETE` has no `WHERE`. The prompt says how many rows an `UPDATE` /
  `DELETE` touches (the same `WHERE` as a `SELECT count(*)`,
  `query.preview_writes`). `query.confirm_writes = false` turns it off.
- **Cascade check:** a `DELETE` is looked up in the schema cache before the
  prompt. Tables that lose rows through `ON DELETE CASCADE` (followed
  transitively) are listed as a warning, e.g. `DELETE on users cascades to
  invoices, invoice_lines (via invoices)`; tables that get `SET NULL` and
  tables whose rows would make the delete fail (`RESTRICT` / `NO ACTION`)
  are listed as notes. `TRUNCATE ... CASCADE` lists what else is truncated;
  a `TRUNCATE` without it says which referencing tables would make it fail.
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

## Plan analysis, errors and hypothetical indexes

`\A` (`:Dbgrid analyze`) takes the cell under the cursor, runs
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

`\!` sends the SQL, the error with its hint and detail, and the tables
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

## Ask about a result

Diagnostic queries (`pg_stat_activity`, lock waits, `pg_stat_user_tables`,
an `EXPLAIN ANALYZE` that does not look right) are easier to read with a
second pair of eyes. Press `\a` in the results pane (or `\?` on the cell in
the query pane) and type a question; leave it empty for "what does this
result show, anything worth attention?". The agent gets, in one prompt:

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
[question]` asks one from the command line. The notebook's agent (`\a` in the
query pane, `-- @agent`) is used, `ai = false` on a connection turns it off,
`ai.investigate` gives it the `dbgrid-query` helper, and
`ai.redact_literals` redacts the SQL and the plan — the rows are sent as
they are, since they are what the question is about.

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

## Schema, indexes, completion

The schema (tables, columns with types, primary/foreign keys, indexes, enums)
is fetched once per connection with one catalog query, cached on disk and
refreshed after `schema.ttl_seconds` or with `\s`.

Four ways to look at it, from quick to thorough:

- `K` on `users`, `u.email` or a bare column name opens a float with the
  columns, defaults, foreign keys (with their `ON DELETE` rule), indexes and
  the tables that reference that table.
- `\k` (or `:Dbgrid relations [table]`) shows the foreign-key neighbourhood
  of the table as a text tree, `schema.relations_depth` hops in each
  direction, ending with what a `DELETE` on it would reach (see below).
- `\S` opens a table picker; the preview is the same description, and
  choosing a table inserts its name.
- `\b` turns the results pane into a schema document: every table is one fold
  showing its columns (type, `PK`, `→ plans(id)`, `not null`, defaults),
  its indexes (`⌗ users_email_key (email) UNIQUE`) and comments. Tables the
  current cell refers to start unfolded, the rest folded, so a big database
  reads like a tree; `/` searches through everything (folds open on a match),
  `\f` narrows the list by table name. The document stays while you move
  between cells; running a cell brings its result back, and so does `\b`.

This is deliberately not a tree widget: a flat, foldable document is
searchable with the keys you already have, shows a whole table at once, and
needs no expand-this-then-that clicking.

The relations tree, for a table in the middle of a schema:

```
users  (~5,000 rows)

References:
  → plans (plan_id → id)

Referenced by:
  ← invoices (user_id)  on delete cascade
    ← invoice_lines (invoice_id)  on delete cascade
  ← orders (user_id)
  ← sessions (user_id)  on delete set null

DELETE on users cascades to invoices, invoice_lines (via invoices)
DELETE on users sets NULL / default in sessions.user_id
DELETE on users fails while rows in orders.user_id still reference it
```

On `u.email` the tree is for whatever `u` aliases in the current cell.

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
  query = { limit = 500, confirm_writes = true, preview_writes = true, dry_run = false, ddl_warnings = true,
            transaction_per_cell = true, timeout_ms = nil, session = false,
            server_cancel = true, cancel_grace_ms = 1500 },
  format = { on_save = false, formatter = "auto", keyword_case = "keep", width = 100, indent = 2,
             order = { "pg_format", "sql-formatter", "sqlfluff", "sqlformat" }, commands = { ... } },
  index_check = { mode = "warn", min_rows = 10000 },        -- "off" | "warn" | "confirm"
  analyze_rules = { estimate_ratio = 10, spill = true, hot_node = true, min_rows = 1000 },
  live = { min_interval_ms = 1000, history = 60, max_cells = 4 },
  templates = { dir = nil },
  history = { enabled = true, max_entries = 2000 },
  aws = { cli = "aws", endpoint_ttl_seconds = 86400, tunnel_ready_ms = 15000, probe_ms = 500, handshake_ms = 3000,
          login_cmd = { "aws", "sso", "login", "--profile", "{profile}" }, ssl = "require",
          bastion_names = { "bastion", "jump" } },
  results = { max_col_width = 40, null_text = "NULL", newline = "↵", align_numbers = true, max_render_rows = 2000 },
  ai = { agent = "claude", agents = { ... }, max_tables = 40, max_result_rows = 100, timeout_ms = 180000, instructions = "", dialect = "PostgreSQL 18",
         analyze = { mode = "analyze", include_stats = true }, redact_literals = false, investigate = false },
  schema = { ttl_seconds = 3600, exclude = {}, relations_depth = 3 },
  completion = { omnifunc = true, keywords = true },
  keymaps = { query = { ... }, results = { ... } },          -- see lua/dbgrid/config.lua
  icons = { ... },
}
```

Highlight groups (`DbgridCellHeader`, `DbgridCellHeaderActive`, `DbgridNull`,
`DbgridNumber`, `DbgridCurrentColumn`, `DbgridWarn`, `DbgridSchemaTable`,
`DbgridSchemaIndex`, `DbgridFindingWarn`, `DbgridChanged`, `DbgridDiffAdd`,
`DbgridDiffDelete`, `DbgridDiffChange`, `DbgridLive`, …) link to standard
groups and can be overridden.

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
  explain_json = function(conn, sql, opts, cb) ... end,        -- cb(plan, err); opts.analyze runs inside a rolled back tx
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

The Postgres tests expect `tests/seed.sql` loaded into the database
(`users`, `plans`, `invoices`) and `pg_stat_statements` available. The AWS
and agent features are tested against a fake `aws` CLI and a fake agent in
`tests/fixtures`, so no account and no model are needed.

## Ideas not built yet

- Pinned results
- Result view in a floating window for one-off peeks from any buffer (`:Dbgrid run` on a visual selection)
- Column statistics popup (distinct count, min/max) on demand
- Django awareness: read `settings.py` for connections
- Adapters for MySQL (`mysql`), DuckDB
