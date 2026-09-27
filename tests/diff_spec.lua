local H = _G.H
local schema = require("dbgrid.schema")
local diff = require("dbgrid.diff")

---Build a dbgrid.SchemaData like the adapter would, with by_name filled in.
local function data(tables, enums)
  local d = { schemas = { "public" }, tables = tables, enums = enums or {}, functions = {}, by_name = {} }
  for _, t in ipairs(tables) do
    t.schema = t.schema or "public"
    t.columns = t.columns or {}
    t.indexes = t.indexes or {}
    t.constraints = t.constraints or {}
    d.by_name[t.name:lower()] = t
    d.by_name[(t.schema .. "." .. t.name):lower()] = t
  end
  return d
end

local function users()
  return { name = "users", rows = 10, columns = { { name = "id", type = "integer", notnull = true } } }
end

local ORDERS_X_A = "CREATE INDEX orders_x ON public.orders USING btree (status)"
local ORDERS_X_B = "CREATE INDEX orders_x ON public.orders USING btree (status, amount)"
local CUSTOMER_IDX = "CREATE INDEX orders_customer_id_idx ON public.orders USING btree (customer_id)"

local function schema_a()
  return data({
    {
      name = "orders",
      rows = 100,
      columns = {
        { name = "id", type = "integer", notnull = true },
        { name = "amount", type = "numeric(10,2)", notnull = true },
        { name = "note", type = "text", notnull = false },
        { name = "status", type = "text", notnull = true, default = "'new'" },
        { name = "old_col", type = "integer", notnull = false },
      },
      indexes = { { name = "orders_x", unique = false, primary = false, def = ORDERS_X_A, columns = { "status" } } },
      constraints = {
        { name = "orders_pkey", type = "p", def = "PRIMARY KEY (id)", columns = { "id" } },
        { name = "orders_fk", type = "f", def = "FOREIGN KEY (customer_id) REFERENCES customers(id)", columns = {} },
      },
    },
    { name = "legacy_flags", rows = 0, columns = { { name = "id", type = "integer" } } },
    users(),
  }, {
    { name = "order_status", values = { "new", "paid", "archived" } },
    { name = "old_enum", values = { "x" } },
  })
end

local function schema_b()
  return data({
    {
      name = "orders",
      rows = 100,
      columns = {
        { name = "id", type = "integer", notnull = true },
        { name = "amount", type = "numeric(12,2)", notnull = true },
        { name = "note", type = "text", notnull = true },
        { name = "status", type = "text", notnull = true, default = "'open'" },
        { name = "email", type = "text", notnull = false },
      },
      indexes = {
        { name = "orders_x", unique = false, primary = false, def = ORDERS_X_B, columns = { "status", "amount" } },
        { name = "orders_customer_id_idx", unique = false, primary = false, def = CUSTOMER_IDX, columns = {} },
      },
      constraints = { { name = "orders_pkey", type = "p", def = "PRIMARY KEY (id)", columns = { "id" } } },
    },
    {
      name = "invoices",
      rows = 0,
      columns = { { name = "id", type = "integer", notnull = true }, { name = "total", type = "numeric" } },
    },
    users(),
  }, {
    { name = "order_status", values = { "new", "paid", "refunded" } },
    { name = "new_enum", values = { "y", "z" } },
  })
end

