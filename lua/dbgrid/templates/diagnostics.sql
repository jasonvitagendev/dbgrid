-- template-name: Diagnostics
-- template-tags: diagnostics
-- template-description: What runs, what is slow, what is bloated and what lags on a PostgreSQL server (14+, RDS/Aurora, no superuser)

-- %% active queries
-- What runs right now, for how long, and what it waits on; idle sessions and this notebook's backend are left out.
select a.pid,
       a.usename,
       a.application_name,
       a.client_addr,
       a.state,
       a.wait_event_type,
       a.wait_event,
       now() - a.query_start as running_for,
       now() - a.xact_start as in_tx_for,
       left(a.query, 120) as query
from pg_stat_activity a
where a.pid <> pg_backend_pid()
  and a.state <> 'idle'
order by a.query_start nulls last;

-- %% blocking tree
-- Which session blocks which: one row per blocked backend and the backend it waits for. No rows means nobody waits on a lock.
select blocked.pid as blocked_pid,
       blocked.usename as blocked_user,
       blocked.wait_event_type || ':' || blocked.wait_event as blocked_on,
       now() - blocked.query_start as blocked_for,
       left(blocked.query, 120) as blocked_query,
       blocking.pid as blocking_pid,
       blocking.usename as blocking_user,
       blocking.state as blocking_state,
       now() - blocking.xact_start as blocking_in_tx_for,
       left(blocking.query, 120) as blocking_query
from pg_stat_activity blocked
join pg_stat_activity blocking on blocking.pid = any(pg_blocking_pids(blocked.pid))
where blocked.pid <> pg_backend_pid()
order by blocked.query_start;

-- %% idle in transaction
-- Sessions doing nothing inside an open transaction (they pin locks and hold back vacuum), oldest first.
select a.pid,
       a.usename,
       a.application_name,
       a.state,
       now() - a.xact_start as tx_age,
       now() - a.state_change as idle_for,
       left(a.query, 120) as last_query
from pg_stat_activity a
where a.state in ('idle in transaction', 'idle in transaction (aborted)')
  and a.pid <> pg_backend_pid()
order by a.xact_start;

-- %% long transactions
-- @param min_age = '1 minute'
-- Transactions open longer than min_age (an interval literal), oldest first. They hold back vacuum and replication slots.
select a.pid,
       a.usename,
       a.application_name,
       now() - a.xact_start as tx_age,
       now() - a.query_start as query_age,
       left(a.query, 120) as query
from pg_stat_activity a
where a.xact_start < now() - :min_age::interval
  and a.pid <> pg_backend_pid()
order by a.xact_start;

