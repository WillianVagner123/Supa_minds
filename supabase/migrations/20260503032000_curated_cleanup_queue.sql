-- Curated cleanup pipeline (approval-based).
-- Goal: identify old/unused objects and only drop when explicitly approved.

create table if not exists maintenance.cleanup_keep_list (
  object_kind text not null check (object_kind in ('table', 'function')),
  object_name text not null,
  reason text,
  created_at timestamptz not null default now(),
  primary key (object_kind, object_name)
);

create table if not exists maintenance.cleanup_candidates_queue (
  object_kind text not null check (object_kind in ('table', 'function')),
  object_name text not null,
  reason text not null,
  source text not null default 'auto_scan',
  approved boolean not null default false,
  approved_at timestamptz,
  executed_at timestamptz,
  execution_status text,
  execution_details text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (object_kind, object_name)
);

create or replace function maintenance.tg_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_cleanup_candidates_queue_touch on maintenance.cleanup_candidates_queue;
create trigger trg_cleanup_candidates_queue_touch
before update on maintenance.cleanup_candidates_queue
for each row
execute function maintenance.tg_touch_updated_at();

create or replace function maintenance.refresh_cleanup_candidates_queue(
  p_min_table_bytes bigint default 1048576,
  p_include_integration boolean default false
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_count integer := 0;
begin
  insert into maintenance.cleanup_candidates_queue (object_kind, object_name, reason, source)
  select r.kind, r.object_name, r.reason, 'auto_scan'
  from maintenance.cleanup_recommendations(p_min_table_bytes, p_include_integration) r
  left join maintenance.cleanup_keep_list k
    on k.object_kind = r.kind
   and k.object_name = r.object_name
  where k.object_name is null
  on conflict (object_kind, object_name) do update
    set reason = excluded.reason,
        source = excluded.source;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function maintenance.execute_approved_cleanup(
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
    select *
    from maintenance.cleanup_candidates_queue
    where approved = true
      and executed_at is null
    order by created_at asc
  loop
    if v_rec.object_kind = 'table' then
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

    update maintenance.cleanup_candidates_queue
      set execution_status = v_status,
          execution_details = v_details,
          executed_at = case when p_dry_run then null else now() end
    where object_kind = v_rec.object_kind
      and object_name = v_rec.object_name;

    object_kind := v_rec.object_kind;
    object_name := v_rec.object_name;
    command := v_cmd;
    status := v_status;
    details := v_details;
    return next;
  end loop;
end;
$$;

comment on table maintenance.cleanup_keep_list is 'Explicit allowlist for objects that must never be auto-queued for cleanup.';
comment on table maintenance.cleanup_candidates_queue is 'Approval queue for cleanup candidates. Only approved objects are eligible for execution.';
comment on function maintenance.refresh_cleanup_candidates_queue(bigint, boolean) is 'Refreshes queue from usage audit recommendations, excluding keep-list objects.';
comment on function maintenance.execute_approved_cleanup(boolean) is 'Executes cleanup only for approved queued objects; defaults to dry-run.';
