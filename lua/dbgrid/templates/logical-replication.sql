-- template-name: Logical replication
-- template-tags: replication, migration
-- template-description: Watch a publication / subscription migration (RDS PostgreSQL to Aurora, or any two servers): initial sync, lag, and load on both sides
-- template-connections: source, target

-- %% replication at a glance
-- @conn source
-- @every 5s
-- @record
-- @alert wal_status = unreserved, wal_status = lost
-- One row per logical slot on the source. lag is WAL the target has not confirmed yet; wal_retained is what the source
-- must keep on disk for the slot (it grows while the target is down or slow, and it is the source's storage at risk).
-- During the initial copy every table being copied has a short-lived slot of its own (pg_<n>_sync_<n>_...).
-- The alert fires when a slot is about to lose (or has lost) WAL it still needs; add your own limit to it, for
-- example lag_bytes > 5000000000.
select s.slot_name,
       s.active,
       s.wal_status,
       r.state as sender_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), s.confirmed_flush_lsn) as lag_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), s.confirmed_flush_lsn)) as lag,
       pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) as wal_retained_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn)) as wal_retained,
       r.write_lag,
       r.flush_lag,
       r.replay_lag
from pg_replication_slots s
left join pg_stat_replication r on r.pid = s.active_pid
where s.slot_type = 'logical'
order by s.slot_name;

-- %% initial sync progress
-- @conn target
-- @every 10s
-- @record
-- Tables of every subscription in this database by sync state. The initial copy is over when ready = tables;
-- copying is capped by max_sync_workers_per_subscription, so not_started drains at that width.
select s.subname,
       s.subenabled as enabled,
       count(r.srrelid) as tables,
       count(*) filter (where r.srsubstate = 'i') as not_started,
       count(*) filter (where r.srsubstate = 'd') as copying,
       count(*) filter (where r.srsubstate in ('f', 's')) as catching_up,
       count(*) filter (where r.srsubstate = 'r') as ready
from pg_subscription s
left join pg_subscription_rel r on r.srsubid = s.oid
where s.subdbid = (select d.oid from pg_database d where d.datname = current_database())
group by s.subname, s.subenabled
order by s.subname;

-- %% tables not ready yet
-- @conn target
-- The tables behind the counts above, biggest first. A table that stays in 'copying' with no row in the copy cell
-- below has a failing sync worker: look at subscription errors and the target's log.
select r.srrelid::regclass as table_name,
       case r.srsubstate
         when 'i' then 'not started'
         when 'd' then 'copying'
         when 'f' then 'copy finished'
         when 's' then 'synchronized'
         else r.srsubstate::text
       end as state,
       r.srsublsn,
       pg_size_pretty(pg_total_relation_size(r.srrelid)) as size_here
from pg_subscription_rel r
where r.srsubstate <> 'r'
order by pg_total_relation_size(r.srrelid) desc;

-- %% copies running
-- @conn target
-- @every 5s
-- @record
-- needs: PostgreSQL 14+ for pg_stat_progress_copy
-- The table copies in flight right now and how far each one is. Compare copied with the table's size on the source.
select p.pid,
       p.relid::regclass as table_name,
       p.command,
       p.type,
       p.tuples_processed,
       p.bytes_processed,
       pg_size_pretty(p.bytes_processed) as copied
from pg_stat_progress_copy p
order by p.bytes_processed desc;

-- %% apply and sync workers
-- @conn target
-- @every 5s
-- The subscription's workers: the row without syncing_table is the apply worker, the others are table copies.
-- pid null means the worker is down; behind is the time since the worker last confirmed a position to the source.
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
-- @conn target
-- @every 10s
-- @record
-- @alert apply_error_count > 0, sync_error_count > 0
-- needs: PostgreSQL 15+ for pg_stat_subscription_stats
-- Apply and initial-sync errors since stats_reset. A rising count is a worker failing and restarting in a loop
-- (a conflict, a missing table or column, a permission): the reason is in the target's log.
select s.subname,
       s.apply_error_count,
       s.sync_error_count,
       s.stats_reset
from pg_stat_subscription_stats s
order by s.apply_error_count desc, s.sync_error_count desc;

