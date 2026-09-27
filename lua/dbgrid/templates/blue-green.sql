-- template-name: Blue/green deployment
-- template-tags: blue-green, replication
-- template-description: Watch an RDS PostgreSQL blue/green switchover: slot lag, writes still landing on blue, and what differs on green
-- template-connections: blue, green

-- %% slot lag
-- @conn blue
-- @every 5s
-- The logical slot green consumes from: lag is WAL blue has written that green has not confirmed yet.
-- Right before switchover it must sit near 0 bytes with active = true and wal_status = reserved.
select s.slot_name,
       s.slot_type,
       s.active,
       s.wal_status,
       s.restart_lsn,
       s.confirmed_flush_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), s.confirmed_flush_lsn)) as lag,
       pg_wal_lsn_diff(pg_current_wal_lsn(), s.confirmed_flush_lsn) as lag_bytes
from pg_replication_slots s
order by lag_bytes desc nulls last;

-- %% sender state
-- @conn blue
-- @every 5s
-- The walsender feeding green: state must be streaming and the lags near zero. No row means green is not connected.
select r.application_name,
       r.client_addr,
       r.state,
       r.sent_lsn,
       r.write_lsn,
       r.flush_lsn,
       r.replay_lsn,
       r.write_lag,
       r.flush_lag,
       r.replay_lag
from pg_stat_replication r
order by r.application_name;

-- %% subscription state
-- @conn green
-- @every 5s
-- The subscription on green: pid null means the apply worker is down (check the green log); behind is the age of the
-- last applied transaction. A row with syncing_table set is an initial table copy still running.
select s.subname,
       s.pid,
       s.relid::regclass as syncing_table,
       s.received_lsn,
       s.latest_end_lsn,
       s.last_msg_receipt_time,
       s.latest_end_time,
       now() - s.latest_end_time as behind
from pg_stat_subscription s
order by s.subname, s.relid;

-- %% subscription errors
-- @conn green
-- @every 5s
-- needs: PostgreSQL 15+ for pg_stat_subscription_stats
-- Apply and initial-sync errors since stats_reset; a rising count means green is stuck on a conflict (see its log).
select s.subname,
       s.apply_error_count,
       s.sync_error_count,
       s.stats_reset
from pg_stat_subscription_stats s
order by s.apply_error_count desc, s.sync_error_count desc;

-- %% writes in flight
-- @conn blue
-- @every 5s
-- A backend gets a transaction id only when it modifies data, so this counts sessions with a write in progress right now.
-- It must read zero before switchover; the second result names the writers.
select count(*) as writing_now
from pg_stat_activity a
where a.backend_xid is not null
  and a.pid <> pg_backend_pid();

select a.pid,
       a.usename,
       a.application_name,
       now() - a.xact_start as tx_age,
       a.state,
       left(a.query, 100) as query
from pg_stat_activity a
where a.backend_xid is not null
  and a.pid <> pg_backend_pid()
order by a.xact_start;

-- %% rows written since last tick
-- @conn blue
-- @every 5s
-- Counters for this database: flat rows_written and xact_commit between ticks mean no DML is arriving on blue.
-- A creeping wal_lsn with flat counters is only checkpoints, vacuum and hint bits, not application writes.
select d.tup_inserted + d.tup_updated + d.tup_deleted as rows_written,
       d.tup_inserted,
       d.tup_updated,
       d.tup_deleted,
       d.xact_commit,
       pg_current_wal_insert_lsn() as wal_lsn,
       now() as sampled_at
from pg_stat_database d
where d.datname = current_database();

-- %% application sessions
-- @conn blue
-- @every 5s
-- Who is still connected to blue, by application and host; rdsadmin and this notebook are left out.
-- Before switchover this should shrink to the sessions you expect to drain or terminate.
select a.application_name,
       a.client_addr,
       a.usename,
       a.state,
       count(*) as sessions,
       max(now() - a.backend_start) as oldest
from pg_stat_activity a
where a.backend_type = 'client backend'
  and a.usename is distinct from 'rdsadmin'
  and a.pid <> pg_backend_pid()
group by a.application_name, a.client_addr, a.usename, a.state
order by sessions desc, a.application_name;

-- %% long transactions on blue
-- @conn blue
-- @every 5s
-- Transactions open for more than 30 seconds, oldest first: the slot cannot advance past the oldest one, so they show up
-- as lag on green. Cancel or terminate them before switchover.
select a.pid,
       a.usename,
       a.application_name,
       age(now(), a.xact_start) as tx_age,
       a.state,
       left(a.query, 100) as query
from pg_stat_activity a
where a.xact_start < now() - interval '30 seconds'
  and a.pid <> pg_backend_pid()
order by a.xact_start;

-- %% tables without replica identity
-- @conn blue
-- Tables with replica identity NOTHING, or DEFAULT without a primary key: logical replication inserts into them but every
-- UPDATE or DELETE on blue fails to apply on green. Fix: add a primary key, or ALTER TABLE ... REPLICA IDENTITY USING INDEX / FULL.
select n.nspname as schemaname,
       c.relname,
       c.relkind,
       c.relreplident,
       pg_size_pretty(pg_relation_size(c.oid)) as size
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r', 'p')
  and (c.relreplident = 'n'
       or (c.relreplident = 'd'
           and not exists (select 1 from pg_constraint k where k.conrelid = c.oid and k.contype = 'p')))
  and n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
  and n.nspname not like 'pg\_temp\_%'
order by pg_relation_size(c.oid) desc;

-- %% row counts on blue
-- @conn blue
-- Approximate live rows per table from the statistics; run the matching cell on green and diff the two results.
-- Counts drift with vacuum and analyze timing, so small differences are normal; use the exact count cells for a final check.
select t.schemaname,
       t.relname,
       t.n_live_tup
from pg_stat_user_tables t
order by t.schemaname, t.relname;

-- %% row counts on green
-- @conn green
-- Same as above on green; the diff against the blue cell shows tables that are behind (or never synced).
select t.schemaname,
       t.relname,
       t.n_live_tup
from pg_stat_user_tables t
order by t.schemaname, t.relname;

-- %% exact count on blue
-- @conn blue
-- @param table = users
-- Exact row count of one table; the value is an identifier (schema.table works) inserted verbatim into the FROM clause.
-- On a busy blue it keeps changing until writes stop; compare with the green cell once it is stable.
select count(*) as row_count
from :table;

-- %% exact count on green
-- @conn green
-- @param table = users
-- Same table on green (the value is an identifier, inserted verbatim); it must match blue once slot lag is zero.
select count(*) as row_count
from :table;

-- %% sequence values on blue
-- @conn blue
-- Logical replication does not carry sequence values: confirm green's values are at or above blue's before writes start
-- on green, or new rows collide with old ids. last_value is null for sequences never used or not readable by this role.
select s.schemaname,
       s.sequencename,
       s.last_value
from pg_sequences s
order by 1, 2;

-- %% sequence values on green
-- @conn green
-- Same on green; diff against the blue cell. Fix a lagging one with select setval('seq', <blue value + margin>).
select s.schemaname,
       s.sequencename,
       s.last_value
from pg_sequences s
order by 1, 2;

-- %% green accepts writes
-- @conn green
-- After switchover both must be off / false: transactions default to read-write and the server is not in recovery.
-- If default_transaction_read_only is still on, an ALTER DATABASE ... SET from a pre-switchover lockdown is still in place.
show default_transaction_read_only;

select pg_is_in_recovery() as in_recovery;
