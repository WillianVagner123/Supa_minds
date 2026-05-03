-- Supabase Cleanup Dry-Run (generic)
-- No DELETE here. Generates counts/previews and SQL templates.

-- 0) Guardrail: schemas that MUST be preserved
select unnest(array['auth','public_payments','public_orders','public_settings']) as protected_domains;

-- 1) Candidate tables by name pattern (temp/log/event/queue)
with candidates as (
  select schemaname, tablename
  from pg_tables
  where schemaname in ('public','integration')
    and (
      tablename ilike '%log%'
      or tablename ilike '%event%'
      or tablename ilike '%queue%'
      or tablename ilike '%temp%'
      or tablename ilike '%tmp%'
      or tablename ilike '%staging%'
      or tablename ilike '%backup%'
      or tablename ilike '%old%'
    )
)
select * from candidates order by schemaname, tablename;

-- 2) Build COUNT templates for tables that have created_at
with target_tables as (
  select c.table_schema, c.table_name
  from information_schema.columns c
  where c.column_name = 'created_at'
    and c.table_schema in ('public','integration')
)
select format(
  'select count(*) as candidate_count from %I.%I where created_at < now() - interval ''90 days'';',
  table_schema, table_name
) as count_sql
from target_tables
order by table_schema, table_name;

-- 3) Build PREVIEW templates (first 200 oldest)
with target_tables as (
  select c.table_schema, c.table_name
  from information_schema.columns c
  where c.column_name = 'created_at'
    and c.table_schema in ('public','integration')
)
select format(
  'select * from %I.%I where created_at < now() - interval ''90 days'' order by created_at asc limit 200;',
  table_schema, table_name
) as preview_sql
from target_tables
order by table_schema, table_name;

-- 4) Detect possible duplicates templates by common business keys
with keys as (
  select table_schema, table_name, column_name
  from information_schema.columns
  where table_schema in ('public','integration')
    and column_name in ('external_id','reference_id','request_id','email','phone')
)
select format(
  'select %I, count(*) from %I.%I group by %I having count(*) > 1 order by count(*) desc limit 100;',
  column_name, table_schema, table_name, column_name
) as duplicate_sql
from keys
order by table_schema, table_name, column_name;
