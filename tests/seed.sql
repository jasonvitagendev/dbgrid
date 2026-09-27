-- Fixture data for the integration tests (tests/postgres_spec.lua, tests/ui_spec.lua).
-- psql "$DBGRID_TEST_URL" -f tests/seed.sql
drop table if exists invoices;
drop table if exists users;
drop table if exists plans;

create table plans (
  id   serial primary key,
  name text not null
);
insert into plans (name) values ('free'), ('pro'), ('team');

-- email must be the 2nd column; indexes: pkey on id first, plus one on created_at.
-- No index on balance, and enough rows (> index_check.min_rows = 1000) that
-- "balance > 5" is planned as a Seq Scan.
create table users (
  id         serial primary key,
  email      text not null,
  plan_id    int references plans (id),
  balance    numeric(10, 2) not null default 0,
  created_at timestamptz not null default now(),
  note       text
);
create index users_created_at_idx on users (created_at);

insert into users (email, plan_id, balance, created_at)
select 'user' || n || '@example.com', n % 3 + 1, n * 1.5, now() - n * interval '1 minute'
from generate_series(1, 5000) n;

comment on table users is 'People with an account';
-- a third index (the UI schema document counts them); not on balance, whose
-- seq scan the index-check tests rely on
create index users_plan_id_idx on users (plan_id);

create table invoices (
  id      serial primary key,
  user_id int not null references users (id),
  amount  numeric(10, 2) not null default 0,
  paid_at timestamptz,
  due_on  date not null default current_date
);
insert into invoices (user_id, amount, paid_at, due_on)
select n, n * 2.5, case when n % 4 = 0 then null else now() end, current_date - (n % 90)
from generate_series(1, 400) n;

analyze plans;
analyze users;
analyze invoices;
