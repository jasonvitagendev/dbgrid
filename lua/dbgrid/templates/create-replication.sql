-- template-name: Create replication
-- template-tags: replication, migration
-- template-description: Build a publication / subscription copy (RDS PostgreSQL to Aurora, or any two servers): preflight, clear the target, indexes off for the copy, create the subscription, then indexes, sequences and a compare against the source
-- template-connections: source, target

-- %% preflight: target empty, no subscription yet
-- @conn target
-- @param keep = 'schema_migrations,ar_internal_metadata'
-- @param keep_schemas = 'ops,datadog'
-- Run before CREATE SUBSCRIPTION. Expect nonempty_tables = 0 and subscriptions = 0. :keep names the tables the
-- publication leaves out (here the two Rails keeps) and :keep_schemas the schemas that are the target's own: ops holds
-- the index definitions this notebook saves, datadog is the monitoring agent's. The subscription and publication
-- names are the :sub and :pub parameters, asked for once and remembered (\p lists them). The Logical replication
-- template is the live view of the copy once it runs; this one does the steps.
select (select count(*) from pg_stat_user_tables
         where n_live_tup > 0
           and schemaname <> all (string_to_array(:keep_schemas, ','))
           and relname <> all (string_to_array(:keep, ','))) as nonempty_tables,
       (select count(*) from pg_subscription) as subscriptions,
       (select count(*) from pg_tables
         where schemaname not in ('pg_catalog', 'information_schema')
           and schemaname <> all (string_to_array(:keep_schemas, ','))) as tables;

-- %% preflight: source publication and role
-- @conn source
-- @param replication_user = 'replicator'
-- One row per publication: its table count and publish_via_partition_root (partitions then arrive as their parent,
-- which a target with plain tables needs). The role in the connection secret must be allowed to replicate:
-- rds_replication on RDS and Aurora, the REPLICATION attribute elsewhere. logical_slots names what is there already;
-- other consumers (a Debezium connector, say) are normal, a slot already named after :sub is not. tables should
-- match the target's count.
select p.pubname,
       (select count(*) from pg_publication_tables t where t.pubname = p.pubname) as published_tables,
       p.pubviaroot as via_root,
       case when exists (select 1 from pg_roles where rolname = 'rds_replication')
            then pg_has_role(:replication_user, 'rds_replication', 'member')
            else (select rolreplication from pg_roles where rolname = :replication_user) end as role_can_replicate,
       (select string_agg(slot_name, ', ' order by slot_name) from pg_replication_slots where slot_type = 'logical') as logical_slots,
       (select count(*) from pg_tables where schemaname not in ('pg_catalog', 'information_schema')) as tables
from pg_publication p
order by p.pubname;

-- %% source: set the replication role's password from the secret
-- @conn source
-- @param role = replicator
-- @param replication_user = 'replicator'
-- @secret pw = scram:prod/db-replication via target
-- For a role that has no password yet, or after the secret changed; skip it when the role already logs in with the
-- secret's password. Name the same secret as "create subscription" below: it is read through the target's aws
-- profile (via target), since that is where the subscription reads it, while the statement runs on the source. :pw
-- is the SCRAM-SHA-256 verifier of the secret's password, hashed here like psql's \password, so the password itself
-- never reaches the source (its log, pg_stat_statements). :role is the role as a bare name, which ALTER ROLE wants,
-- and :replication_user the same name as a string. A write on the source: a read-only connection refuses it, and
-- the login must be allowed to alter the role. Expect can_login = t and no valid_until.
alter role :role password :pw;
select rolname, rolcanlogin as can_login, rolvaliduntil as valid_until
from pg_roles
where rolname = :replication_user;

