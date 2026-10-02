-- Default configuration. Everything here can be overridden through
-- require("dbgrid").setup({ ... }); tables are deep-merged.
local M = {}

---@class dbgrid.Connection
---@field name string             display name, referenced by notebooks
---@field url string              postgres://user:pass@host:port/db or sqlite:path/to.db ($VAR and ${VAR} are expanded)
---@field readonly? boolean       enforce read-only transactions server side (PGOPTIONS)
---@field index_check? "off"|"warn"|"confirm"  per-connection override
---@field statement_timeout_ms? integer          server-side statement_timeout
---@field password_cmd? string    shell command printing the password (1Password, pass, ...)
---@field adapter? string         force an adapter instead of deriving it from the url scheme ("postgres", "sqlite")
---@field env? table<string,string> extra environment for the client process
---@field lock_timeout_ms? integer server-side lock_timeout (recommended for DDL on a busy database)
---@field aws? table              AWS RDS / Aurora block: profile, region, cluster|instance, bastion, secret, auth, ...
---@field aws_role? string        "writer" | "reader" | "reader-N", set on the expanded picker entries
---@field tunnel? table           generic port forward: { kind = "ssh"|"cmd"|"ssm", ... } (see README)
---@field ssl? string             sslmode for tunnelled connections ("require" | "verify-full")
---@field sslrootcert? string     CA bundle for sslmode=verify-full
---@field ai? boolean             false: never send this connection's SQL, plans or schema to an agent
---@field session? boolean        keep one psql alive across runs (overrides query.session)
---@field parent? string          name of the declared connection an expanded entry came from
---@field _resolved? boolean      set on the effective copy produced by connections.resolve
---@field declared_url? string    the url as declared, kept on the effective copy

