-- Default configuration. Everything here can be overridden through
-- require("dbgrid").setup({ ... }); tables are deep-merged.
local M = {}

---@class dbgrid.Connection
---@field name string             display name, referenced by notebooks
---@field url string              postgres://user:pass@host:port/db  ($VAR and ${VAR} are expanded)
---@field readonly? boolean       enforce read-only transactions server side (PGOPTIONS)
---@field index_check? "off"|"warn"|"confirm"  per-connection override
---@field statement_timeout_ms? integer          server-side statement_timeout
---@field password_cmd? string    shell command printing the password (1Password, pass, ...)
---@field adapter? string         force an adapter instead of deriving it from the url scheme
---@field env? table<string,string> extra environment for the client process

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
    -- Wrap multi-statement cells in a single transaction.
    transaction_per_cell = true,
    -- Kill the client after this long (nil = wait forever).
    timeout_ms = nil,
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
  },

  schema = {
    -- Re-fetch the schema after this many seconds (also `:Dbgrid schema refresh`).
    ttl_seconds = 3600,
    -- Schemas never listed (pg_catalog & co are always excluded).
    exclude = {},
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
      generate = "<localleader>g",
      ask = "<localleader>a",
      tags = "<localleader>t",
      connection = "<localleader>c",
      schema_refresh = "<localleader>s",
      tables = "<localleader>S",
      describe = "K",
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
      toggle_truncate = "<localleader>w",
      sort = "<localleader>s",
      filter = "<localleader>f",
      yank_cell = "<localleader>yc",
      yank_row_json = "<localleader>yr",
      yank_csv = "<localleader>ya",
      yank_insert = "<localleader>yi",
      ask = "<localleader>a",
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
