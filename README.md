# MINDS — Supabase (MINDSv2)

Projeto: `ujbhgocpgsdefrwanlsm`

## Estrutura
- `supabase/migrations/` — migrations versionadas. A migration `*_minds_session_consolidation.sql`
  contém a auto-cura, o auto-monitor, a view de saúde, o hardening de grants e os crons de automação.
- `supabase/schema_snapshot/` — snapshot de referência do estado atual do banco:
  - `01_functions.sql` — todas as 286 funções `public` (pg_get_functiondef)
  - `02_views.sql` — todas as views `public` (gerar via `supabase db pull`, ver abaixo)
- `MINDS_RUNBOOK.md` — operação, arquitetura do disparo, crons, monitoramento.

## Sincronizar o repo com o banco (fonte da verdade = banco)
O banco evoluiu além do histórico antigo do repo. Para realinhar 100% (schema completo,
tabelas, RLS, policies, tipos), rode na sua máquina com a CLI do Supabase:

```bash
supabase login
supabase link --project-ref ujbhgocpgsdefrwanlsm
supabase db pull            # gera migration com o schema real atual
git add supabase && git commit -m "sync: estado real do banco" && git push
```

A migration de consolidação desta sessão já está incluída e pode coexistir com o `db pull`
(ela usa create-or-replace / if-not-exists, é idempotente).

## Monitoramento rápido
```sql
select * from public.minds_health;                                   -- estado geral
select * from public.minds_self_heal_log order by ran_at desc limit 20;   -- auto-cura
select * from public.minds_health_alerts order by raised_at desc limit 20; -- alertas
```
