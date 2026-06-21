# MINDS — Runbook do Sistema (Supabase MINDSv2)

**Projeto:** `ujbhgocpgsdefrwanlsm` · **Plano:** Free (uso ~22% disco, ~0% egress)
**Stack:** Supabase (Postgres + pg_cron + pg_net + Edge) + n8n + WhatsApp Cloud API (oficial) + Evolution API (Pingo)

---

## 1. Como ver a saúde do sistema (1 comando)

```sql
select * from public.minds_health;
```

`status_geral` resume tudo: **OK** | **ATENCAO** | **CRITICO**.

O que o sistema fez/alertou sozinho:
```sql
select * from public.minds_self_heal_log order by ran_at desc limit 20;   -- o que se curou
select * from public.minds_health_alerts order by raised_at desc limit 20; -- o que precisa de você
```

---

## 2. Arquitetura do disparo (pipeline)

```
[athlete_registration]  ──► minds_plan_next_notifications  (CÉREBRO: decide quem recebe o quê)
                               │  (cron minds-plan-enqueue, 15min)
                               ▼
                        [minds_planned_notifications]  (plano: planned→enqueued→superseded)
                               │  minds_enqueue_due_planned_notifications
                               ▼
                        [minds_webhook_queue]  (fila: pending→processing→sent/failed)
                               │  minds_call_questionnaire_dispatcher (cron minds-dispatcher, 10min)
                               ▼
                        Edge: minds-questionnaire-dispatcher ──► WhatsApp Cloud API (oficial) ──► wamid
```

Regras de decisão do planner:
- **post**: após cada *pre* respondido (espera 60min)
- **pre**: dias úteis, quando não está esperando post; agendado no horário mediano de resposta do atleta
- **weekly**: fim de semana, se último >6 dias
- **quarterly / semiannual**: >90 / >180 dias
- Dedup triplo: notification_log + webhook_queue + superseded
- Janela de envio: **08–21h BRT** (envios de madrugada foram eliminados)

---

## 3. Auto-cura e auto-monitoramento

| Função | Cron | O que faz |
|---|---|---|
| `minds_self_heal()` | minds-self-heal (15min) | Reconcilia respostas, destrava processing preso, corrige sent/status. Idempotente, com advisory lock. |
| `minds_health_check()` | minds-health-check (30min) | Lê `minds_health`, grava alerta em `minds_health_alerts` quando foge do normal. |

**Limite honesto:** a auto-cura resolve o **operacional repetitivo**. Ela **não** conserta bug de lógica nem mexe em schema — nesses casos ela **alerta** e a correção é humana.

---

## 4. Crons (14 ativos)

Núcleo de disparo:
- `minds-plan-enqueue` — `*/15 * * * *` — planeja e enfileira
- `minds-dispatcher` — `*/10 * * * *` — dispara via Edge (lote 10)
- `minds-weekday-adherence-reporter-21h` — `0 0 * * 2-6` (UTC) = **21h BRT seg–sex**
- `minds-queue-reactivation-weekly` — `30 12 * * 1` (UTC) = **09:30 BRT seg**

Auto-gestão:
- `minds-self-heal` — `*/15 * * * *`
- `minds-health-check` — `*/30 * * * *`

Pingo reativação (STANDBY — tabela vazia, podem ser pausados):
- `pingo-reactivation-drip` — `*/30 * * * *`
- `pingo-reactivation-reconcile` — `*/30 * * * *`

Limpeza (madrugada BRT):
- `cleanup-cron-job-run-details`, `cleanup-integration-outbox` (2d), `cleanup-minds-webhook-queue` (7d),
  `cleanup-net-http-response` (3d), `cleanup-planned-superseded` (2d), `cleanup-self-heal-logs` (14d)

> pg_cron roda em **UTC**. BRT = UTC−3.

---

## 5. Segurança (hardening aplicado)

- **Funções internas protegidas**: revogado EXECUTE de `PUBLIC`/`anon` em todo o motor (planner, dispatcher, self-heal, enqueue, engine…). Só `service_role` executa.
- **Exposto a anon (mínimo necessário)**: apenas o que o n8n/webhook usa — `minds_prepare_questionnaire_dispatch`, `minds_mark_template_sent`, `minds_run_engine_v4`, `minds_register_whatsapp_inbound`, `minds_save_whatsapp_flow_response`, `minds_bridge_*`, `minds_reactivate_by_token` + 3 helpers puros.
- **Views internas** (`minds_health`, alerts, self_heal_log): sem acesso anon.
- Todas as funções SECURITY DEFINER têm `search_path` fixo.

### PENDENTE (ação sua — crítico)
- **Rotacionar credenciais** que vazaram em texto puro nos JSONs do n8n: `service_role key` do Supabase e `WHATSAPP_TOKEN` da Meta. Guardar como credentials do n8n.
- **Ideal futuro**: n8n usar `service_role` (não a chave publishable/anon) para chamadas de escrita; aí dá pra fechar 100%.

---

## 6. Performance

- Removidos índices duplicados (`minds_notification_log_idx`, `athlete_registration_athlete_id_idx`).
- Banco enxugado de ~263MB → ~110MB (outbox órfão + planned superseded).
- `integration.outbox`: trigger grava sem consumidor. **Decisão pendente**: desligar trigger se a integração não for usada.

---

## 7. GitHub desatualizado (importante)

O repositório está defasado: as migrations refletem maio, mas o banco vivo evoluiu muito desde então (todas as correções e estas melhorias foram aplicadas direto no banco). **O banco é a fonte da verdade atual.**

Para realinhar (passo manual seu, na sua máquina com a CLI do Supabase):
```bash
supabase login
supabase link --project-ref ujbhgocpgsdefrwanlsm
supabase db pull            # puxa o schema atual do banco para migrations/
git add supabase/migrations
git commit -m "sync: estado real do banco (planner fix, self-heal, monitor, hardening)"
git push
```
Daí em diante, mudanças via migration versionada → `supabase db push`.