H.describe("schema.diff", function()
  H.it("lists every kind of difference", function()
    local d = schema.diff(schema_a(), schema_b(), { a_name = "dev", b_name = "prod" })
    local w = #"orders_customer_id_idx"
    local function name(s)
      return s .. string.rep(" ", w - #s)
    end
    H.eq(d.lines, {
      "dev → prod: 13 differences",
      "+ table invoices (2 columns)",
      "- table legacy_flags",
      "~ table orders",
      "  ~ column " .. name("amount") .. "  numeric(10,2) → numeric(12,2)",
      "  ~ column " .. name("note") .. "  nullable → not null",
      "  ~ column " .. name("status") .. "  default 'new' → default 'open'",
      "  + column " .. name("email") .. "  text",
      "  - column " .. name("old_col") .. "  integer",
      "  ~ index " .. name("orders_x") .. "  " .. ORDERS_X_A .. " → " .. ORDERS_X_B,
      "  + index " .. name("orders_customer_id_idx") .. "  " .. CUSTOMER_IDX,
      "  - constraint orders_fk",
      "+ enum new_enum (y, z)",
      "- enum old_enum",
      "~ enum order_status: + refunded, - archived",
    })
    H.eq(d.changes, 13)
    H.eq(d.tables, {
      { name = "invoices", lnum = 2 },
      { name = "legacy_flags", lnum = 3 },
      { name = "orders", lnum = 4 },
    })
    for _, t in ipairs(d.tables) do
      H.matches(d.lines[t.lnum], "^[%+%-~] table " .. t.name .. "")
    end
  end)
  H.it("reports matching schemas and a single difference", function()
    local same = schema.diff(schema_a(), schema_a())
    H.eq(same, { lines = { "a and b: schemas match (3 tables)" }, changes = 0, tables = {} })
    local b = schema_a()
    b.tables[3].columns[1].type = "bigint"
    local one = schema.diff(schema_a(), b)
    H.eq(one.lines[1], "a → b: 1 difference")
    H.eq(one.lines[3], "  ~ column id  integer → bigint")
    H.eq(one.tables, { { name = "users", lnum = 2 } })
    -- other schemas keep their prefix
    local c = schema_a()
    c.tables[3].schema = "audit"
    H.eq(schema.diff(schema_a(), c).lines, {
      "a → b: 2 differences",
      "+ table audit.users (1 columns)",
      "- table users",
    })
  end)
end)

H.describe("schema.settings_diff", function()
  local ra = {
    { "work_mem", "4096", "kB", "configuration file" },
    { "shared_buffers", "16384", "8kB", "configuration file" },
    { "only_a", "on", vim.NIL, "session" },
    { "same", "1", vim.NIL, "session" },
    { "statement_timeout", "0", "ms", "default" },
  }
  local rb = {
    { "work_mem", "16384", "kB", "configuration file" },
    { "shared_buffers", "32768", "8kB", "configuration file" },
    { "only_b", "off", vim.NIL, "session" },
    { "same", "1", vim.NIL, "session" },
    { "statement_timeout", "0", "ms", "default" },
  }
  H.it("compares values with units", function()
    H.matches(schema.SETTINGS_SQL, "^select name, setting, unit, source from pg_settings")
    local s = schema.settings_diff(ra, rb, { a_name = "dev", b_name = "prod" })
    H.eq(s.changes, 4)
    H.eq(s.lines, {
      "dev → prod: 4 differences",
      "- only_a          on",
      "+ only_b          off",
      "~ shared_buffers  131072kB → 262144kB",
      "~ work_mem        4096kB → 16384kB",
    })
    H.eq(schema.settings_diff(ra, ra), { lines = { "a and b: settings match (5 settings)" }, changes = 0 })
  end)
end)

local before = {
  columns = { "id", "email", "balance" },
  rows = { { "1", "a@x", "1.5" }, { "2", "b@x", vim.NIL }, { "3", "c@x", "3" } },
}
local after = {
  columns = { "id", "email", "balance" },
  rows = { { "1", "a@x", "1.5" }, { "2", "b@x", "9" }, { "4", "d@x", "4" } },
}

H.describe("diff.rows", function()
  H.it("matches rows by key", function()
    local d = diff.rows(before, after, { key = { 1 } })
    H.eq(d.same, 1)
    H.eq(d.added, { { "4", "d@x", "4" } })
    H.eq(d.removed, { { "3", "c@x", "3" } })
    H.eq(d.changed, { { before = { "2", "b@x", vim.NIL }, after = { "2", "b@x", "9" }, cols = { 3 } } })
    H.eq(d.columns_changed, false)
    H.eq(d.key, { 1 })
    H.eq(d.columns, after.columns)
    -- duplicate keys pair up in order, leftovers are added / removed
    local dup = diff.rows(
      { columns = { "k", "v" }, rows = { { "1", "a" }, { "1", "b" }, { "1", "c" } } },
      { columns = { "k", "v" }, rows = { { "1", "a" }, { "1", "x" } } },
      { key = { 1 } }
    )
    H.eq(dup.same, 1)
    H.eq(#dup.changed, 1)
    H.eq(dup.removed, { { "1", "c" } })
  end)
  H.it("compares whole rows without a key", function()
    local d = diff.rows(before, after, {})
    H.eq(d.same, 1)
    H.eq(d.added, { { "2", "b@x", "9" }, { "4", "d@x", "4" } })
    H.eq(d.removed, { { "2", "b@x", vim.NIL }, { "3", "c@x", "3" } })
    H.eq(d.changed, {})
    H.eq(d.key, nil)
    local dup = diff.rows({ columns = { "a" }, rows = { { "1" }, { "1" } } }, { columns = { "a" }, rows = { { "1" } } })
    H.eq(dup.same, 1)
    H.eq(dup.removed, { { "1" } })
    H.eq(dup.added, {})
  end)
  H.it("diffs the shared columns when the columns changed", function()
    local wider = { columns = { "id", "balance", "extra" }, rows = { { "1", "1.5", "x" }, { "2", "9", "y" } } }
    local d = diff.rows(before, wider, { key = { 1 } })
    H.eq(d.columns_changed, true)
    H.eq(d.columns, { "id", "balance" })
    H.eq(d.key, { 1 })
    H.eq(d.same, 1)
    H.eq(d.added, {})
    H.eq(d.removed, { { "3", "3" } })
    H.eq(d.changed, { { before = { "2", vim.NIL }, after = { "2", "9" }, cols = { 2 } } })
    -- a key column that is not shared means no key
    H.eq(diff.rows(before, wider, { key = { 3 } }).key, nil)
  end)
end)

H.describe("diff.pick_key", function()
  H.it("uses the primary key, then an id column", function()
    local tbl = {
      constraints = { { type = "f", columns = { "plan_id" } }, { type = "p", columns = { "tenant_id", "id" } } },
    }
    H.eq(diff.pick_key({ "id", "email", "tenant_id" }, tbl), { 3, 1 })
    H.eq(diff.pick_key({ "email", "id" }, tbl), { 2 })
    H.eq(diff.pick_key({ "ID", "x" }), { 1 })
    H.eq(diff.pick_key({ "email" }), nil)
    H.eq(diff.pick_key({ "email" }, tbl), nil)
  end)
end)

H.describe("diff.render", function()
  H.it("renders a grid with highlights", function()
    local d = diff.rows(before, after, { key = { 1 } })
    local lines, hl = diff.render(d, after.columns)
    H.eq(lines, {
      " +1 added · −1 removed · ~1 changed · 1 same",
      "",
      "  id │ email │ balance ",
      "─────┼───────┼─────────",
      "+ 4  │ d@x   │ 4       ",
      "- 3  │ c@x   │ 3       ",
      "~ 2  │ b@x   │ NULL → 9",
    })
    H.eq(hl[1], { 3, 0, #lines[3], "DbgridColumnHeader" })
    H.eq(hl[2], { 4, 0, #lines[4], "DbgridRule" })
    H.eq(hl[3], { 5, 0, #lines[5], "DbgridDiffAdd" })
    H.eq(hl[4], { 6, 0, #lines[6], "DbgridDiffDelete" })
    H.eq(#hl, 5)
    H.eq(hl[5][1], 7)
    H.eq(hl[5][4], "DbgridDiffChange")
    H.eq(lines[7]:sub(hl[5][2] + 1, hl[5][3]), "NULL → 9")
    -- the changed cell is the only highlight on that line, the key cell is left alone
    H.eq(lines[7]:sub(1, hl[5][2]), "~ 2  │ b@x   │ ")
  end)
  H.it("handles an empty diff and custom null text", function()
    local lines, hl = diff.render(diff.rows(before, before, { key = { 1 } }), before.columns)
    H.eq(lines, { " +0 added · −0 removed · ~0 changed · 3 same", "", " (no differences)" })
    H.eq(hl, {})
    local d = diff.rows({ columns = { "a" }, rows = {} }, { columns = { "a" }, rows = { { vim.NIL } } })
    local l2 = diff.render(d, nil, { null_text = "∅" })
    H.eq(l2[5], "+ ∅")
  end)
end)
