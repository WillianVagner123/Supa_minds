-- Supabase Cleanup Execute (manual plan driven)
-- This script only executes rows listed in maintenance.cleanup_delete_plan.
-- Create backup/export first.

-- 0) One-time plan table
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
  executed_at timestamptz not null default now(),
  deleted_rows bigint,
  delete_sql text not null
);

-- 1) DRY RUN COUNTS for enabled plans (run first)
-- select * from maintenance.cleanup_delete_plan where enabled = true;
-- For each plan row, run:
-- select count(*) from <table_schema>.<table_name> where <where_sql>;

-- 2) Execute enabled plans safely
DO $$
DECLARE
  v_plan record;
  v_sql text;
  v_rows bigint;
BEGIN
  FOR v_plan IN
    SELECT * FROM maintenance.cleanup_delete_plan WHERE enabled = true ORDER BY id
  LOOP
    v_sql := format('delete from %I.%I where %s', v_plan.table_schema, v_plan.table_name, v_plan.where_sql);
    EXECUTE v_sql;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    insert into maintenance.cleanup_delete_log(plan_id, deleted_rows, delete_sql)
    values (v_plan.id, v_rows, v_sql);
  END LOOP;
END $$;

-- 3) Pós-delete: VACUUM/ANALYZE recomendado (sem VACUUM FULL automático)
-- Exemplo (rodar manualmente por tabela afetada):
-- vacuum (analyze) public.sua_tabela;
-- VACUUM FULL só em janela de manutenção (bloqueia tabela).