-- %% top by total time
-- Statements that cost the most overall since the last pg_stat_statements_reset(); hit_pct is the share served from shared_buffers.
-- needs: pg_stat_statements (other roles' queries show as <insufficient privilege> without pg_read_all_stats)
select d.datname,
       s.calls,
       round(s.total_exec_time::numeric, 1) as total_ms,
       round(s.mean_exec_time::numeric, 2) as mean_ms,
       round(s.max_exec_time::numeric, 1) as max_ms,
       s.rows,
       round(100.0 * s.shared_blks_hit / nullif(s.shared_blks_hit + s.shared_blks_read, 0), 1) as hit_pct,
       left(s.query, 120) as query
from pg_stat_statements s
join pg_database d on d.oid = s.dbid
order by s.total_exec_time desc
limit 25;

-- %% top by calls
-- Chatty statements: cheap each time but run so often that they add up (or a cache in front of them is missing).
-- needs: pg_stat_statements
select d.datname,
       s.calls,
       round(s.mean_exec_time::numeric, 3) as mean_ms,
       s.rows,
       round(s.rows::numeric / nullif(s.calls, 0), 1) as rows_per_call,
       left(s.query, 120) as query
from pg_stat_statements s
join pg_database d on d.oid = s.dbid
order by s.calls desc
limit 25;

-- %% top by buffers
-- Statements reading the most blocks from disk (shared_blks_read) or spilling to temp files: the ones that thrash the cache.
-- needs: pg_stat_statements
select d.datname,
       s.calls,
       s.shared_blks_read,
       s.shared_blks_hit,
       round(100.0 * s.shared_blks_hit / nullif(s.shared_blks_hit + s.shared_blks_read, 0), 1) as hit_pct,
       s.temp_blks_written,
       left(s.query, 120) as query
from pg_stat_statements s
join pg_database d on d.oid = s.dbid
order by s.shared_blks_read desc
limit 25;

-- %% seq scans by table
-- Tables above 10000 live rows read sequentially far more than by index: a missing index, or a planner that prefers the scan.
select t.schemaname,
       t.relname,
       t.seq_scan,
       t.seq_tup_read,
       t.idx_scan,
       t.n_live_tup,
       round((t.seq_scan::float / nullif(t.seq_scan + t.idx_scan, 0))::numeric, 3) as seq_ratio,
       pg_size_pretty(pg_relation_size(t.relid)) as size
from pg_stat_user_tables t
where t.n_live_tup > 10000
order by t.seq_tup_read desc
limit 50;

-- %% dead tuples and vacuum
-- Bloat and autovacuum falling behind: a high dead_pct with an old last_autovacuum means vacuum is not keeping up.
select t.schemaname,
       t.relname,
       t.n_live_tup,
       t.n_dead_tup,
       round(100.0 * t.n_dead_tup / nullif(t.n_live_tup + t.n_dead_tup, 0), 1) as dead_pct,
       t.last_autovacuum,
       t.last_vacuum,
       t.last_autoanalyze,
       t.last_analyze,
       t.autovacuum_count
from pg_stat_user_tables t
order by t.n_dead_tup desc
limit 50;

-- %% unused indexes
-- Indexes never scanned since stats_reset, largest first; primary keys and unique indexes are skipped (they enforce constraints).
select i.schemaname,
       i.relname,
       i.indexrelname,
       i.idx_scan,
       pg_size_pretty(pg_relation_size(i.indexrelid)) as size
from pg_stat_user_indexes i
join pg_index x on x.indexrelid = i.indexrelid
where i.idx_scan = 0
  and not x.indisunique
  and not x.indisprimary
order by pg_relation_size(i.indexrelid) desc
limit 50;

-- %% redundant indexes
-- An index whose column list is a prefix of another index on the same table (same access method and same WHERE clause)
-- is redundant: the longer one serves the same lookups. Unique and expression indexes are never reported as redundant.
select n.nspname as schemaname,
       c.relname,
       a.indexrelid::regclass as redundant_index,
       pg_size_pretty(pg_relation_size(a.indexrelid)) as redundant_size,
       pg_get_indexdef(a.indexrelid) as redundant_definition,
       b.indexrelid::regclass as covering_index,
       pg_get_indexdef(b.indexrelid) as covering_definition
from pg_index a
join pg_index b
  on b.indrelid = a.indrelid
 and b.indexrelid <> a.indexrelid
 and position(a.indkey::text || ' ' in b.indkey::text || ' ') = 1
join pg_class ia on ia.oid = a.indexrelid
join pg_class ib on ib.oid = b.indexrelid and ib.relam = ia.relam
join pg_class c on c.oid = a.indrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
  and not a.indisunique
  and a.indexprs is null
  and pg_get_expr(a.indpred, a.indrelid) is not distinct from pg_get_expr(b.indpred, b.indrelid)
order by pg_relation_size(a.indexrelid) desc;

-- %% cache hit ratio
-- Buffer cache effectiveness since stats_reset: the database, then the 20 tables reading most from disk (aim above ~99% for OLTP).
select d.datname,
       d.blks_read,
       round(100.0 * d.blks_hit / nullif(d.blks_hit + d.blks_read, 0), 2) as hit_pct,
       d.stats_reset
from pg_stat_database d
where d.datname = current_database();

select t.schemaname,
       t.relname,
       t.heap_blks_hit,
       t.heap_blks_read,
       round(100.0 * t.heap_blks_hit / nullif(t.heap_blks_hit + t.heap_blks_read, 0), 2) as heap_hit_pct,
       round(100.0 * t.idx_blks_hit / nullif(t.idx_blks_hit + t.idx_blks_read, 0), 2) as idx_hit_pct
from pg_statio_user_tables t
order by t.heap_blks_read desc
limit 20;

-- %% table sizes
-- Largest tables with how much of their footprint is indexes (total also includes toast).
select t.schemaname,
       t.relname,
       pg_size_pretty(pg_total_relation_size(t.relid)) as total,
       pg_size_pretty(pg_relation_size(t.relid)) as heap,
       pg_size_pretty(pg_indexes_size(t.relid)) as indexes,
       round(100.0 * pg_indexes_size(t.relid) / nullif(pg_total_relation_size(t.relid), 0), 1) as index_pct,
       t.n_live_tup
from pg_stat_user_tables t
order by pg_total_relation_size(t.relid) desc
limit 30;

-- %% connections
-- By state and application, then client backends against max_connections (RDS reserves slots for rdsadmin, so 100% is never reached).
select a.state,
       a.application_name,
       count(*) as connections,
       max(now() - a.state_change) as longest_in_state
from pg_stat_activity a
where a.backend_type = 'client backend'
group by a.state, a.application_name
order by connections desc;

select current_setting('max_connections')::int as max_connections,
       count(*) as client_backends,
       round(100.0 * count(*) / current_setting('max_connections')::int, 1) as used_pct
from pg_stat_activity a
where a.backend_type = 'client backend';

-- %% wraparound age
-- Distance to a forced anti-wraparound vacuum per database (autovacuum runs at autovacuum_freeze_max_age; writes stop near 2^31).
select d.datname,
       age(d.datfrozenxid) as xid_age,
       current_setting('autovacuum_freeze_max_age')::bigint as freeze_max_age,
       round(100.0 * age(d.datfrozenxid) / current_setting('autovacuum_freeze_max_age')::bigint, 1) as pct_of_freeze_max,
       round(100.0 * age(d.datfrozenxid) / 2147483647, 2) as pct_of_wraparound,
       mxid_age(d.datminmxid) as multixact_age
from pg_database d
order by age(d.datfrozenxid) desc;

-- %% temp files and deadlocks
-- Work spilling to disk (sorts and hashes larger than work_mem) and lock failures for this database since stats_reset.
select d.datname,
       d.temp_files,
       pg_size_pretty(d.temp_bytes) as temp_size,
       d.deadlocks,
       d.conflicts,
       d.stats_reset
from pg_stat_database d
where d.datname = current_database();

-- %% replica lag
-- @every 5s
-- How far behind this server is when it is a streaming replica. On a primary in_recovery is false and the lag columns are null.
select pg_is_in_recovery() as in_recovery,
       now() - pg_last_xact_replay_timestamp() as replay_lag,
       pg_last_wal_receive_lsn() as receive_lsn,
       pg_last_wal_replay_lsn() as replay_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) as replay_backlog;

