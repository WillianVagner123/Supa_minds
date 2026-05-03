-- Complete cleanup toolkit:
-- 1) snapshot object definitions
-- 2) create drop plan from audit helpers
-- 3) execute drops with dry-run support

create table if not exists maintenance.cleanup_snapshot (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  object_kind text not null check (object_kind in ('table', 'function')),
  object_name text not null,
  definition text,
  notes text
);

create table if not exists maintenance.cleanup_run_log (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  dry_run boolean not null,
  object_kind text not null,
  object_name text not null,
  command text not null,
  status text not null,
  details text
);

create or replace function maintenance.snapshot_cleanup_candidates(
  p_min_table_bytes bigint default 1048576,
  p_include_integration boolean default false
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_rec record;
  v_inserted integer := 0;
  v_schema text;
  v_name text;
  v_args text;
  v_oid oid;
begin
  for v_rec in
    select * from maintenance.cleanup_recommendations(p_min_table_bytes, p_include_integration)
  loop
    if v_rec.kind = 'function' then
      -- object_name format: schema.function(args)
      v_schema := split_part(v_rec.object_name, '.', 1);
      v_name := split_part(split_part(v_rec.object_name, '.', 2), '(', 1);
      v_args := regexp_replace(v_rec.object_name, '^.*\((.*)\)$', '\1');

      select p.oid
        into v_oid
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = replace(v_schema, '"', '')
        and p.proname = replace(v_name, '"', '')
        and pg_get_function_identity_arguments(p.oid) = v_args
      limit 1;

      insert into maintenance.cleanup_snapshot(object_kind, object_name, definition, notes)
      values (
        v_rec.kind,
        v_rec.object_name,
        case when v_oid is null then null else pg_get_functiondef(v_oid) end,
        v_rec.reason
      );
    else
      insert into maintenance.cleanup_snapshot(object_kind, object_name, definition, notes)
      values (
        v_rec.kind,
        v_rec.object_name,
        format('table snapshot only; use pg_dump --schema-only --table=%s before drop', v_rec.object_name),
        v_rec.reason
      );
    end if;

    v_inserted := v_inserted + 1;
  end loop;

  return v_inserted;
end;
$$;

create or replace function maintenance.execute_cleanup_candidates(
  p_min_table_bytes bigint default 1048576,
  p_include_integration boolean default false,
  p_dry_run boolean default true
)
returns table(object_kind text, object_name text, command text, status text, details text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_rec record;
  v_cmd text;
  v_status text;
  v_details text;
begin
  for v_rec in
    select * from maintenance.cleanup_recommendations(p_min_table_bytes, p_include_integration)
  loop
    if v_rec.kind = 'table' then
      v_cmd := format('drop table if exists %s cascade', v_rec.object_name);
    else
      v_cmd := format('drop function if exists %s cascade', v_rec.object_name);
    end if;

    begin
      if p_dry_run then
        v_status := 'dry_run';
        v_details := 'not executed';
      else
        execute v_cmd;
        v_status := 'executed';
        v_details := 'ok';
      end if;
    exception
      when others then
        v_status := 'error';
        v_details := SQLERRM;
    end;

    insert into maintenance.cleanup_run_log(dry_run, object_kind, object_name, command, status, details)
    values (p_dry_run, v_rec.kind, v_rec.object_name, v_cmd, v_status, v_details);

    object_kind := v_rec.kind;
    object_name := v_rec.object_name;
    command := v_cmd;
    status := v_status;
    details := v_details;
    return next;
  end loop;
end;
$$;

comment on table maintenance.cleanup_snapshot is 'Backup metadata/definitions before cleanup execution.';
comment on table maintenance.cleanup_run_log is 'Execution log for cleanup actions (dry run or real run).';
comment on function maintenance.snapshot_cleanup_candidates(bigint, boolean) is 'Saves candidate object definitions/reasons before deletion.';
comment on function maintenance.execute_cleanup_candidates(bigint, boolean, boolean) is 'Executes or simulates DROP commands for candidates from cleanup_recommendations.';
