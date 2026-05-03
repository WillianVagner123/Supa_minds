-- Supabase Free Plan Retention Profile (optimized + defensive checks)
-- Purpose: control database growth for common high-churn tables.
-- Safe to run multiple times (idempotent cron recreation).
--
-- Retention targets:
--   cron.job_run_details       -> 3 days
--   net._http_response         -> 3 days
--   integration.outbox         -> 7 days (occurred_at)
--   public.minds_webhook_queue -> 7 days (auto-detected timestamp column)

create schema if not exists maintenance;

create or replace function maintenance.table_exists(p_schema text, p_table text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from information_schema.tables
    where table_schema = p_schema
      and table_name = p_table
  );
$$;

create or replace function maintenance.unschedule_job_if_exists(p_jobname text)
returns void
language plpgsql
as $$
declare
  v_jobid bigint;
begin
  if not maintenance.table_exists('cron', 'job') then
    return;
  end if;

  for v_jobid in
    select jobid from cron.job where jobname = p_jobname
  loop
    perform cron.unschedule(v_jobid);
  end loop;
end;
$$;

create or replace function maintenance.first_existing_column(
  p_schema text,
  p_table text,
  p_candidates text[]
)
returns text
language sql
stable
as $$
  with ranked as (
    select c.column_name,
           array_position(p_candidates, c.column_name) as ord
    from information_schema.columns c
    where c.table_schema = p_schema
      and c.table_name = p_table
      and c.column_name = any(p_candidates)
  )
  select column_name
  from ranked
  where ord is not null
  order by ord
  limit 1;
$$;

create or replace function maintenance.delete_older_than(
  p_schema text,
  p_table text,
  p_ts_column text,
  p_interval interval
)
returns bigint
language plpgsql
as $$
declare
  v_sql text;
  v_rows bigint;
begin
  if not maintenance.table_exists(p_schema, p_table) then
    return 0;
  end if;

  v_sql := format(
    'delete from %I.%I where %I < now() - $1',
    p_schema, p_table, p_ts_column
  );

  execute v_sql using p_interval;
  get diagnostics v_rows = row_count;
  return coalesce(v_rows, 0);
end;
$$;

-- 1) Immediate cleanup (defensive)
select maintenance.delete_older_than('cron', 'job_run_details', 'start_time', interval '3 days') as deleted_cron_job_run_details;
select maintenance.delete_older_than('net', '_http_response', 'created', interval '3 days') as deleted_net_http_response;
select maintenance.delete_older_than('integration', 'outbox', 'occurred_at', interval '7 days') as deleted_integration_outbox;

do $block$
declare
  v_col text;
  v_deleted bigint;
begin
  if maintenance.table_exists('public', 'minds_webhook_queue') then
    v_col := maintenance.first_existing_column(
      'public',
      'minds_webhook_queue',
      array['processed_at', 'created_at']
    );

    if v_col is null then
      raise notice 'minds_webhook_queue exists but no processed_at/created_at column found.';
    else
      v_deleted := maintenance.delete_older_than('public', 'minds_webhook_queue', v_col, interval '7 days');
      raise notice 'Deleted % rows from public.minds_webhook_queue using column %.', v_deleted, v_col;
    end if;
  end if;
end
$block$;

-- 2) Recreate retention cron jobs (idempotent)
do $block$
declare
  v_col text;
  v_cmd text;
begin
  if not maintenance.table_exists('cron', 'job') then
    raise notice 'cron.job not found. Skipping job scheduling.';
    return;
  end if;

  perform maintenance.unschedule_job_if_exists('cleanup-cron-job-run-details');
  perform maintenance.unschedule_job_if_exists('cleanup-net-http-response');
  perform maintenance.unschedule_job_if_exists('cleanup-integration-outbox');
  perform maintenance.unschedule_job_if_exists('cleanup-minds-webhook-queue');

  perform cron.schedule(
    'cleanup-cron-job-run-details',
    '10 3 * * *',
    $job$delete from cron.job_run_details where start_time < now() - interval '3 days'$job$
  );

  perform cron.schedule(
    'cleanup-net-http-response',
    '20 3 * * *',
    $job$delete from net._http_response where created < now() - interval '3 days'$job$
  );

  perform cron.schedule(
    'cleanup-integration-outbox',
    '30 3 * * *',
    $job$delete from integration.outbox where occurred_at < now() - interval '7 days'$job$
  );

  if maintenance.table_exists('public', 'minds_webhook_queue') then
    v_col := maintenance.first_existing_column(
      'public',
      'minds_webhook_queue',
      array['processed_at', 'created_at']
    );

    if v_col is null then
      raise notice 'Job cleanup-minds-webhook-queue not created: no processed_at/created_at column.';
    else
      v_cmd := format(
        'delete from public.minds_webhook_queue where %I < now() - interval ''7 days''',
        v_col
      );

      perform cron.schedule(
        'cleanup-minds-webhook-queue',
        '40 3 * * *',
        v_cmd
      );
    end if;
  end if;
end
$block$;

-- 3) Verification
do $block$
begin
  if maintenance.table_exists('cron', 'job') then
    raise notice 'cron.job exists. Run the verification query below:';
    raise notice '%',
      'select jobid, jobname, schedule, active from cron.job '
      || 'where jobname in (''cleanup-cron-job-run-details'',''cleanup-net-http-response'',''cleanup-integration-outbox'',''cleanup-minds-webhook-queue'') '
      || 'order by jobname;';
  else
    raise notice 'cron.job does not exist in this environment. Skipping job listing query.';
  end if;

  if maintenance.table_exists('cron', 'job_run_details') then
    raise notice 'cron.job_run_details exists. Run the verification query below:';
    raise notice '%',
      'select count(*) as cron_history_rows, min(start_time) as oldest, max(start_time) as newest from cron.job_run_details;';
  else
    raise notice 'cron.job_run_details does not exist in this environment. Skipping history stats query.';
  end if;
end
$block$;
