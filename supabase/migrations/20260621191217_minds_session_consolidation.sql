-- =====================================================================
-- MINDS — Consolidação da sessão de manutenção (auto-cura + monitor + hardening)
-- Aplicado direto no banco; este arquivo versiona o estado para o repo.
-- =====================================================================

-- ---------- 1. Auto-cura: log + função ----------
create table if not exists public.minds_self_heal_log (
  id bigserial primary key,
  ran_at timestamptz not null default now(),
  action text not null,
  affected integer not null default 0,
  details text
);
create index if not exists idx_minds_self_heal_log_ran on public.minds_self_heal_log (ran_at desc);

create or replace function public.minds_self_heal()
returns jsonb language plpgsql security definer
set search_path to 'public','net','pg_catalog'
as $$
declare
  v_reconciled integer := 0; v_requeued integer := 0; v_fixed_sent integer := 0;
  v_total integer := 0; v_got_lock boolean;
begin
  v_got_lock := pg_try_advisory_lock(hashtext('minds_self_heal'));
  if not v_got_lock then
    return jsonb_build_object('ok',true,'skipped','already_running','ran_at',now());
  end if;
  begin v_reconciled := public.reconcile_minds_webhook_responses();
  exception when others then
    insert into public.minds_self_heal_log(action,affected,details) values ('reconcile_error',0,sqlerrm); end;
  if v_reconciled>0 then insert into public.minds_self_heal_log(action,affected) values ('reconciled_responses',v_reconciled); end if;
  begin v_requeued := public.requeue_stale_minds_webhooks();
  exception when others then
    insert into public.minds_self_heal_log(action,affected,details) values ('requeue_error',0,sqlerrm); end;
  if v_requeued>0 then insert into public.minds_self_heal_log(action,affected) values ('requeued_stale',v_requeued); end if;
  update public.minds_webhook_queue set sent=false
   where sent=true and status in ('failed','archived_failed','cancelled','pending','hibernated');
  get diagnostics v_fixed_sent = row_count;
  if v_fixed_sent>0 then insert into public.minds_self_heal_log(action,affected) values ('fixed_sent_inconsistency',v_fixed_sent); end if;
  v_total := coalesce(v_reconciled,0)+coalesce(v_requeued,0)+coalesce(v_fixed_sent,0);
  perform pg_advisory_unlock(hashtext('minds_self_heal'));
  return jsonb_build_object('ok',true,'ran_at',now(),'reconciled',v_reconciled,
    'requeued_stale',v_requeued,'fixed_sent_inconsistency',v_fixed_sent,'total_actions',v_total);
end; $$;
grant execute on function public.minds_self_heal() to service_role;

-- ---------- 2. Auto-monitor: alertas + função ----------
create table if not exists public.minds_health_alerts (
  id bigserial primary key,
  raised_at timestamptz not null default now(),
  severity text not null, metric text not null, value text, message text
);
create index if not exists idx_minds_health_alerts_raised on public.minds_health_alerts (raised_at desc);

-- ---------- 3. View de saúde (painel num select) ----------
drop view if exists public.minds_health;
create view public.minds_health as
with fila as (
  select count(*) filter (where status='pending' and sent=false) as fila_pendente,
         count(*) filter (where status='processing') as em_processamento,
         count(*) filter (where status='failed') as falhados,
         count(*) filter (where sent=true and status in ('failed','archived_failed','cancelled','pending','hibernated')) as inconsistencias,
         max(sent_at) as ultimo_envio
  from public.minds_webhook_queue),
planner as (
  select count(*) filter (where status='enqueued') as planned_enqueued,
         count(*) filter (where status='superseded') as planned_lixo,
         count(*) filter (where status='planned' and due_at<=now()) as planned_atrasado
  from public.minds_planned_notifications),
janela as (
  select count(*) as envios_fora_janela_7d from public.minds_webhook_queue
  where sent=true and sent_at>now()-interval '7 days'
    and extract(hour from sent_at at time zone 'America/Sao_Paulo')::int not between 8 and 21),
crons as (
  select count(*) filter (where d.status='failed') as cron_falhas_1h,
         count(*) filter (where d.status='succeeded') as cron_ok_1h
  from cron.job_run_details d where d.start_time>now()-interval '1 hour'),
crons24 as (
  select count(*) filter (where d.status='failed') as cron_falhas_24h
  from cron.job_run_details d where d.start_time>now()-interval '24 hours'),
saude_http as (
  select count(*) filter (where status_code between 200 and 299) as http_ok_2h,
         count(*) filter (where status_code>=400 or status_code is null) as http_erro_2h
  from net._http_response where created>now()-interval '2 hours'),
heal as (
  select max(ran_at) as ultima_autocura,
         coalesce(sum(affected) filter (where ran_at>now()-interval '24 hours'),0) as autocorrecoes_24h
  from public.minds_self_heal_log),
base as (
  select (select count(*) from public.athlete_registration
            where coalesce(athlete_enabled,true)=true
              and nullif(trim(coalesce(athlete_phone,'')),'') is not null) as atletas_ativos,
         (select count(*) from public.minds_athlete_delivery_state where send_state='hibernated') as hibernados)
