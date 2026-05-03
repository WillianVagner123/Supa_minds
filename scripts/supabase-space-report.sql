-- Supabase Space Report (read-only)
-- Run in SQL editor or psql. No destructive commands.

-- 1) Tabelas maiores
select
  n.nspname as schema_name,
  c.relname as table_name,
  pg_size_pretty(pg_total_relation_size(c.oid)) as total_size,
  pg_size_pretty(pg_relation_size(c.oid)) as table_size,
  pg_size_pretty(pg_total_relation_size(c.oid) - pg_relation_size(c.oid)) as indexes_toast_size,
  coalesce(s.n_live_tup, 0) as estimated_rows
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_stat_user_tables s on s.relid = c.oid
where c.relkind = 'r'
  and n.nspname not in ('pg_catalog', 'information_schema')
order by pg_total_relation_size(c.oid) desc;

-- 2) Índices maiores + possivelmente não usados
select
  schemaname,
  relname as table_name,
  indexrelname as index_name,
  pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch,
  case when coalesce(idx_scan, 0) = 0 then true else false end as possibly_unused
from pg_stat_user_indexes
order by pg_relation_size(indexrelid) desc;

-- 3) Materialized views maiores
select
  schemaname,
  matviewname,
  pg_size_pretty(pg_total_relation_size((quote_ident(schemaname) || '.' || quote_ident(matviewname))::regclass)) as total_size
from pg_matviews
order by pg_total_relation_size((quote_ident(schemaname) || '.' || quote_ident(matviewname))::regclass) desc;

-- 4) Tabelas com muito dead tuple (potencial bloat)
select
  schemaname,
  relname as table_name,
  n_live_tup,
  n_dead_tup,
  round(case when n_live_tup + n_dead_tup = 0 then 0 else n_dead_tup::numeric * 100 / (n_live_tup + n_dead_tup) end, 2) as dead_pct
from pg_stat_user_tables
order by n_dead_tup desc;

-- 5) Colunas de tempo candidatas para retenção (inspeção)
select
  table_schema,
  table_name,
  column_name,
  data_type
from information_schema.columns
where table_schema not in ('pg_catalog', 'information_schema')
  and column_name in ('created_at','updated_at','inserted_at','timestamp','event_at','deleted_at','expires_at')
order by table_schema, table_name;

-- 6) Buckets Storage e volume estimado (metadados)
select
  b.id as bucket_id,
  b.name as bucket_name,
  count(o.id) as file_count,
  pg_size_pretty(coalesce(sum(o.metadata->>'size')::bigint, 0)) as total_size_pretty,
  coalesce(sum((o.metadata->>'size')::bigint), 0) as total_size_bytes,
  min(o.created_at) as oldest_file,
  max(o.created_at) as newest_file
from storage.buckets b
left join storage.objects o on o.bucket_id = b.id
group by b.id, b.name
order by total_size_bytes desc;