-- %% load on source
-- @conn source
-- @every 5s
-- @record
-- Client sessions on the source right now. The initial copy reads every table once, so expect waiting_on_io to rise
-- while it runs; waiting_on_lock should stay near zero. oldest_tx_s matters twice: the slot cannot be created while
-- an older transaction is open, and decoding holds a transaction back until it commits.
select count(*) as sessions,
       count(*) filter (where a.state = 'active') as active,
       count(*) filter (where a.state = 'idle in transaction') as idle_in_tx,
       count(*) filter (where a.state = 'active' and a.wait_event_type = 'Lock') as waiting_on_lock,
       count(*) filter (where a.state = 'active' and a.wait_event_type = 'IO') as waiting_on_io,
       count(*) filter (where a.state = 'active' and a.wait_event_type = 'LWLock') as waiting_on_lwlock,
       extract(epoch from max(now() - a.xact_start))::int as oldest_tx_s,
       extract(epoch from max(now() - a.query_start) filter (where a.state = 'active'))::int as longest_query_s
from pg_stat_activity a
where a.backend_type = 'client backend'
  and a.pid <> pg_backend_pid();

-- %% load on target
-- @conn target
-- @every 5s
-- @record
-- The same on the target. Before cutover the only work here is replication, so client sessions should be few;
-- the replication workers themselves are in the cell below.
select count(*) as sessions,
       count(*) filter (where a.state = 'active') as active,
       count(*) filter (where a.state = 'idle in transaction') as idle_in_tx,
       count(*) filter (where a.state = 'active' and a.wait_event_type = 'Lock') as waiting_on_lock,
       count(*) filter (where a.state = 'active' and a.wait_event_type = 'IO') as waiting_on_io,
       count(*) filter (where a.state = 'active' and a.wait_event_type = 'LWLock') as waiting_on_lwlock,
       extract(epoch from max(now() - a.xact_start))::int as oldest_tx_s,
       extract(epoch from max(now() - a.query_start) filter (where a.state = 'active'))::int as longest_query_s
from pg_stat_activity a
where a.backend_type = 'client backend'
  and a.pid <> pg_backend_pid();

-- %% throughput on source
-- @conn source
-- @every 5s
-- @record
-- @rate xact_commit, rows_written, rows_read, blks_read, wal_bytes
-- Counters for this database since stats_reset: they only grow, so each one named by @rate gets a _per_s column,
-- the change since the previous tick per second. wal_bytes is all WAL the server has written, so wal_bytes_per_s
-- is how fast the source produces what the target has to apply.
select d.xact_commit,
       d.xact_rollback,
       d.tup_inserted + d.tup_updated + d.tup_deleted as rows_written,
       d.tup_returned as rows_read,
       d.blks_read,
       d.blks_hit,
       d.temp_bytes,
       d.deadlocks,
       pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0') as wal_bytes
from pg_stat_database d
where d.datname = current_database();

-- %% throughput on target
-- @conn target
-- @every 5s
-- @record
-- @rate xact_commit, rows_written, rows_read, blks_read
-- The same counters on the target: rows_written is the copy plus the applied changes, so once the initial sync is
-- over rows_written_per_s should follow the source's.
select d.xact_commit,
       d.xact_rollback,
       d.tup_inserted + d.tup_updated + d.tup_deleted as rows_written,
       d.tup_returned as rows_read,
       d.blks_read,
       d.blks_hit,
       d.temp_bytes,
       d.deadlocks
from pg_stat_database d
where d.datname = current_database();

-- %% cloudwatch on source
-- @conn source
-- @every 60s
-- @record
-- @metrics CPUUtilization, CPUCreditBalance, NetworkTransmitThroughput, ReadThroughput, ReadIOPS, FreeableMemory, FreeStorageSpace, TransactionLogsDiskUsage, OldestReplicationSlotLag
-- needs: an AWS connection (cluster or instance in its aws block) allowed to call cloudwatch:GetMetricData
-- No SQL here: the newest CloudWatch datapoint of each metric, which is what the database cannot say about itself.
-- CPU and IOPS are the load of the initial copy; FreeStorageSpace against TransactionLogsDiskUsage is the room the
-- slot's WAL has left. Datapoints are a minute apart and a minute or two late (datapoint_utc says which one this is).
-- Name metrics after @metrics to sample others. On a burstable source, NetworkTransmitThroughput is the one that
-- shows the network burst running out (a t3.small settles on about 16 MB/s) and CPUCreditBalance the CPU one.

