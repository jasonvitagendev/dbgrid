local H = _G.H
local sql = require("dbgrid.sql")

H.describe("sql.split", function()
  H.it("splits on top-level semicolons only", function()
    local s = sql.split(
      "select 1; select ';' as x; select $$a;b$$; create function f() returns int as $f$ begin return 1; end $f$ language plpgsql"
    )
    H.eq(#s, 4)
    H.eq(s[2].sql, "select ';' as x")
    H.eq(s[3].sql, "select $$a;b$$")
    H.eq(s[4].kind, "create")
  end)

  H.it("ignores comments, keeps line numbers", function()
    local s = sql.split("-- lead\n/* block ; */\nselect 1 -- trailing ; here\n;\n\nupdate t set a = 1 where b = 2;")
    H.eq(#s, 2)
    H.eq(s[1].sql, "select 1")
    H.eq(s[1].line, 3)
    H.eq(s[2].line, 6)
    H.eq(s[2].class, "write")
  end)

  H.it("handles nested block comments and escape strings", function()
    local s = sql.split("/* a /* b */ c */ select E'it\\'s;' as q; select 2")
    H.eq(#s, 2)
    H.eq(s[1].sql, "select E'it\\'s;' as q")
  end)

  H.it("classifies statements", function()
    local function class(t)
      return sql.split(t)[1].class
    end
    H.eq(class("select * from t"), "read")
    H.eq(class("with a as (select 1) select * from a"), "read")
    H.eq(class("with a as (delete from t returning *) select * from a"), "write")
    H.eq(class("with a as (select 1) insert into t select * from a"), "write")
    H.eq(class("select * into newt from t"), "write")
    H.eq(class("(select 1) union (select 2)"), "read")
    H.eq(class("insert into t values (1)"), "write")
    H.eq(class("create index on t(a)"), "ddl")
    H.eq(class("begin"), "tx")
    H.eq(class("set search_path to x"), "other")
    H.eq(class("explain select 1"), "read")
    H.eq(class("explain analyze delete from t"), "explain_analyze")
    H.eq(class("values (1), (2)"), "read")
    H.eq(class("table users"), "read")
  end)
end)

H.describe("sql.ensure_limit", function()
  local function lim(t, n)
    return sql.ensure_limit(sql.split(t)[1], n or 500)
  end
  H.it("appends a limit to selects", function()
    local out, applied = lim("select * from users")
    H.eq(applied, true)
    H.eq(out, "select * from users\nLIMIT 500")
  end)
  H.it("respects existing top-level limit / fetch", function()
    H.eq({ lim("select * from users limit 10") }, { "select * from users limit 10", false })
    H.eq(
      { lim("select * from users fetch first 5 rows only") },
      { "select * from users fetch first 5 rows only", false }
    )
  end)
  H.it("ignores limits inside subqueries", function()
    local out, applied = lim("select * from (select * from users limit 1) s")
    H.eq(applied, true)
    H.matches(out, "LIMIT 500$")
  end)
  H.it("puts the limit before a locking clause", function()
    local out = lim("select * from jobs where done = false for update skip locked")
    H.eq(out, "select * from jobs where done = false \nLIMIT 500\nfor update skip locked")
  end)
  H.it("leaves writes, ctes-with-dml and other statements alone", function()
    H.eq({ lim("update t set a=1") }, { "update t set a=1", false })
    H.eq(
      { lim("with d as (delete from t returning *) select * from d") },
      { "with d as (delete from t returning *) select * from d", false }
    )
    H.eq({ lim("show search_path") }, { "show search_path", false })
  end)
  H.it("works for cte reads, values and table", function()
    H.eq(select(2, lim("with a as (select 1) select * from a")), true)
    H.eq(select(2, lim("table users")), true)
    H.eq(select(2, lim("values (1)")), true)
  end)
  H.it("ignores a trailing line comment safely", function()
    local out = lim("select 1 -- no limit here\n")
    H.eq(out, "select 1\nLIMIT 500")
  end)
end)

H.describe("sql.danger", function()
  H.it("flags writes without where", function()
    H.matches(sql.danger(sql.split("delete from users")[1]), "without a WHERE")
    H.matches(sql.danger(sql.split("update users set a = 1")[1]), "without a WHERE")
    H.eq(sql.danger(sql.split("update users set a = 1 where id = 1")[1]), nil)
    H.eq(sql.danger(sql.split("delete from users where id in (select id from x where a = 1)")[1]), nil)
    H.matches(sql.danger(sql.split("truncate users")[1]), "TRUNCATE")
  end)
end)

H.describe("sql.referenced_tables", function()
  H.it("finds tables and aliases", function()
    local refs = sql.referenced_tables(
      "select u.id from public.users u join plans as p on p.id = u.plan_id left join (select 1) s on true, invoices where u.id = 1"
    )
    H.eq(refs, {
      { name = "public.users", alias = "u" },
      { name = "plans", alias = "p" },
      { name = "invoices" },
    })
  end)
  H.it("handles update / insert / delete", function()
    H.eq(sql.referenced_tables("update users set a = 1 where id = 2"), { { name = "users" } })
    H.eq(sql.referenced_tables("insert into users (a) values (1)"), { { name = "users" } })
    H.eq(sql.referenced_tables("delete from users u where u.id = 1"), { { name = "users", alias = "u" } })
    H.eq(sql.referenced_tables('select * from "Weird Table" w'), { { name = '"Weird Table"', alias = "w" } })
  end)
end)

H.describe("sql.write_targets", function()
  local function targets(text)
    return sql.write_targets(sql.split(text)[1])
  end
  H.it("finds the table of a DELETE", function()
    H.eq(targets("delete from users where id = 1"), { kind = "delete", names = { "users" }, cascade = false })
    H.eq(targets("DELETE FROM ONLY billing.invoices i USING x WHERE i.x = x.id"), {
      kind = "delete",
      names = { "billing.invoices" },
      cascade = false,
    })
    H.eq(targets('delete from "Users"'), { kind = "delete", names = { '"Users"' }, cascade = false })
    H.eq(targets("with old as (select id from users) delete from sessions where user_id in (select id from old)"), {
      kind = "delete",
      names = { "sessions" },
      cascade = false,
    })
  end)
  H.it("finds the tables of a TRUNCATE", function()
    H.eq(targets("truncate users"), { kind = "truncate", names = { "users" }, cascade = false })
    H.eq(targets("truncate table only users *, app.plans restart identity cascade"), {
      kind = "truncate",
      names = { "users", "app.plans" },
      cascade = true,
    })
    H.eq(targets("truncate users, invoices continue identity restrict"), {
      kind = "truncate",
      names = { "users", "invoices" },
      cascade = false,
    })
  end)
  H.it("ignores other statements", function()
    H.eq(targets("select * from users"), nil)
    H.eq(targets("update users set a = 1"), nil)
    H.eq(targets("insert into users values (1)"), nil)
    H.eq(targets("with a as (select 1) select * from a"), nil)
  end)
end)

H.describe("sql.placeholders", function()
  H.it("finds :name and {{name}} outside strings, comments and casts", function()
    local text =
      "select x::int from t where id=:id and a = ':nope' -- :c\n and b = {{ since }} and c = {{overdue-invoices}} and $1 = 1"
    local names = vim.tbl_map(function(r)
      return r.style .. r.name
    end, sql.placeholders(text))
    H.eq(names, { ":id", "{{since", "{{overdue-invoices" })
    local out = sql.substitute(text, sql.placeholders(text), function(r)
      return "<" .. r.name .. ">"
    end)
    H.matches(out, "id=<id>")
    H.matches(out, "b = <since>")
    H.matches(out, "c = <overdue%-invoices>")
    H.matches(out, "':nope'")
    H.matches(out, "x::int")
  end)
  H.it("normalises and inlines text", function()
    H.eq(sql.normalize("SELECT  a ,\n b FROM t -- x"), sql.normalize("select a, b\nfrom t"))
    H.truthy(sql.normalize("select 'A'") ~= sql.normalize("select 'a'"))
    H.eq(
      sql.inline("select a.b, -- c\n  1e-5, x::int\nfrom t /* z */ where a = 1"),
      "select a.b, 1e-5, x::int from t where a = 1"
    )
    H.eq(#sql.tokenize("select 1 -- c\n/* b */", { comments = true }), 4)
    H.eq(sql.tokenize("select 1e-5, 2.5E+3, 3-1")[2].value, "1e-5")
    H.eq(#sql.tokenize("select 3-1"), 4)
  end)
  H.it("lists the columns a WHERE clause uses", function()
    H.eq(
      sql.where_columns(
        "select * from t where balance > 5 and email like 'x' order by id",
        { "id", "email", "balance" }
      ),
      { "balance", "email" }
    )
  end)
end)

H.describe("bundled templates", function()
  H.it("blue-green only reads", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local text = require("dbgrid.util").read_file(root .. "/lua/dbgrid/templates/blue-green.sql")
    local stmts = sql.split(text)
    H.truthy(#stmts > 10)
    for _, st in ipairs(stmts) do
      H.eq(st.class, "read", st.kind)
    end
  end)
  H.it("logical-replication only reads", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local text = require("dbgrid.util").read_file(root .. "/lua/dbgrid/templates/logical-replication.sql")
    local stmts = sql.split(text)
    H.truthy(#stmts > 20)
    for _, st in ipairs(stmts) do
      H.eq(st.class, "read", st.kind)
    end
  end)
end)

H.describe("sql.no_transaction", function()
  local function what(t)
    return sql.no_transaction(sql.split(t)[1])
  end
  H.it("names statements that refuse a transaction block", function()
    H.eq(what("create subscription s connection 'x' publication p with (copy_data = true)"), "CREATE SUBSCRIPTION")
    H.eq(what("drop subscription s"), "DROP SUBSCRIPTION")
    H.eq(what("VACUUM (ANALYZE) users"), "VACUUM")
    H.eq(what("create index concurrently i on users (a)"), "CREATE ... CONCURRENTLY")
    H.eq(what("drop index concurrently if exists i"), "DROP ... CONCURRENTLY")
    H.eq(what("reindex table concurrently users"), "REINDEX ... CONCURRENTLY")
    H.eq(what("create database x"), "CREATE DATABASE")
    H.eq(what("alter system set work_mem = '64MB'"), "ALTER SYSTEM")
  end)
  H.it("leaves ordinary statements alone", function()
    H.eq(what("select 1"), nil)
    H.eq(what("create index i on users (a)"), nil)
    H.eq(what("alter subscription s disable"), nil)
    H.eq(what("create table t (id int)"), nil)
    H.eq(what("update users set a = 1 where id = 1"), nil)
  end)
end)
