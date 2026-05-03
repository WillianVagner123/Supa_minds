-- Supabase Maintenance All-in-One
-- Usage (psql):
--   psql "$DATABASE_URL" -v mode='report'  -f scripts/supabase-maintenance-all-in-one.sql
--   psql "$DATABASE_URL" -v mode='dry_run' -v retention_days='90' -f scripts/supabase-maintenance-all-in-one.sql
--   psql "$DATABASE_URL" -v mode='execute' -v retention_days='90' -f scripts/supabase-maintenance-all-in-one.sql
--
-- IMPORTANT:
-- - Never removes Supabase Storage files via SQL.
-- - In execute mode, only deletes rows from maintenance.cleanup_delete_plan where enabled=true.
-- - Always run report + dry_run and backup first.

\if :{?mode}
\else
\set mode 'report'
\endif

\if :{?retention_days}
\else
\set retention_days '90'
\endif

create schema if not exists maintenance;

create table if not exists maintenance.cleanup_delete_plan (
  id bigserial primary key,
  table_schema text not null,
  table_name text not null,
  where_sql text not null,
  enabled boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists maintenance.cleanup_delete_log (
  id bigserial primary key,
  plan_id bigint not null references maintenance.cleanup_delete_plan(id),
  mode text not null,
  counted_rows bigint,
  deleted_rows bigint,
  executed_at timestamptz not null default now(),
  count_sql text not null,
  delete_sql text not null
);

-- 1) Space report: largest tables
select n.nspname as schema_name,
       c.relname as table_name,
       pg_size_pretty(pg_total_relation_size(c.oid)) as total_size,
       coalesce(s.n_live_tup, 0) as estimated_rows
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_stat_user_tables s on s.relid = c.oid
where c.relkind = 'r'
  and n.nspname not in ('pg_catalog', 'information_schema')
order by pg_total_relation_size(c.oid) desc;

-- 2) Largest/possibly-unused indexes
select schemaname,
       relname as table_name,
       indexrelname as index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
       idx_scan,
       (coalesce(idx_scan,0)=0) as possibly_unused
from pg_stat_user_indexes
order by pg_relation_size(indexrelid) desc;

-- 3) Dead tuple / bloat indicator
select schemaname, relname as table_name, n_live_tup, n_dead_tup
from pg_stat_user_tables
order by n_dead_tup desc;

-- 4) Storage metadata report only (no delete)
select b.id as bucket_id,
       b.name as bucket_name,
       count(o.id) as file_count,
       coalesce(sum((o.metadata->>'size')::bigint),0) as total_size_bytes,
       min(o.created_at) as oldest_file,
       max(o.created_at) as newest_file
from storage.buckets b
left join storage.objects o on o.bucket_id = b.id
group by b.id, b.name
order by total_size_bytes desc;

\if :mode = 'dry_run'
DO $$
DECLARE
  v_plan record;
  v_count_sql text;
  v_count bigint;
BEGIN
  FOR v_plan IN SELECT * FROM maintenance.cleanup_delete_plan WHERE enabled = true ORDER BY id LOOP
    v_count_sql := format('select count(*) from %I.%I where (%s)', v_plan.table_schema, v_plan.table_name, v_plan.where_sql);
    EXECUTE v_count_sql INTO v_count;

    insert into maintenance.cleanup_delete_log(plan_id, mode, counted_rows, deleted_rows, count_sql, delete_sql)
    values (
      v_plan.id,
      'dry_run',
      v_count,
      0,
      v_count_sql,
      format('delete from %I.%I where (%s)', v_plan.table_schema, v_plan.table_name, v_plan.where_sql)
    );
  END LOOP;
END $$;
\endif

\if :mode = 'execute'
DO $$
DECLARE
  v_plan record;
  v_count_sql text;
  v_delete_sql text;
  v_count bigint;
  v_deleted bigint;
BEGIN
  FOR v_plan IN SELECT * FROM maintenance.cleanup_delete_plan WHERE enabled = true ORDER BY id LOOP
    v_count_sql := format('select count(*) from %I.%I where (%s)', v_plan.table_schema, v_plan.table_name, v_plan.where_sql);
    EXECUTE v_count_sql INTO v_count;

    v_delete_sql := format('delete from %I.%I where (%s)', v_plan.table_schema, v_plan.table_name, v_plan.where_sql);
    EXECUTE v_delete_sql;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    insert into maintenance.cleanup_delete_log(plan_id, mode, counted_rows, deleted_rows, count_sql, delete_sql)
    values (v_plan.id, 'execute', v_count, v_deleted, v_count_sql, v_delete_sql);
  END LOOP;
END $$;

-- Post-cleanup maintenance suggestion (manual):
-- vacuum (analyze) <schema>.<table>;
-- VACUUM FULL only in maintenance window (locks table).
\endif