-- %% cloudwatch on target
-- @conn target
-- @every 60s
-- @record
-- @metrics CPUUtilization, NetworkReceiveThroughput, WriteIOPS, CommitLatency, FreeableMemory, DatabaseConnections
-- needs: an AWS connection (cluster or instance in its aws block) allowed to call cloudwatch:GetMetricData
-- The same for the target: CPU, memory and write IOPS are what the copy and the apply workers cost it.

-- %% walsenders on source
-- @conn source
-- What the processes feeding the target are doing. A walsender waiting on WalSenderWaitForWAL is idle (caught up);
-- one busy in a COPY is an initial table copy.
select a.pid,
       a.application_name,
       a.client_addr,
       a.state,
       a.wait_event_type,
       a.wait_event,
       now() - a.backend_start as up_for,
       left(a.query, 80) as query
from pg_stat_activity a
where a.backend_type = 'walsender'
order by a.backend_start;

-- %% replication workers on target
-- @conn target
-- The launcher, the apply worker and the table sync workers on the target, and what each one waits for.
select a.pid,
       a.backend_type,
       a.state,
       a.wait_event_type,
       a.wait_event,
       now() - a.backend_start as up_for
from pg_stat_activity a
where a.backend_type like 'logical replication%'
order by a.backend_start;

-- %% decoding stats
-- @conn source
-- needs: PostgreSQL 14+ for pg_stat_replication_slots
-- How hard decoding works per slot. spill_bytes is transactions too big for logical_decoding_work_mem written to disk
-- on the source: a lot of it means big transactions, and raising that setting is the fix.
select s.slot_name,
       s.total_txns,
       pg_size_pretty(s.total_bytes) as decoded,
       s.spill_txns,
       s.spill_count,
       pg_size_pretty(s.spill_bytes) as spilled,
       s.stream_txns,
       pg_size_pretty(s.stream_bytes) as streamed,
       s.stats_reset
from pg_stat_replication_slots s
order by s.slot_name;

-- %% what the slots hold back
-- @conn source
-- A slot pins WAL and the catalog xmin horizon on the source. catalog_xmin_age growing without bound keeps vacuum from
-- cleaning the system catalogs; wal_status 'unreserved' or 'lost' means max_slot_wal_keep_size is about to break
-- (or has broken) the slot. Drop a slot you no longer need: an abandoned one fills the source's disk.
select s.slot_name,
       s.active,
       s.wal_status,
       age(s.xmin) as xmin_age,
       age(s.catalog_xmin) as catalog_xmin_age,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn)) as wal_retained,
       pg_size_pretty(s.safe_wal_size) as safe_wal_left
from pg_replication_slots s
order by pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) desc nulls last;

-- %% long transactions on source
-- @conn source
-- @every 10s
-- Transactions open for more than 30 seconds, oldest first. Creating the slot waits for the ones open at that moment,
-- and a long writing transaction reaches the target only when it commits, so it shows up as lag.
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

-- %% settings on source
-- @conn source
-- What logical replication needs on the publisher: wal_level logical (on RDS that is rds.logical_replication = 1 and a
-- reboot), a free slot and walsender per subscription plus one per table copied in parallel.
select s.name,
       s.setting,
       s.unit,
       s.pending_restart
from pg_settings s
where s.name in ('wal_level', 'rds.logical_replication', 'max_replication_slots', 'max_wal_senders',
                 'max_slot_wal_keep_size', 'logical_decoding_work_mem', 'wal_sender_timeout')
order by s.name;

-- %% settings on target
-- @conn target
-- What the subscriber needs: max_logical_replication_workers covers the apply worker plus the sync workers, and all of
-- them come out of max_worker_processes. max_sync_workers_per_subscription is how many tables are copied at once, so it
-- is the knob for how hard the initial sync hits the source.
select s.name,
       s.setting,
       s.unit,
       s.pending_restart
