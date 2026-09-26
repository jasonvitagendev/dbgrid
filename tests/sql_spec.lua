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
