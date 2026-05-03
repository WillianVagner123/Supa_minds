-- Fixes for dispatch policy evaluation and account_key normalization.

-- Normalize existing blank account keys so rate-limit bucketing is consistent.
update public.minds_webhook_queue
set account_key = null
where account_key is not null
  and btrim(account_key) = '';

update public.minds_webhook_queue
set account_key = athlete_id
where account_key is null
  and athlete_id is not null
  and btrim(athlete_id) <> '';

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
  v_today_start timestamptz := date_trunc('day', v_now);
  v_minute_start timestamptz := date_trunc('minute', v_now);
  v_hour_start timestamptz := date_trunc('hour', v_now);
  v_last_phone_sent timestamptz;
  v_cnt integer;
  v_end_today timestamptz := date_trunc('day', v_now) + interval '1 day';
  v_account text := coalesce(nullif(trim(p_account_key), ''), '_unknown_');
  v_now_time time := localtime;
  v_cross_midnight boolean;
  v_window_open boolean;
  v_next_window timestamptz;
begin
  select * into v_policy from public.minds_dispatch_policy where id = true;

  if not found or v_policy.enabled is false then
    return query select true, 'policy_disabled', v_now;
    return;
  end if;

  v_cross_midnight := v_policy.window_end <= v_policy.window_start;
  if v_cross_midnight then
    v_window_open := (v_now_time >= v_policy.window_start) or (v_now_time < v_policy.window_end);
  else
    v_window_open := (v_now_time >= v_policy.window_start) and (v_now_time < v_policy.window_end);
  end if;

  if not v_window_open then
    if v_now_time < v_policy.window_start then
      v_next_window := date_trunc('day', v_now) + v_policy.window_start;
    else
      v_next_window := date_trunc('day', v_now) + interval '1 day' + v_policy.window_start;
    end if;

    return query select false, 'outside_window', v_next_window;
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
  where coalesce(nullif(trim(account_key), ''), nullif(trim(athlete_id), ''), '_unknown_') = v_account
    and sent = true
    and sent_at >= v_minute_start;
  if v_cnt >= v_policy.per_account_max_minute then
    return query select false, 'per_account_max_minute', v_minute_start + interval '1 minute';
    return;
  end if;

  select count(*) into v_cnt
  from public.minds_webhook_queue
  where coalesce(nullif(trim(account_key), ''), nullif(trim(athlete_id), ''), '_unknown_') = v_account
    and sent = true
    and sent_at >= v_hour_start;
  if v_cnt >= v_policy.per_account_max_hour then
    return query select false, 'per_account_max_hour', v_hour_start + interval '1 hour';
    return;
  end if;

  select count(*) into v_cnt
  from public.minds_webhook_queue
  where coalesce(nullif(trim(account_key), ''), nullif(trim(athlete_id), ''), '_unknown_') = v_account
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
