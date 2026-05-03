-- Refine minds_webhook_queue pipeline:
-- 1) Remove legacy immediate-send trigger to avoid duplicate dispatch.
-- 2) Remove duplicate index (same key order as idx_mwq_worker).
-- 3) Redirect legacy retry function to dispatcher-based flow.

-- Legacy trigger sends webhooks immediately on INSERT and can race/duplicate
-- with the dispatcher flow introduced later.
drop trigger if exists trigger_send_minds_webhook on public.minds_webhook_queue;

-- Duplicate of idx_mwq_worker (status, available_at, created_at).
drop index if exists public.idx_mwq_dispatch;

-- Keep backward compatibility for callers of retry_minds_webhooks(),
-- but route execution through the dispatcher pipeline.
create or replace function public.retry_minds_webhooks()
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_done integer;
begin
  v_done := public.dispatch_minds_webhook_batch(50);
  return v_done;
end;
$$;