-- %% clear target: what the truncate will empty (review before the next cell)
-- @conn target
-- @nolimit
-- @param keep = 'schema_migrations,ar_internal_metadata'
-- @param keep_schemas = 'ops,datadog'
-- A new subscription with copy_data copies every published table again, so rows left from an earlier copy collide
-- (duplicate keys on tables with a unique index, silently doubled rows on the ones without). Every schema except
-- :keep_schemas and every table except :keep; an already empty table is harmless. Check nothing odd is here.
select schemaname || '.' || relname as table_name,
       n_live_tup as rows_estimate,
       pg_size_pretty(pg_total_relation_size(format('%I.%I', schemaname, relname)::regclass)) as size_here
from pg_stat_user_tables
where schemaname <> all (string_to_array(:keep_schemas, ','))
  and relname <> all (string_to_array(:keep, ','))
order by n_live_tup desc, relname;

-- %% clear target: truncate everything the copy will refill
-- @conn target
-- @param keep = 'schema_migrations,ar_internal_metadata'
-- @param keep_schemas = 'ops,datadog'
-- Same list as above, one statement, so it is all or nothing. cascade also empties any table reached through a
-- foreign key, which is in the list anyway. The two lists go in through session settings because placeholders inside
-- the dollar-quoted body are left alone. Run "preflight: target empty" after this; nonempty_tables must be 0.
select set_config('dbgrid.keep', :keep, false), set_config('dbgrid.keep_schemas', :keep_schemas, false);
do $$
declare stmt text;
begin
  select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
    into stmt
  from pg_tables
  where schemaname not in ('pg_catalog', 'information_schema')
    and schemaname <> all (string_to_array(current_setting('dbgrid.keep_schemas'), ','))
    and tablename <> all (string_to_array(current_setting('dbgrid.keep'), ','));
  execute stmt;
end $$;