-- %% aurora replica lag
-- @every 5s
-- needs: Aurora (aurora_replica_status)
-- Lag of every instance in the cluster as Aurora storage sees it; session_id MASTER_SESSION_ID is the writer. Run on any instance.
select server_id,
       session_id,
       replica_lag_in_msec,
       last_update_timestamp
from aurora_replica_status()
order by replica_lag_in_msec desc;

-- %% replication on primary
-- @every 5s
-- Walsenders and slots as seen from the primary (fails on a replica). An inactive slot with growing lag keeps WAL forever.
select r.client_addr,
       r.application_name,
       r.state,
       r.sent_lsn,
       r.write_lag,
       r.flush_lag,
       r.replay_lag
from pg_stat_replication r
order by r.replay_lag desc nulls last;

select s.slot_name,
       s.slot_type,
       s.active,
       s.wal_status,
       s.restart_lsn,
       s.confirmed_flush_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), coalesce(s.confirmed_flush_lsn, s.restart_lsn))) as lag
from pg_replication_slots s
order by pg_wal_lsn_diff(pg_current_wal_lsn(), coalesce(s.confirmed_flush_lsn, s.restart_lsn)) desc nulls last;

-- %% settings that matter
-- The handful of settings that explain most plans and most surprises; source says where each value comes from.
select s.name,
       s.setting,
       s.unit,
       s.source
from pg_settings s
where s.name in (
  'shared_buffers', 'work_mem', 'maintenance_work_mem', 'effective_cache_size', 'random_page_cost', 'seq_page_cost',
  'effective_io_concurrency', 'max_connections', 'statement_timeout', 'lock_timeout', 'idle_in_transaction_session_timeout',
  'track_io_timing', 'shared_preload_libraries', 'autovacuum_vacuum_scale_factor', 'autovacuum_analyze_scale_factor',
  'max_parallel_workers_per_gather', 'jit'
)
order by s.name;

-- %% extensions
-- Installed versus merely available: installed_version is null until CREATE EXTENSION runs in this database.
select e.name,
       e.default_version,
       e.installed_version
from pg_available_extensions e
where e.name in (
  'pg_stat_statements', 'pg_trgm', 'hypopg', 'pgstattuple', 'pg_buffercache', 'pg_prewarm', 'pg_visibility', 'pg_cron',
  'pgaudit', 'pg_partman', 'pglogical', 'pg_repack', 'postgres_fdw', 'dblink', 'postgis', 'vector', 'timescaledb',
  'citext', 'hstore', 'uuid-ossp', 'pgcrypto', 'btree_gin', 'btree_gist', 'aws_s3', 'aws_commons', 'aws_lambda'
)
order by e.installed_version is null, e.name;

-- %% locks on a table
-- @param table = 'users'
-- Who holds or waits for which lock on that table (a quoted relation name); granted = false rows are the waiters.
select l.pid,
       a.usename,
       l.locktype,
       l.mode,
       l.granted,
       a.state,
       now() - a.xact_start as in_tx_for,
       left(a.query, 120) as query
from pg_locks l
join pg_class c on c.oid = l.relation
join pg_stat_activity a on a.pid = l.pid
where c.relname = :table
  and l.pid <> pg_backend_pid()
order by l.granted, l.pid;

-- %% cancel a backend
-- @param pid
-- Stops the running query of that backend (like Ctrl-C in psql); the session stays connected. pg_terminate_backend(:pid) kills
-- the session instead. Your own role's sessions need no privilege; other roles' need pg_signal_backend (or rds_superuser).
select pg_cancel_backend(:pid) as cancelled;
