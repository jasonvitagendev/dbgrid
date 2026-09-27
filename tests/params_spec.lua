local H = _G.H
local sql = require("dbgrid.sql")

H.describe("sql.preview_count", function()
  local function count(t)
    return sql.preview_count(sql.split(t)[1])
  end
  H.it("counts the rows an update or delete would touch", function()
    H.eq(count("update users u set a = 1 where u.id > 5"), "SELECT count(*) FROM users u where u.id > 5")
    H.eq(
      count("delete from users where id in (select id from x where a = 1)"),
      "SELECT count(*) FROM users where id in (select id from x where a = 1)"
    )
    H.eq(
      count("delete from users u using plans p where p.id = u.plan_id and p.name = 'free'"),
      "SELECT count(*) FROM users u, plans p where p.id = u.plan_id and p.name = 'free'"
    )
    H.eq(
      count("update users u set plan_id = p.id from plans p, x where p.name = u.note returning *"),
      "SELECT count(*) FROM users u, plans p, x where p.name = u.note"
    )
    H.eq(count("update users set a = 1\nwhere id = 1\nreturning id, a"), "SELECT count(*) FROM users where id = 1")
    H.eq(count("update only public.users set a = 1 where id = 1"), "SELECT count(*) FROM public.users where id = 1")
  end)
  H.it("returns nil when unsure", function()
    H.eq(count("with x as (select 1) update users set a = 1 where id = 1"), nil)
    H.eq(count("update users set a = 1"), nil)
    H.eq(count("delete from users"), nil)
    H.eq(count("insert into users (a) values (1)"), nil)
    H.eq(count("update users set a = 1 where current of cur"), nil)
    H.eq(count("select 1 where true"), nil)
  end)
end)

H.describe("sql.ensure_returning", function()
  local function ret(t)
    return { sql.ensure_returning(sql.split(t)[1]) }
  end
  H.it("appends RETURNING * to writes without one", function()
    H.eq(ret("insert into t values (1)"), { "insert into t values (1)\nRETURNING *", true })
    H.eq(ret("update t set a = 1 where b = 2"), { "update t set a = 1 where b = 2\nRETURNING *", true })
    H.eq(ret("delete from t where a = 1 returning id"), { "delete from t where a = 1 returning id", false })
    H.eq(ret("insert into t values (1) on conflict do nothing"), {
      "insert into t values (1) on conflict do nothing\nRETURNING *",
      true,
    })
  end)
  H.it("leaves reads, ctes, ddl and other statements alone", function()
    H.eq(ret("select 1"), { "select 1", false })
    H.eq(ret("with d as (delete from t returning *) select * from d"), {
      "with d as (delete from t returning *) select * from d",
      false,
    })
    H.eq(ret("create table t (a int)"), { "create table t (a int)", false })
    H.eq(ret("call p()"), { "call p()", false })
  end)
end)