---@class dbgrid.Config
M.defaults = {
  ---@type dbgrid.Connection[]
  connections = {},
  -- Name of the connection used by new notebooks (nil = ask).
  default_connection = nil,
  -- Read DATABASE_URL (and friends) from these files in the project root.
  env_files = { ".env", ".env.local", ".env.development", ".env.development.local" },
  env_vars = { "DATABASE_URL", "DB_URL", "POSTGRES_URL", "PG_URL" },

  storage = {
    -- "auto": use <root>/.dbgrid when it exists, else the data dir.
    -- "project": always <root>/<project_dir>.  "data": always the data dir.
    mode = "auto",
    project_dir = ".dbgrid",
    data_dir = vim.fn.stdpath("data") .. "/dbgrid",
    -- How many result rows are cached on disk per cell (0 disables the cache).
    cache_rows = 500,
  },

  layout = {
    -- Where the results pane goes relative to the query pane.
    results = "left", ---@type "left"|"right"|"bottom"
    -- Fraction of the editor taken by the results pane.
    size = 0.5,
    -- Open every notebook in its own tabpage (like an octo review).
    tab = true,
  },

  query = {
    -- SELECTs without a LIMIT/FETCH get this one appended. nil disables.
    limit = 500,
    -- Ask before running INSERT/UPDATE/DELETE/DDL.
    confirm_writes = true,
    -- Count the rows an UPDATE / DELETE would touch and show it in the confirmation.
    preview_writes = true,
    -- Run writes inside a transaction that is rolled back, showing RETURNING * (also `-- @dryrun` per cell).
    dry_run = false,
    -- Warn about DDL that takes heavy locks (CREATE INDEX without CONCURRENTLY, ALTER TABLE, ...).
    ddl_warnings = true,
    -- Wrap multi-statement cells in a single transaction.
    transaction_per_cell = true,
    -- Kill the client after this long (nil = wait forever).
    timeout_ms = nil,
    -- Keep one psql per connection alive across runs (temp tables and SET carry over,
    -- the connection handshake is paid once). Also per connection: `session = true`.
    session = false,
    -- When a cancel (SIGINT) has not stopped the query after `cancel_grace_ms`,
    -- ask the server to cancel it (pg_cancel_backend) through a second
    -- connection; for sessions behind proxies that swallow cancel requests.
    server_cancel = true,
    cancel_grace_ms = 1500,
  },

  format = {
    -- Reformat every cell's SQL when the notebook is written.
    on_save = false,
    -- "auto": conform.nvim when it has a formatter for the sql filetype, else
    -- the first of `order` found on PATH, else the built-in formatter.
    -- Also: "builtin", "conform", a name from `commands`, or { cmd = { ... } }.
    formatter = "auto", ---@type "auto"|"builtin"|"conform"|string|{ cmd: string[] }
    order = { "pg_format", "sql-formatter", "sqlfluff", "sqlformat" },
    -- External formatters: SQL on stdin, formatted SQL on stdout. `{dialect}`
    -- becomes "postgresql" or "sqlite" depending on the connection.
    commands = {
      pg_format = { "pg_format" },
      ["sql-formatter"] = { "sql-formatter", "-l", "{dialect}" },
      sqlfluff = { "sqlfluff", "format", "--dialect", "postgres", "-" },
      sqlformat = { "sqlformat", "-r", "-" },
    },
    -- Built-in formatter options.
    keyword_case = "keep", ---@type "keep"|"upper"|"lower"
    width = 100,
    indent = 2,
    timeout_ms = 5000,
  },

  -- Rails projects: connections from config/database.yml (no setup needed).
  rails = {
    enabled = true,
    environments = { "development", "test" },
  },

  -- `-- @every 5s` cells.
  live = {
    -- Smallest interval accepted.
    min_interval_ms = 1000,
    -- Ticks kept in memory per live cell (for the change highlight and the sparkline).
    history = 60,
    -- Live cells per notebook.
    max_cells = 4,
  },

  -- Rules applied to EXPLAIN ANALYZE plans (analyze command, plan view).
  analyze_rules = {
    -- Planner estimate off by more than this factor.
    estimate_ratio = 10,
    -- Flag sorts and hashes that spill to disk.
    spill = true,
    -- Mark the node with the highest exclusive time.
    hot_node = true,
    -- Ignore nodes smaller than this many rows.
    min_rows = 1000,
  },

  -- Bundled notebooks (`:Dbgrid new --template <name>`).
  templates = {
    -- Extra directory with your own *.sql templates.
    dir = nil,
  },

  -- Every statement run is appended to <store>/history.jsonl.
  history = {
    enabled = true,
    max_entries = 2000,
  },

  -- AWS RDS / Aurora connections (connections with an `aws` block).
  aws = {
    cli = "aws",
    -- Endpoint cache lifetime.
    endpoint_ttl_seconds = 86400,
    -- How long to wait for the local port after spawning a tunnel.
    tunnel_ready_ms = 15000,
    -- Timeout of the pre-run tunnel probe: a plain connect to the local port, or,
    -- for PostgreSQL, the round trip of a handshake to the server behind the tunnel.
    probe_ms = 500,
    handshake_ms = 3000,
    -- Command that refreshes credentials; "{profile}" is substituted. A company CLI goes here.
    login_cmd = { "aws", "sso", "login", "--profile", "{profile}" },
    -- Default sslmode through the tunnel ("require" | "verify-full", the latter needs sslrootcert).
    ssl = "require",
    -- Name tags (substrings, case-insensitive) that mark an SSM-managed instance as a jumpbox:
    -- `aws add` picks a matching instance as the bastion, and `bastion = "auto"` resolves to one.
    bastion_names = { "bastion", "jump" },
  },

  index_check = {
    -- "warn": run and show the warning. "confirm": ask first. "off": skip.
    mode = "warn", ---@type "off"|"warn"|"confirm"
    -- Only complain about sequential scans on tables with at least this many rows.
    min_rows = 10000,
  },

  results = {
    max_col_width = 40,
    null_text = "NULL",
    -- Replace newlines inside values with this in the grid.
    newline = "↵",
    -- Right align numeric columns.
    align_numbers = true,
    -- Row limit rendered in the grid (cached rows are already capped by storage.cache_rows).
    max_render_rows = 2000,
  },

  ai = {
    -- Which agent generates SQL from `-- ?` prompts.
    agent = "claude", ---@type "claude"|"kimi"|"codex"|string
    -- Agent commands. `{prompt}` is replaced with the prompt when stdin is false;
    -- `{output}` with a temp file path the agent should write its answer to.
    agents = {
      claude = {
        cmd = {
          "claude",
          "-p",
          "--output-format",
          "text",
          "--no-session-persistence",
          "--max-turns",
          "3",
          "--disallowedTools",
          "Bash,Edit,Write,NotebookEdit,Read,Glob,Grep,Task,WebFetch,WebSearch",
        },
        stdin = true,
      },
      kimi = { cmd = { "kimi", "--print", "-p", "{prompt}" }, stdin = false },
      codex = {
        cmd = { "codex", "exec", "--skip-git-repo-check", "-s", "read-only", "-o", "{output}", "-" },
        stdin = true,
      },
    },
    -- How many tables of the schema are described to the agent.
    max_tables = 40,
    -- How many result rows go to the agent when asking about a result.
    max_result_rows = 100,
    timeout_ms = 180000,
    -- Extra instructions appended to every prompt (house style, naming, ...).
    instructions = "",
    -- Target dialect reported to the agent.
    dialect = "PostgreSQL 18",
    -- `:Dbgrid analyze`: "analyze" runs EXPLAIN ANALYZE (rolled back); "estimate" only EXPLAIN.
    analyze = { mode = "analyze", include_stats = true },
    -- Replace string and numeric literals in SQL and plans before they leave the machine.
    redact_literals = false,
    -- Give the agent a `dbgrid-query` helper bound to the connection (read-only) so it can run its own queries.
    investigate = false,
  },

  schema = {
    -- Re-fetch the schema after this many seconds (also `:Dbgrid schema refresh`).
    ttl_seconds = 3600,
    -- Schemas never listed (pg_catalog & co are always excluded).
    exclude = {},
    -- How many foreign-key hops `:Dbgrid relations` follows in each direction.
    relations_depth = 3,
  },

  completion = {
    -- Register an omnifunc on notebook buffers (blink/cmp sources are separate modules).
    omnifunc = true,
    keywords = true,
  },

  -- Buffer-local keymaps. Set a value to false to leave a key unmapped.
  keymaps = {
    query = {
      run = { "<CR>", "<localleader>r" },
      run_all = "<localleader>R",
      explain = "<localleader>e",
      explain_analyze = "<localleader>E",
      cancel = "<localleader>x",
      next_cell = "]c",
      prev_cell = "[c",
      first_cell = "[C",
      last_cell = "]C",
      new_cell = "<localleader>n",
      new_cell_below = "<localleader>o",
      new_cell_above = "<localleader>O",
      delete_cell = "<localleader>d",
      yank_cell = "<localleader>y",
      rename_cell = "<localleader>m",
      clone_cell = "<localleader>D",
      last_error = "<localleader>l",
      generate = "<localleader>g",
      ask = "<localleader>?",
      tags = "<localleader>t",
      connection = "<localleader>c",
      schema_refresh = "<localleader>s",
      tables = "<localleader>S",
      schema_view = "<localleader>b",
      describe = "K",
      format = "<localleader>=",
      params = "<localleader>p",
      agent = "<localleader>a",
      analyze = "<localleader>A",
      explain_error = "<localleader>!",
      try_index = "<localleader>i",
      history = "<localleader>H",
      relations = "<localleader>k",
      focus_results = "<localleader><Tab>",
      zoom = "<localleader>z",
      close = "<localleader>q",
      textobj_inner = "ic",
      textobj_around = "ac",
    },
    results = {
      inspect = { "<CR>", "K" },
      record_view = "<localleader>v",
      plan_view = "<localleader>p",
      schema_view = "<localleader>b",
      toggle_truncate = "<localleader>w",
      sort = "<localleader>s",
      filter = "<localleader>f",
      diff = "<localleader>d",
      history = "<localleader>h",
      yank_cell = "<localleader>yc",
      yank_row_json = "<localleader>yr",
      yank_csv = "<localleader>ya",
      yank_insert = "<localleader>yi",
      ask = "<localleader>a",
      yank_plan = "<localleader>yp",
      next_col = "<Tab>",
      prev_col = "<S-Tab>",
      next_cell = "]c",
      prev_cell = "[c",
      focus_query = "<localleader><Tab>",
      zoom = "<localleader>z",
      close = "q",
    },
  },

  icons = {
    ok = "✓",
    error = "✗",
    running = "●",
    idle = "○",
    stale = "↻",
    warn = "⚠",
    generated = "✦",
    tag = "#",
    connection = "⛁",
    cell = "▸",
    agent = "✦",
    param = ":",
    table = "▤",
    index = "⌗",
    live = "◉",
    changed = "Δ",
  },
}

---@type dbgrid.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- keymaps given as a single string are fine; normalise lists later at map time
  return M.options
end

---@return dbgrid.Config
function M.get()
  return M.options
end

return M