-- %% before copy: secondary indexes the next cell drops (review)
-- @conn target
-- @nolimit
-- @param keep_schemas = 'ops,datadog'
-- COPY into an indexed table pays for every index on every row; a first run with them in place had the subscriber's
-- CPU and log writes at the limit. The copy goes faster into bare tables, with the indexes built once afterwards.
-- Kept: primary keys, anything backing a constraint (unique, exclusion), the replica identity index, indexes attached
-- to a partitioned parent (the parent's index covers them), and every index on a table that has replica identity
-- FULL and no primary key: the apply worker needs an index to find the rows it updates. With a primary key it uses
-- that one, so FULL tables that have a key lose their secondary indexes like the rest. A run that kept them copied
-- such a table at 13k rows/s against 100k rows/s for a bare one. The :keep_schemas schemas are not touched.
select i.indrelid::regclass as table_name,
       i.indexrelid::regclass as index_name,
       pg_get_indexdef(i.indexrelid) as definition
from pg_index i
join pg_class t on t.oid = i.indrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
  and n.nspname <> all (string_to_array(:keep_schemas, ','))
  and t.relkind in ('r', 'p')
  and (t.relreplident <> 'f'
       or exists (select 1 from pg_index p where p.indrelid = t.oid and p.indisprimary))
  and not i.indisprimary
  and not i.indisreplident
  and not exists (select 1 from pg_constraint c where c.conindid = i.indexrelid)
  and not exists (select 1 from pg_inherits ih where ih.inhrelid = i.indexrelid)
order by 1, 2;

-- %% before copy: drop them, definitions saved in ops.indexes_dropped_for_copy
-- @conn target
-- @param keep_schemas = 'ops,datadog'
-- Same selection as above. Each CREATE INDEX statement is saved before its index is dropped, in one transaction, so
-- "after copy: recreate the dropped indexes" can put them back. Running it twice is harmless: an index already gone
-- is not selected again.
select set_config('dbgrid.keep_schemas', :keep_schemas, false);
create schema if not exists ops;
create table if not exists ops.indexes_dropped_for_copy (
  index_name   text primary key,
  table_name   text not null,
  definition   text not null,
  dropped_at   timestamptz not null default now(),
  recreated_at timestamptz
);
do $$
declare r record;
begin
  for r in
    select i.indexrelid::regclass as index_name,
           i.indrelid::regclass as table_name,
           pg_get_indexdef(i.indexrelid) as definition
    from pg_index i
    join pg_class t on t.oid = i.indrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
      and n.nspname <> all (string_to_array(current_setting('dbgrid.keep_schemas'), ','))
      and t.relkind in ('r', 'p')
      and (t.relreplident <> 'f'
           or exists (select 1 from pg_index p where p.indrelid = t.oid and p.indisprimary))
      and not i.indisprimary
      and not i.indisreplident
      and not exists (select 1 from pg_constraint c where c.conindid = i.indexrelid)
      and not exists (select 1 from pg_inherits ih where ih.inhrelid = i.indexrelid)
  loop
    insert into ops.indexes_dropped_for_copy (index_name, table_name, definition)
    values (r.index_name::text, r.table_name::text, r.definition)
    on conflict (index_name) do update
      set definition = excluded.definition, dropped_at = now(), recreated_at = null;
    execute format('drop index %s', r.index_name);
  end loop;
end $$;
select count(*) as dropped_now_missing from ops.indexes_dropped_for_copy where recreated_at is null;

-- %% create subscription
-- @conn target
-- @notx
-- @secret conn = conninfo:prod/db-replication
-- Name the secret that holds the source's replication user after conninfo: above. :conn is built from it when the
-- cell runs (host, port, dbname, user, password, sslmode=require), through the target's aws profile, and is not
-- saved in this notebook or in history. The statement cannot run inside a transaction block, so it stays alone.
-- binary = true: the initial copy and the stream skip text formatting on both ends. Needs the publisher on PG 16+
-- and identical column types on both sides, else the sync errors and text is the fallback.
create subscription :sub
  connection :conn
  publication :pub
  with (copy_data = true, binary = true);

-- %% pause replication
-- @conn target
-- Stops the apply worker and the table copies. The source keeps the slot, so its retained WAL grows for as long as
-- this stays off (watch "what the slots hold back" in the Logical replication notebook). A table that was mid-copy
-- ('copying') starts its copy again from zero on resume; tables already 'ready' only catch up.
alter subscription :sub disable;

-- %% resume replication
-- @conn target
-- The workers come back within a few seconds; "initial sync progress" shows copying again if any table was unfinished.
alter subscription :sub enable;

-- %% replication status
-- @conn target
-- enabled, the workers alive (pid not null) and the per-state table counts, one row per subscription.
select s.subname,
       s.subenabled as enabled,
       (select count(*) from pg_stat_subscription w where w.subname = s.subname and w.pid is not null) as workers,
       count(*) filter (where r.srsubstate = 'i') as not_started,
       count(*) filter (where r.srsubstate = 'd') as copying,
       count(*) filter (where r.srsubstate in ('f', 's')) as catching_up,
       count(*) filter (where r.srsubstate = 'r') as ready
from pg_subscription s
left join pg_subscription_rel r on r.srsubid = s.oid
group by s.subname, s.subenabled
order by s.subname;

-- %% after copy: everything ready, no errors
-- @conn target
-- ready must equal tables and both error counts must be 0 before trusting the data.
select (select count(*) from pg_subscription_rel) as tables,
       (select count(*) from pg_subscription_rel where srsubstate = 'r') as ready,
       (select coalesce(sum(apply_error_count), 0) from pg_stat_subscription_stats) as apply_errors,
       (select coalesce(sum(sync_error_count), 0) from pg_stat_subscription_stats) as sync_errors;

-- %% after copy: recreate the dropped indexes
-- @conn target
-- Run once every table is ready, while the writer is still the size you gave it for the copy. Builds each saved index
-- in turn and marks it done; the whole cell is one transaction, so a failure leaves nothing half built and a rerun
-- starts from the ones still missing. The two settings size the sort memory and the parallel build (2GB and 4 workers
-- suit a 32 GB box) and last for this session only. Then run "after copy: analyze target".
set maintenance_work_mem = '2GB';
set max_parallel_maintenance_workers = 4;
do $$
declare r record;
begin
  for r in
    select index_name, definition
    from ops.indexes_dropped_for_copy
    where recreated_at is null
    order by table_name, index_name
  loop
    execute r.definition;
    update ops.indexes_dropped_for_copy set recreated_at = now() where index_name = r.index_name;
  end loop;
end $$;
select count(*) filter (where recreated_at is null) as still_missing, count(*) as saved
from ops.indexes_dropped_for_copy;

-- %% after copy: index rebuild progress
-- @conn target
-- Run from a second cell while "recreate the dropped indexes" is still going; each cell run is its own psql, so this
-- session can see the other one. ops.indexes_dropped_for_copy stays unchanged until that cell commits, so progress
-- comes from pg_stat_progress_create_index (the index being built now) and from the locks the builder holds (one
-- AccessExclusiveLock per index already built, rough). Only the table name resolves: the new index is uncommitted.
-- Phases: scanning table (pct_blocks), sorting live tuples (no counter, watch db_size), loading tuples in tree
-- (pct_tuples). No rows means nothing is building: the cell finished, or it failed and rolled back.
select p.relid::regclass                                              as table_being_indexed,
       p.phase,
       round(100.0 * p.blocks_done / nullif(p.blocks_total, 0), 1)     as pct_blocks,
       round(100.0 * p.tuples_done / nullif(p.tuples_total, 0), 1)     as pct_tuples,
       now() - a.xact_start                                            as cell_running_for,
       (select count(*) from pg_locks l
         where l.pid = p.pid and l.locktype = 'relation' and l.mode = 'AccessExclusiveLock') as built_so_far_approx,
       (select count(*) from ops.indexes_dropped_for_copy)             as saved_total,
       pg_size_pretty(pg_database_size(current_database()))            as db_size
from pg_stat_progress_create_index p
join pg_stat_activity a on a.pid = p.pid;

-- %% after copy: index check (every row should say ok)
-- @conn target
-- @nolimit
-- Each saved index must exist again, with the definition that was saved, and be valid. Problems sort to the top.
-- A plain CREATE INDEX that commits is always valid, so INVALID would mean something else touched it since. This
-- only knows the indexes the drop cell saved; "index compare against source" below checks the target against the
-- source itself.
with checked as (
  select d.index_name, d.table_name,
         case when i.indexrelid is null then 'MISSING'
              when not i.indisvalid then 'INVALID'
              when pg_get_indexdef(i.indexrelid) <> d.definition then 'DEFINITION DIFFERS'
              when d.recreated_at is null then 'ok, but not marked recreated'
              else 'ok' end as status,
         pg_size_pretty(pg_relation_size(i.indexrelid)) as size,
         d.recreated_at
  from ops.indexes_dropped_for_copy d
  left join pg_class c on c.oid = to_regclass(d.index_name)
  left join pg_index i on i.indexrelid = c.oid
)
select * from checked
order by status = 'ok', table_name, index_name;

-- %% after copy: index compare against source (run here, then :Dbgrid diff <source connection>)
-- @conn target
-- @nolimit
-- Same query on both sides; the diff lists what one side has and the other lacks (a + row is an index the target is
-- missing). Covers every index, constraint-backed ones too. Only tables in a publication (source) or the subscription
-- (target). Source partitions are skipped and ONLY is dropped from their parents' definitions, since a target that
-- receives them through the root holds plain tables. The first column is id so the diff matches rows by index and
-- marks a drifted definition as changed. Escape a space in the connection name: :Dbgrid diff my\ source.
select n.nspname || '.' || t.relname || '.' || c.relname as id,
       replace(pg_get_indexdef(i.indexrelid), ' ON ONLY ', ' ON ') as definition
from pg_index i
join pg_class c on c.oid = i.indexrelid
join pg_class t on t.oid = i.indrelid
join pg_namespace n on n.oid = t.relnamespace
where t.relkind in ('r', 'p')
  and not exists (select 1 from pg_inherits ih where ih.inhrelid = t.oid)
  and (exists (select 1 from pg_publication_tables p where p.schemaname = n.nspname and p.tablename = t.relname)
       or exists (select 1 from pg_subscription_rel r where r.srrelid = t.oid))
order by 1;

-- %% after copy: analyze target
-- @conn target
-- @notx
-- The row-count cells in the Logical replication notebook read pg_stat_user_tables, which is empty until this runs.
analyze;

-- %% after copy: sequence reset statements (generate, review, then run them)
-- @conn target
-- @nolimit
-- Sequence values are not replicated. This prints one setval per owned sequence, past the copied data. The next cell
-- runs the same thing; this one is for reading first. Do it before anything writes to the target.
select format('select setval(%L, coalesce((select max(%I) from %s), 0) + 1, false);',
              s.seqrelid::regclass, a.attname, d.refobjid::regclass) as statement
from pg_sequence s
join pg_depend d on d.objid = s.seqrelid and d.deptype in ('a', 'i')
join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
order by 1;

-- %% after copy: sequence reset (apply)
-- @conn target
-- @nolimit
-- Runs the statements the generator prints, no copy step. setval is not transactional, so what this sets stays set
-- even if the cell fails halfway. Then run "sequence check" below: every row should say ok.
do $$
declare r record;
begin
  for r in
    select s.seqrelid::regclass as seq, a.attname as col, d.refobjid::regclass as tbl
    from pg_sequence s
    join pg_depend d on d.objid = s.seqrelid and d.deptype in ('a', 'i')
    join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
  loop
    execute format('select setval(%L, coalesce((select max(%I) from %s), 0) + 1, false)', r.seq, r.col, r.tbl);
  end loop;
end $$;

-- %% after copy: sequence check (every row should say ok)
-- @conn target
-- @nolimit
-- Same sequences as the generator. next_value is what nextval would return now; it must sit above the max already in
-- the table. query_to_xml is the trick that runs a per-table max (and a per-sequence read) inside a plain select;
-- pg_sequences is no use here, its last_value is null while is_called is false, which is what setval(.., false) leaves.
-- BEHIND means a nextval would collide with a copied row: rerun the setval for that sequence.
with owned as (
  select s.seqrelid::regclass as sequence, d.refobjid::regclass as "table", a.attname as "column",
         (xpath('/row/max/text()',
                query_to_xml(format('select max(%I) from %s', a.attname, d.refobjid::regclass), false, true, '')
         ))[1]::text::bigint as max_in_table,
         (xpath('/row/last_value/text()',
                query_to_xml(format('select last_value from %s', s.seqrelid::regclass), false, true, '')
         ))[1]::text::bigint as last_value,
         (xpath('/row/is_called/text()',
                query_to_xml(format('select is_called from %s', s.seqrelid::regclass), false, true, '')
         ))[1]::text::boolean as is_called
  from pg_sequence s
  join pg_depend d on d.objid = s.seqrelid and d.deptype in ('a', 'i')
  join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
)
select sequence, "table", "column", max_in_table,
       case when is_called then last_value + 1 else last_value end as next_value,
       case when (case when is_called then last_value + 1 else last_value end) > coalesce(max_in_table, 0) then 'ok'
            else 'BEHIND' end as status
from owned
order by status, "table";

-- %% probe: write on source
-- @conn source
-- @notx
-- @param table = users
-- Lag probe: one row of :table has updated_at set to its own value, so no data changes. For the worst case pick a
-- table with replica identity FULL and no primary key (the apply worker scans for the row). Note the time, then
-- watch the next cell.
update :table set updated_at = updated_at
where ctid = (select ctid from :table limit 1)
returning ctid, updated_at, now() as written_at;

-- %% probe: lag on source after the write
-- @conn source
-- @every 2s
-- 0 bytes once the target has confirmed the probe.
select slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as subscriber_lag
from pg_replication_slots
where slot_type = 'logical';

-- %% stream test: dblink extension (one-time)
-- @conn target
-- Lets the target pull rows from the source over the same path the subscription uses, so the stream rate can be
-- measured without any extra host. Drop it again with the cleanup cell when done.
create extension if not exists dblink;

-- %% stream test: one stream from the source (run alone first, note mb_per_s)
-- @conn target
-- @param table = users
-- Pulls 100000 rows of :table as text over the subscription's own connection string (pg_subscription keeps it,
-- password included, readable by the owner). bytes is what crossed the wire. Reads only. Raise the limit if the pull
-- finishes in under 20 s, the window needs time to open.
select n as rows,
       pg_size_pretty(b) as bytes,
       round(extract(epoch from clock_timestamp() - now())::numeric, 1) as seconds,
       round((b / extract(epoch from clock_timestamp() - now()) / 1e6)::numeric, 1) as mb_per_s
