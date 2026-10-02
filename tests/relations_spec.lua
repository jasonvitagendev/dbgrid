local H = _G.H
local relations = require("dbgrid.relations")
local schema = require("dbgrid.schema")
local sql = require("dbgrid.sql")

-- users <- invoices (cascade) <- invoice_lines (cascade)
-- users <- sessions (set null)
-- users <- orders (no action)
-- audit.events -> users (restrict)
-- users -> plans (no action)
-- categories -> categories (cascade, self)
local function fixture()
  local function tbl(sch, name, rows, constraints)
    return { schema = sch, name = name, kind = "r", rows = rows, columns = {}, indexes = {}, constraints = constraints }
  end
  local function fk(name, cols, ref, refcols, rule)
    return {
      name = name,
      type = "f",
      def = "FOREIGN KEY ("
        .. table.concat(cols, ", ")
        .. ") REFERENCES "
        .. ref
        .. "("
        .. table.concat(refcols, ", ")
        .. ")"
        .. (rule and (" ON DELETE " .. rule) or ""),
      columns = cols,
      ref_table = ref,
      ref_columns = refcols,
    }
  end
  local data = {
    tables = {
      tbl("public", "plans", 3, { { name = "plans_pkey", type = "p", def = "PRIMARY KEY (id)", columns = { "id" } } }),
      tbl("public", "users", 5000, {
        { name = "users_pkey", type = "p", def = "PRIMARY KEY (id)", columns = { "id" } },
        fk("users_plan_id_fkey", { "plan_id" }, "public.plans", { "id" }),
      }),
      tbl(
        "public",
        "invoices",
        20000,
        { fk("invoices_user_fkey", { "user_id" }, "public.users", { "id" }, "CASCADE") }
      ),
      tbl("public", "invoice_lines", 90000, {
        fk("lines_invoice_fkey", { "invoice_id" }, "public.invoices", { "id" }, "CASCADE"),
      }),
      tbl("public", "sessions", 100, { fk("sessions_user_fkey", { "user_id" }, "public.users", { "id" }, "SET NULL") }),
      tbl("public", "orders", 10, { fk("orders_user_fkey", { "user_id" }, "public.users", { "id" }) }),
      tbl("audit", "events", 10, { fk("events_user_fkey", { "actor_id" }, "public.users", { "id" }, "RESTRICT") }),
      tbl("public", "categories", 10, {
        fk("categories_parent_fkey", { "parent_id" }, "public.categories", { "id" }, "CASCADE"),
      }),
    },
  }
  data.by_name = {}
  for _, t in ipairs(data.tables) do
    data.by_name[(t.schema .. "." .. t.name):lower()] = t
    data.by_name[t.name:lower()] = t
  end
  return data
end

H.describe("relations.delete_rule", function()
  H.it("reads the ON DELETE rule from the constraint definition", function()
    H.eq(relations.delete_rule({ def = "FOREIGN KEY (a) REFERENCES b(id) ON DELETE CASCADE" }), "cascade")
    H.eq(
      relations.delete_rule({ def = "FOREIGN KEY (a) REFERENCES b(id) ON UPDATE CASCADE ON DELETE SET NULL" }),
      "set null"
    )
    H.eq(relations.delete_rule({ def = "FOREIGN KEY (a) REFERENCES b(id)\n  ON DELETE  SET DEFAULT" }), "set default")
    H.eq(relations.delete_rule({ def = "FOREIGN KEY (a) REFERENCES b(id) ON DELETE RESTRICT" }), "restrict")
    H.eq(relations.delete_rule({ def = "FOREIGN KEY (a) REFERENCES b(id) ON UPDATE CASCADE" }), "no action")
    H.eq(relations.delete_rule({}), "no action")
  end)
end)