H.describe("sql.ddl_warnings", function()
  local rows = { users = 1000000, tiny = 12 }
  local function warn(t, opts)
    opts = opts or {}
    opts.table_rows = opts.table_rows or function(name)
      return rows[name]
    end
    return sql.ddl_warnings(sql.split(t)[1], opts)
  end
  H.it("flags create/drop index without concurrently, unless the table is small", function()
    local w = warn("create index users_email_idx on users (email)")
    H.eq(#w, 1)
    H.matches(w[1], "^CREATE INDEX without CONCURRENTLY locks writes on users %(~1,000,000 rows%) for the whole build")
    H.matches(w[1], "use CREATE INDEX CONCURRENTLY$")
    H.eq(warn("create unique index concurrently on users (email)"), {})
    H.eq(warn("create index on tiny (a)"), {})
    H.eq(#warn("create index on unknown (a)"), 1)
    H.matches(warn("create index on unknown (a)")[1], "locks writes on unknown for the whole build")
    H.matches(warn("create index if not exists i on only public.users using btree (a)")[1], "on public%.users")
    H.matches(warn("drop index users_email_idx")[1], "^DROP INDEX without CONCURRENTLY")
    H.matches(warn("drop index if exists users_email_idx")[1], "users_email_idx; use DROP INDEX CONCURRENTLY$")
    H.eq(warn("drop index concurrently if exists users_email_idx"), {})
  end)
  H.it("explains what alter table does", function()
    local w = warn("alter table only public.users alter column email type varchar(100), alter balance set not null")
    H.eq(#w, 3)
    H.matches(w[1], "^ALTER TABLE takes an ACCESS EXCLUSIVE lock on public%.users; every query on it waits")
    H.eq(w[2], "changing a column type rewrites the whole table")
    H.eq(w[3], "SET NOT NULL scans the whole table unless a matching CHECK constraint exists")
    local fk = warn("alter table users add constraint users_plan_fk foreign key (plan_id) references plans (id)")
    H.eq(#fk, 2)
    H.eq(fk[2], "validate the constraint separately: ADD CONSTRAINT ... NOT VALID, then VALIDATE CONSTRAINT")
    H.eq(#warn("alter table users add constraint c check (balance >= 0) not valid"), 1)
    H.eq(#warn("alter table users add check (balance >= 0)"), 2)
    H.eq(#warn("alter table users add primary key (id)"), 1)
    local def = warn("alter table users add column token uuid default gen_random_uuid()")
    H.eq(#def, 2)
    H.eq(def[2], "a volatile default rewrites the table; add the column first, then backfill")
    H.eq(#warn("alter table users add column flag boolean default false"), 1)
    H.eq(#warn("alter table users add column flag boolean, add column n int default 0"), 1)
    H.eq(#warn("alter table if exists users rename to people"), 1)
    -- the same specific is reported once per statement
    H.eq(#warn("alter table users alter a type int, alter b type int"), 2)
  end)
  H.it("flags truncate, vacuum full, cluster and reindex", function()
    H.eq(warn("truncate table users")[1], "TRUNCATE takes an ACCESS EXCLUSIVE lock on users and cannot be undone")
    H.matches(warn("truncate only users, plans")[1], "lock on users")
    H.eq(warn("vacuum full users"), { "VACUUM FULL rewrites users and locks the table for the whole run" })
    H.eq(warn("vacuum (full, analyze) users"), { "VACUUM FULL rewrites users and locks the table for the whole run" })
    H.matches(warn("vacuum full")[1], "^VACUUM FULL rewrites every table")
    H.eq(warn("vacuum analyze users"), {})
    H.eq(warn("vacuum (full false) users"), {})
    H.eq(warn("cluster users using users_pkey"), { "CLUSTER rewrites users and locks the table for the whole run" })
    H.matches(warn("cluster")[1], "^CLUSTER rewrites every clustered table")
    H.eq(warn("reindex index users_email_idx"), {
      "REINDEX without CONCURRENTLY locks index users_email_idx for the whole run; use REINDEX INDEX CONCURRENTLY",
    })
    H.matches(warn("reindex (verbose) table users")[1], "locks table users for the whole run; use REINDEX TABLE")
    H.eq(warn("reindex table concurrently users"), {})
    H.eq(warn("select 1"), {})
    H.eq(warn("create table t (a int)"), {})
  end)
  H.it("mentions a missing lock_timeout for ddl that waits for locks", function()
    local w = warn("alter table users drop column note", { lock_timeout = false })
    H.eq(#w, 2)
    H.matches(w[2], "^no lock_timeout is set on this connection")
    H.eq(#warn("alter table users drop column note", { lock_timeout = true }), 1)
    H.eq(#warn("alter table users drop column note"), 1)
    H.eq(#warn("drop table users", { lock_timeout = false }), 1)
    H.eq(#warn("create index on tiny (a)", { lock_timeout = false }), 1)
    H.eq(warn("create table t (a int)", { lock_timeout = false }), {})
    H.eq(warn("vacuum full users", { lock_timeout = false }), {
      "VACUUM FULL rewrites users and locks the table for the whole run",
    })
  end)
end)