from (select count(*) as n, sum(octet_length(x))::bigint as b
      from dblink((select subconninfo from pg_subscription order by oid limit 1),
                  format('select t::text from %s t limit 100000', :table::regclass)) as r(x text)) s;

-- %% stream test: second stream, start it right after the one above
-- @conn target
-- @param table = users
-- Same pull, the next 100000 rows, on its own connection. Run "one stream" and then this one straight away so the
-- two overlap. If each still shows the solo mb_per_s, the ceiling is per connection and splitting the big table
-- across row-filtered publications helps. If the two share it, the ceiling is on the source's side.
select n as rows,
       pg_size_pretty(b) as bytes,
       round(extract(epoch from clock_timestamp() - now())::numeric, 1) as seconds,
       round((b / extract(epoch from clock_timestamp() - now()) / 1e6)::numeric, 1) as mb_per_s
from (select count(*) as n, sum(octet_length(x))::bigint as b
      from dblink((select subconninfo from pg_subscription order by oid limit 1),
                  format('select t::text from %s t offset 100000 limit 100000', :table::regclass)) as r(x text)) s;

-- %% stream test: cleanup
-- @conn target
drop extension if exists dblink;

-- %% rollback: drop the subscription
-- @conn target
-- @notx
-- Only on the database that really subscribes: this also drops the slot on the source, which is what a rollback
-- wants. On a cluster restored from a snapshot of the target, or when the source cannot be reached, use the detach
-- cell below instead. Everything copied stays on the target.
drop subscription :sub;

