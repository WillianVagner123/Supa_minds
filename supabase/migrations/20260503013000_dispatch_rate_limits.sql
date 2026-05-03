-- Global/per-account/per-number throttling for webhook dispatch

create table if not exists public.minds_dispatch_policy (
  id boolean primary key default true,
  enabled boolean not null default true,
  window_start time not null default time '08:00',
  window_end time not null default time '20:00',
  per_number_min_interval interval not null default interval '120 minutes',
  per_number_max_24h integer not null default 2,
  per_account_max_minute integer not null default 5,
  per_account_max_hour integer not null default 60,
  per_account_max_day integer not null default 150,
  global_max_minute integer not null default 15,
  global_max_hour integer not null default 600,
  global_max_day integer not null default 3000,
  updated_at timestamptz not null default now()
);

insert into public.minds_dispatch_policy (id)
values (true)
on conflict (id) do nothing;

alter table public.minds_webhook_queue
  add column if not exists account_key text;

update public.minds_webhook_queue
set account_key = coalesce(account_key, athlete_id)
where account_key is null;

create index if not exists idx_mwq_account_created
  on public.minds_webhook_queue (account_key, created_at desc);

create or replace function public.can_dispatch_minds_webhook(
  p_phone text,
  p_account_key text
) returns table(can_dispatch boolean, reason text, retry_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_policy public.minds_dispatch_policy%rowtype;
  v_now timestamptz := now();
  v_today_start timestamptz := date_trunc('day', now());
  v_minute_start timestamptz := date_trunc('minute', now());
  v_hour_start timestamptz := date_trunc('hour', now());
  v_last_phone_sent timestamptz;
  v_cnt integer;
  v_end_today timestamptz := date_trunc('day', now()) + interval '1 day';
  v_account text := coalesce(nullif(trim(p_account_key), ''), '_unknown_');
begin
  select * into v_policy from public.minds_dispatch_policy where id = true;

  if not found or v_policy.enabled is false then
    return query select true, 'policy_disabled', v_now;
    return;
  end if;

  if localtime < v_policy.window_start then
    return query select false, 'outside_window_before', date_trunc('day', v_now) + v_policy.window_start;
    return;
  end if;

  if localtime >= v_policy.window_end then
    return query select false, 'outside_window_after', date_trunc('day', v_now) + interval '1 day' + v_policy.window_start;
    return;
  end if;

  if p_phone is not null then
    select max(sent_at) into v_last_phone_sent
    from public.minds_webhook_queue
    where athlete_phone = p_phone and sent = true;

    if v_last_phone_sent is not null and v_last_phone_sent + v_policy.per_number_min_interval > v_now then
      return query select false, 'per_number_min_interval', v_last_phone_sent + v_policy.per_number_min_interval;
      return;
    end if;

    select count(*) into v_cnt
    from public.minds_webhook_queue
    where athlete_phone = p_phone
      and sent = true
      and sent_at >= v_now - interval '24 hours';

    if v_cnt >= v_policy.per_number_max_24h then
      return query select false, 'per_number_max_24h', v_now + interval '1 hour';
      return;
    end if;
  end if;

  select count(*) into v_cnt
  from public.minds_webhook_queue
  where coalesce(account_key, athlete_id, '_unknown_') = v_account
    and sent = true
    and sent_at >= v_minute_start;
  if v_cnt >= v_policy.per_account_max_minute then
    return query select false, 'per_account_max_minute', v_minute_start + interval '1 minute';
    return;
  end if;

  select count(*) into v_cnt
  from public.minds_webhook_queue
  where coalesce(account_key, athlete_id, '_unknown_') = v_account
    and sent = true
    and sent_at >= v_hour_start;
  if v_cnt >= v_policy.per_account_max_hour then
    return query select false, 'per_account_max_hour', v_hour_start + interval '1 hour';
    return;
  end if;

  select count(*) into v_cnt
  from public.minds_webhook_queue
  where coalesce(account_key, athlete_id, '_unknown_') = v_account
    and sent = true
    and sent_at >= v_today_start;
  if v_cnt >= v_policy.per_account_max_day then
    return query select false, 'per_account_max_day', v_end_today;
    return;
  end if;

  select count(*) into v_cnt
  from public.minds_webhook_queue
  where sent = true
    and sent_at >= v_minute_start;
  if v_cnt >= v_policy.global_max_minute then
    return query select false, 'global_max_minute', v_minute_start + interval '1 minute';
    return;
  end if;

  select count(*) into v_cnt
  from public.minds_webhook_queue
  where sent = true
    and sent_at >= v_hour_start;
  if v_cnt >= v_policy.global_max_hour then
    return query select false, 'global_max_hour', v_hour_start + interval '1 hour';
    return;
  end if;

  select count(*) into v_cnt
  from public.minds_webhook_queue
  where sent = true
    and sent_at >= v_today_start;
  if v_cnt >= v_policy.global_max_day then
    return query select false, 'global_max_day', v_end_today;
    return;
  end if;

  return query select true, 'ok', v_now;
end;
$$;

create or replace function public.dispatch_next_minds_webhook() returns bigint
language plpgsql security definer
set search_path to 'public', 'pg_catalog'
as $$
DECLARE
  v_row public.minds_webhook_queue%ROWTYPE;
  v_request_id bigint;
  v_can boolean;
  v_reason text;
  v_retry_at timestamptz;
BEGIN
  SELECT *
    INTO v_row
  FROM public.minds_webhook_queue
  WHERE status = 'pending'
    AND sent = false
    AND available_at <= now()
    AND retry_count < max_retries
  ORDER BY available_at ASC, created_at ASC, id ASC
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  select can_dispatch, reason, retry_at
    into v_can, v_reason, v_retry_at
  from public.can_dispatch_minds_webhook(v_row.athlete_phone, coalesce(v_row.account_key, v_row.athlete_id));

  if coalesce(v_can, false) = false then
    update public.minds_webhook_queue
       set available_at = greatest(coalesce(v_retry_at, now() + interval '10 minutes'), now() + interval '1 minute'),
           last_error = 'throttled: ' || coalesce(v_reason, 'unknown')
     where id = v_row.id;
    return null;
  end if;

  UPDATE public.minds_webhook_queue
  SET
    status = 'processing',
    processing_at = now(),
    last_attempt_at = now(),
    last_error = NULL
  WHERE id = v_row.id;

  SELECT net.http_post(
    url := 'https://autowebhook.opingo.com.br/webhook/Questionario-Minds',
    body := jsonb_build_object(
      'athlete_id', v_row.athlete_id,
      'athlete_name', v_row.athlete_name,
      'phone', v_row.athlete_phone,
      'questionnaire', v_row.questionnaire
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json'
    ),
    timeout_milliseconds := 10000
  )
  INTO v_request_id;

  UPDATE public.minds_webhook_queue
  SET request_id = v_request_id
  WHERE id = v_row.id;

  RETURN v_row.id;

EXCEPTION
  WHEN OTHERS THEN
    IF v_row.id IS NOT NULL THEN
      UPDATE public.minds_webhook_queue
      SET
        retry_count = retry_count + 1,
        status = CASE
          WHEN retry_count + 1 >= max_retries THEN 'failed'
          ELSE 'pending'
        END,
        available_at = now() + interval '5 minutes',
        processing_at = NULL,
        last_error = 'dispatch exception: ' || SQLERRM
      WHERE id = v_row.id;
    END IF;
    RETURN NULL;
END;
$$;

create or replace function public.dispatch_minds_webhook_batch(p_max integer default 15)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_done integer := 0;
  v_id bigint;
  v_i integer := 0;
begin
  while v_i < greatest(coalesce(p_max, 1), 1) loop
    v_id := public.dispatch_next_minds_webhook();
    exit when v_id is null;
    v_done := v_done + 1;
    v_i := v_i + 1;
  end loop;
  return v_done;
end;
$$;