from pg_settings s
where s.name in ('max_logical_replication_workers', 'max_sync_workers_per_subscription', 'max_worker_processes',
                 'max_replication_slots', 'wal_receiver_timeout')
order by s.name;

-- %% publications
-- @conn source
-- What is published, and which operations. Logical replication carries no DDL and no sequence values.
select p.pubname,
       p.puballtables as all_tables,
       p.pubinsert,
       p.pubupdate,
       p.pubdelete,
       p.pubtruncate,
       (select count(*) from pg_publication_tables t where t.pubname = p.pubname) as tables
from pg_publication p
order by p.pubname;

-- %% tables not published
-- @conn source
-- Ordinary tables in no publication: they stay empty on the target. With publish_via_partition_root the partitions
-- are published under their parent and are listed here although their rows do arrive.
select n.nspname as schemaname,
       c.relname,
       pg_size_pretty(pg_total_relation_size(c.oid)) as size
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r'
  and c.relpersistence = 'p'
  and not exists (select 1
                  from pg_publication_tables t
                  where t.schemaname = n.nspname
                    and t.tablename = c.relname)
  and n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
  and n.nspname not like 'pg\_temp\_%'
order by pg_total_relation_size(c.oid) desc;

-- %% tables without replica identity
-- @conn source
-- Tables with replica identity NOTHING, or DEFAULT without a primary key. Once such a table is published, every
-- UPDATE or DELETE on it fails on the source. Fix: add a primary key, or ALTER TABLE ... REPLICA IDENTITY USING INDEX / FULL.
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

-- %% biggest tables on source
-- @conn source
-- The initial copy takes about as long as its biggest tables: this is the order to expect them to finish last.
select t.schemaname,
       t.relname,
       t.n_live_tup,
       pg_size_pretty(pg_table_size(t.relid)) as table_size,
       pg_size_pretty(pg_indexes_size(t.relid)) as index_size
from pg_stat_user_tables t
order by pg_total_relation_size(t.relid) desc
limit 30;

-- %% row counts on source
-- @conn source
-- Approximate live rows per table from the statistics; run the matching cell on the target and diff the two results.
-- Counts drift with vacuum and analyze timing (the target's are empty until it is analyzed), so use the exact count
-- cells for a final check.
select t.schemaname,
       t.relname,
       t.n_live_tup
from pg_stat_user_tables t
order by t.schemaname, t.relname;

-- %% row counts on target
-- @conn target
-- Same on the target; the diff against the source cell shows tables that are behind or never synced.
select t.schemaname,
       t.relname,
       t.n_live_tup
from pg_stat_user_tables t
order by t.schemaname, t.relname;

-- %% exact count on source
-- @conn source
-- @param table = users
-- Exact row count of one table; the value is an identifier (schema.table works) inserted verbatim into the FROM clause.
-- On a busy source it keeps changing; compare with the target cell once lag is zero.
select count(*) as row_count
from :table;

-- %% exact count on target
-- @conn target
-- @param table = users
-- Same table on the target (the value is an identifier, inserted verbatim).
select count(*) as row_count
from :table;

-- %% sequence values on source
-- @conn source
-- Logical replication does not carry sequence values: before the application writes to the target, its sequences must
-- be at or above the source's, or new rows collide with old ids. last_value is null for sequences never used.
select s.schemaname,
       s.sequencename,
       s.last_value
from pg_sequences s
order by 1, 2;

-- %% sequence values on target
-- @conn target
-- Same on the target; diff against the source cell. Fix a lagging one with select setval('seq', <source value + margin>).
select s.schemaname,
       s.sequencename,
       s.last_value
from pg_sequences s
order by 1, 2;

-- %% writes in flight on source
-- @conn source
-- @every 5s
-- For the cutover: a backend gets a transaction id only when it modifies data, so this counts sessions with a write in
-- progress. It must read zero, and lag in the first cell must be 0 bytes, before the application moves to the target.
select count(*) as writing_now
from pg_stat_activity a
where a.backend_xid is not null
  and a.pid <> pg_backend_pid();