-- %% rollback: detach (a restored copy of the target, or the source unreachable)
-- @conn target
-- @notx
-- A cluster restored from a snapshot of the target still carries the subscription, with the source's connection
-- string and password in it. A plain DROP SUBSCRIPTION there reaches the source and drops the SOURCE's slot, which
-- stops the real replication. Detaching first leaves the slot alone: note the oid the first statement prints, the
-- tablesync slots of any table still copying are named after it on the source (next cell).
select oid as subscription_oid, subname from pg_subscription;
alter subscription :sub disable;
alter subscription :sub set (slot_name = none);
drop subscription :sub;

-- %% rollback: drop the slots a detach left on the source
-- @conn source
-- @param slot =
-- @param subscription_oid =
-- Run on the source after a detach, never after a plain drop (nothing is left then). Both values are asked for:
-- the slot is the subscription name as a SQL string ('my_sub'), the oid the number the detach cell printed. The
-- first statement is the review; the second drops the main slot and the pg_<oid>_sync_% tablesync slots. Only
-- inactive logical slots of this database are considered, so a slot another consumer is connected to (the real
-- subscriber, a Debezium connector) is never dropped, whatever is typed.
select slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as retained_wal
from pg_replication_slots
where slot_type = 'logical' and database = current_database()
  and (slot_name = :slot or slot_name like 'pg_' || :subscription_oid || '_sync_%')
order by slot_name;
select slot_name, pg_drop_replication_slot(slot_name)
from pg_replication_slots
where slot_type = 'logical' and database = current_database() and not active
  and (slot_name = :slot or slot_name like 'pg_' || :subscription_oid || '_sync_%');