H.describe("relations.incoming", function()
  H.it("indexes who references a table, sorted by name", function()
    local data = fixture()
    local users = schema.find_table(data, "users")
    local names = vim.tbl_map(function(e)
      return e.from.name .. ":" .. e.rule
    end, relations.incoming(data, users))
    H.eq(names, { "events:restrict", "invoices:cascade", "orders:no action", "sessions:set null" })
    H.eq(#relations.incoming(data, schema.find_table(data, "orders")), 0)
    H.eq(relations.outgoing(data, users)[1].to.name, "plans")
  end)
end)

H.describe("relations.delete_impact", function()
  H.it("follows cascades transitively and separates set-null and blocking edges", function()
    local data = fixture()
    local impact = relations.delete_impact(data, schema.find_table(data, "users"))
    H.eq(
      vim.tbl_map(function(i)
        return i.table.name .. (i.via and (" via " .. i.via.name) or "")
      end, impact.cascade),
      { "invoices", "invoice_lines via invoices" }
    )
    H.eq(
      vim.tbl_map(function(i)
        return i.table.name
      end, impact.set_null),
      { "sessions" }
    )
    H.eq(
      vim.tbl_map(function(i)
        return i.table.schema .. "." .. i.table.name
      end, impact.blocked),
      { "audit.events", "public.orders" }
    )
  end)

  H.it("handles self references without looping", function()
    local data = fixture()
    local impact = relations.delete_impact(data, schema.find_table(data, "categories"))
    H.eq(#impact.cascade, 1)
    H.eq(impact.cascade[1].table.name, "categories")
  end)

  H.it("is empty for a leaf table", function()
    local impact = relations.delete_impact(fixture(), schema.find_table(fixture(), "invoice_lines"))
    H.eq(impact, { cascade = {}, set_null = {}, blocked = {} })
  end)
end)

H.describe("relations.truncate_impact", function()
  H.it("lists every referencing table outside the truncated set", function()
    local data = fixture()
    local extra = relations.truncate_impact(data, { schema.find_table(data, "users") })
    local names = vim.tbl_map(function(i)
      return i.table.name
    end, extra)
    table.sort(names)
    H.eq(names, { "events", "invoice_lines", "invoices", "orders", "sessions" })
    extra =
      relations.truncate_impact(data, { schema.find_table(data, "invoices"), schema.find_table(data, "invoice_lines") })
    H.eq(#extra, 0)
  end)
end)

H.describe("relations.write_warnings", function()
  H.it("warns about cascades, set null and blocking rows of a DELETE", function()
    local data = fixture()
    local dangers, notes = relations.write_warnings(data, sql.split("delete from users where id = 1"))
    H.eq(dangers, { "DELETE on users cascades to invoices, invoice_lines (via invoices)" })
    H.eq(notes, {
      "DELETE on users sets NULL / default in sessions.user_id",
      "DELETE on users fails while rows in audit.events.actor_id, orders.user_id still reference it",
    })
  end)

  H.it("stays quiet for leaf tables, unknown tables and reads", function()
    local data = fixture()
    local d, n = relations.write_warnings(data, sql.split("delete from invoice_lines; delete from nope; select 1"))
    H.eq(d, {})
    H.eq(n, {})
    d, n = relations.write_warnings(nil, sql.split("delete from users"))
    H.eq(d, {})
    H.eq(n, {})
  end)

  H.it("explains TRUNCATE with and without CASCADE", function()
    local data = fixture()
    local dangers, notes = relations.write_warnings(data, sql.split("truncate table users cascade"))
    H.eq(#dangers, 1)
    H.matches(dangers[1], "^TRUNCATE users CASCADE also truncates ")
    H.matches(dangers[1], "invoice_lines %(via invoices%)")
    H.eq(notes, {})
    dangers, notes = relations.write_warnings(data, sql.split("truncate users, invoices restart identity"))
    H.eq(dangers, {})
    H.eq(#notes, 1)
    H.matches(notes[1], "^TRUNCATE users, invoices fails: referenced by ")
    H.matches(notes[1], "add CASCADE or truncate them too")
    dangers, notes = relations.write_warnings(data, sql.split("truncate invoices, invoice_lines"))
    H.eq(dangers, {})
    H.eq(notes, {})
  end)
end)

H.describe("relations.tree_lines", function()
  H.it("prints both directions with rules and the delete summary", function()
    local data = fixture()
    local lines = relations.tree_lines(data, schema.find_table(data, "users"), { depth = 3 })
    H.eq(lines, {
      "users  (~5,000 rows)",
      "",
      "References:",
      "  → plans (plan_id → id)",
      "",
      "Referenced by:",
      "  ← audit.events (actor_id)  on delete restrict",
      "  ← invoices (user_id)  on delete cascade",
      "    ← invoice_lines (invoice_id)  on delete cascade",
      "  ← orders (user_id)",
      "  ← sessions (user_id)  on delete set null",
      "",
      "DELETE on users cascades to invoices, invoice_lines (via invoices)",
      "DELETE on users sets NULL / default in sessions.user_id",
      "DELETE on users fails while rows in audit.events.actor_id, orders.user_id still reference it",
    })
  end)

  H.it("respects the depth and marks cycles", function()
    local data = fixture()
    local lines = relations.tree_lines(data, schema.find_table(data, "users"), { depth = 1 })
    H.falsy(vim.tbl_contains(lines, "    ← invoice_lines (invoice_id)  on delete cascade"))
    lines = relations.tree_lines(data, schema.find_table(data, "categories"), { depth = 3 })
    H.truthy(vim.tbl_contains(lines, "  → categories (parent_id → id)  on delete cascade  (cycle)"))
    H.truthy(vim.tbl_contains(lines, "  ← categories (parent_id)  on delete cascade  (cycle)"))
  end)
end)

H.describe("schema.describe_lines", function()
  H.it("shows delete rules on foreign keys and who references the table", function()
    local data = fixture()
    local invoices = schema.find_table(data, "invoices")
    invoices.columns = { { name = "id", type = "integer", notnull = true }, { name = "user_id", type = "integer" } }
    local lines = schema.describe_lines(invoices, data)
    H.truthy(vim.tbl_contains(lines, "  user_id  integer  → public.users(id) on delete cascade"))
    H.truthy(vim.tbl_contains(lines, "Referenced by:"))
    H.truthy(vim.tbl_contains(lines, "  ← invoice_lines (invoice_id)  on delete cascade"))
    -- without the schema document the section is simply absent
    H.falsy(vim.tbl_contains(schema.describe_lines(invoices), "Referenced by:"))
  end)
end)
