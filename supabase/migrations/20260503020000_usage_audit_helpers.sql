-- Helpers to identify low-usage tables/functions before cleanup.
-- Safe migration: creates only views/functions for audit (no DROP).

create schema if not exists maintenance;

create or replace view maintenance.table_usage_audit as
select
  n.nspname as schema_name,
  c.relname as table_name,
  coalesce(s.seq_scan, 0) as seq_scan,
  coalesce(s.idx_scan, 0) as idx_scan,
  coalesce(s.n_tup_ins, 0) as rows_inserted,
  coalesce(s.n_tup_upd, 0) as rows_updated,
  coalesce(s.n_tup_del, 0) as rows_deleted,
  coalesce(s.n_live_tup, 0) as live_rows,
  pg_total_relation_size(c.oid) as total_bytes,
  case
    when coalesce(s.seq_scan, 0) + coalesce(s.idx_scan, 0) = 0
      and coalesce(s.n_tup_ins, 0) + coalesce(s.n_tup_upd, 0) + coalesce(s.n_tup_del, 0) = 0
    then true
    else false
  end as candidate_unused
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_stat_user_tables s on s.relid = c.oid
where c.relkind = 'r'
  and n.nspname not in ('pg_catalog', 'information_schema', 'auth', 'storage', 'realtime', 'vault', 'extensions')
order by total_bytes desc;

create or replace view maintenance.function_usage_audit as
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as args,
  coalesce(sf.calls, 0) as calls,
  sf.total_time,
  sf.self_time,
  case when coalesce(sf.calls, 0) = 0 then true else false end as candidate_unused
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
left join pg_stat_user_functions sf on sf.funcid = p.oid
where n.nspname not in ('pg_catalog', 'information_schema', 'auth', 'storage', 'realtime', 'vault', 'extensions')
order by calls asc, schema_name, function_name;

create or replace function maintenance.cleanup_recommendations(
  p_min_table_bytes bigint default 1048576,
  p_include_integration boolean default false
)
returns table(kind text, object_name text, reason text)
language sql
stable
as $$
  with table_candidates as (
    select
      'table'::text as kind,
      format('%I.%I', schema_name, table_name) as object_name,
      format('no scans/writes in pg_stat_user_tables; size=%s bytes', total_bytes) as reason
    from maintenance.table_usage_audit
    where candidate_unused = true
      and total_bytes >= coalesce(p_min_table_bytes, 0)
      and (p_include_integration or schema_name <> 'integration')
  ),
  function_candidates as (
    select
      'function'::text as kind,
      format('%I.%I(%s)', schema_name, function_name, args) as object_name,
      '0 calls in pg_stat_user_functions' as reason
    from maintenance.function_usage_audit
    where candidate_unused = true
      and (p_include_integration or schema_name <> 'integration')
  )
  select * from table_candidates
  union all
  select * from function_candidates
  order by kind, object_name;
$$;

comment on schema maintenance is 'Utilities for safe cleanup audit of unused tables/functions.';
comment on view maintenance.table_usage_audit is 'Tracks per-table activity from pg_stat_user_tables to identify likely unused tables.';
comment on view maintenance.function_usage_audit is 'Tracks per-function activity from pg_stat_user_functions to identify likely unused functions.';
comment on function maintenance.cleanup_recommendations(bigint, boolean) is 'Returns candidate unused objects. Validate manually before any DROP.';