select
  case when c.cron_falhas_1h>3 or f.em_processamento>50 or p.planned_atrasado>20 then 'CRITICO'
       when f.inconsistencias>0 or j.envios_fora_janela_7d>0 or h2.http_erro_2h>5 then 'ATENCAO'
       else 'OK' end as status_geral,
  f.fila_pendente,f.em_processamento,f.falhados,f.inconsistencias,f.ultimo_envio,
  p.planned_enqueued,p.planned_lixo,p.planned_atrasado,j.envios_fora_janela_7d,
  c.cron_ok_1h,c.cron_falhas_1h,c24.cron_falhas_24h,h2.http_ok_2h,h2.http_erro_2h,
  hl.ultima_autocura,hl.autocorrecoes_24h,b.atletas_ativos,b.hibernados,now() as verificado_em
from fila f,planner p,janela j,crons c,crons24 c24,saude_http h2,heal hl,base b;

create or replace function public.minds_health_check()
returns jsonb language plpgsql security definer set search_path to 'public','pg_catalog'
as $$
declare h record; v_alerts integer := 0;
begin
  select * into h from public.minds_health;
  if h.cron_falhas_1h>3 then insert into public.minds_health_alerts(severity,metric,value,message)
    values('CRITICO','cron_falhas_1h',h.cron_falhas_1h::text,'Crons falhando agora — pode ser bug de logica.'); v_alerts:=v_alerts+1; end if;
  if h.em_processamento>50 then insert into public.minds_health_alerts(severity,metric,value,message)
    values('CRITICO','em_processamento',h.em_processamento::text,'Muitos itens presos em processing.'); v_alerts:=v_alerts+1; end if;
  if h.planned_atrasado>20 then insert into public.minds_health_alerts(severity,metric,value,message)
    values('CRITICO','planned_atrasado',h.planned_atrasado::text,'Planner atrasado — disparo pode ter parado.'); v_alerts:=v_alerts+1; end if;
  if h.envios_fora_janela_7d>0 then insert into public.minds_health_alerts(severity,metric,value,message)
    values('ATENCAO','envios_fora_janela',h.envios_fora_janela_7d::text,'Envios fora da janela 08-21h BRT.'); v_alerts:=v_alerts+1; end if;
  if h.http_erro_2h>5 then insert into public.minds_health_alerts(severity,metric,value,message)
    values('ATENCAO','http_erro_2h',h.http_erro_2h::text,'Varios erros HTTP no webhook.'); v_alerts:=v_alerts+1; end if;
  return jsonb_build_object('ok',true,'status',h.status_geral,'novos_alertas',v_alerts,'checado_em',now());
end; $$;
grant execute on function public.minds_health_check() to service_role;

revoke select on public.minds_health from anon, authenticated;
revoke select on public.minds_health_alerts from anon, authenticated;
revoke select on public.minds_self_heal_log from anon, authenticated;

-- ---------- 4. Hardening: revogar EXECUTE de funções internas de PUBLIC/anon ----------
do $$
declare fn text;
  manter text[] := array[
    'minds_prepare_questionnaire_dispatch','minds_mark_template_sent','minds_run_engine_v4',
    'minds_register_whatsapp_inbound','minds_save_whatsapp_flow_response',
    'minds_bridge_whatsapp_flow_response_to_pingo_observation','minds_reactivate_by_token',
    'minds_norm_athlete_id','minds_digits','minds_window_is_open'];
begin
  for fn in select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname like 'minds%' and p.proname <> all(manter)
  loop
    execute format('revoke execute on function public.%I from public, anon, authenticated', fn);
    execute format('grant execute on function public.%I to service_role', fn);
  end loop;
end$$;

-- ---------- 5. Performance: remover índices duplicados ----------
drop index if exists public.minds_notification_log_idx;
drop index if exists public.athlete_registration_athlete_id_idx;

-- ---------- 6. Crons de automação (auto-cura + monitor + limpeza de logs) ----------
do $$ begin
  if exists (select 1 from cron.job where jobname='minds-self-heal') then perform cron.unschedule('minds-self-heal'); end if;
  if exists (select 1 from cron.job where jobname='minds-health-check') then perform cron.unschedule('minds-health-check'); end if;
  if exists (select 1 from cron.job where jobname='cleanup-self-heal-logs') then perform cron.unschedule('cleanup-self-heal-logs'); end if;
end $$;
select cron.schedule('minds-self-heal','*/15 * * * *',$ck$ select public.minds_self_heal(); $ck$);
select cron.schedule('minds-health-check','*/30 * * * *',$ck$ select public.minds_health_check(); $ck$);
select cron.schedule('cleanup-self-heal-logs','15 3 * * *',
  $ck$ delete from public.minds_self_heal_log where ran_at < now()-interval '14 days';
       delete from public.minds_health_alerts where raised_at < now()-interval '14 days'; $ck$);

-- ---------- 7. Documentação (COMMENT ON) ----------
comment on view public.minds_health is 'PAINEL DE SAUDE. Estado do sistema em uma linha. status_geral: OK|ATENCAO|CRITICO.';
comment on function public.minds_self_heal() is 'AUTO-CURA operacional idempotente (reconcile, requeue stale, fix sent). Cron 15min.';
comment on function public.minds_health_check() is 'AUTO-MONITOR. Grava alertas em minds_health_alerts. Cron 30min.';
comment on table public.minds_self_heal_log is 'Log da auto-cura. Retencao 14 dias.';
comment on table public.minds_health_alerts is 'Alertas do auto-monitor. Retencao 14 dias.';
