


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE SCHEMA IF NOT EXISTS "integration";


ALTER SCHEMA "integration" OWNER TO "postgres";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "public";






CREATE OR REPLACE FUNCTION "integration"."ack_changes_for_horizons"("p_event_ids" "uuid"[], "p_success" boolean DEFAULT true, "p_error" "text" DEFAULT NULL::"text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
declare
  v_count integer := 0;
begin
  if coalesce(array_length(p_event_ids, 1), 0) = 0 then
    return 0;
  end if;

  if p_success then
    update integration.outbox
       set delivered_at   = now(),
           reserved_until = null,
           last_error     = null
     where id = any(p_event_ids);
  else
    update integration.outbox
       set reserved_until = null,
           last_error     = coalesce(p_error, 'delivery_failed')
     where id = any(p_event_ids);
  end if;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


ALTER FUNCTION "integration"."ack_changes_for_horizons"("p_event_ids" "uuid"[], "p_success" boolean, "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "integration"."capture_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
declare
  v_old jsonb;
  v_new jsonb;
  v_pk  jsonb;
begin
  -- proteção extra
  if TG_TABLE_SCHEMA in (
    'pg_catalog',
    'information_schema',
    'auth',
    'storage',
    'realtime',
    'vault',
    'extensions',
    'integration'
  ) then
    if TG_OP = 'DELETE' then
      return OLD;
    else
      return NEW;
    end if;
  end if;

  if TG_OP = 'DELETE' then
    v_old := to_jsonb(OLD);
    v_new := null;
    v_pk  := integration.get_primary_key_json(TG_TABLE_SCHEMA, TG_TABLE_NAME, v_old);

  elsif TG_OP = 'INSERT' then
    v_old := null;
    v_new := to_jsonb(NEW);
    v_pk  := integration.get_primary_key_json(TG_TABLE_SCHEMA, TG_TABLE_NAME, v_new);

  else -- UPDATE
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    v_pk  := integration.get_primary_key_json(TG_TABLE_SCHEMA, TG_TABLE_NAME, v_new);
  end if;

  insert into integration.outbox (
    schema_name,
    table_name,
    op,
    pk,
    old_row,
    new_row
  )
  values (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    TG_OP,
    v_pk,
    v_old,
    v_new
  );

  if TG_OP = 'DELETE' then
    return OLD;
  else
    return NEW;
  end if;
end;
$$;


ALTER FUNCTION "integration"."capture_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "integration"."export_table_json"("p_schema_name" "text", "p_table_name" "text", "p_limit" integer DEFAULT 1000, "p_offset" integer DEFAULT 0) RETURNS SETOF "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
declare
  v_sql text;
begin
  v_sql := format(
    'select to_jsonb(t)
       from %I.%I t
      limit %s
     offset %s',
    p_schema_name,
    p_table_name,
    greatest(coalesce(p_limit, 1000), 1),
    greatest(coalesce(p_offset, 0), 0)
  );

  return query execute v_sql;
end;
$$;


ALTER FUNCTION "integration"."export_table_json"("p_schema_name" "text", "p_table_name" "text", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "integration"."get_primary_key_json"("p_schema_name" "text", "p_table_name" "text", "p_row" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
  with pk_cols as (
    select a.attname::text as col_name, cols.ord
    from pg_index i
    join pg_class c
      on c.oid = i.indrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    join unnest(i.indkey) with ordinality as cols(attnum, ord)
      on true
    join pg_attribute a
      on a.attrelid = c.oid
     and a.attnum   = cols.attnum
    where i.indisprimary
      and n.nspname = p_schema_name
      and c.relname = p_table_name
  )
  select case
           when count(*) = 0 then null
           else jsonb_object_agg(col_name, p_row -> col_name order by ord)
         end
  from pk_cols;
$$;


ALTER FUNCTION "integration"."get_primary_key_json"("p_schema_name" "text", "p_table_name" "text", "p_row" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "integration"."install_outbox_triggers"("p_target_schema" "text" DEFAULT 'public'::"text") RETURNS TABLE("schema_name" "text", "table_name" "text", "status" "text")
    LANGUAGE "plpgsql"
    AS $$
declare
  r record;
begin
  for r in
    select c.relname as table_name
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = p_target_schema
      and c.relkind in ('r', 'p') -- tabela normal e particionada
      and c.relname <> 'schema_migrations'
    order by c.relname
  loop
    execute format(
      'drop trigger if exists trg_integration_outbox on %I.%I',
      p_target_schema,
      r.table_name
    );

    execute format(
      'create trigger trg_integration_outbox
         after insert or update or delete
         on %I.%I
         for each row
         execute function integration.capture_change()',
      p_target_schema,
      r.table_name
    );

    schema_name := p_target_schema;
    table_name  := r.table_name;
    status      := 'ok';
    return next;
  end loop;
end;
$$;


ALTER FUNCTION "integration"."install_outbox_triggers"("p_target_schema" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "integration"."pull_changes_for_horizons"("p_limit" integer DEFAULT 500, "p_reserve_minutes" integer DEFAULT 5) RETURNS TABLE("event_id" "uuid", "occurred_at" timestamp with time zone, "schema_name" "text", "table_name" "text", "op" "text", "pk" "jsonb", "old_row" "jsonb", "new_row" "jsonb", "txid" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
begin
  return query
  with picked as (
    select o.id
    from integration.outbox o
    where o.delivered_at is null
      and (o.reserved_until is null or o.reserved_until < now())
    order by o.occurred_at, o.id
    limit greatest(coalesce(p_limit, 500), 1)
    for update skip locked
  ),
  upd as (
    update integration.outbox o
       set reserved_until  = now() + make_interval(mins => greatest(coalesce(p_reserve_minutes, 5), 1)),
           last_attempt_at = now(),
           delivery_attempts = o.delivery_attempts + 1
      from picked p
     where o.id = p.id
     returning o.*
  )
  select
    u.id,
    u.occurred_at,
    u.schema_name,
    u.table_name,
    u.op,
    u.pk,
    u.old_row,
    u.new_row,
    u.txid
  from upd u
  order by u.occurred_at, u.id;
end;
$$;


ALTER FUNCTION "integration"."pull_changes_for_horizons"("p_limit" integer, "p_reserve_minutes" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "integration"."remove_outbox_triggers"("p_target_schema" "text" DEFAULT 'public'::"text") RETURNS TABLE("schema_name" "text", "table_name" "text", "status" "text")
    LANGUAGE "plpgsql"
    AS $$
declare
  r record;
begin
  for r in
    select c.relname as table_name
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = p_target_schema
      and c.relkind in ('r', 'p')
    order by c.relname
  loop
    execute format(
      'drop trigger if exists trg_integration_outbox on %I.%I',
      p_target_schema,
      r.table_name
    );

    schema_name := p_target_schema;
    table_name  := r.table_name;
    status      := 'removed';
    return next;
  end loop;
end;
$$;


ALTER FUNCTION "integration"."remove_outbox_triggers"("p_target_schema" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_athlete_bundle"("p_athlete_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_profile jsonb := '{}'::jsonb;
  v_status jsonb := '{}'::jsonb;
  v_kpis jsonb := '{}'::jsonb;
  v_charts jsonb := '{}'::jsonb;
  v_timeline jsonb := '[]'::jsonb;
  v_derived jsonb := '{}'::jsonb;
  v_latest_questionnaires jsonb := '{}'::jsonb;
  v_latest_records jsonb := '{}'::jsonb;

  v_latest_metrics record;
  v_latest_training record;
begin

  ---------------------------------------------------------
  -- 1) PROFILE
  ---------------------------------------------------------
  select jsonb_build_object(
    'id', a.athlete_id,
    'name', a.athlete_name,
    'team', a.team_name,
    'phone', a.athlete_phone,

    'sport', coalesce(ar.payload->>'Modalidade esportiva principal', 'Não informado'),
    'category', coalesce(ar.payload->>'Categoria (sub-10, sub-12, sub-14, sub-17, adulto etc.)', 'Principal'),

    'coach_name', coalesce(ar.coach_name, a.coach_phone),

    'age',
      case
        when ar.payload->>'REG_DOB | Data de nascimento' is not null
        then extract(year from age(current_date, (ar.payload->>'REG_DOB | Data de nascimento')::date))
      end,

    'years_practice',
      coalesce(ar.payload->>'Tempo de prática na modalidade atual (anos/meses)', '0'),

    'club',
      coalesce(ar.payload->>'Clube atual / equipe / centro de treinamento', a.team_name),

    'career', jsonb_build_object(
      'achievements', coalesce(ar.payload->>'Maiores conquistas esportivas', 'Sem registros'),
      'years_in_sport', coalesce(ar.payload->>'Tempo de prática na modalidade atual (anos/meses)', '0')
    ),

    'health', jsonb_build_object(
      'injuries', coalesce(ar.payload->>'Lesões prévias relevantes (tipo, data, tratamento)', 'Nenhuma'),
      'chronic_pain', coalesce(ar.payload->>'Dores crônicas (onde, intensidade, frequência)', 'Nenhuma'),
      'surgeries', coalesce(ar.payload->>'Cirurgias importantes', 'Nenhuma')
    ),

    'goals', jsonb_build_object(
      'sport_goals', coalesce(ar.payload->>'Metas esportivas', 'Melhorar performance'),
      'upcoming_competitions', coalesce(ar.payload->>'Competições previstas nos próximos 3–6 meses', 'Nenhuma cadastrada')
    ),

    'ideal_weight_kg', ar.ideal_weight_kg,
    'registration_last_update', ar.inserted_at::text
  )
  into v_profile
  from api_athletes a
  left join lateral (
    select *
    from athlete_registration ar2
    where ar2.athlete_id = a.athlete_id
    order by ar2.inserted_at desc nulls last
    limit 1
  ) ar on true
  where a.athlete_id = p_athlete_id
  limit 1;

  ---------------------------------------------------------
  -- 2) LATEST SNAPSHOT
  ---------------------------------------------------------
  select *
  into v_latest_metrics
  from pingo_scoring_inputs_view_final
  where athlete_id = p_athlete_id
  order by reference_date desc nulls last
  limit 1;

  ---------------------------------------------------------
  -- 3) LATEST TRAINING SESSION
  ---------------------------------------------------------
  select data, load
  into v_latest_training
  from v_training_calendar_world
  where athlete_id = p_athlete_id
    and has_session = true
  order by data desc nulls last
  limit 1;

  ---------------------------------------------------------
  -- 4) STATUS
  ---------------------------------------------------------
  v_status := jsonb_build_object(
    'level',
      case
        when coalesce(v_latest_metrics.pattern_burnout, false)
          or coalesce(v_latest_metrics.pattern_flat, false)
          or coalesce(v_latest_metrics.stress_index, 0) >= 7
        then 'high'

        when coalesce(v_latest_metrics.pattern_hyperactivation, false)
          or coalesce(v_latest_metrics.stress_index, 0) >= 4
        then 'medium'

        else 'low'
      end,

    'score', coalesce(v_latest_metrics.stress_index, 0),

    'drivers',
      to_jsonb(
        array_remove(
          array[
            case when coalesce(v_latest_metrics.pattern_burnout, false) then 'Burnout' end,
            case when coalesce(v_latest_metrics.pattern_flat, false) then 'Flat' end,
            case when coalesce(v_latest_metrics.pattern_hyperactivation, false) then 'Hiperativação' end,
            case when coalesce(v_latest_metrics.stress_index, 0) >= 7 then 'Estresse elevado' end,
            case when coalesce(v_latest_metrics.adherence_score, 100) < 60 then 'Baixa adesão alimentar' end
          ],
          null
        )
      )
  );

  ---------------------------------------------------------
  -- 5) KPIS
  ---------------------------------------------------------
  v_kpis := jsonb_build_object(
    'vigor', jsonb_build_object(
      'current', coalesce(v_latest_metrics.vigor, 0),
      'last_update', v_latest_metrics.brums_date::text
    ),

    'weight', jsonb_build_object(
      'current', coalesce(v_latest_metrics.weight_kg, 0),
      'last_update', v_latest_metrics.weight_date::text
    ),

    'training_load', jsonb_build_object(
      'current', coalesce(v_latest_training.load, 0),
      'last_update', v_latest_training.data::text
    ),

    'diet_adherence', jsonb_build_object(
      'current', coalesce(v_latest_metrics.adherence_score, 0),
      'last_update', v_latest_metrics.reference_date::text
    )
  );

  ---------------------------------------------------------
  -- 6) LATEST QUESTIONNAIRES / LATEST RECORDS
  ---------------------------------------------------------
  v_latest_questionnaires := jsonb_build_object(
    'brums', public.api_latest_row_json('public.brums_analysis', p_athlete_id),
    'acsi',  public.api_latest_row_json('public.acsi_analysis', p_athlete_id),
    'gses',  public.api_latest_row_json('public.gses_analysis', p_athlete_id),
    'pmcsq', public.api_latest_row_json('public.pmcsq_analysis', p_athlete_id),
    'restq', public.api_latest_row_json('public.restq_analysis', p_athlete_id),
    'cbas',  public.api_latest_row_json('public.cbas_analysis', p_athlete_id)
  );

  v_latest_records := jsonb_build_object(
    'scoring_snapshot', public.api_latest_row_json('public.pingo_scoring_inputs_view_final', p_athlete_id),
    'diet_daily',       public.api_latest_row_json('public.diet_daily', p_athlete_id),
    'weight_analysis',  public.api_latest_row_json('public.weight_analysis', p_athlete_id),
    'latest_note',      public.api_latest_row_json('public.pingo_athlete_notes', p_athlete_id),
    'latest_flag',      public.api_latest_row_json('public.api_flags_events', p_athlete_id),
    'latest_training',  coalesce(
                          (
                            select jsonb_build_object(
                              'data', t.data::text,
                              'load', t.load
                            )
                            from (
                              select data, load
                              from v_training_calendar_world
                              where athlete_id = p_athlete_id
                                and has_session = true
                              order by data desc nulls last
                              limit 1
                            ) t
                          ),
                          '{}'::jsonb
                        )
  );

  ---------------------------------------------------------
  -- 7) CHARTS
  ---------------------------------------------------------
  v_charts := jsonb_build_object(
    'brums_series',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'date', s.data::text,
              'vigor', s.vigor,
              'tension', s.tension,
              'fatigue', s.fatigue,
              'confusion', s.confusion,
              'anger', s.anger,
              'depression', s.depression
            )
            order by s.data asc
          )
          from (
            select *
            from brums_analysis
            where athlete_id = p_athlete_id
            order by data desc
            limit 14
          ) s
        ),
        '[]'::jsonb
      ),

    'load_series',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'date', s.data::text,
              'load', s.load
            )
            order by s.data asc
          )
          from (
            select data, load
            from v_training_calendar_world
            where athlete_id = p_athlete_id
              and has_session = true
            order by data desc
            limit 90
          ) s
        ),
        '[]'::jsonb
      )
  );

  ---------------------------------------------------------
  -- 8) TIMELINE
  ---------------------------------------------------------
  select coalesce(jsonb_agg(event order by event->>'date' desc), '[]'::jsonb)
  into v_timeline
  from (
    select jsonb_build_object(
      'type', 'training',
      'date', data::text,
      'title', 'Sessão de Treino',
      'load', load
    ) as event
    from v_training_calendar_world
    where athlete_id = p_athlete_id
      and has_session = true
      and data >= current_date - interval '365 days'

    union all

    select jsonb_build_object(
      'type', 'brums',
      'date', data::text,
      'title', 'Questionário BRUMS',
      'vigor', vigor,
      'dth', dth
    ) as event
    from brums_analysis
    where athlete_id = p_athlete_id
      and data >= current_date - interval '365 days'

    union all

    select jsonb_build_object(
      'type', 'diet',
      'date', data::text,
      'title', 'Registro Nutricional',
      'adherence', adherence_score,
      'weight', weight_kg
    ) as event
    from diet_daily
    where athlete_id = p_athlete_id
      and data >= current_date - interval '365 days'
  ) s;

  ---------------------------------------------------------
  -- 9) DERIVED METRICS
  ---------------------------------------------------------
  v_derived := (
    with sessions as (
      select data, load
      from v_training_calendar_world
      where athlete_id = p_athlete_id
        and has_session = true
        and data >= current_date - interval '60 days'
    ),
    acute as (
      select avg(load) as acute
      from sessions
      where data >= current_date - interval '7 days'
    ),
    chronic as (
      select avg(load) as chronic
      from sessions
      where data >= current_date - interval '28 days'
    )
    select jsonb_build_object(
      'acute_load', (select acute from acute),
      'chronic_load', (select chronic from chronic),
      'acwr',
        (select acute from acute) /
        nullif((select chronic from chronic), 0)
    )
  );

  ---------------------------------------------------------
  -- RETURN
  ---------------------------------------------------------
  return jsonb_build_object(
    'profile', v_profile,
    'status', v_status,
    'kpis', v_kpis,
    'charts', v_charts,
    'timeline_events', coalesce(v_timeline, '[]'::jsonb),
    'derived_metrics', v_derived,
    'latest_questionnaires', v_latest_questionnaires,
    'latest_records', v_latest_records
  );

end;
$$;


ALTER FUNCTION "public"."api_athlete_bundle"("p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_get_athlete_bundle"("p_athlete_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE

  v_profile jsonb;
  v_status jsonb;
  v_kpis jsonb;
  v_charts jsonb;
  v_timeline jsonb;
  v_derived jsonb;
  v_pattern jsonb;
  v_psychology jsonb;
  v_alerts jsonb;
  v_notes jsonb;
  v_diet_metrics jsonb;
  v_weekly_narratives jsonb;
  v_construcional_profile jsonb;
  v_contact jsonb;

  v_latest_metrics record;
  v_latest_training record;

BEGIN


SELECT jsonb_build_object(

'id', a.athlete_id,
'name', a.athlete_name,
'team', a.team_name,
'phone', a.athlete_phone,

'sport', COALESCE(ar.payload->>'Modalidade esportiva principal','Não informado'),
'category', COALESCE(ar.payload->>'Categoria (sub-10, sub-12, sub-14, sub-17, adulto etc.)','Principal'),

'coach_name', COALESCE(ar.coach_name,a.coach_phone),

'age',
CASE
WHEN ar.payload->>'REG_DOB | Data de nascimento' IS NOT NULL
THEN EXTRACT(year FROM age(current_date,(ar.payload->>'REG_DOB | Data de nascimento')::date))
END,

'years_practice',
COALESCE(ar.payload->>'Tempo de prática na modalidade atual (anos/meses)','0'),

'club',
COALESCE(ar.payload->>'Clube atual / equipe / centro de treinamento',a.team_name),

'career',
jsonb_build_object(
'achievements',COALESCE(ar.payload->>'Maiores conquistas esportivas','Sem registros'),
'years_in_sport',COALESCE(ar.payload->>'Tempo de prática na modalidade atual (anos/meses)','0')
),

'health',
jsonb_build_object(
'injuries',COALESCE(ar.payload->>'Lesões prévias relevantes (tipo, data, tratamento)','Nenhuma'),
'chronic_pain',COALESCE(ar.payload->>'Dores crônicas (onde, intensidade, frequência)','Nenhuma'),
'surgeries',COALESCE(ar.payload->>'Cirurgias importantes','Nenhuma')
),

'goals',
jsonb_build_object(
'sport_goals',COALESCE(ar.payload->>'Metas esportivas','Melhorar performance'),
'upcoming_competitions',COALESCE(ar.payload->>'Competições previstas nos próximos 3–6 meses','Nenhuma cadastrada')
),

'ideal_weight_kg',ar.ideal_weight_kg

)

INTO v_profile
FROM api_athletes a
LEFT JOIN athlete_registration ar
ON a.athlete_id = ar.athlete_id
WHERE a.athlete_id = p_athlete_id
LIMIT 1;


SELECT *
INTO v_latest_metrics
FROM pingo_scoring_inputs_view_final
WHERE athlete_id = p_athlete_id
ORDER BY reference_date DESC
LIMIT 1;


SELECT data,load
INTO v_latest_training
FROM v_training_calendar_world
WHERE athlete_id = p_athlete_id
AND has_session = TRUE
ORDER BY data DESC
LIMIT 1;


v_status := jsonb_build_object(

'level',

CASE
WHEN COALESCE(v_latest_metrics.pattern_burnout,false)
OR COALESCE(v_latest_metrics.pattern_flat,false)
THEN 'high'

WHEN COALESCE(v_latest_metrics.pattern_hyperactivation,false)
THEN 'medium'

ELSE 'low'
END,

'score',COALESCE(v_latest_metrics.stress_index,0),

'drivers',jsonb_build_array('Carga','Recuperação','Sono')

);


v_kpis := jsonb_build_object(

'vigor',
jsonb_build_object(
'current',COALESCE(v_latest_metrics.vigor,0),
'last_update',v_latest_metrics.brums_date::text
),

'weight',
jsonb_build_object(
'current',COALESCE(v_latest_metrics.weight_kg,0),
'last_update',v_latest_metrics.weight_date::text
),

'training_load',
jsonb_build_object(
'current',COALESCE(v_latest_training.load,0),
'last_update',v_latest_training.data::text
),

'diet_adherence',
jsonb_build_object(
'current',COALESCE(v_latest_metrics.adherence_score,0),
'last_update',v_latest_metrics.reference_date::text
)

);


v_charts := jsonb_build_object(

'brums_series',

COALESCE(

(
SELECT jsonb_agg(
jsonb_build_object(
'date',data::text,
'vigor',vigor,
'tension',tension,
'fatigue',fatigue,
'confusion',confusion,
'anger',anger,
'depression',depression
)
ORDER BY data ASC
)

FROM
(
SELECT *
FROM brums_analysis
WHERE athlete_id = p_athlete_id
ORDER BY data DESC
LIMIT 14
) s

),

'[]'::jsonb

),

'load_series',

COALESCE(

(
SELECT jsonb_agg(
jsonb_build_object(
'date',data::text,
'load',load
)
ORDER BY data ASC
)

FROM
(
SELECT data,load
FROM v_training_calendar_world
WHERE athlete_id = p_athlete_id
AND has_session = TRUE
ORDER BY data DESC
LIMIT 90
) s

),

'[]'::jsonb

)

);


SELECT jsonb_agg(event ORDER BY event->>'date' DESC)
INTO v_timeline
FROM(

SELECT jsonb_build_object(
'type','training',
'date',data::text,
'title','Sessão de Treino',
'load',load
) event
FROM v_training_calendar_world
WHERE athlete_id = p_athlete_id
AND has_session = TRUE
AND data >= CURRENT_DATE - INTERVAL '365 days'

UNION ALL

SELECT jsonb_build_object(
'type','brums',
'date',data::text,
'title','Questionário BRUMS',
'vigor',vigor,
'dth',dth
)
FROM brums_analysis
WHERE athlete_id = p_athlete_id
AND data >= CURRENT_DATE - INTERVAL '365 days'

UNION ALL

SELECT jsonb_build_object(
'type','diet',
'date',data::text,
'title','Registro Nutricional',
'adherence',adherence_score,
'weight',weight_kg
)
FROM diet_daily
WHERE athlete_id = p_athlete_id
AND data >= CURRENT_DATE - INTERVAL '365 days'

) s;


v_derived := (

WITH sessions AS (

SELECT data,load
FROM v_training_calendar_world
WHERE athlete_id = p_athlete_id
AND has_session = TRUE
AND data >= CURRENT_DATE - INTERVAL '60 days'

),

acute AS (

SELECT avg(load) acute
FROM sessions
WHERE data >= CURRENT_DATE - INTERVAL '7 days'

),

chronic AS (

SELECT avg(load) chronic
FROM sessions
WHERE data >= CURRENT_DATE - INTERVAL '28 days'

)

SELECT jsonb_build_object(

'acute_load',(SELECT acute FROM acute),

'chronic_load',(SELECT chronic FROM chronic),

'acwr',
(SELECT acute FROM acute)
/ NULLIF((SELECT chronic FROM chronic),0)

)

);


RETURN jsonb_build_object(

'profile',v_profile,
'status',v_status,
'kpis',v_kpis,
'charts',v_charts,
'timeline_events',COALESCE(v_timeline,'[]'::jsonb),
'derived_metrics',v_derived

);

END;
$$;


ALTER FUNCTION "public"."api_get_athlete_bundle"("p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_get_athlete_snapshot"("p_athlete_id" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    AS $$

with profile as (
    select
        athlete_id,
        athlete_name,
        team_name,
        athlete_phone,
        coach_phone,
        payload
    from athlete_registration
    where athlete_id = p_athlete_id
),

state as (
    select to_jsonb(v) as state
    from pingo_scoring_inputs_view_final v
    where v.athlete_id = p_athlete_id
    order by reference_date desc
    limit 1
),

brums_last7 as (
    select jsonb_agg(
        jsonb_build_object(
            'date', data,
            'vigor', vigor,
            'tension', tension,
            'depression', depression,
            'anger', anger,
            'fatigue', fatigue,
            'confusion', confusion
        )
        order by data desc
    ) as brums
    from brums_analysis
    where athlete_id = p_athlete_id
    and data >= current_date - interval '7 days'
),

diet_last7 as (
    select jsonb_agg(
        jsonb_build_object(
            'date', data,
            'weight_kg', weight_kg,
            'adherence', adherence_score,
            'gi', gi_distress,
            'payload', payload
        )
        order by data desc
    ) as diet
    from diet_daily
    where athlete_id = p_athlete_id
    and data >= current_date - interval '7 days'
),

training_last7 as (
    select jsonb_agg(
        jsonb_build_object(
            'date', data,
            'rpe', rpe,
            'duration_min', duration_min,
            'srpe_load', srpe_load,
            'payload', payload
        )
        order by data desc
    ) as training
    from training_load_daily
    where athlete_id = p_athlete_id
    and data >= current_date - interval '7 days'
),

weekly_last as (
    select payload
    from weekly_analysis
    where athlete_id = p_athlete_id
    order by start_date desc
    limit 1
),

acsi_last as (
    select payload
    from acsi_analysis
    where athlete_id = p_athlete_id
    order by data desc
    limit 1
),

gses_last as (
    select payload
    from gses_analysis
    where athlete_id = p_athlete_id
    order by data desc
    limit 1
),

restq_last as (
    select payload
    from restq_analysis
    where athlete_id = p_athlete_id
    order by data desc
    limit 1
),

pmcsq_last as (
    select payload
    from pmcsq_analysis
    where athlete_id = p_athlete_id
    order by data desc
    limit 1
),

cbas_last as (
    select payload
    from cbas_analysis
    where athlete_id = p_athlete_id
    order by data desc
    limit 1
)

select jsonb_build_object(

    'profile', to_jsonb(p),

    'state', s.state,

    'timeline', jsonb_build_object(
        'brums', b.brums,
        'diet', d.diet,
        'training', t.training
    ),

    'questionnaires', jsonb_build_object(
        'weekly', (select payload from weekly_last),
        'acsi', (select payload from acsi_last),
        'gses', (select payload from gses_last),
        'restq', (select payload from restq_last),
        'pmcsq', (select payload from pmcsq_last),
        'cbas', (select payload from cbas_last)
    )

)

from profile p
left join state s on true
left join brums_last7 b on true
left join diet_last7 d on true
left join training_last7 t on true;

$$;


ALTER FUNCTION "public"."api_get_athlete_snapshot"("p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_latest_row_json"("p_relation" "text", "p_athlete_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $_$
declare
  v_schema text;
  v_name text;
  v_date_col text;
  v_has_athlete_id boolean;
  v_sql text;
  v_result jsonb;
begin
  if position('.' in p_relation) > 0 then
    v_schema := split_part(p_relation, '.', 1);
    v_name   := split_part(p_relation, '.', 2);
  else
    v_schema := 'public';
    v_name   := p_relation;
  end if;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = v_schema
      and table_name   = v_name
      and column_name  = 'athlete_id'
  )
  into v_has_athlete_id;

  if not v_has_athlete_id then
    return '{}'::jsonb;
  end if;

  select c.column_name
  into v_date_col
  from information_schema.columns c
  where c.table_schema = v_schema
    and c.table_name   = v_name
    and c.column_name in (
      'reference_date',
      'data',
      'created_at',
      'inserted_at',
      'updated_at'
    )
  order by case c.column_name
    when 'reference_date' then 1
    when 'data'           then 2
    when 'created_at'     then 3
    when 'inserted_at'    then 4
    when 'updated_at'     then 5
    else 99
  end
  limit 1;

  v_sql := format(
    'select to_jsonb(x)
       from (
         select *
         from %I.%I
         where athlete_id = $1
         %s
         limit 1
       ) x',
    v_schema,
    v_name,
    case
      when v_date_col is not null
        then format('order by %I desc nulls last', v_date_col)
      else ''
    end
  );

  execute v_sql
    into v_result
    using p_athlete_id;

  return coalesce(v_result, '{}'::jsonb);
end;
$_$;


ALTER FUNCTION "public"."api_latest_row_json"("p_relation" "text", "p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."attach_note_embedding"("p_note_id" bigint, "p_embedding" "public"."vector") RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
declare
  n record;
  v_id bigint;
  v_meta jsonb;
begin
  select * into n
  from public.pingo_athlete_notes
  where id = p_note_id;

  if not found then
    raise exception 'Nota não encontrada: %', p_note_id;
  end if;

  v_meta := jsonb_build_object(
    'note_id', n.id,
    'tags', n.tags,
    'user_id', n.user_id
  );

  insert into public.analysis_vectors(
    athlete_id, data, source, embedding, metadata
  )
  values (
    n.athlete_id,
    (n.created_at at time zone 'America/Sao_Paulo')::date,
    'pingo_chat_note',
    p_embedding,
    v_meta
  )
  returning id into v_id;

  return v_id;
end $$;


ALTER FUNCTION "public"."attach_note_embedding"("p_note_id" bigint, "p_embedding" "public"."vector") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clean_zero_flags"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.attention_level = 0 THEN
    NEW.flag_count := 0;
    NEW.flags := '[]'::jsonb;
    NEW.rules_triggered := '[]'::jsonb;
    NEW.thresholds_used := '{}'::jsonb;
    NEW.summary := NULL;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."clean_zero_flags"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_athlete_note"("p_athlete_id" "text", "p_note_text" "text", "p_user_id" "text" DEFAULT NULL::"text", "p_source_message_id" bigint DEFAULT NULL::bigint, "p_title" "text" DEFAULT NULL::"text", "p_tags" "text"[] DEFAULT '{}'::"text"[], "p_confidence" numeric DEFAULT NULL::numeric, "p_model_name" "text" DEFAULT NULL::"text", "p_note_meta" "jsonb" DEFAULT '{}'::"jsonb") RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
declare
  v_id bigint;
begin
  insert into public.pingo_athlete_notes(
    athlete_id, user_id, source_message_id,
    title, note_text, tags, confidence, model_name, note_meta
  )
  values (
    p_athlete_id, p_user_id, p_source_message_id,
    p_title, p_note_text, coalesce(p_tags,'{}'::text[]),
    p_confidence, p_model_name, coalesce(p_note_meta,'{}'::jsonb)
  )
  returning id into v_id;

  if p_source_message_id is not null then
    update public.pingo_user_messages
    set include_in_history = true,
        saved_at = now(),
        saved_by = 'agent'
    where id = p_source_message_id;
  end if;

  return v_id;
end $$;


ALTER FUNCTION "public"."create_athlete_note"("p_athlete_id" "text", "p_note_text" "text", "p_user_id" "text", "p_source_message_id" bigint, "p_title" "text", "p_tags" "text"[], "p_confidence" numeric, "p_model_name" "text", "p_note_meta" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_full_user"("p_user_id" "text", "p_name" "text", "p_phone" "text", "p_email" "text", "p_password_hash" "text", "p_master_id" "text", "p_coach_id" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin

  -- cria identidade
  insert into public.users_identity (
    user_id,
    phone,
    email,
    password_hash
  )
  values (
    p_user_id,
    p_phone,
    p_email,
    p_password_hash
  );

  -- cria registro completo
  insert into public.users (
    user_id,
    name,
    phone,
    email,
    master_id,
    coach_id
  )
  values (
    p_user_id,
    p_name,
    p_phone,
    p_email,
    p_master_id,
    p_coach_id
  );

end;
$$;


ALTER FUNCTION "public"."create_full_user"("p_user_id" "text", "p_name" "text", "p_phone" "text", "p_email" "text", "p_password_hash" "text", "p_master_id" "text", "p_coach_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crypt"("pass" "text", "salt" "text") RETURNS "text"
    LANGUAGE "sql"
    AS $$
select encode(digest(pass || salt, 'sha256'), 'hex');
$$;


ALTER FUNCTION "public"."crypt"("pass" "text", "salt" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."digest"("data" "text", "alg" "text") RETURNS "bytea"
    LANGUAGE "sql"
    AS $$
select decode(md5(data), 'hex');
$$;


ALTER FUNCTION "public"."digest"("data" "text", "alg" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dispatch_next_minds_webhook"() RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_row public.minds_webhook_queue%ROWTYPE;
  v_request_id bigint;
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


ALTER FUNCTION "public"."dispatch_next_minds_webhook"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_coach_user"("p_coach_name" "text", "p_coach_phone" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_phone         text;
  v_user_id_txt   text;
  v_user_id_type  text;
  v_seq           text;
  v_name          text;
begin
  v_phone := public.only_digits(p_coach_phone);
  v_name  := coalesce(nullif(trim(p_coach_name), ''), 'Coach');

  if v_phone is null then
    return;
  end if;

  -- lock por telefone para evitar corrida
  perform pg_advisory_xact_lock(hashtext(v_phone));

  -- descobre o tipo real de users.user_id
  select format_type(a.atttypid, a.atttypmod)
    into v_user_id_type
  from pg_attribute a
  join pg_class c on c.oid = a.attrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'users'
    and a.attname = 'user_id'
    and a.attnum > 0
    and not a.attisdropped;

  if v_user_id_type is null then
    raise exception 'Nao foi possivel identificar o tipo de public.users.user_id';
  end if;

  -- tenta achar usuário existente pelo telefone
  select u.user_id::text
    into v_user_id_txt
  from public.users u
  where public.only_digits(u.phone) = v_phone
  order by u.user_id::text
  limit 1;

  -- se não existir, cria com user_id explícito
  if v_user_id_txt is null then

    if v_user_id_type = 'uuid' then
      v_user_id_txt := gen_random_uuid()::text;

    elsif v_user_id_type in ('bigint', 'integer', 'smallint') then
      select pg_get_serial_sequence('public.users', 'user_id')
        into v_seq;

      if v_seq is not null then
        execute format('select nextval(%L)::text', v_seq)
          into v_user_id_txt;
      else
        lock table public.users in share row exclusive mode;
        execute 'select (coalesce(max(user_id), 0) + 1)::text from public.users'
          into v_user_id_txt;
      end if;

    else
      -- text / varchar / similares
      v_user_id_txt := v_phone;
    end if;

    execute format(
      'insert into public.users (user_id, name, phone)
       values (%L::%s, %L, %L)
       returning user_id::text',
      v_user_id_txt,
      v_user_id_type,
      v_name,
      v_phone
    )
    into v_user_id_txt;

  else
    -- atualiza nome e telefone se já existir
    update public.users u
       set name = case
                    when coalesce(nullif(trim(u.name), ''), '') = '' then v_name
                    when u.name ilike 'coach%%' then v_name
                    when public.only_digits(u.phone) = public.only_digits(u.name) then v_name
                    else u.name
                  end,
           phone = case
                     when public.only_digits(u.phone) is distinct from v_phone then v_phone
                     else u.phone
                   end
     where u.user_id::text = v_user_id_txt;
  end if;

  -- garante role coach
  execute format(
    'insert into public.user_roles (user_id, role)
     values (%L::%s, %L)
     on conflict (user_id, role) do nothing',
    v_user_id_txt,
    v_user_id_type,
    'coach'
  );
end;
$$;


ALTER FUNCTION "public"."ensure_coach_user"("p_coach_name" "text", "p_coach_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."find_athletes"("p_query" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 10) RETURNS TABLE("athlete_id" "text", "athlete_name" "text", "team_name" "text", "athlete_phone" "text", "coach_phone" "text", "last_seen" timestamp with time zone)
    LANGUAGE "sql" STABLE
    AS $$
  with q as (
    select trim(coalesce(p_query,'')) as query
  )
  select
    a.athlete_id,
    a.athlete_name,
    a.team_name,
    a.athlete_phone,
    a.coach_phone,
    a.inserted_at as last_seen
  from public.athlete_latest_view a, q
  where
    -- ✅ se query vazia: mostra recentes
    (q.query = '')
    OR
    -- ✅ se tem query: faz o filtro normal
    (
      q.query <> ''
      and (
        a.athlete_id ilike q.query || '%'
        or coalesce(a.athlete_name,'') ilike '%' || q.query || '%'
        or coalesce(a.team_name,'') ilike '%' || q.query || '%'
        or coalesce(a.athlete_phone,'') ilike '%' || regexp_replace(q.query,'\D','','g') || '%'
        or coalesce(a.coach_phone,'') ilike '%' || regexp_replace(q.query,'\D','','g') || '%'
      )
    )
  order by a.inserted_at desc
  limit greatest(1, least(p_limit, 25));
$$;


ALTER FUNCTION "public"."find_athletes"("p_query" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."gen_salt"("type" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $_$
declare
    salt text;
begin

    if type != 'bf' then
        raise exception 'Only bcrypt (bf) supported in this custom gen_salt';
    end if;

    -- gera salt pseudo aleatório
    salt :=
        '$2a$10$' ||
        substring(
            encode(
                digest(random()::text || clock_timestamp()::text, 'sha256'),
                'base64'
            )
        from 1 for 22);

    return salt;

end;
$_$;


ALTER FUNCTION "public"."gen_salt"("type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_all_coaches"() RETURNS TABLE("user_id" "text", "coach_name" "text", "coach_phone" "text", "role" "text")
    LANGUAGE "sql" STABLE
    AS $$
  select
    uc.user_id::text as user_id,
    uc.name::text as coach_name,
    uc.phone::text as coach_phone,
    uc.role::text as role
  from public.users_coaches uc
  order by uc.name;
$$;


ALTER FUNCTION "public"."get_all_coaches"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_all_teams_with_athletes"() RETURNS json
    LANGUAGE "sql"
    AS $$
with athletes_grouped as (

  select
    a.coach_phone,
    count(*) as total_athletes,
    json_agg(
      json_build_object(
        'athlete_id', a.athlete_id,
        'athlete_name', a.athlete_name,
        'athlete_phone', a.athlete_phone,
        'coach_phone', a.coach_phone
      )
    ) as athletes
  from public.api_athletes a
  group by a.coach_phone

)

select json_agg(
  json_build_object(
    'coach_phone', ag.coach_phone,
    'coach_name', u.name,
    'total_athletes', ag.total_athletes,
    'athletes', ag.athletes
  )
)
from athletes_grouped ag
left join public.users u
  on u.phone = ag.coach_phone;
$$;


ALTER FUNCTION "public"."get_all_teams_with_athletes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_athlete_full_analysis"("p_athlete_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    AS $$
declare
  v_brums jsonb;
  v_load jsonb;
begin

  select to_jsonb(b)
  into v_brums
  from public.brums_analysis b
  where b.athlete_id = p_athlete_id
  order by b.data desc
  limit 1;

  select to_jsonb(t)
  into v_load
  from public.training_load_analysis t
  where t.athlete_id = p_athlete_id
  order by t.inserted_at desc
  limit 1;

  return jsonb_build_object(
    'athlete_id', p_athlete_id,
    'brums', coalesce(v_brums,'{}'::jsonb),
    'training_load', coalesce(v_load,'{}'::jsonb)
  );

end;
$$;


ALTER FUNCTION "public"."get_athlete_full_analysis"("p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_athletes_by_coach"("p_coach_phone" "text", "p_limit" integer DEFAULT 60) RETURNS TABLE("athlete_id" "text", "athlete_name" "text", "team_name" "text", "athlete_phone" "text", "coach_phone" "text", "last_seen" timestamp with time zone)
    LANGUAGE "sql" STABLE
    AS $$
  with p as (
    select regexp_replace(coalesce(p_coach_phone,''), '\D','','g') as coach_digits
  )
  select
    a.athlete_id,
    a.athlete_name,
    a.team_name,
    a.athlete_phone,
    a.coach_phone,
    a.inserted_at as last_seen
  from public.athlete_latest_view a, p
  where
    p.coach_digits <> ''
    and regexp_replace(coalesce(a.coach_phone,''), '\D','','g') like '%' || p.coach_digits || '%'
  order by a.inserted_at desc
  limit greatest(1, least(p_limit, 200));
$$;


ALTER FUNCTION "public"."get_athletes_by_coach"("p_coach_phone" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_coach_bundle"("p_phone" "text", "p_limit" integer DEFAULT 10) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  athletes jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into athletes
  from (
    select
      athlete_id,
      athlete_name,
      team_name
    from public.athlete_registration
    where coach_phone = p_phone
    order by inserted_at desc
    limit p_limit
  ) x;

  return jsonb_build_object(
    'coach_phone', p_phone,
    'athletes', athletes
  );
end;
$$;


ALTER FUNCTION "public"."get_coach_bundle"("p_phone" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_coaches_by_master"() RETURNS TABLE("user_id" "text", "coach_name" "text", "coach_phone" "text", "role" "text")
    LANGUAGE "sql" STABLE
    AS $$
  select
    uc.user_id::text as user_id,
    uc.name::text as coach_name,
    uc.phone::text as coach_phone,
    uc.role::text as role
  from public.users_coaches uc
  order by uc.name;
$$;


ALTER FUNCTION "public"."get_coaches_by_master"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_coaches_by_master"("p_master_phone" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 100) RETURNS TABLE("user_id" "text", "coach_name" "text", "coach_phone" "text", "role" "text")
    LANGUAGE "sql" STABLE
    AS $$
  with p as (
    select regexp_replace(coalesce(p_master_phone,''), '\D','','g') as master_digits
  )
  select
    uc.user_id::text as user_id,
    uc.name::text as coach_name,
    uc.phone::text as coach_phone,
    uc.role::text as role
  from public.users_coaches uc, p
  order by uc.name
  limit greatest(1, least(coalesce(p_limit, 100), 200));
$$;


ALTER FUNCTION "public"."get_coaches_by_master"("p_master_phone" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_master_data"() RETURNS TABLE("athlete_id" "text", "athlete_name" "text", "team_name" "text", "athlete_phone" "text", "coach_phone" "text", "inserted_at" timestamp with time zone, "athlete_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  select
    a.athlete_id,
    a.athlete_name,
    a.team_name,
    a.athlete_phone,
    a.coach_phone,
    a.inserted_at,
    t.athlete_count
  from public.api_athletes a
  left join public.api_teams t
    on a.team_name = t.team_name;
$$;


ALTER FUNCTION "public"."get_master_data"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_pingo_chat_bundle"("p_user_id" "text", "p_notes_limit" integer DEFAULT 8, "p_msgs_limit" integer DEFAULT 10) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  c record;
  a record;
  notes jsonb;
  msgs jsonb;
begin
  select * into c
  from public.pingo_chat_context
  where user_id = p_user_id;

  if not found or c.last_athlete_id is null then
    return jsonb_build_object(
      'user_id', p_user_id,
      'context', coalesce(to_jsonb(c), '{}'::jsonb),
      'athlete', null,
      'recent_notes', '[]'::jsonb,
      'recent_messages', '[]'::jsonb
    );
  end if;

  select * into a
  from public.athlete_latest_view
  where athlete_id = c.last_athlete_id;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into notes
  from (
    select * from public.get_recent_notes(c.last_athlete_id, p_notes_limit)
  ) x;

  select coalesce(jsonb_agg(to_jsonb(y)), '[]'::jsonb)
  into msgs
  from (
    select * from public.get_recent_user_messages(c.last_athlete_id, p_msgs_limit, false)
  ) y;

  return jsonb_build_object(
    'user_id', p_user_id,
    'context', to_jsonb(c),
    'athlete', to_jsonb(a),
    'recent_notes', notes,
    'recent_messages', msgs
  );
end $$;


ALTER FUNCTION "public"."get_pingo_chat_bundle"("p_user_id" "text", "p_notes_limit" integer, "p_msgs_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_pingo_chat_context"("p_user_id" "text") RETURNS TABLE("user_id" "text", "last_athlete_id" "text", "last_athlete_name" "text", "last_team_name" "text", "last_athlete_phone" "text", "last_coach_phone" "text", "meta" "jsonb", "updated_at" timestamp with time zone)
    LANGUAGE "sql" STABLE
    AS $$
  select
    c.user_id,
    c.last_athlete_id,
    c.last_athlete_name,
    c.last_team_name,
    c.last_athlete_phone,
    c.last_coach_phone,
    c.meta,
    c.updated_at
  from public.pingo_chat_context c
  where c.user_id = p_user_id;
$$;


ALTER FUNCTION "public"."get_pingo_chat_context"("p_user_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_recent_notes"("p_athlete_id" "text", "p_limit" integer DEFAULT 10) RETURNS TABLE("id" bigint, "created_at" timestamp with time zone, "title" "text", "note_text" "text", "confidence" numeric, "model_name" "text")
    LANGUAGE "sql" STABLE
    AS $$
                                  select
                                      n.id,
                                          n.created_at,
                                              n.title,
                                                  n.note_text,
                                                      n.confidence,
                                                          n.model_name
                                                          from public.pingo_athlete_notes n
                                                          where n.athlete_id = p_athlete_id
                                                          order by n.created_at desc
                                                          limit greatest(1, least(p_limit, 30));
                                                          $$;


ALTER FUNCTION "public"."get_recent_notes"("p_athlete_id" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_recent_user_messages"("p_athlete_id" "text", "p_limit" integer DEFAULT 15, "p_only_history" boolean DEFAULT false) RETURNS TABLE("id" bigint, "received_at" timestamp with time zone, "message_text" "text", "include_in_history" boolean, "saved_at" timestamp with time zone, "saved_by" "text")
    LANGUAGE "sql" STABLE
    AS $$
  select
    m.id, m.received_at, m.message_text, m.include_in_history, m.saved_at, m.saved_by
  from public.pingo_user_messages m
  where m.athlete_id = p_athlete_id
    and (case when p_only_history then m.include_in_history else true end)
  order by m.received_at desc
  limit greatest(1, least(p_limit, 50));
$$;


ALTER FUNCTION "public"."get_recent_user_messages"("p_athlete_id" "text", "p_limit" integer, "p_only_history" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_team_analysis"("p_coach_phone" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
    v_result jsonb;
    v_has_state boolean;
    v_analysis_date date := (now() at time zone 'America/Sao_Paulo')::date;
    v_window_start date := ((now() at time zone 'America/Sao_Paulo')::date - 6);
begin
    v_has_state := to_regclass('public.pingo_scoring_inputs_view_final') is not null;

    create temp table tmp_athletes (
        athlete_id text,
        athlete_name text,
        athlete_phone text,
        team_name text,
        coach_phone text
    ) on commit drop;

    insert into tmp_athletes (athlete_id, athlete_name, athlete_phone, team_name, coach_phone)
    select
        regexp_replace(coalesce(ar.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
        max(nullif(trim(ar.athlete_name), '')) as athlete_name,
        max(nullif(trim(ar.athlete_phone), '')) as athlete_phone,
        max(nullif(trim(ar.team_name), '')) as team_name,
        max(nullif(trim(ar.coach_phone), '')) as coach_phone
    from public.athlete_registration ar
    where regexp_replace(coalesce(ar.coach_phone::text, ''), '\D', '', 'g')
          = regexp_replace(coalesce(p_coach_phone, ''), '\D', '', 'g')
    group by 1;

    create temp table tmp_state_latest (
        athlete_id text,
        reference_date date,
        repertorio_risco text,
        dth numeric,
        vigor numeric,
        tension numeric,
        daily_load numeric,
        adherence_score numeric
    ) on commit drop;

    create temp table tmp_state_week (
        athlete_id text,
        reference_date date,
        repertorio_risco text,
        dth numeric,
        tension numeric,
        adherence_score numeric
    ) on commit drop;

    create temp table tmp_questionnaire_events (
        athlete_id text,
        questionnaire text,
        fill_date date
    ) on commit drop;

    if v_has_state then
        insert into tmp_state_latest (
            athlete_id,
            reference_date,
            repertorio_risco,
            dth,
            vigor,
            tension,
            daily_load,
            adherence_score
        )
        select
            regexp_replace(coalesce(x.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
            x.reference_date::date,
            x.repertorio_risco,
            x.dth,
            x.vigor,
            x.tension,
            x.daily_load,
            x.adherence_score
        from (
            select distinct on (regexp_replace(coalesce(v.athlete_id::text, ''), '\D', '', 'g'))
                v.*
            from public.pingo_scoring_inputs_view_final v
            where regexp_replace(coalesce(v.athlete_id::text, ''), '\D', '', 'g')
                  in (select athlete_id from tmp_athletes)
            order by
                regexp_replace(coalesce(v.athlete_id::text, ''), '\D', '', 'g'),
                v.reference_date desc nulls last
        ) x;

        insert into tmp_state_week (
            athlete_id,
            reference_date,
            repertorio_risco,
            dth,
            tension,
            adherence_score
        )
        select
            regexp_replace(coalesce(v.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
            v.reference_date::date as reference_date,
            v.repertorio_risco,
            v.dth,
            v.tension,
            v.adherence_score
        from public.pingo_scoring_inputs_view_final v
        where regexp_replace(coalesce(v.athlete_id::text, ''), '\D', '', 'g')
              in (select athlete_id from tmp_athletes)
          and v.reference_date::date between v_window_start and v_analysis_date;

        -- BRUMS PRE: usa SOMENTE a data real do BRUMS
        insert into tmp_questionnaire_events (athlete_id, questionnaire, fill_date)
        select distinct
            regexp_replace(coalesce(v.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
            'brums_pre'::text as questionnaire,
            coalesce(
                v.brums_date,
                (v.brums_inserted_at at time zone 'America/Sao_Paulo')::date
            ) as fill_date
        from public.pingo_scoring_inputs_view_final v
        where regexp_replace(coalesce(v.athlete_id::text, ''), '\D', '', 'g')
              in (select athlete_id from tmp_athletes)
          and coalesce(
                v.brums_date,
                (v.brums_inserted_at at time zone 'America/Sao_Paulo')::date
              ) is not null
          and (
                v.brums_date is not null
             or v.brums_inserted_at is not null
             or (v.brums_entries is not null and v.brums_entries > 0)
          )
          and coalesce(
                v.brums_date,
                (v.brums_inserted_at at time zone 'America/Sao_Paulo')::date
              ) between v_window_start and v_analysis_date;

        -- LOAD POST: continua pela reference_date
        insert into tmp_questionnaire_events (athlete_id, questionnaire, fill_date)
        select distinct
            regexp_replace(coalesce(v.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
            'training_load_post'::text as questionnaire,
            v.reference_date::date as fill_date
        from public.pingo_scoring_inputs_view_final v
        where regexp_replace(coalesce(v.athlete_id::text, ''), '\D', '', 'g')
              in (select athlete_id from tmp_athletes)
          and v.daily_load is not null
          and v.reference_date::date between v_window_start and v_analysis_date;
    end if;

    insert into tmp_questionnaire_events (athlete_id, questionnaire, fill_date)
    select distinct
        regexp_replace(coalesce(a.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
        'acsi'::text as questionnaire,
        coalesce(a.data::date, (a.inserted_at at time zone 'America/Sao_Paulo')::date) as fill_date
    from public.acsi_analysis a
    where regexp_replace(coalesce(a.athlete_id::text, ''), '\D', '', 'g')
          in (select athlete_id from tmp_athletes)
      and coalesce(a.data::date, (a.inserted_at at time zone 'America/Sao_Paulo')::date)
          between v_window_start and v_analysis_date;

    insert into tmp_questionnaire_events (athlete_id, questionnaire, fill_date)
    select distinct
        regexp_replace(coalesce(c.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
        'cbas'::text as questionnaire,
        coalesce(c.data::date, (c.inserted_at at time zone 'America/Sao_Paulo')::date) as fill_date
    from public.cbas_analysis c
    where regexp_replace(coalesce(c.athlete_id::text, ''), '\D', '', 'g')
          in (select athlete_id from tmp_athletes)
      and coalesce(c.data::date, (c.inserted_at at time zone 'America/Sao_Paulo')::date)
          between v_window_start and v_analysis_date;

    insert into tmp_questionnaire_events (athlete_id, questionnaire, fill_date)
    select distinct
        regexp_replace(coalesce(g.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
        'gses'::text as questionnaire,
        coalesce(g.data::date, (g.inserted_at at time zone 'America/Sao_Paulo')::date) as fill_date
    from public.gses_analysis g
    where regexp_replace(coalesce(g.athlete_id::text, ''), '\D', '', 'g')
          in (select athlete_id from tmp_athletes)
      and coalesce(g.data::date, (g.inserted_at at time zone 'America/Sao_Paulo')::date)
          between v_window_start and v_analysis_date;

    insert into tmp_questionnaire_events (athlete_id, questionnaire, fill_date)
    select distinct
        regexp_replace(coalesce(p.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
        'pmcsq'::text as questionnaire,
        coalesce(p.data::date, (p.inserted_at at time zone 'America/Sao_Paulo')::date) as fill_date
    from public.pmcsq_analysis p
    where regexp_replace(coalesce(p.athlete_id::text, ''), '\D', '', 'g')
          in (select athlete_id from tmp_athletes)
      and coalesce(p.data::date, (p.inserted_at at time zone 'America/Sao_Paulo')::date)
          between v_window_start and v_analysis_date;

    insert into tmp_questionnaire_events (athlete_id, questionnaire, fill_date)
    select distinct
        regexp_replace(coalesce(r.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
        'restq'::text as questionnaire,
        coalesce(r.data::date, (r.inserted_at at time zone 'America/Sao_Paulo')::date) as fill_date
    from public.restq_analysis r
    where regexp_replace(coalesce(r.athlete_id::text, ''), '\D', '', 'g')
          in (select athlete_id from tmp_athletes)
      and coalesce(r.data::date, (r.inserted_at at time zone 'America/Sao_Paulo')::date)
          between v_window_start and v_analysis_date;

    with
    acsi_last as (
        select distinct on (regexp_replace(coalesce(a.athlete_id::text, ''), '\D', '', 'g'))
            regexp_replace(coalesce(a.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
            a.media
        from public.acsi_analysis a
        where regexp_replace(coalesce(a.athlete_id::text, ''), '\D', '', 'g')
              in (select athlete_id from tmp_athletes)
        order by
            regexp_replace(coalesce(a.athlete_id::text, ''), '\D', '', 'g'),
            a.data desc nulls last,
            a.inserted_at desc nulls last
    ),

    cbas_last as (
        select distinct on (regexp_replace(coalesce(c.athlete_id::text, ''), '\D', '', 'g'))
            regexp_replace(coalesce(c.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
            c.relacao,
            c.aversivos
        from public.cbas_analysis c
        where regexp_replace(coalesce(c.athlete_id::text, ''), '\D', '', 'g')
              in (select athlete_id from tmp_athletes)
        order by
            regexp_replace(coalesce(c.athlete_id::text, ''), '\D', '', 'g'),
            c.data desc nulls last,
            c.inserted_at desc nulls last
    ),

    gses_last as (
        select distinct on (regexp_replace(coalesce(g.athlete_id::text, ''), '\D', '', 'g'))
            regexp_replace(coalesce(g.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
            g.media
        from public.gses_analysis g
        where regexp_replace(coalesce(g.athlete_id::text, ''), '\D', '', 'g')
              in (select athlete_id from tmp_athletes)
        order by
            regexp_replace(coalesce(g.athlete_id::text, ''), '\D', '', 'g'),
            g.data desc nulls last,
            g.inserted_at desc nulls last
    ),

    pmcsq_last as (
        select distinct on (regexp_replace(coalesce(p.athlete_id::text, ''), '\D', '', 'g'))
            regexp_replace(coalesce(p.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
            p.clima_ego,
            p.punicao_erros
        from public.pmcsq_analysis p
        where regexp_replace(coalesce(p.athlete_id::text, ''), '\D', '', 'g')
              in (select athlete_id from tmp_athletes)
        order by
            regexp_replace(coalesce(p.athlete_id::text, ''), '\D', '', 'g'),
            p.data desc nulls last,
            p.inserted_at desc nulls last
    ),

    restq_last as (
        select distinct on (regexp_replace(coalesce(r.athlete_id::text, ''), '\D', '', 'g'))
            regexp_replace(coalesce(r.athlete_id::text, ''), '\D', '', 'g') as athlete_id,
            r.balance,
            r.stress_index,
            r.recovery_index
        from public.restq_analysis r
        where regexp_replace(coalesce(r.athlete_id::text, ''), '\D', '', 'g')
              in (select athlete_id from tmp_athletes)
        order by
            regexp_replace(coalesce(r.athlete_id::text, ''), '\D', '', 'g'),
            r.data desc nulls last,
            r.inserted_at desc nulls last
    ),

    base as (
        select
            a.athlete_id,
            a.athlete_name,
            a.athlete_phone,
            a.team_name,
            (ac.athlete_id is not null) as has_acsi,
            (cb.athlete_id is not null) as has_cbas,
            (gs.athlete_id is not null) as has_gses,
            (pm.athlete_id is not null) as has_pmcsq,
            (rq.athlete_id is not null) as has_restq,
            st.reference_date,
            st.repertorio_risco,
            st.dth,
            st.vigor,
            st.tension,
            st.daily_load,
            st.adherence_score,
            ac.media as acsi_media,
            gs.media as gses_media,
            pm.clima_ego,
            pm.punicao_erros,
            cb.relacao as cbas_relacao,
            cb.aversivos as cbas_aversivos,
            rq.stress_index,
            rq.balance,
            rq.recovery_index
        from tmp_athletes a
        left join acsi_last ac on ac.athlete_id = a.athlete_id
        left join cbas_last cb on cb.athlete_id = a.athlete_id
        left join gses_last gs on gs.athlete_id = a.athlete_id
        left join pmcsq_last pm on pm.athlete_id = a.athlete_id
        left join restq_last rq on rq.athlete_id = a.athlete_id
        left join tmp_state_latest st on st.athlete_id = a.athlete_id
    ),

    full_missing as (
        select athlete_name
        from base
        where not has_acsi
          and not has_cbas
          and not has_gses
          and not has_pmcsq
          and not has_restq
        order by athlete_name
    ),

    risk_flag_rows as (
        select
            sw.athlete_id,
            a.athlete_name,
            a.athlete_phone,
            a.team_name,
            sw.reference_date,
            'high'::text as severity,
            'repertorio_risco'::text as flag_type,
            'maior vulnerabilidade para sustentar pressão'::text as reason
        from tmp_state_week sw
        join tmp_athletes a on a.athlete_id = sw.athlete_id
        where sw.repertorio_risco = 'high'

        union all

        select
            sw.athlete_id,
            a.athlete_name,
            a.athlete_phone,
            a.team_name,
            sw.reference_date,
            'high',
            'dth',
            'prontidão do dia muito alta'
        from tmp_state_week sw
        join tmp_athletes a on a.athlete_id = sw.athlete_id
        where sw.dth is not null and sw.dth >= 15

        union all

        select
            sw.athlete_id,
            a.athlete_name,
            a.athlete_phone,
            a.team_name,
            sw.reference_date,
            'high',
            'tension',
            'tensão do dia elevada'
        from tmp_state_week sw
        join tmp_athletes a on a.athlete_id = sw.athlete_id
        where sw.tension is not null and sw.tension >= 10

        union all

        select
            sw.athlete_id,
            a.athlete_name,
            a.athlete_phone,
            a.team_name,
            sw.reference_date,
            'medium',
            'adherence',
            'regularidade alimentar baixa'
        from tmp_state_week sw
        join tmp_athletes a on a.athlete_id = sw.athlete_id
        where sw.adherence_score is not null and sw.adherence_score <= 50

        union all

        select
            b.athlete_id,
            b.athlete_name,
            b.athlete_phone,
            b.team_name,
            null::date,
            'medium',
            'acsi',
            'recursos de enfrentamento mais baixos'
        from base b
        where b.acsi_media is not null and b.acsi_media <= 1.5

        union all

        select
            b.athlete_id,
            b.athlete_name,
            b.athlete_phone,
            b.team_name,
            null::date,
            'medium',
            'gses',
            'confiança mais baixa para lidar com dificuldade'
        from base b
        where b.gses_media is not null and b.gses_media <= 3

        union all

        select
            b.athlete_id,
            b.athlete_name,
            b.athlete_phone,
            b.team_name,
            null::date,
            'medium',
            'pmcsq',
            'clima do grupo mais pressionado por erro'
        from base b
        where (b.clima_ego is not null and b.clima_ego >= 4)
           or (b.punicao_erros is not null and b.punicao_erros >= 4)

        union all

        select
            b.athlete_id,
            b.athlete_name,
            b.athlete_phone,
            b.team_name,
            null::date,
            'medium',
            'cbas',
            'sinais de ambiente de treino mais desgastante'
        from base b
        where (b.cbas_aversivos is not null and b.cbas_aversivos >= 1.4)
           or (b.cbas_relacao is not null and b.cbas_relacao < 4)

        union all

        select
            b.athlete_id,
            b.athlete_name,
            b.athlete_phone,
            b.team_name,
            null::date,
            'high',
            'restq',
            'sinais recentes de desgaste e recuperação apertada'
        from base b
        where (b.stress_index is not null and b.stress_index >= 3)
           or (b.balance is not null and b.balance < 0)
    ),

    risk_grouped_week as (
        select
            r.athlete_id,
            r.athlete_name,
            r.athlete_phone,
            r.team_name,
            max(case when r.severity = 'high' then 1 else 0 end) as has_high,
            count(*) as flag_count,
            count(distinct r.reference_date) filter (where r.reference_date is not null) as flagged_days,
            max(r.reference_date) as last_flag_date,
            sum(case when r.severity = 'high' then 3 else 2 end) as score,
            array_agg(distinct r.reason order by r.reason) as reasons
        from risk_flag_rows r
        group by r.athlete_id, r.athlete_name, r.athlete_phone, r.team_name
    ),

    priority_athletes as (
        select
            athlete_id,
            athlete_name,
            athlete_phone,
            team_name,
            case when has_high = 1 then 'high' else 'medium' end as severity,
            flag_count,
            flagged_days,
            last_flag_date,
            score,
            reasons
        from risk_grouped_week
        order by score desc, flag_count desc, athlete_name
        limit 5
    ),

    questionnaire_kinds as (
        select *
        from (
            values
                ('acsi'::text),
                ('cbas'::text),
                ('gses'::text),
                ('pmcsq'::text),
                ('restq'::text),
                ('brums_pre'::text),
                ('training_load_post'::text)
        ) q(questionnaire)
    ),

    questionnaire_summary as (
        select
            q.questionnaire,
            count(e.*) as total_answers,
            count(distinct e.athlete_id) as athletes_with_answer,
            max(e.fill_date) as latest_fill_date
        from questionnaire_kinds q
        left join tmp_questionnaire_events e
          on e.questionnaire = q.questionnaire
        group by q.questionnaire
    ),

    questionnaire_latest_stats as (
        select
            qs.questionnaire,
            qs.latest_fill_date,
            count(*) filter (where e.athlete_id is not null) as filled_count,
            coalesce(
                jsonb_agg(a.athlete_name order by a.athlete_name) filter (where e.athlete_id is not null),
                '[]'::jsonb
            ) as filled_names,
            count(*) filter (where e.athlete_id is null) as not_filled_count,
            coalesce(
                jsonb_agg(a.athlete_name order by a.athlete_name) filter (where e.athlete_id is null),
                '[]'::jsonb
            ) as not_filled_names
        from questionnaire_summary qs
        cross join tmp_athletes a
        left join tmp_questionnaire_events e
          on e.athlete_id = a.athlete_id
         and e.questionnaire = qs.questionnaire
         and e.fill_date = qs.latest_fill_date
        group by qs.questionnaire, qs.latest_fill_date
    )

    select jsonb_build_object(
        'team_name', (select max(team_name) from tmp_athletes),
        'team_size', (select count(*) from tmp_athletes),
        'analysis_date', to_char(v_analysis_date, 'DD/MM/YYYY'),
        'reference_date', (
            select to_char(max(reference_date), 'DD/MM/YYYY')
            from base
            where reference_date is not null
        ),

        'coverage', jsonb_build_object(
            'acsi', (select count(*) from base where has_acsi),
            'cbas', (select count(*) from base where has_cbas),
            'gses', (select count(*) from base where has_gses),
            'pmcsq', (select count(*) from base where has_pmcsq),
            'restq', (select count(*) from base where has_restq),
            'brums_pre', coalesce((select athletes_with_answer from questionnaire_summary where questionnaire = 'brums_pre'), 0),
            'training_load_post', coalesce((select athletes_with_answer from questionnaire_summary where questionnaire = 'training_load_post'), 0)
        ),

        'team_signals', jsonb_strip_nulls(jsonb_build_object(
            'avg_vigor', (select round(avg(vigor)::numeric, 2) from base where vigor is not null),
            'avg_tension', (select round(avg(tension)::numeric, 2) from base where tension is not null),
            'avg_daily_load', (select round(avg(daily_load)::numeric, 2) from base where daily_load is not null),
            'avg_adherence', (select round(avg(adherence_score)::numeric, 2) from base where adherence_score is not null),
            'athletes_with_flags', (select count(*) from risk_grouped_week)
        )),

        'priority_athletes', coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'name', athlete_name,
                    'severity', severity,
                    'reasons', to_jsonb(reasons)
                )
                order by score desc, flag_count desc, athlete_name
            )
            from priority_athletes
        ), '[]'::jsonb),

        'missing_data', jsonb_build_object(
            'full_missing_names', coalesce(
                (select jsonb_agg(athlete_name order by athlete_name) from full_missing),
                '[]'::jsonb
            )
        ),

        'risk_last_week', jsonb_build_object(
            'high_risk_names', coalesce((
                select jsonb_agg(athlete_name order by athlete_name)
                from risk_grouped_week
                where has_high = 1
            ), '[]'::jsonb),
            'medium_risk_names', coalesce((
                select jsonb_agg(athlete_name order by athlete_name)
                from risk_grouped_week
                where has_high = 0
            ), '[]'::jsonb),
            'athletes', coalesce((
                select jsonb_agg(
                    jsonb_build_object(
                        'athlete_name', athlete_name,
                        'severity', case when has_high = 1 then 'high' else 'medium' end,
                        'reasons', to_jsonb(reasons)
                    )
                    order by score desc, flag_count desc, athlete_name
                )
                from risk_grouped_week
            ), '[]'::jsonb)
        ),

        'questionnaires_last_week', jsonb_build_object(
            'acsi', jsonb_build_object(
                'fill_date', (
                    select case
                        when latest_fill_date is not null then to_char(latest_fill_date, 'YYYY-MM-DD')
                        else null
                    end
                    from questionnaire_summary
                    where questionnaire = 'acsi'
                ),
                'filled', coalesce((
                    select athletes_with_answer > 0
                    from questionnaire_summary
                    where questionnaire = 'acsi'
                ), false)
            ),
            'cbas', jsonb_build_object(
                'fill_date', (
                    select case
                        when latest_fill_date is not null then to_char(latest_fill_date, 'YYYY-MM-DD')
                        else null
                    end
                    from questionnaire_summary
                    where questionnaire = 'cbas'
                ),
                'filled', coalesce((
                    select athletes_with_answer > 0
                    from questionnaire_summary
                    where questionnaire = 'cbas'
                ), false)
            ),
            'gses', jsonb_build_object(
                'fill_date', (
                    select case
                        when latest_fill_date is not null then to_char(latest_fill_date, 'YYYY-MM-DD')
                        else null
                    end
                    from questionnaire_summary
                    where questionnaire = 'gses'
                ),
                'filled', coalesce((
                    select athletes_with_answer > 0
                    from questionnaire_summary
                    where questionnaire = 'gses'
                ), false)
            ),
            'pmcsq', jsonb_build_object(
                'fill_date', (
                    select case
                        when latest_fill_date is not null then to_char(latest_fill_date, 'YYYY-MM-DD')
                        else null
                    end
                    from questionnaire_summary
                    where questionnaire = 'pmcsq'
                ),
                'filled', coalesce((
                    select athletes_with_answer > 0
                    from questionnaire_summary
                    where questionnaire = 'pmcsq'
                ), false)
            ),
            'restq', jsonb_build_object(
                'fill_date', (
                    select case
                        when latest_fill_date is not null then to_char(latest_fill_date, 'YYYY-MM-DD')
                        else null
                    end
                    from questionnaire_summary
                    where questionnaire = 'restq'
                ),
                'filled', coalesce((
                    select athletes_with_answer > 0
                    from questionnaire_summary
                    where questionnaire = 'restq'
                ), false)
            ),
            'brums_pre', jsonb_build_object(
                'fill_date', (
                    select case
                        when latest_fill_date is not null then to_char(latest_fill_date, 'YYYY-MM-DD')
                        else null
                    end
                    from questionnaire_latest_stats
                    where questionnaire = 'brums_pre'
                ),
                'filled_count', coalesce((
                    select filled_count
                    from questionnaire_latest_stats
                    where questionnaire = 'brums_pre'
                ), 0),
                'filled_names', coalesce((
                    select filled_names
                    from questionnaire_latest_stats
                    where questionnaire = 'brums_pre'
                ), '[]'::jsonb),
                'not_filled_count', coalesce((
                    select not_filled_count
                    from questionnaire_latest_stats
                    where questionnaire = 'brums_pre'
                ), 0),
                'not_filled_names', coalesce((
                    select not_filled_names
                    from questionnaire_latest_stats
                    where questionnaire = 'brums_pre'
                ), '[]'::jsonb)
            ),
            'training_load_post', jsonb_build_object(
                'fill_date', (
                    select case
                        when latest_fill_date is not null then to_char(latest_fill_date, 'YYYY-MM-DD')
                        else null
                    end
                    from questionnaire_latest_stats
                    where questionnaire = 'training_load_post'
                ),
                'filled_count', coalesce((
                    select filled_count
                    from questionnaire_latest_stats
                    where questionnaire = 'training_load_post'
                ), 0),
                'filled_names', coalesce((
                    select filled_names
                    from questionnaire_latest_stats
                    where questionnaire = 'training_load_post'
                ), '[]'::jsonb),
                'not_filled_count', coalesce((
                    select not_filled_count
                    from questionnaire_latest_stats
                    where questionnaire = 'training_load_post'
                ), 0),
                'not_filled_names', coalesce((
                    select not_filled_names
                    from questionnaire_latest_stats
                    where questionnaire = 'training_load_post'
                ), '[]'::jsonb)
            )
        ),

        'generated_at', now()
    )
    into v_result;

    return coalesce(v_result, '{}'::jsonb);
end;
$$;


ALTER FUNCTION "public"."get_team_analysis"("p_coach_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_team_analysis_compact"("p_coach_phone" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
with athletes as (
    select distinct
        ar.athlete_id,
        ar.athlete_name,
        ar.team_name,
        ar.athlete_phone,
        ar.coach_phone
    from public.athlete_registration ar
    where regexp_replace(coalesce(ar.coach_phone, ''), '\D', '', 'g')
        = regexp_replace(coalesce(p_coach_phone, ''), '\D', '', 'g')
      and coalesce(ar.athlete_id, '') <> ''
),

base as (
    select
        a.athlete_id,
        a.athlete_name,
        a.team_name,
        a.athlete_phone,
        a.coach_phone,

        st.reference_date,
        st.repertorio_risco,
        st.adherence_score,
        st.vigor,
        st.tension,
        st.fatigue,
        st.confusion,
        st.depression,
        st.daily_load,
        st.stress_index,
        st.recovery_index,
        st.sleep_quality,
        st.lack_energy,
        st.gi_distress,
        st.pattern_iceberg,
        st.pattern_burnout,
        st.pattern_hyperactivation,

        ac.acsi_summary,
        gs.gses_summary,
        rs.restq_summary,
        pm.pmcsq_summary,
        cb.cbas_summary,
        wk.weekly_comment

    from athletes a

    left join lateral (
        select
            v.reference_date,
            v.repertorio_risco,
            v.adherence_score,
            v.vigor,
            v.tension,
            v.fatigue,
            v.confusion,
            v.depression,
            v.daily_load,
            v.stress_index,
            v.recovery_index,
            v.sleep_quality,
            v.lack_energy,
            v.gi_distress,
            v.pattern_iceberg,
            v.pattern_burnout,
            v.pattern_hyperactivation
        from public.pingo_scoring_inputs_view_final v
        where v.athlete_id = a.athlete_id
        order by v.reference_date desc
        limit 1
    ) st on true

    left join lateral (
        select jsonb_strip_nulls(
            jsonb_build_object(
                'media', x.media,
                'concentracao', x.concentracao,
                'confianca', x.confianca_motivacao,
                'pressao', x.pico_pressao
            )
        ) as acsi_summary
        from public.acsi_analysis x
        where x.athlete_id = a.athlete_id
        order by x.data desc nulls last, x.inserted_at desc nulls last
        limit 1
    ) ac on true

    left join lateral (
        select jsonb_strip_nulls(
            jsonb_build_object(
                'media', x.media,
                'classificacao', x.classification
            )
        ) as gses_summary
        from public.gses_analysis x
        where x.athlete_id = a.athlete_id
        order by x.data desc nulls last, x.inserted_at desc nulls last
        limit 1
    ) gs on true

    left join lateral (
        select jsonb_strip_nulls(
            jsonb_build_object(
                'media', x.media,
                'stress', x.stress_index,
                'recovery', x.recovery_index,
                'sono', x.sleep_quality,
                'energia', x.lack_energy,
                'queixas', x.physical_complaints
            )
        ) as restq_summary
        from public.restq_analysis x
        where x.athlete_id = a.athlete_id
        order by x.data desc nulls last, x.inserted_at desc nulls last
        limit 1
    ) rs on true

    left join lateral (
        select jsonb_strip_nulls(
            jsonb_build_object(
                'tarefa', x.clima_tarefa,
                'ego', x.clima_ego,
                'coletivo', x.coletivo
            )
        ) as pmcsq_summary
        from public.pmcsq_analysis x
        where x.athlete_id = a.athlete_id
        order by x.data desc nulls last, x.inserted_at desc nulls last
        limit 1
    ) pm on true

    left join lateral (
        select jsonb_strip_nulls(
            jsonb_build_object(
                'relacao', x.relacao,
                'tecnica', x.tecnica,
                'motivacional', x.motivacional,
                'aversivos', x.aversivos
            )
        ) as cbas_summary
        from public.cbas_analysis x
        where x.athlete_id = a.athlete_id
        order by x.data desc nulls last, x.inserted_at desc nulls last
        limit 1
    ) cb on true

    left join lateral (
        select
            w.payload ->> 'WEEK_COMMENTS | Outros comentários sobre sua semana (sentimentos, percepções, etc.)'
            as weekly_comment
        from public.weekly_analysis w
        where w.athlete_id = a.athlete_id
        order by w.start_date desc nulls last
        limit 1
    ) wk on true
),

scored as (
    select
        b.*,

        (b.acsi_summary is not null)  as has_acsi,
        (b.gses_summary is not null)  as has_gses,
        (b.restq_summary is not null) as has_restq,
        (b.pmcsq_summary is not null) as has_pmcsq,
        (b.cbas_summary is not null)  as has_cbas,
        (b.weekly_comment is not null and btrim(b.weekly_comment) <> '') as has_weekly,

        case
            when
                coalesce(b.repertorio_risco, '') = 'high'
                or coalesce(b.tension, 0) >= 10
                or coalesce(b.fatigue, 0) >= 4
                or coalesce(b.stress_index, 0) >= 3
                or (b.recovery_index is not null and b.recovery_index <= 1.5)
                or (b.lack_energy is not null and b.lack_energy >= 4)
                or (b.adherence_score is not null and b.adherence_score <= 50)
                or (b.gi_distress is not null and b.gi_distress >= 2)
                or coalesce(b.weekly_comment, '') ilike '%ansios%'
                or coalesce(b.weekly_comment, '') ilike '%nervos%'
            then 'high'

            when
                coalesce(b.repertorio_risco, '') = 'medium'
                or coalesce(b.tension, 0) between 4 and 9
                or coalesce(b.fatigue, 0) between 2 and 3
                or coalesce(b.stress_index, 0) between 2 and 2.99
                or (b.adherence_score is not null and b.adherence_score between 51 and 79)
                or coalesce(b.weekly_comment, '') ilike '%compet%'
            then 'attention'

            when
                b.reference_date is null
                and b.acsi_summary is null
                and b.gses_summary is null
                and b.restq_summary is null
                and b.pmcsq_summary is null
                and b.cbas_summary is null
                and (b.weekly_comment is null or btrim(b.weekly_comment) = '')
            then 'no_data'

            else 'ok'
        end as flag_level,

        to_jsonb(array_remove(array[
            case when coalesce(b.repertorio_risco, '') = 'high' then 'repertório de risco alto' end,
            case when coalesce(b.tension, 0) >= 10 then 'tensão alta' end,
            case when coalesce(b.fatigue, 0) >= 4 then 'fadiga alta' end,
            case when coalesce(b.stress_index, 0) >= 3 then 'estresse elevado' end,
            case when b.recovery_index is not null and b.recovery_index <= 1.5 then 'recuperação baixa' end,
            case when b.lack_energy is not null and b.lack_energy >= 4 then 'baixa energia' end,
            case when b.adherence_score is not null and b.adherence_score <= 50 then 'adesão alimentar baixa' end,
            case when b.gi_distress is not null and b.gi_distress >= 2 then 'desconforto gastrointestinal' end,
            case when coalesce(b.weekly_comment, '') ilike '%ansios%' then 'relato de ansiedade' end,
            case when coalesce(b.weekly_comment, '') ilike '%nervos%' then 'relato de nervosismo' end,
            case when coalesce(b.weekly_comment, '') ilike '%compet%' then 'semana de competição' end,
            case when
                b.reference_date is null
                and b.acsi_summary is null
                and b.gses_summary is null
                and b.restq_summary is null
                and b.pmcsq_summary is null
                and b.cbas_summary is null
                and (b.weekly_comment is null or btrim(b.weekly_comment) = '')
            then 'sem dados recentes' end
        ], null)) as flags

    from base b
),

coverage as (
    select jsonb_build_object(
        'acsi', jsonb_build_object(
            'answered', count(*) filter (where has_acsi),
            'missing', count(*) filter (where not has_acsi),
            'answered_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where has_acsi), '[]'::jsonb),
            'missing_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where not has_acsi), '[]'::jsonb)
        ),
        'gses', jsonb_build_object(
            'answered', count(*) filter (where has_gses),
            'missing', count(*) filter (where not has_gses),
            'answered_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where has_gses), '[]'::jsonb),
            'missing_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where not has_gses), '[]'::jsonb)
        ),
        'restq', jsonb_build_object(
            'answered', count(*) filter (where has_restq),
            'missing', count(*) filter (where not has_restq),
            'answered_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where has_restq), '[]'::jsonb),
            'missing_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where not has_restq), '[]'::jsonb)
        ),
        'pmcsq', jsonb_build_object(
            'answered', count(*) filter (where has_pmcsq),
            'missing', count(*) filter (where not has_pmcsq),
            'answered_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where has_pmcsq), '[]'::jsonb),
            'missing_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where not has_pmcsq), '[]'::jsonb)
        ),
        'cbas', jsonb_build_object(
            'answered', count(*) filter (where has_cbas),
            'missing', count(*) filter (where not has_cbas),
            'answered_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where has_cbas), '[]'::jsonb),
            'missing_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where not has_cbas), '[]'::jsonb)
        ),
        'weekly', jsonb_build_object(
            'answered', count(*) filter (where has_weekly),
            'missing', count(*) filter (where not has_weekly),
            'answered_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where has_weekly), '[]'::jsonb),
            'missing_names', coalesce(jsonb_agg(athlete_name order by athlete_name) filter (where not has_weekly), '[]'::jsonb)
        )
    ) as questionnaire_coverage
    from scored
),

team_snapshot as (
    select jsonb_build_object(
        'diet', jsonb_build_object(
            'avg_adherence', round(avg(adherence_score)::numeric, 2),
            'avg_gi', round(avg(gi_distress)::numeric, 2)
        ),
        'brums', jsonb_build_object(
            'avg_vigor', round(avg(vigor)::numeric, 2),
            'avg_tension', round(avg(tension)::numeric, 2),
            'avg_fatigue', round(avg(fatigue)::numeric, 2),
            'avg_confusion', round(avg(confusion)::numeric, 2),
            'avg_depression', round(avg(depression)::numeric, 2)
        ),
        'training', jsonb_build_object(
            'avg_load', round(avg(daily_load)::numeric, 2)
        )
    ) as snapshot
    from scored
),

flagged as (
    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'athlete_name', athlete_name,
                'flag', flag_level,
                'reasons', flags,
                'weekly', weekly_comment
            )
            order by
                case flag_level
                    when 'high' then 1
                    when 'attention' then 2
                    when 'no_data' then 3
                    else 4
                end,
                athlete_name
        ) filter (where flag_level <> 'ok'),
        '[]'::jsonb
    ) as flagged_athletes
    from scored
),

weekly_examples as (
    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'athlete_name', x.athlete_name,
                'comment', x.weekly_comment
            )
            order by x.athlete_name
        ),
        '[]'::jsonb
    ) as examples
    from (
        select athlete_name, weekly_comment
        from scored
        where has_weekly
        order by athlete_name
        limit 6
    ) x
),

athlete_briefs as (
    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'athlete_name', s.athlete_name,
                'flag', s.flag_level,
                'reasons', s.flags,
                'answered', to_jsonb(array_remove(array[
                    case when s.has_acsi then 'acsi' end,
                    case when s.has_gses then 'gses' end,
                    case when s.has_restq then 'restq' end,
                    case when s.has_pmcsq then 'pmcsq' end,
                    case when s.has_cbas then 'cbas' end,
                    case when s.has_weekly then 'weekly' end
                ], null)),
                'missing', to_jsonb(array_remove(array[
                    case when not s.has_acsi then 'acsi' end,
                    case when not s.has_gses then 'gses' end,
                    case when not s.has_restq then 'restq' end,
                    case when not s.has_pmcsq then 'pmcsq' end,
                    case when not s.has_cbas then 'cbas' end,
                    case when not s.has_weekly then 'weekly' end
                ], null)),
                'questionnaire_summary', jsonb_strip_nulls(
                    jsonb_build_object(
                        'acsi', s.acsi_summary,
                        'gses', s.gses_summary,
                        'restq', s.restq_summary,
                        'pmcsq', s.pmcsq_summary,
                        'cbas', s.cbas_summary,
                        'weekly', s.weekly_comment
                    )
                )
            )
            order by s.athlete_name
        ),
        '[]'::jsonb
    ) as athlete_summaries
    from scored s
),

team_summary as (
    select jsonb_build_object(
        'team_name', max(team_name),
        'team_size', count(*),
        'with_state', count(*) filter (where reference_date is not null),
        'flags_high', count(*) filter (where flag_level = 'high'),
        'flags_attention', count(*) filter (where flag_level = 'attention'),
        'no_data', count(*) filter (where flag_level = 'no_data')
    ) as summary
    from scored
)

select jsonb_build_object(
    'coach_phone', regexp_replace(coalesce(p_coach_phone, ''), '\D', '', 'g'),
    'generated_at', now(),
    'summary', (select summary from team_summary),
    'team_snapshot', (select snapshot from team_snapshot),
    'questionnaire_coverage', (select questionnaire_coverage from coverage),
    'flagged_athletes', (select flagged_athletes from flagged),
    'weekly_examples', (select examples from weekly_examples),
    'athletes', (select athlete_summaries from athlete_briefs)
);
$$;


ALTER FUNCTION "public"."get_team_analysis_compact"("p_coach_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_hibernated_minds_notification_queue"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_send_state text;
begin
  select coalesce(s.send_state, 'active')
    into v_send_state
  from public.minds_athlete_delivery_state s
  where s.athlete_id = new.athlete_id;

  if v_send_state = 'hibernated' then
    new.status := 'hibernated';
    new.next_retry_at := null;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."guard_hibernated_minds_notification_queue"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_hibernated_minds_webhook_queue"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_send_state text;
begin
  select coalesce(s.send_state, 'active')
    into v_send_state
  from public.minds_athlete_delivery_state s
  where s.athlete_id = new.athlete_id;

  if v_send_state = 'hibernated' then
    new.status := 'hibernated';
    new.available_at := null;
    new.last_error := 'athlete hibernated';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."guard_hibernated_minds_webhook_queue"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."hibernate_athlete"("p_athlete_id" "text", "p_reason" "text" DEFAULT NULL::"text", "p_auto" boolean DEFAULT false) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into public.minds_athlete_delivery_state (
    athlete_id,
    send_state,
    auto_hibernated,
    reason,
    hibernated_at,
    updated_at
  )
  values (
    p_athlete_id,
    'hibernated',
    p_auto,
    p_reason,
    now(),
    now()
  )
  on conflict (athlete_id)
  do update set
    send_state = 'hibernated',
    auto_hibernated = excluded.auto_hibernated,
    reason = excluded.reason,
    hibernated_at = now(),
    updated_at = now();

  update public.minds_notification_queue
     set status = 'hibernated',
         next_retry_at = null
   where athlete_id = p_athlete_id
     and coalesce(status, 'pending') in ('pending', 'queued', 'retry');

  update public.minds_webhook_queue
     set status = 'hibernated',
         available_at = null,
         last_error = coalesce(p_reason, 'athlete hibernated')
   where athlete_id = p_athlete_id
     and coalesce(status, 'pending') in ('pending', 'queued', 'retry')
     and coalesce(sent, false) = false;
end;
$$;


ALTER FUNCTION "public"."hibernate_athlete"("p_athlete_id" "text", "p_reason" "text", "p_auto" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."horizons_ack_changes"("p_event_ids" "uuid"[], "p_success" boolean DEFAULT true, "p_error" "text" DEFAULT NULL::"text") RETURNS integer
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  select integration.ack_changes_for_horizons(p_event_ids, p_success, p_error);
$$;


ALTER FUNCTION "public"."horizons_ack_changes"("p_event_ids" "uuid"[], "p_success" boolean, "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."horizons_export_table_json"("p_schema_name" "text", "p_table_name" "text", "p_limit" integer DEFAULT 1000, "p_offset" integer DEFAULT 0) RETURNS SETOF "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  select *
  from integration.export_table_json(
    p_schema_name,
    p_table_name,
    p_limit,
    p_offset
  );
$$;


ALTER FUNCTION "public"."horizons_export_table_json"("p_schema_name" "text", "p_table_name" "text", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."horizons_pull_changes"("p_limit" integer DEFAULT 500, "p_reserve_minutes" integer DEFAULT 5) RETURNS TABLE("event_id" "uuid", "occurred_at" timestamp with time zone, "schema_name" "text", "table_name" "text", "op" "text", "pk" "jsonb", "old_row" "jsonb", "new_row" "jsonb", "txid" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  select *
  from integration.pull_changes_for_horizons(p_limit, p_reserve_minutes);
$$;


ALTER FUNCTION "public"."horizons_pull_changes"("p_limit" integer, "p_reserve_minutes" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_analysis_vector"("p_athlete_id" "text", "p_data" "date", "p_source" "text", "p_embedding" "public"."vector", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
declare
  v_id bigint;
begin
  insert into public.analysis_vectors(
    athlete_id, data, source, embedding, metadata
  )
  values (
    p_athlete_id, p_data, p_source, p_embedding, coalesce(p_metadata,'{}'::jsonb)
  )
  returning id into v_id;

  return v_id;
end $$;


ALTER FUNCTION "public"."insert_analysis_vector"("p_athlete_id" "text", "p_data" "date", "p_source" "text", "p_embedding" "public"."vector", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_athlete_allowed"("p_athlete_id" "text") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
select
case
    when ar.athlete_enabled = true then true
    when u.account_active = true then true
    else false
end
from athlete_registration ar
left join users u
    on u.user_id = ar.athlete_id
where ar.athlete_id = p_athlete_id
order by ar.inserted_at desc
limit 1;
$$;


ALTER FUNCTION "public"."is_athlete_allowed"("p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_user_athletes"("p_user_id" "text", "p_limit" integer DEFAULT 20) RETURNS TABLE("athlete_id" "text", "athlete_name" "text", "team_name" "text", "athlete_phone" "text", "coach_phone" "text", "pinned" boolean, "last_used_at" timestamp with time zone)
    LANGUAGE "sql" STABLE
    AS $$
  select
    athlete_id, athlete_name, team_name, athlete_phone, coach_phone, pinned, last_used_at
  from public.pingo_user_athletes
  where user_id = p_user_id
  order by pinned desc, last_used_at desc
  limit greatest(1, least(p_limit, 50));
$$;


ALTER FUNCTION "public"."list_user_athletes"("p_user_id" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_user_message"("p_user_id" "text", "p_message_text" "text", "p_message_type" "text" DEFAULT 'text'::"text", "p_message_meta" "jsonb" DEFAULT '{}'::"jsonb", "p_athlete_id" "text" DEFAULT NULL::"text") RETURNS TABLE("message_id" bigint, "athlete_id" "text")
    LANGUAGE "plpgsql"
    AS $$
declare
  v_athlete_id text;
  v_id bigint;
begin
  v_athlete_id := p_athlete_id;

  if v_athlete_id is null then
    select c.last_athlete_id into v_athlete_id
    from public.pingo_chat_context c
    where c.user_id = p_user_id;
  end if;

  insert into public.pingo_user_messages(
    user_id, athlete_id, message_text, message_type, message_meta
  )
  values (
    p_user_id, v_athlete_id, p_message_text, coalesce(p_message_type,'text'), coalesce(p_message_meta,'{}'::jsonb)
  )
  returning id into v_id;

  return query select v_id, v_athlete_id;
end $$;


ALTER FUNCTION "public"."log_user_message"("p_user_id" "text", "p_message_text" "text", "p_message_type" "text", "p_message_meta" "jsonb", "p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."minds_run_engine_v4"() RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_filled integer;
  v_processed integer;
begin

  v_filled := public.minds_fill_queue();

  v_processed := public.minds_process_queue_safe(10);

  return jsonb_build_object(
    'filled', v_filled,
    'processed', v_processed,
    'ran_at', now()
  );

end;
$$;


ALTER FUNCTION "public"."minds_run_engine_v4"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."norm_phone"("p_phone" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when p_phone is null then null
    when nullif(regexp_replace(p_phone, '\D', '', 'g'), '') is null then null
    else '+' || regexp_replace(p_phone, '\D', '', 'g')
  end;
$$;


ALTER FUNCTION "public"."norm_phone"("p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."norm_role"("p_role" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v text := lower(trim(coalesce(p_role, '')));
begin
  if v in ('master', 'admin', 'administrator') then
    return 'MASTER';
  elsif v in ('coach', 'treinador', 'comissao', 'commission', 'staff') then
    return 'COACH';
  elsif v in ('athlete', 'atleta', 'player') then
    return 'ATHLETE';
  elsif v = '' then
    return null;
  else
    return upper(trim(p_role));
  end if;
end;
$$;


ALTER FUNCTION "public"."norm_role"("p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_phone"("raw" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  digits text;
begin
  if raw is null or trim(raw) = '' then
    return null;
  end if;

  -- remove tudo que não é número
  digits := regexp_replace(raw, '\D', '', 'g');

  if length(digits) < 10 then
    return null;
  end if;

  -- se já começa com 55 → mantém
  if digits like '55%' then
    return '+' || digits;
  end if;

  -- assume Brasil
  return '+55' || digits;
end;
$$;


ALTER FUNCTION "public"."normalize_phone"("raw" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."only_digits"("p_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select nullif(regexp_replace(coalesce(p_text, ''), '\D', '', 'g'), '');
$$;


ALTER FUNCTION "public"."only_digits"("p_text" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."patch_pingo_chat_context"("p_user_id" "text", "p_patch" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_patch       jsonb := coalesce(p_patch, '{}'::jsonb);

  -- se vier { meta:{...} } usa meta; senão usa o próprio patch
  v_meta_patch  jsonb := case
                           when jsonb_typeof(v_patch->'meta') = 'object'
                             then v_patch->'meta'
                           when jsonb_typeof(v_patch) = 'object'
                             then v_patch
                           else '{}'::jsonb
                         end;

  -- extras que também entram no meta
  v_extra jsonb := case
                     when jsonb_typeof(v_patch->'meta') = 'object'
                       then (v_patch - 'meta'
                                    - 'last_athlete_id'
                                    - 'last_athlete_name'
                                    - 'last_team_name'
                                    - 'last_athlete_phone'
                                    - 'last_coach_phone')
                     else '{}'::jsonb
                   end;

  v_meta jsonb;
begin
  ------------------------------------------------------------------
  -- garante a linha
  ------------------------------------------------------------------
  insert into public.pingo_chat_context(user_id, meta)
  values (p_user_id, '{}'::jsonb)
  on conflict (user_id) do nothing;

  ------------------------------------------------------------------
  -- UPDATE PRINCIPAL (NULL-safe + remove "=")
  ------------------------------------------------------------------
  update public.pingo_chat_context c
  set

    ----------------------------------------------------------------
    -- last_athlete_id (NULL overwrite real)
    ----------------------------------------------------------------
    last_athlete_id =
      case
        when (v_meta_patch ? 'last_athlete_id')
          or (v_patch ? 'last_athlete_id')
        then
          case
            when coalesce(v_meta_patch->>'last_athlete_id',
                          v_patch->>'last_athlete_id') is null
              then null
            when left(coalesce(v_meta_patch->>'last_athlete_id',
                               v_patch->>'last_athlete_id'),1) = '='
              then substr(coalesce(v_meta_patch->>'last_athlete_id',
                                   v_patch->>'last_athlete_id'),2)
            else coalesce(v_meta_patch->>'last_athlete_id',
                          v_patch->>'last_athlete_id')
          end
        else c.last_athlete_id
      end,

    ----------------------------------------------------------------
    -- last_athlete_name
    ----------------------------------------------------------------
    last_athlete_name =
      case
        when (v_meta_patch ? 'last_athlete_name')
          or (v_patch ? 'last_athlete_name')
        then
          case
            when coalesce(v_meta_patch->>'last_athlete_name',
                          v_patch->>'last_athlete_name') is null
              then null
            when left(coalesce(v_meta_patch->>'last_athlete_name',
                               v_patch->>'last_athlete_name'),1) = '='
              then substr(coalesce(v_meta_patch->>'last_athlete_name',
                                   v_patch->>'last_athlete_name'),2)
            else coalesce(v_meta_patch->>'last_athlete_name',
                          v_patch->>'last_athlete_name')
          end
        else c.last_athlete_name
      end,

    ----------------------------------------------------------------
    -- last_athlete_phone
    ----------------------------------------------------------------
    last_athlete_phone =
      case
        when (v_meta_patch ? 'last_athlete_phone')
          or (v_patch ? 'last_athlete_phone')
        then
          case
            when coalesce(v_meta_patch->>'last_athlete_phone',
                          v_patch->>'last_athlete_phone') is null
              then null
            when left(coalesce(v_meta_patch->>'last_athlete_phone',
                               v_patch->>'last_athlete_phone'),1) = '='
              then substr(coalesce(v_meta_patch->>'last_athlete_phone',
                                   v_patch->>'last_athlete_phone'),2)
            else coalesce(v_meta_patch->>'last_athlete_phone',
                          v_patch->>'last_athlete_phone')
          end
        else c.last_athlete_phone
      end,

    ----------------------------------------------------------------
    -- last_team_name
    ----------------------------------------------------------------
    last_team_name =
      case
        when (v_meta_patch ? 'last_team_name')
          or (v_patch ? 'last_team_name')
        then
          case
            when coalesce(v_meta_patch->>'last_team_name',
                          v_patch->>'last_team_name') is null
              then null
            when left(coalesce(v_meta_patch->>'last_team_name',
                               v_patch->>'last_team_name'),1) = '='
              then substr(coalesce(v_meta_patch->>'last_team_name',
                                   v_patch->>'last_team_name'),2)
            else coalesce(v_meta_patch->>'last_team_name',
                          v_patch->>'last_team_name')
          end
        else c.last_team_name
      end,

    ----------------------------------------------------------------
    -- last_coach_phone
    ----------------------------------------------------------------
    last_coach_phone =
      case
        when (v_meta_patch ? 'last_coach_phone')
          or (v_patch ? 'last_coach_phone')
        then
          case
            when coalesce(v_meta_patch->>'last_coach_phone',
                          v_patch->>'last_coach_phone') is null
              then null
            when left(coalesce(v_meta_patch->>'last_coach_phone',
                               v_patch->>'last_coach_phone'),1) = '='
              then substr(coalesce(v_meta_patch->>'last_coach_phone',
                                   v_patch->>'last_coach_phone'),2)
            else coalesce(v_meta_patch->>'last_coach_phone',
                          v_patch->>'last_coach_phone')
          end
        else c.last_coach_phone
      end,

    ----------------------------------------------------------------
    -- META MERGE
    ----------------------------------------------------------------
    meta = jsonb_strip_nulls(
             coalesce(c.meta,'{}'::jsonb)
             || coalesce(v_meta_patch,'{}'::jsonb)
             || coalesce(v_extra,'{}'::jsonb)
           ),

    updated_at = now()

  where c.user_id = p_user_id;

  ------------------------------------------------------------------
  -- retorno
  ------------------------------------------------------------------
  select meta into v_meta
  from public.pingo_chat_context
  where user_id = p_user_id;

  return jsonb_build_object(
    'user_id', p_user_id,
    'meta', v_meta
  );
end;
$$;


ALTER FUNCTION "public"."patch_pingo_chat_context"("p_user_id" "text", "p_patch" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."phone_digits"("p" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
select regexp_replace(p,'[^0-9]','','g');
$$;


ALTER FUNCTION "public"."phone_digits"("p" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pin_user_athlete"("p_user_id" "text", "p_athlete_id" "text", "p_pinned" boolean DEFAULT true) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  update public.pingo_user_athletes
  set pinned = p_pinned
  where user_id = p_user_id and athlete_id = p_athlete_id;
end $$;


ALTER FUNCTION "public"."pin_user_athlete"("p_user_id" "text", "p_athlete_id" "text", "p_pinned" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reactivate_athlete"("p_athlete_id" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into public.minds_athlete_delivery_state (
    athlete_id,
    send_state,
    auto_hibernated,
    reactivated_at,
    updated_at,
    reason
  )
  values (
    p_athlete_id,
    'active',
    false,
    now(),
    now(),
    null
  )
  on conflict (athlete_id)
  do update set
    send_state = 'active',
    auto_hibernated = false,
    reactivated_at = now(),
    updated_at = now(),
    reason = null;

  update public.minds_notification_queue
     set status = 'pending',
         next_retry_at = coalesce(next_retry_at, now())
   where athlete_id = p_athlete_id
     and status = 'hibernated';

  update public.minds_webhook_queue
     set status = 'pending',
         available_at = coalesce(available_at, now()),
         last_error = null
   where athlete_id = p_athlete_id
     and status = 'hibernated'
     and coalesce(sent, false) = false;
end;
$$;


ALTER FUNCTION "public"."reactivate_athlete"("p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rebuild_auth_credentials"("p_reset_password" boolean DEFAULT true) RETURNS TABLE("phones_processed" integer, "credentials_created" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_phone text;
  v_processed integer := 0;
  v_created integer := 0;
begin
  -- recriação total
  truncate table public.user_credentials;

  for v_phone in
    select distinct phone_norm
    from (
      select public.norm_phone(m.phone) as phone_norm
      from public.masters m

      union

      select public.norm_phone(ar.athlete_phone) as phone_norm
      from public.athlete_registration ar
      where coalesce(ar.athlete_enabled, true) = true

      union

      select public.norm_phone(ar.coach_phone) as phone_norm
      from public.athlete_registration ar
    ) q
    where phone_norm <> ''
  loop
    v_processed := v_processed + 1;

    if public.refresh_auth_credential_by_phone(v_phone, p_reset_password) then
      v_created := v_created + 1;
    end if;
  end loop;

  return query
  select v_processed, v_created;
end;
$$;


ALTER FUNCTION "public"."rebuild_auth_credentials"("p_reset_password" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalc_user_account_active"("p_user_id" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_new_account_active boolean;
begin
  select
    case
      when exists (
        select 1
        from public.user_roles ur
        where ur.user_id = p_user_id
          and ur.role in ('master', 'coach')
      ) then true
      when exists (
        select 1
        from public.athlete_registration ar
        where ar.athlete_id = p_user_id
          and coalesce(ar.athlete_enabled, false) = true
      ) then true
      else false
    end
  into v_new_account_active;

  update public.users u
  set
    account_active = v_new_account_active,
    updated_at = now()
  where u.user_id = p_user_id
    and u.account_active is distinct from v_new_account_active;
end;
$$;


ALTER FUNCTION "public"."recalc_user_account_active"("p_user_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reconcile_minds_webhook_responses"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'net', 'pg_catalog'
    AS $$
DECLARE
  v_done integer := 0;
  v_step integer := 0;
BEGIN
  -- SUCESSO (2xx, sem timeout, sem error_msg)
  WITH success_rows AS (
    SELECT
      q.id,
      r.status_code,
      r.created
    FROM public.minds_webhook_queue q
    JOIN net._http_response r
      ON r.id = q.request_id
    WHERE q.status = 'processing'
      AND q.request_id IS NOT NULL
      AND r.status_code BETWEEN 200 AND 299
      AND COALESCE(r.timed_out, false) = false
      AND r.error_msg IS NULL
  )
  UPDATE public.minds_webhook_queue q
  SET
    sent = true,
    status = 'sent',
    sent_at = now(),
    processing_at = NULL,
    last_error = NULL,
    last_status_code = s.status_code,
    last_response_at = s.created
  FROM success_rows s
  WHERE q.id = s.id;

  GET DIAGNOSTICS v_step = ROW_COUNT;
  v_done := v_done + v_step;

  -- FALHA (timeout, error_msg, ou HTTP fora de 2xx)
  WITH failed_rows AS (
    SELECT
      q.id,
      r.status_code,
      r.error_msg,
      r.timed_out,
      r.created
    FROM public.minds_webhook_queue q
    JOIN net._http_response r
      ON r.id = q.request_id
    WHERE q.status = 'processing'
      AND q.request_id IS NOT NULL
      AND (
        r.error_msg IS NOT NULL
        OR COALESCE(r.timed_out, false) = true
        OR r.status_code IS NULL
        OR r.status_code NOT BETWEEN 200 AND 299
      )
  )
  UPDATE public.minds_webhook_queue q
  SET
    sent = false,
    retry_count = q.retry_count + 1,
    status = CASE
      WHEN q.retry_count + 1 >= q.max_retries THEN 'failed'
      ELSE 'pending'
    END,
    available_at = CASE
      WHEN q.retry_count + 1 = 1 THEN now() + interval '1 minute'
      WHEN q.retry_count + 1 = 2 THEN now() + interval '5 minutes'
      WHEN q.retry_count + 1 = 3 THEN now() + interval '15 minutes'
      ELSE now() + interval '1 hour'
    END,
    processing_at = NULL,
    last_error = COALESCE(
      f.error_msg,
      CASE
        WHEN COALESCE(f.timed_out, false) = true THEN 'timeout'
        WHEN f.status_code IS NULL THEN 'sem status_code'
        ELSE 'HTTP ' || f.status_code::text
      END
    ),
    last_status_code = f.status_code,
    last_response_at = f.created
  FROM failed_rows f
  WHERE q.id = f.id;

  GET DIAGNOSTICS v_step = ROW_COUNT;
  v_done := v_done + v_step;

  RETURN v_done;
END;
$$;


ALTER FUNCTION "public"."reconcile_minds_webhook_responses"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_auth_credential_by_phone"("p_phone" "text", "p_reset_password" boolean DEFAULT false) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_phone text := public.norm_phone(p_phone);
  v_existing_hash text;
  v_existing_must_change boolean;
  v_winner record;
begin
  if v_phone = '' then
    return false;
  end if;

  select uc.password_hash, uc.must_change
    into v_existing_hash, v_existing_must_change
  from public.user_credentials uc
  where public.norm_phone(uc.phone) = v_phone
  limit 1;

  with candidates as (

    -- MASTERS
    select
      coalesce(nullif(trim(m.master_id::text), ''), public.norm_phone(m.phone)) as user_id,
      public.norm_phone(m.phone) as phone,
      public.resolve_role_from_user_roles(
        'MASTER',
        coalesce(nullif(trim(m.master_id::text), ''), public.norm_phone(m.phone)),
        m.phone,
        null
      ) as role,
      coalesce(nullif(trim(m.name), ''), public.norm_phone(m.phone)) as name,
      null::text as athlete_id,
      'MASTER'::text as source_kind,
      coalesce(nullif(trim(m.master_id::text), ''), public.norm_phone(m.phone)) as source_ref,
      coalesce(m.created_at, now()) as source_ts
    from public.masters m
    where public.norm_phone(m.phone) = v_phone

    union all

    -- ATHLETES
    select
      ar.athlete_id as user_id,
      public.norm_phone(ar.athlete_phone) as phone,
      public.resolve_role_from_user_roles(
        'ATHLETE',
        ar.athlete_id,
        ar.athlete_phone,
        ar.athlete_id
      ) as role,
      coalesce(nullif(trim(ar.athlete_name), ''), ar.athlete_id) as name,
      ar.athlete_id::text as athlete_id,
      'ATHLETE'::text as source_kind,
      ar.id::text as source_ref,
      coalesce(ar.inserted_at, now()) as source_ts
    from public.athlete_registration ar
    where coalesce(ar.athlete_enabled, true) = true
      and public.norm_phone(ar.athlete_phone) = v_phone

    union all

    -- COACHES
    select
      public.norm_phone(ar.coach_phone) as user_id,
      public.norm_phone(ar.coach_phone) as phone,
      public.resolve_role_from_user_roles(
        'COACH',
        public.norm_phone(ar.coach_phone),
        ar.coach_phone,
        null
      ) as role,
      coalesce(nullif(trim(ar.coach_name), ''), public.norm_phone(ar.coach_phone)) as name,
      null::text as athlete_id,
      'COACH'::text as source_kind,
      ar.id::text as source_ref,
      coalesce(ar.inserted_at, now()) as source_ts
    from public.athlete_registration ar
    where public.norm_phone(ar.coach_phone) = v_phone

  ),
  ranked as (
    select
      c.*,
      row_number() over (
        partition by c.phone
        order by
          case public.norm_role(c.role)
            when 'MASTER' then 1
            when 'COACH' then 2
            when 'ATHLETE' then 3
            else 9
          end,
          c.source_ts desc,
          c.user_id
      ) as rn
    from candidates c
    where c.phone <> ''
  )
  select *
    into v_winner
  from ranked
  where rn = 1;

  -- se não sobrou ninguém para esse telefone, remove a credencial
  if v_winner is null then
    delete from public.user_credentials
    where public.norm_phone(phone) = v_phone;
    return false;
  end if;

  -- remove linha atual do mesmo telefone ou do mesmo user_id
  delete from public.user_credentials
  where public.norm_phone(phone) = v_phone
     or user_id = v_winner.user_id;

  insert into public.user_credentials (
    user_id,
    phone,
    password_hash,
    must_change,
    role,
    name,
    athlete_id,
    source_kind,
    source_ref,
    created_at,
    updated_at
  )
  values (
    v_winner.user_id,
    v_winner.phone,
    case
      when p_reset_password or v_existing_hash is null
        then crypt(v_winner.phone, gen_salt('bf'))
      else v_existing_hash
    end,
    case
      when p_reset_password or v_existing_hash is null
        then true
      else coalesce(v_existing_must_change, true)
    end,
    public.norm_role(v_winner.role),
    v_winner.name,
    v_winner.athlete_id,
    v_winner.source_kind,
    v_winner.source_ref,
    now(),
    now()
  );

  return true;
end;
$$;


ALTER FUNCTION "public"."refresh_auth_credential_by_phone"("p_phone" "text", "p_reset_password" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_athlete_with_coach"("p_master_id" "text", "p_athlete_name" "text", "p_athlete_phone" "text", "p_coach_name" "text", "p_coach_phone" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_athlete_id text;
  v_coach_id text;
begin

  -- ======================
  -- 1) UPSERT ATHLETE
  -- ======================
  v_athlete_id := 'athlete:' || p_athlete_phone;

  insert into public.users (user_id, name, phone, master_id)
  values (v_athlete_id, p_athlete_name, p_athlete_phone, p_master_id)
  on conflict (user_id) do update
  set name = excluded.name,
      phone = excluded.phone,
      master_id = excluded.master_id;

  insert into public.user_roles (user_id, role)
  values (v_athlete_id, 'athlete')
  on conflict do nothing;

  -- ======================
  -- 2) UPSERT COACH
  -- ======================
  v_coach_id := 'coach:' || p_coach_phone;

  insert into public.users (user_id, name, phone, master_id)
  values (v_coach_id, p_coach_name, p_coach_phone, p_master_id)
  on conflict (user_id) do update
  set name = excluded.name,
      phone = excluded.phone,
      master_id = excluded.master_id;

  insert into public.user_roles (user_id, role)
  values (v_coach_id, 'coach')
  on conflict do nothing;

  -- ======================
  -- 3) RELAÇÃO N:N
  -- ======================
  insert into public.coach_athletes (coach_id, athlete_id, master_id)
  values (v_coach_id, v_athlete_id, p_master_id)
  on conflict do nothing;

end;
$$;


ALTER FUNCTION "public"."register_athlete_with_coach"("p_master_id" "text", "p_athlete_name" "text", "p_athlete_phone" "text", "p_coach_name" "text", "p_coach_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."requeue_stale_minds_webhooks"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'net', 'pg_catalog'
    AS $$
DECLARE
  v_count integer := 0;
BEGIN
  UPDATE public.minds_webhook_queue q
  SET
    sent = false,
    retry_count = q.retry_count + 1,
    status = CASE
      WHEN q.retry_count + 1 >= q.max_retries THEN 'failed'
      ELSE 'pending'
    END,
    available_at = now() + interval '5 minutes',
    processing_at = NULL,
    last_error = COALESCE(q.last_error, 'sem resposta do pg_net no tempo esperado')
  WHERE q.status = 'processing'
    AND q.processing_at < now() - interval '5 minutes'
    AND NOT EXISTS (
      SELECT 1
      FROM net._http_response r
      WHERE r.id = q.request_id
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


ALTER FUNCTION "public"."requeue_stale_minds_webhooks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_role_from_user_roles"("p_default_role" "text", "p_user_id" "text", "p_phone" "text", "p_athlete_id" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
declare
  v_role_col text;
  v_active_col text;
  v_phone text := public.norm_phone(p_phone);
  v_sql text;
  v_role text;
  v_conds text[] := array[]::text[];

  v_has_user_id boolean := false;
  v_has_master_id boolean := false;
  v_has_phone boolean := false;
  v_has_athlete_phone boolean := false;
  v_has_coach_phone boolean := false;
  v_has_athlete_id boolean := false;
begin
  if to_regclass('public.user_roles') is null then
    return public.norm_role(p_default_role);
  end if;

  select c.column_name
    into v_role_col
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name = 'user_roles'
    and c.column_name in ('role', 'user_role', 'access_role')
  order by case c.column_name
    when 'role' then 1
    when 'user_role' then 2
    when 'access_role' then 3
    else 99
  end
  limit 1;

  if v_role_col is null then
    return public.norm_role(p_default_role);
  end if;

  select c.column_name
    into v_active_col
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name = 'user_roles'
    and c.column_name in ('active', 'is_active', 'enabled', 'ativo')
  order by case c.column_name
    when 'active' then 1
    when 'is_active' then 2
    when 'enabled' then 3
    when 'ativo' then 4
    else 99
  end
  limit 1;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'user_roles' and column_name = 'user_id'
  ) into v_has_user_id;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'user_roles' and column_name = 'master_id'
  ) into v_has_master_id;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'user_roles' and column_name = 'phone'
  ) into v_has_phone;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'user_roles' and column_name = 'athlete_phone'
  ) into v_has_athlete_phone;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'user_roles' and column_name = 'coach_phone'
  ) into v_has_coach_phone;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'user_roles' and column_name = 'athlete_id'
  ) into v_has_athlete_id;

  if v_has_user_id and coalesce(trim(p_user_id), '') <> '' then
    v_conds := array_append(v_conds, format('coalesce(ur.user_id::text, '''') = %L', p_user_id));
  end if;

  if v_has_master_id and coalesce(trim(p_user_id), '') <> '' then
    v_conds := array_append(v_conds, format('coalesce(ur.master_id::text, '''') = %L', p_user_id));
  end if;

  if v_has_athlete_id and coalesce(trim(p_athlete_id), '') <> '' then
    v_conds := array_append(v_conds, format('coalesce(ur.athlete_id::text, '''') = %L', p_athlete_id));
  end if;

  if v_has_phone and v_phone <> '' then
    v_conds := array_append(v_conds, format('regexp_replace(coalesce(ur.phone::text, ''''), ''\D'', '''', ''g'') = %L', v_phone));
  end if;

  if v_has_athlete_phone and v_phone <> '' then
    v_conds := array_append(v_conds, format('regexp_replace(coalesce(ur.athlete_phone::text, ''''), ''\D'', '''', ''g'') = %L', v_phone));
  end if;

  if v_has_coach_phone and v_phone <> '' then
    v_conds := array_append(v_conds, format('regexp_replace(coalesce(ur.coach_phone::text, ''''), ''\D'', '''', ''g'') = %L', v_phone));
  end if;

  if coalesce(array_length(v_conds, 1), 0) = 0 then
    return public.norm_role(p_default_role);
  end if;

  v_sql := format(
    'select %1$I::text
       from public.user_roles ur
      where (%2$s) %3$s
      limit 1',
    v_role_col,
    array_to_string(v_conds, ' or '),
    case
      when v_active_col is null then ''
      else format(
        ' and (ur.%1$I is null or lower(trim(ur.%1$I::text)) not in (''false'',''0'',''f'',''n'',''no'',''nao'',''não'',''inactive'',''inativo''))',
        v_active_col
      )
    end
  );

  execute v_sql into v_role;

  return coalesce(public.norm_role(v_role), public.norm_role(p_default_role));
end;
$_$;


ALTER FUNCTION "public"."resolve_role_from_user_roles"("p_default_role" "text", "p_user_id" "text", "p_phone" "text", "p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."retry_minds_webhooks"() RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare
    rec record;
    total int := 0;
begin

for rec in
    select *
    from public.minds_webhook_queue
    where sent = false
    and created_at <= now() - interval '10 minutes'
    limit 50
loop

    perform public.send_minds_webhook(
        rec.athlete_id,
        rec.athlete_name,
        rec.athlete_phone,
        rec.questionnaire
    );

    total := total + 1;

end loop;

return total;

end;
$$;


ALTER FUNCTION "public"."retry_minds_webhooks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_change_password"("p_user_id" "text", "p_old_pass" "text", "p_new_pass" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_hash text;
begin
  select uc.password_hash
    into v_hash
  from public.user_credentials uc
  where uc.user_id = p_user_id
  limit 1;

  if v_hash is null then
    return false;
  end if;

  if v_hash <> crypt(p_old_pass, v_hash) then
    return false;
  end if;

  update public.user_credentials
     set password_hash = crypt(p_new_pass, gen_salt('bf')),
         must_change = false,
         updated_at = now()
   where user_id = p_user_id;

  return true;
end;
$$;


ALTER FUNCTION "public"."rpc_change_password"("p_user_id" "text", "p_old_pass" "text", "p_new_pass" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_create_user"("p_name" "text", "p_phone" "text", "p_role" "text", "p_password" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_user_id text;
  v_result jsonb;
BEGIN
  -- Generate a new UUID for the user
  v_user_id := gen_random_uuid()::text;

  -- Insert into identity
  INSERT INTO public.users_identity (user_id, name, phone, role, updated_at)
  VALUES (v_user_id, p_name, p_phone, p_role, now());

  -- Insert into credentials with hashed password
  INSERT INTO public.user_credentials (user_id, phone, password_hash, must_change, created_at, updated_at)
  VALUES (
    v_user_id, 
    p_phone, 
    crypt(p_password, gen_salt('bf')), 
    true, 
    now(), 
    now()
  );

  SELECT to_jsonb(ui.*) INTO v_result FROM public.users_identity ui WHERE ui.user_id = v_user_id;
  
  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."rpc_create_user"("p_name" "text", "p_phone" "text", "p_role" "text", "p_password" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_delete_user"("p_user_id" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Constraints usually handle cascade, but let's be explicit
  DELETE FROM public.user_credentials WHERE user_id = p_user_id;
  DELETE FROM public.users_identity WHERE user_id = p_user_id;
END;
$$;


ALTER FUNCTION "public"."rpc_delete_user"("p_user_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_liga_minds_athlete_score"("p_start_date" "date" DEFAULT ("date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone))::"date", "p_end_date" "date" DEFAULT CURRENT_DATE) RETURNS TABLE("athlete_id" "text", "athlete_name" "text", "team_name" "text", "athlete_phone" "text", "photo_url" "text", "instagram" "text", "total_score" numeric, "xp_total" integer, "engagement_score" numeric, "response_speed_score" numeric, "consistency_score" numeric, "stability_score" numeric, "mood_score" numeric, "recovery_score" numeric, "nutrition_score" numeric, "load_score" numeric, "streak_days" bigint, "badges_count" integer, "current_badge" "text", "badge_list" "text"[], "questionnaires_sent_total" bigint, "questionnaires_answered_total" bigint, "same_day_total" bigint, "late_total" bigint, "unresolved_total" bigint, "repeated_unanswered_sends" bigint, "total_flag_count" bigint, "max_flag_count" integer, "avg_attention_level" numeric, "high_attention_days" bigint, "avg_vigor" numeric, "avg_fatigue" numeric, "avg_dth" numeric, "avg_sleep_quality" numeric, "avg_recovery_index" numeric, "avg_stress_index" numeric, "avg_lack_energy" numeric, "avg_physical_complaints" numeric, "avg_acwr" numeric, "avg_ewma_acwr" numeric, "avg_monotony" numeric, "avg_strain" numeric, "high_load_risk_days" bigint, "position_overall" bigint, "position_team" bigint, "trend" "text")
    LANGUAGE "sql" STABLE
    AS $$
with athletes as (
    select
        a.athlete_id,
        a.athlete_name,
        a.team_name,
        a.athlete_phone,
        a.photo_url,
        a.instagram
    from public.api_athletes a
),

responses as (
    select athlete_id, 'pre'::text as questionnaire, inserted_at as response_time
    from public.brums_analysis

    union all

    select athlete_id, 'post'::text as questionnaire, inserted_at as response_time
    from public.training_load_daily
    where kind = 'daily_post'

    union all

    select athlete_id, 'weekly'::text as questionnaire, inserted_at as response_time
    from public.weekly_analysis

    union all

    select athlete_id, 'quarterly'::text as questionnaire, inserted_at as response_time
    from public.acsi_analysis

    union all

    select athlete_id, 'semiannual'::text as questionnaire, inserted_at as response_time
    from public.cbas_analysis

    union all

    select athlete_id, 'construcional'::text as questionnaire, submitted_at as response_time
    from public.construcional_raw
),

sends as (
    select
        l.athlete_id,
        l.notification_type as questionnaire,
        l.sent_at
    from public.minds_notification_log l
    where l.sent_at::date between p_start_date and p_end_date
      and l.notification_type in ('pre','post','weekly','quarterly','semiannual','construcional')
),

sends_ordered as (
    select
        s.*,
        lead(s.sent_at) over (
            partition by s.athlete_id, s.questionnaire
            order by s.sent_at
        ) as next_same_send_at
    from sends s
),

paired as (
    select
        s.athlete_id,
        s.questionnaire,
        s.sent_at,
        s.next_same_send_at,

        (
            select min(r.response_time)
            from responses r
            where r.athlete_id = s.athlete_id
              and r.questionnaire = s.questionnaire
              and r.response_time >= s.sent_at
              and (s.next_same_send_at is null or r.response_time < s.next_same_send_at)
        ) as response_time_in_cycle,

        (
            select min(r.response_time)
            from responses r
            where r.athlete_id = s.athlete_id
              and r.questionnaire = s.questionnaire
              and r.response_time >= s.sent_at
        ) as first_response_anytime
    from sends_ordered s
),

engagement_per_send as (
    select
        p.*,
        case
            when p.response_time_in_cycle is not null
                 and p.response_time_in_cycle::date = p.sent_at::date
            then 'answered_same_day'

            when p.response_time_in_cycle is not null
            then 'answered_late'

            when p.next_same_send_at is not null
                 and p.response_time_in_cycle is null
            then 'repeated_without_response'

            when p.next_same_send_at is null
                 and p.first_response_anytime is null
            then 'open_without_response'

            else 'unresolved'
        end as send_status
    from paired p
),

engagement_by_questionnaire as (
    select
        athlete_id,
        questionnaire,
        count(*) as sent_count,
        count(*) filter (where send_status in ('answered_same_day','answered_late')) as answered_count,
        count(*) filter (where send_status = 'answered_same_day') as same_day_count,
        count(*) filter (where send_status = 'answered_late') as late_count,
        count(*) filter (where send_status = 'open_without_response') as unresolved_count,
        count(*) filter (where send_status = 'repeated_without_response') as repeated_unanswered_count,
        round(
            100.0
            * count(*) filter (where send_status in ('answered_same_day','answered_late'))
            / nullif(count(*), 0),
            2
        ) as adherence_percent
    from engagement_per_send
    group by athlete_id, questionnaire
),

engagement_block as (
    select
        a.athlete_id,

        round(
            coalesce(sum(
                case q.questionnaire
                    when 'pre'          then q.adherence_percent * 0.08
                    when 'post'         then q.adherence_percent * 0.08
                    when 'weekly'       then q.adherence_percent * 0.05
                    when 'quarterly'    then q.adherence_percent * 0.03
                    when 'semiannual'   then q.adherence_percent * 0.03
                    when 'construcional'then q.adherence_percent * 0.03
                    else 0
                end
            ), 0),
            2
        ) as engagement_score,

        coalesce(sum(q.sent_count), 0) as questionnaires_sent_total,
        coalesce(sum(q.answered_count), 0) as questionnaires_answered_total,
        coalesce(sum(q.same_day_count), 0) as same_day_total,
        coalesce(sum(q.late_count), 0) as late_total,
        coalesce(sum(q.unresolved_count), 0) as unresolved_total,
        coalesce(sum(q.repeated_unanswered_count), 0) as repeated_unanswered_sends

    from athletes a
    left join engagement_by_questionnaire q
        on q.athlete_id = a.athlete_id
    group by a.athlete_id
),

speed_block as (
    select
        a.athlete_id,
        round(
            least(
                10,
                greatest(
                    0,
                    coalesce(
                        (
                            (
                                coalesce(e.same_day_total, 0) * 1.0
                                + coalesce(e.late_total, 0) * 0.45
                            ) / nullif(coalesce(e.questionnaires_sent_total, 0), 0)
                        ) * 10,
                        0
                    )
                    - least(coalesce(e.repeated_unanswered_sends, 0) * 0.75, 4)
                )
            ),
            2
        ) as response_speed_score
    from athletes a
    left join engagement_block e
        on e.athlete_id = a.athlete_id
),

behavior_block as (
    select
        a.athlete_id,
        coalesce(b.max_consecutive_days, 0) as streak_days,
        case
            when coalesce(b.max_consecutive_days, 0) >= 15 then 10
            when coalesce(b.max_consecutive_days, 0) >= 10 then 8
            when coalesce(b.max_consecutive_days, 0) >= 6  then 6
            when coalesce(b.max_consecutive_days, 0) >= 3  then 4
            when coalesce(b.max_consecutive_days, 0) >= 1  then 2
            else 0
        end::numeric as consistency_score
    from athletes a
    left join public.minds_behavior_analytics b
        on b.athlete_id = a.athlete_id
),

flags_block as (
    select
        f.athlete_id,
        count(*) as flag_days,
        coalesce(sum(f.flag_count), 0) as total_flag_count,
        coalesce(max(f.flag_count), 0) as max_flag_count,
        round(coalesce(avg(f.attention_level::numeric), 0), 2) as avg_attention_level,
        count(*) filter (where f.attention_level >= 2) as high_attention_days
    from public.api_flags_events f
    where f.reference_date between p_start_date and p_end_date
    group by f.athlete_id
),

stability_block as (
    select
        a.athlete_id,
        round(
            greatest(
                0,
                least(
                    20,
                    20
                    - coalesce(f.total_flag_count, 0) * 1.2
                    - coalesce(f.high_attention_days, 0) * 2.0
                    - coalesce(f.max_flag_count, 0) * 1.5
                    - coalesce(f.avg_attention_level, 0) * 2.0
                )
            ),
            2
        ) as stability_score
    from athletes a
    left join flags_block f
        on f.athlete_id = a.athlete_id
),

brums_period as (
    select
        b.athlete_id,
        round(avg(b.vigor), 2) as avg_vigor,
        round(avg(b.fatigue), 2) as avg_fatigue,
        round(avg(b.dth), 2) as avg_dth,
        bool_or(coalesce(b.pattern_burnout, false)) as any_burnout,
        bool_or(coalesce(b.pattern_flat, false)) as any_flat,
        bool_or(coalesce(b.pattern_hyperactivation, false)) as any_hyperactivation
    from public.brums_analysis_view b
    where b.data between p_start_date and p_end_date
    group by b.athlete_id
),

mood_block as (
    select
        a.athlete_id,
        bp.avg_vigor,
        bp.avg_fatigue,
        bp.avg_dth,
        round(
            greatest(
                0,
                least(
                    10,
                    6
                    + coalesce(bp.avg_vigor, 0) * 0.35
                    - coalesce(bp.avg_fatigue, 0) * 0.70
                    - coalesce(bp.avg_dth, 0) * 0.18
                    - case when coalesce(bp.any_burnout, false) then 2.5 else 0 end
                    - case when coalesce(bp.any_flat, false) then 1.5 else 0 end
                    - case when coalesce(bp.any_hyperactivation, false) then 0.8 else 0 end
                )
            ),
            2
        ) as mood_score
    from athletes a
    left join brums_period bp
        on bp.athlete_id = a.athlete_id
),

restq_period as (
    select
        r.athlete_id,
        round(avg(r.sleep_quality), 2) as avg_sleep_quality,
        round(avg(r.recovery_index), 2) as avg_recovery_index,
        round(avg(r.stress_index), 2) as avg_stress_index,
        round(avg(r.lack_energy), 2) as avg_lack_energy,
        round(avg(r.physical_complaints), 2) as avg_physical_complaints,
        round(avg(r.balance), 2) as avg_balance
    from public.restq_analysis_view r
    where r.data between p_start_date and p_end_date
    group by r.athlete_id
),

recovery_block as (
    select
        a.athlete_id,
        rp.avg_sleep_quality,
        rp.avg_recovery_index,
        rp.avg_stress_index,
        rp.avg_lack_energy,
        rp.avg_physical_complaints,
        round(
            greatest(
                0,
                least(
                    10,
                    5
                    + coalesce(rp.avg_sleep_quality, 0) * 0.70
                    + coalesce(rp.avg_recovery_index, 0) * 0.90
                    - coalesce(rp.avg_stress_index, 0) * 0.85
                    - coalesce(rp.avg_lack_energy, 0) * 0.60
                    - coalesce(rp.avg_physical_complaints, 0) * 0.55
                )
            ),
            2
        ) as recovery_score
    from athletes a
    left join restq_period rp
        on rp.athlete_id = a.athlete_id
),

diet_period as (
    select
        d.athlete_id,
        round(avg(d.adherence_score), 2) as avg_diet_adherence,
        round(avg(d.gi_distress), 2) as avg_gi_distress
    from public.diet_daily d
    where d.data between p_start_date and p_end_date
    group by d.athlete_id
),

weekly_period as (
    select
        w.athlete_id,
        round(avg(w.adesao_nutricional), 2) as avg_weekly_nutrition
    from public.weekly_analysis_view w
    where w.start_date between p_start_date and p_end_date
    group by w.athlete_id
),

nutrition_block as (
    select
        a.athlete_id,
        round(
            greatest(
                0,
                least(
                    5,
                    coalesce(dp.avg_diet_adherence, 0) * 0.035
                    + coalesce(wp.avg_weekly_nutrition, 0) * 0.18
                    - coalesce(dp.avg_gi_distress, 0) * 0.55
                )
            ),
            2
        ) as nutrition_score
    from athletes a
    left join diet_period dp
        on dp.athlete_id = a.athlete_id
    left join weekly_period wp
        on wp.athlete_id = a.athlete_id
),

load_period as (
    select
        l.athlete_id,
        round(avg(l.acwr), 3) as avg_acwr,
        round(avg(l.monotony), 2) as avg_monotony,
        round(avg(l.strain), 2) as avg_strain
    from public.v_training_metrics_world l
    where l.data between p_start_date and p_end_date
    group by l.athlete_id
),

load_risk_period as (
    select
        r.athlete_id,
        round(avg(r.ewma_acwr), 3) as avg_ewma_acwr,
        count(*) filter (where r.risk_level = 'high') as high_load_risk_days
    from public.v_training_risk_world r
    where r.reference_date between p_start_date and p_end_date
    group by r.athlete_id
),

load_block as (
    select
        a.athlete_id,
        lp.avg_acwr,
        lrp.avg_ewma_acwr,
        lp.avg_monotony,
        lp.avg_strain,
        coalesce(lrp.high_load_risk_days, 0) as high_load_risk_days,
        round(
            greatest(
                0,
                least(
                    5,
                    5
                    - case
                        when lp.avg_acwr is null then 0
                        when lp.avg_acwr > 1.5 then 1.6
                        when lp.avg_acwr > 1.3 then 0.8
                        when lp.avg_acwr < 0.8 then 0.7
                        else 0
                      end
                    - case
                        when lrp.avg_ewma_acwr is null then 0
                        when lrp.avg_ewma_acwr > 1.5 then 1.2
                        when lrp.avg_ewma_acwr > 1.3 then 0.6
                        when lrp.avg_ewma_acwr < 0.8 then 0.5
                        else 0
                      end
                    - case
                        when lp.avg_monotony is not null and lp.avg_monotony > 2.5 then 0.7 else 0 end
                    - case
                        when lp.avg_strain is not null and lp.avg_strain > 6000 then 0.7 else 0 end
                    - least(coalesce(lrp.high_load_risk_days, 0) * 0.35, 1.4)
                )
            ),
            2
        ) as load_score
    from athletes a
    left join load_period lp
        on lp.athlete_id = a.athlete_id
    left join load_risk_period lrp
        on lrp.athlete_id = a.athlete_id
),

badge_block as (
    select
        a.athlete_id,

        array_remove(array[
            case when coalesce(eb.same_day_total, 0) >= 5 then 'Resposta Relâmpago' end,
            case when coalesce(bb.streak_days, 0) >= 10 then 'Guardião da Rotina' end,
            case when coalesce(sb.stability_score, 0) >= 17 and coalesce(fb.high_attention_days, 0) = 0 then 'Muralha Verde' end,
            case when coalesce(rb.avg_sleep_quality, 0) >= 4 and coalesce(rb.avg_recovery_index, 0) >= 2 then 'Sono Blindado' end,
            case when coalesce(lb.load_score, 0) >= 4.2 and coalesce(lb.high_load_risk_days, 0) = 0 then 'Carga Inteligente' end,
            case when coalesce(nb.nutrition_score, 0) >= 4 then 'Nutri em Dia' end
        ], null) as badge_list

    from athletes a
    left join engagement_block eb on eb.athlete_id = a.athlete_id
    left join behavior_block bb on bb.athlete_id = a.athlete_id
    left join stability_block sb on sb.athlete_id = a.athlete_id
    left join flags_block fb on fb.athlete_id = a.athlete_id
    left join recovery_block rb on rb.athlete_id = a.athlete_id
    left join load_block lb on lb.athlete_id = a.athlete_id
    left join nutrition_block nb on nb.athlete_id = a.athlete_id
),

final_base as (
    select
        a.athlete_id,
        a.athlete_name,
        a.team_name,
        a.athlete_phone,
        a.photo_url,
        a.instagram,

        coalesce(eb.engagement_score, 0) as engagement_score,
        coalesce(sp.response_speed_score, 0) as response_speed_score,
        coalesce(bb.consistency_score, 0) as consistency_score,
        coalesce(sb.stability_score, 0) as stability_score,
        coalesce(mb.mood_score, 0) as mood_score,
        coalesce(rb.recovery_score, 0) as recovery_score,
        coalesce(nb.nutrition_score, 0) as nutrition_score,
        coalesce(lb.load_score, 0) as load_score,

        coalesce(bb.streak_days, 0) as streak_days,

        coalesce(eb.questionnaires_sent_total, 0) as questionnaires_sent_total,
        coalesce(eb.questionnaires_answered_total, 0) as questionnaires_answered_total,
        coalesce(eb.same_day_total, 0) as same_day_total,
        coalesce(eb.late_total, 0) as late_total,
        coalesce(eb.unresolved_total, 0) as unresolved_total,
        coalesce(eb.repeated_unanswered_sends, 0) as repeated_unanswered_sends,

        coalesce(fb.total_flag_count, 0) as total_flag_count,
        coalesce(fb.max_flag_count, 0) as max_flag_count,
        coalesce(fb.avg_attention_level, 0) as avg_attention_level,
        coalesce(fb.high_attention_days, 0) as high_attention_days,

        mb.avg_vigor,
        mb.avg_fatigue,
        mb.avg_dth,

        rb.avg_sleep_quality,
        rb.avg_recovery_index,
        rb.avg_stress_index,
        rb.avg_lack_energy,
        rb.avg_physical_complaints,

        lb.avg_acwr,
        lb.avg_ewma_acwr,
        lb.avg_monotony,
        lb.avg_strain,
        lb.high_load_risk_days,

        coalesce(array_length(bd.badge_list, 1), 0) as badges_count,
        bd.badge_list,

        round(
            greatest(
                0,
                least(
                    100,
                    coalesce(eb.engagement_score, 0)
                    + coalesce(sp.response_speed_score, 0)
                    + coalesce(bb.consistency_score, 0)
                    + coalesce(sb.stability_score, 0)
                    + coalesce(mb.mood_score, 0)
                    + coalesce(rb.recovery_score, 0)
                    + coalesce(nb.nutrition_score, 0)
                    + coalesce(lb.load_score, 0)
                    - least(coalesce(eb.repeated_unanswered_sends, 0) * 1.8, 12)
                )
            ),
            2
        ) as total_score
    from athletes a
    left join engagement_block eb on eb.athlete_id = a.athlete_id
    left join speed_block sp on sp.athlete_id = a.athlete_id
    left join behavior_block bb on bb.athlete_id = a.athlete_id
    left join stability_block sb on sb.athlete_id = a.athlete_id
    left join mood_block mb on mb.athlete_id = a.athlete_id
    left join recovery_block rb on rb.athlete_id = a.athlete_id
    left join nutrition_block nb on nb.athlete_id = a.athlete_id
    left join load_block lb on lb.athlete_id = a.athlete_id
    left join flags_block fb on fb.athlete_id = a.athlete_id
    left join badge_block bd on bd.athlete_id = a.athlete_id
),

final_scored as (
    select
        fb.*,
        (
            coalesce(fb.questionnaires_answered_total, 0) * 10
            + coalesce(fb.same_day_total, 0) * 5
            + coalesce(fb.streak_days, 0) * 4
            + coalesce(fb.badges_count, 0) * 20
            + floor(coalesce(fb.stability_score, 0)) * 2
            - coalesce(fb.repeated_unanswered_sends, 0) * 6
        )::integer as xp_total
    from final_base fb
),

ranked as (
    select
        fs.*,
        dense_rank() over (
            order by fs.total_score desc, fs.xp_total desc, fs.streak_days desc, fs.athlete_name
        ) as position_overall,
        dense_rank() over (
            partition by fs.team_name
            order by fs.total_score desc, fs.xp_total desc, fs.streak_days desc, fs.athlete_name
        ) as position_team
    from final_scored fs
)

select
    r.athlete_id,
    r.athlete_name,
    r.team_name,
    r.athlete_phone,
    r.photo_url,
    r.instagram,

    r.total_score,
    r.xp_total,

    r.engagement_score,
    r.response_speed_score,
    r.consistency_score,
    r.stability_score,
    r.mood_score,
    r.recovery_score,
    r.nutrition_score,
    r.load_score,

    r.streak_days,
    r.badges_count,

    case
        when r.position_team = 1 and r.total_score >= 70 then 'Capitão da Equipe'
        when r.badges_count > 0 then r.badge_list[1]
        else 'Em evolução'
    end as current_badge,

    case
        when r.position_team = 1 and r.total_score >= 70
        then array_prepend('Capitão da Equipe', coalesce(r.badge_list, '{}'))
        else coalesce(r.badge_list, '{}')
    end as badge_list,

    r.questionnaires_sent_total,
    r.questionnaires_answered_total,
    r.same_day_total,
    r.late_total,
    r.unresolved_total,
    r.repeated_unanswered_sends,

    r.total_flag_count,
    r.max_flag_count,
    r.avg_attention_level,
    r.high_attention_days,

    r.avg_vigor,
    r.avg_fatigue,
    r.avg_dth,

    r.avg_sleep_quality,
    r.avg_recovery_index,
    r.avg_stress_index,
    r.avg_lack_energy,
    r.avg_physical_complaints,

    r.avg_acwr,
    r.avg_ewma_acwr,
    r.avg_monotony,
    r.avg_strain,
    r.high_load_risk_days,

    r.position_overall,
    r.position_team,

    case
        when r.total_score >= 85 then 'elite'
        when r.total_score >= 70 then 'subindo'
        when r.total_score >= 50 then 'estavel'
        else 'alerta'
    end as trend

from ranked r
order by r.total_score desc, r.xp_total desc, r.streak_days desc, r.athlete_name;
$$;


ALTER FUNCTION "public"."rpc_liga_minds_athlete_score"("p_start_date" "date", "p_end_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_liga_minds_podium"("p_start_date" "date" DEFAULT ("date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone))::"date", "p_end_date" "date" DEFAULT CURRENT_DATE) RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
with athlete_top3 as (
    select *
    from public.rpc_liga_minds_athlete_score(p_start_date, p_end_date)
    order by total_score desc, xp_total desc, streak_days desc, athlete_name
    limit 3
),
team_top3 as (
    select *
    from public.rpc_liga_minds_team_score(p_start_date, p_end_date)
    order by team_score desc, total_xp desc, team_name
    limit 3
)
select jsonb_build_object(
    'athletes', coalesce((select jsonb_agg(to_jsonb(a)) from athlete_top3 a), '[]'::jsonb),
    'teams',    coalesce((select jsonb_agg(to_jsonb(t)) from team_top3 t), '[]'::jsonb),
    'start_date', p_start_date,
    'end_date', p_end_date,
    'generated_at', now()
);
$$;


ALTER FUNCTION "public"."rpc_liga_minds_podium"("p_start_date" "date", "p_end_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_liga_minds_team_score"("p_start_date" "date" DEFAULT ("date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone))::"date", "p_end_date" "date" DEFAULT CURRENT_DATE) RETURNS TABLE("team_name" "text", "athletes_count" bigint, "avg_athlete_score" numeric, "total_xp" bigint, "adherence_team_score" numeric, "stability_team_score" numeric, "streak_team_score" numeric, "low_repeat_penalty_score" numeric, "team_score" numeric, "top_athlete_name" "text", "top_athlete_score" numeric, "team_position" bigint)
    LANGUAGE "sql" STABLE
    AS $$
with athlete_scores as (
    select *
    from public.rpc_liga_minds_athlete_score(p_start_date, p_end_date)
),
team_base as (
    select
        team_name,
        count(*) as athletes_count,
        round(avg(total_score), 2) as avg_athlete_score,
        sum(xp_total)::bigint as total_xp,
        round(avg(engagement_score), 2) as adherence_team_score,
        round(avg(stability_score), 2) as stability_team_score,
        round(avg(consistency_score), 2) as streak_team_score,
        round(
            greatest(
                0,
                10 - avg(coalesce(repeated_unanswered_sends, 0))
            ),
            2
        ) as low_repeat_penalty_score
    from athlete_scores
    where team_name is not null
    group by team_name
),
team_top_athlete as (
    select distinct on (team_name)
        team_name,
        athlete_name as top_athlete_name,
        total_score as top_athlete_score
    from athlete_scores
    where team_name is not null
    order by team_name, total_score desc, xp_total desc, athlete_name
),
team_final as (
    select
        tb.team_name,
        tb.athletes_count,
        tb.avg_athlete_score,
        tb.total_xp,
        tb.adherence_team_score,
        tb.stability_team_score,
        tb.streak_team_score,
        tb.low_repeat_penalty_score,
        round(
            tb.avg_athlete_score * 0.50
            + tb.adherence_team_score * 0.20
            + tb.stability_team_score * 0.15
            + tb.streak_team_score * 0.10
            + tb.low_repeat_penalty_score * 0.05,
            2
        ) as team_score,
        tt.top_athlete_name,
        tt.top_athlete_score
    from team_base tb
    left join team_top_athlete tt
        on tt.team_name = tb.team_name
)
select
    tf.*,
    dense_rank() over (
        order by tf.team_score desc, tf.total_xp desc, tf.team_name
    ) as team_position
from team_final tf
order by tf.team_score desc, tf.total_xp desc, tf.team_name;
$$;


ALTER FUNCTION "public"."rpc_liga_minds_team_score"("p_start_date" "date", "p_end_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_login_phone"("p_phone" "text", "p_pass" "text") RETURNS TABLE("user_id" "text", "role" "text", "athlete_id" "text", "must_change" boolean, "name" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_phone text;
begin

  v_phone := regexp_replace(coalesce(p_phone,''),'\D','','g');

  return query
  select
    uc.user_id,
    uc.role,
    uc.athlete_id,
    uc.must_change,
    uc.name
  from public.user_credentials uc
  where regexp_replace(uc.phone,'\D','','g') = v_phone
  and uc.password_hash = md5(p_pass)
  limit 1;

end;
$$;


ALTER FUNCTION "public"."rpc_login_phone"("p_phone" "text", "p_pass" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_minds_all_coaches_teams"() RETURNS "jsonb"
    LANGUAGE "sql"
    AS $$with responses as (

select athlete_id,'pre' as questionnaire, inserted_at as response_time
from brums_analysis

union all
select athlete_id,'post', inserted_at as response_time
from training_load_daily

union all
select athlete_id,'weekly', inserted_at as response_time
from weekly_analysis

union all
select athlete_id,'quarterly', inserted_at as response_time
from acsi_analysis

union all
select athlete_id,'semiannual', inserted_at as response_time
from cbas_analysis

union all
select athlete_id,'construcional', submitted_at as response_time
from construcional_raw

),

sent as (

select
athlete_id,
notification_type as questionnaire,
sent_at
from minds_notification_log

),

paired as (

select
s.athlete_id,
s.questionnaire,
s.sent_at,
r.response_time,
extract(epoch from (r.response_time - s.sent_at))/3600 as response_hours

from sent s

left join lateral (

select response_time
from responses r
where r.athlete_id = s.athlete_id
and r.questionnaire = s.questionnaire
and r.response_time >= s.sent_at
order by r.response_time
limit 1

) r on true

),

classified as (

select

athlete_id,

case
when response_time is null then 'not_answered'
when response_hours <= 24 then 'same_day'
when response_hours <= 48 then 'near'
else 'late'
end as response_status

from paired

),

stats as (

select

athlete_id,

count(*) as sent,

count(*) filter (where response_status <> 'not_answered') as answered,

count(*) filter (where response_status='same_day') as same_day,
count(*) filter (where response_status='near') as near,
count(*) filter (where response_status='late') as late,
count(*) filter (where response_status='not_answered') as not_answered

from classified
group by athlete_id

),

athlete_data as (

select

a.athlete_id,
a.athlete_name,

initcap(trim(reg.coach_name)) as coach_name,
reg.coach_phone,

coalesce(s.sent,0) as sent,
coalesce(s.answered,0) as answered,
coalesce(s.same_day,0) as same_day,
coalesce(s.near,0) as near,
coalesce(s.late,0) as late,
coalesce(s.not_answered,0) as not_answered,

round(
100.0 * coalesce(s.answered,0) /
nullif(s.sent,0)
,2) as adherence_percent

from api_athletes a

left join athlete_registration reg
on reg.athlete_id = a.athlete_id

left join stats s
on s.athlete_id = a.athlete_id

where public.is_athlete_allowed(a.athlete_id)
and coalesce(s.sent,0) > 0
),

team_summary as (

select

coach_name,
coach_phone,

count(*) as athletes,

round(
coalesce(avg(adherence_percent),0)
,2) as avg_adherence

from athlete_data
group by coach_name,coach_phone

),

team_athletes as (

select

coach_name,
coach_phone,

jsonb_agg(

jsonb_build_object(

'athlete_name',athlete_name,
'sent',sent,
'answered',answered,

'same_day',same_day,
'near',near,
'late',late,
'not_answered',not_answered,

'adherence_percent',adherence_percent

)

order by adherence_percent desc

) as athletes

from athlete_data
group by coach_name,coach_phone

)

select jsonb_agg(

jsonb_build_object(

'coach_name',s.coach_name,
'coach_phone',s.coach_phone,

'team_summary',jsonb_build_object(
'athletes',s.athletes,
'avg_adherence',s.avg_adherence
),

'athletes',a.athletes

)

order by s.coach_name

)

from team_summary s
join team_athletes a
using (coach_name,coach_phone)$$;


ALTER FUNCTION "public"."rpc_minds_all_coaches_teams"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."acsi_analysis" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "data" "date",
    "media" numeric,
    "metas_preparacao" numeric,
    "relacao_treinador" numeric,
    "concentracao" numeric,
    "confianca_motivacao" numeric,
    "pico_pressao" numeric,
    "adversidade" numeric,
    "ausencia_preocupacao" numeric,
    "inserted_at" timestamp with time zone DEFAULT "now"(),
    "kind" "text",
    "master_sheet_id" "text",
    "payload" "jsonb",
    "source" "text"
);


ALTER TABLE "public"."acsi_analysis" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."athlete_registration" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "data" "date" DEFAULT CURRENT_DATE,
    "payload" "jsonb",
    "ideal_weight_kg" numeric,
    "inserted_at" timestamp with time zone DEFAULT "now"(),
    "athlete_name" "text",
    "team_name" "text",
    "kind" "text",
    "athlete_phone" "text",
    "coach_phone" "text",
    "source" "text",
    "master_sheet_id" "text",
    "coach_name" "text",
    "instagram" "text",
    "photo_url" "text",
    "athlete_enabled" boolean DEFAULT true,
    CONSTRAINT "athlete_id_digits_only" CHECK (("athlete_id" ~ '^[0-9]+$'::"text"))
);


ALTER TABLE "public"."athlete_registration" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."api_athletes" AS
 SELECT DISTINCT ON ("athlete_id") "athlete_id",
    "athlete_name",
    "team_name",
    "athlete_phone",
    "coach_phone",
    "inserted_at",
    "photo_url",
    "instagram"
   FROM "public"."athlete_registration"
  ORDER BY "athlete_id", "inserted_at" DESC;


ALTER VIEW "public"."api_athletes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."brums_analysis" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "data" "date",
    "dth" numeric,
    "vigor" numeric,
    "dth_minus" numeric,
    "inserted_at" timestamp with time zone DEFAULT "now"(),
    "tension" numeric,
    "depression" numeric,
    "anger" numeric,
    "fatigue" numeric,
    "confusion" numeric
);


ALTER TABLE "public"."brums_analysis" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cbas_analysis" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "data" "date",
    "tecnica" numeric,
    "planejamento" numeric,
    "motivacional" numeric,
    "relacao" numeric,
    "aversivos" numeric,
    "inserted_at" timestamp with time zone DEFAULT "now"(),
    "kind" "text",
    "master_sheet_id" "text",
    "payload" "jsonb",
    "source" "text"
);


ALTER TABLE "public"."cbas_analysis" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."construcional_raw" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"(),
    "bloco_1" "text",
    "bloco_2" "text",
    "bloco_3" "text",
    "bloco_4" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "last_error" "text",
    "kind" "text",
    "master_sheet_id" "text",
    "payload" "jsonb",
    "source" "text"
);


ALTER TABLE "public"."construcional_raw" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."weekly_analysis" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "start_date" "date",
    "desempenho" numeric,
    "adesao_nutricional" numeric,
    "dieta_comentarios" "text",
    "cansaco_acao" "text",
    "semana_comentarios" "text",
    "eventos" "text",
    "inserted_at" timestamp with time zone DEFAULT "now"(),
    "kind" "text",
    "master_sheet_id" "text",
    "payload" "jsonb",
    "source" "text"
);


ALTER TABLE "public"."weekly_analysis" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."minds_last_response" AS
 SELECT "athlete_id",
    "max"("ts") AS "last_response"
   FROM ( SELECT "brums_analysis"."athlete_id",
            "brums_analysis"."inserted_at" AS "ts"
           FROM "public"."brums_analysis"
        UNION ALL
         SELECT "weekly_analysis"."athlete_id",
            "weekly_analysis"."inserted_at"
           FROM "public"."weekly_analysis"
        UNION ALL
         SELECT "acsi_analysis"."athlete_id",
            "acsi_analysis"."inserted_at"
           FROM "public"."acsi_analysis"
        UNION ALL
         SELECT "cbas_analysis"."athlete_id",
            "cbas_analysis"."inserted_at"
           FROM "public"."cbas_analysis"
        UNION ALL
         SELECT "construcional_raw"."athlete_id",
            "construcional_raw"."submitted_at"
           FROM "public"."construcional_raw") "t"
  GROUP BY "athlete_id";


ALTER VIEW "public"."minds_last_response" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."minds_notification_log" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "notification_type" "text" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."minds_notification_log" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."minds_behavior_analytics" AS
 WITH "responses" AS (
         SELECT "minds_last_response"."athlete_id",
            "date"("minds_last_response"."last_response") AS "response_day"
           FROM "public"."minds_last_response"
        ), "sent" AS (
         SELECT "minds_notification_log"."athlete_id",
            "date"("minds_notification_log"."sent_at") AS "sent_day",
            "minds_notification_log"."sent_at"
           FROM "public"."minds_notification_log"
        ), "response_pairs" AS (
         SELECT "s"."athlete_id",
            "s"."sent_at",
            "r"."response_day"
           FROM ("sent" "s"
             LEFT JOIN "responses" "r" ON ((("r"."athlete_id" = "s"."athlete_id") AND ("r"."response_day" >= "date"("s"."sent_at")))))
        ), "response_time" AS (
         SELECT "response_pairs"."athlete_id",
            "avg"((EXTRACT(epoch FROM ((("response_pairs"."response_day")::timestamp without time zone)::timestamp with time zone - "response_pairs"."sent_at")) / (3600)::numeric)) AS "avg_response_hours"
           FROM "response_pairs"
          WHERE ("response_pairs"."response_day" IS NOT NULL)
          GROUP BY "response_pairs"."athlete_id"
        ), "responses_count" AS (
         SELECT "minds_last_response"."athlete_id",
            "count"(*) AS "total_responses",
            "max"("minds_last_response"."last_response") AS "last_response"
           FROM "public"."minds_last_response"
          GROUP BY "minds_last_response"."athlete_id"
        ), "sent_count" AS (
         SELECT "minds_notification_log"."athlete_id",
            "count"(*) AS "total_sent"
           FROM "public"."minds_notification_log"
          GROUP BY "minds_notification_log"."athlete_id"
        ), "streak_calc" AS (
         SELECT "t"."athlete_id",
            "count"(*) AS "consecutive_days"
           FROM ( SELECT "responses"."athlete_id",
                    "responses"."response_day",
                    ("responses"."response_day" - (("row_number"() OVER (PARTITION BY "responses"."athlete_id" ORDER BY "responses"."response_day"))::double precision * '1 day'::interval)) AS "grp"
                   FROM "responses") "t"
          GROUP BY "t"."athlete_id", "t"."grp"
        ), "max_streak" AS (
         SELECT "streak_calc"."athlete_id",
            "max"("streak_calc"."consecutive_days") AS "max_consecutive_days"
           FROM "streak_calc"
          GROUP BY "streak_calc"."athlete_id"
        )
 SELECT "a"."athlete_id",
    "a"."athlete_name",
    "rc"."last_response",
    "sc"."total_sent",
    "rc"."total_responses",
    "round"(((("rc"."total_responses")::numeric / (NULLIF("sc"."total_sent", 0))::numeric) * (100)::numeric), 2) AS "adherence_percent",
    COALESCE("rt"."avg_response_hours", (0)::numeric) AS "avg_response_hours",
    COALESCE("ms"."max_consecutive_days", (0)::bigint) AS "max_consecutive_days",
        CASE
            WHEN ("rc"."last_response" IS NULL) THEN 'never responded'::"text"
            WHEN (("now"() - "rc"."last_response") > '14 days'::interval) THEN 'abandonment risk'::"text"
            WHEN (("now"() - "rc"."last_response") > '7 days'::interval) THEN 'inactive'::"text"
            ELSE 'active'::"text"
        END AS "engagement_status",
        CASE
            WHEN ((("rc"."total_responses")::numeric / (NULLIF("sc"."total_sent", 1))::numeric) < 0.3) THEN 'high drop-out risk'::"text"
            WHEN ((("rc"."total_responses")::numeric / (NULLIF("sc"."total_sent", 1))::numeric) < 0.6) THEN 'moderate risk'::"text"
            ELSE 'low risk'::"text"
        END AS "dropout_risk"
   FROM (((("public"."api_athletes" "a"
     LEFT JOIN "responses_count" "rc" ON (("rc"."athlete_id" = "a"."athlete_id")))
     LEFT JOIN "sent_count" "sc" ON (("sc"."athlete_id" = "a"."athlete_id")))
     LEFT JOIN "response_time" "rt" ON (("rt"."athlete_id" = "a"."athlete_id")))
     LEFT JOIN "max_streak" "ms" ON (("ms"."athlete_id" = "a"."athlete_id")));


ALTER VIEW "public"."minds_behavior_analytics" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_minds_behavior_analytics"() RETURNS SETOF "public"."minds_behavior_analytics"
    LANGUAGE "sql"
    AS $$

select *
from minds_behavior_analytics

$$;


ALTER FUNCTION "public"."rpc_minds_behavior_analytics"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_minds_behavior_engine_v3"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$with responses as (

select athlete_id,'pre' as questionnaire, inserted_at as response_time
from brums_analysis

union all
select athlete_id,'weekly', inserted_at from weekly_analysis
union all
select athlete_id,'quarterly', inserted_at from acsi_analysis
union all
select athlete_id,'semiannual', inserted_at from cbas_analysis
union all
select athlete_id,'construcional', submitted_at from construcional_raw

),

sent as (

select
athlete_id,
notification_type as questionnaire,
sent_at
from minds_notification_log

),

timeline as (

select
s.athlete_id,
s.questionnaire,
s.sent_at,
min(r.response_time) as response_time
from sent s
left join responses r
on r.athlete_id=s.athlete_id
and r.questionnaire=s.questionnaire
and r.response_time>=s.sent_at
group by s.athlete_id,s.questionnaire,s.sent_at

),

timeline_status as (

select

t.*,

case
when response_time is null then 'not_answered'
when response_time::date = sent_at::date then 'same_day'
else 'late'
end as response_status

from timeline t

),

questionnaire_stats as (

select

athlete_id,
questionnaire,

count(*) as sent,

count(response_time) as answered,

count(*) filter(
where response_status='same_day'
) as same_day,

count(*) filter(
where response_status='late'
) as late,

count(*) filter(
where response_status='not_answered'
) as not_answered

from timeline_status

group by athlete_id,questionnaire

),

athlete_summary as (

select

athlete_id,

sum(sent) as total_sent,
sum(answered) as total_answered

from questionnaire_stats

group by athlete_id

),

behavior as (

select

a.athlete_id,

round(
100.0*total_answered/nullif(total_sent,0),
2
) as adherence_percent,

(0.7*(total_answered::float/nullif(total_sent,1))*100)
as discipline_score

from athlete_summary a

),

risk as (

select

*,

case
when discipline_score>=85 then 'stable'
when discipline_score>=60 then 'attention'
else 'risk'
end as behavioral_risk

from behavior

),

athlete_block as (

select

a.athlete_id,
a.athlete_name,

reg.coach_name,
reg.coach_phone,

r.discipline_score,
r.behavioral_risk,

s.total_sent,
s.total_answered,

(
select jsonb_object_agg(

qs.questionnaire,

jsonb_build_object(
'sent',qs.sent,
'answered',qs.answered,
'same_day',qs.same_day,
'late',qs.late,
'not_answered',qs.not_answered
)

)

from questionnaire_stats qs
where qs.athlete_id=a.athlete_id

) as questionnaires

from api_athletes a

left join athlete_registration reg
on reg.athlete_id = a.athlete_id

left join athlete_summary s
on s.athlete_id = a.athlete_id

left join risk r
on r.athlete_id = a.athlete_id

where public.is_athlete_allowed(a.athlete_id)

),
team_summary as (

select

count(*) as athletes,

avg(discipline_score) as avg_score,

count(*) filter(
where behavioral_risk='risk'
) as athletes_at_risk

from athlete_block

)

select jsonb_build_object(

'team_summary',
(
select to_jsonb(team_summary)
from team_summary
),

'athletes',
(
select jsonb_agg(athlete_block)
from athlete_block
)

);$$;


ALTER FUNCTION "public"."rpc_minds_behavior_engine_v3"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_minds_cron_flags"() RETURNS TABLE("athlete_id" "text", "athlete_name" "text", "athlete_phone" "text", "needs_post" boolean, "needs_pre" boolean, "needs_weekly" boolean, "needs_quarterly" boolean, "needs_semiannual" boolean, "needs_construcional" boolean, "escalation_level" integer, "priority_rank" integer)
    LANGUAGE "plpgsql"
    AS $$begin

  return query
  with base as (
    select a.athlete_id, a.athlete_name, a.athlete_phone
    from public.api_athletes a
    where public.is_athlete_allowed(a.athlete_id)
  ),

  last_activity as (
    select
      t.athlete_id,
      max(t.inserted_at) as last_response
    from (
      select athlete_id, inserted_at from brums_analysis
      union all
      select athlete_id, inserted_at from weekly_analysis
      union all
      select athlete_id, inserted_at from acsi_analysis
      union all
      select athlete_id, inserted_at from cbas_analysis
      union all
      select athlete_id, submitted_at as inserted_at from construcional_raw
    ) t
    group by t.athlete_id
  ),

  daily as (
    select
      d.athlete_id,
      max(reference_date) filter (where has_pre) as last_pre,
      max(reference_date) filter (where has_post) as last_post
    from api_daily_pre_post d
    group by d.athlete_id
  ),

  weekly as (
    select athlete_id, max(start_date) as last_week
    from weekly_analysis
    group by athlete_id
  ),

  quarterly as (
    select athlete_id, max(data) as last_quarter
    from acsi_analysis
    group by athlete_id
  ),

  semiannual as (
    select athlete_id, max(data) as last_semi
    from cbas_analysis
    group by athlete_id
  ),

  construcional as (
    select athlete_id, max(submitted_at::date) as last_cons
    from construcional_raw
    group by athlete_id
  ),

  merged as (
    select
      b.*,
      la.last_response,
      d.last_pre,
      d.last_post,
      w.last_week,
      q.last_quarter,
      s.last_semi,
      c.last_cons
    from base b
    left join last_activity la on la.athlete_id = b.athlete_id
    left join daily d on d.athlete_id = b.athlete_id
    left join weekly w on w.athlete_id = b.athlete_id
    left join quarterly q on q.athlete_id = b.athlete_id
    left join semiannual s on s.athlete_id = b.athlete_id
    left join construcional c on c.athlete_id = b.athlete_id
  ),

  decision as (
    select
      m.*,

      (m.last_pre is not null and (m.last_post is null or m.last_post < m.last_pre)) as needs_post,

      (m.last_pre is null or m.last_pre < current_date) as needs_pre,

      (m.last_week is null or m.last_week < current_date - interval '7 days') as needs_weekly,

      (m.last_quarter is null or m.last_quarter < current_date - interval '90 days') as needs_quarterly,

      (m.last_semi is null or m.last_semi < current_date - interval '180 days') as needs_semiannual,

      (m.last_cons is null) as needs_construcional

    from merged m
  ),

  escalation as (
    select
      d.*,
      (
        select count(*)
        from minds_notification_log l
        where l.athlete_id = d.athlete_id
        and l.sent_at::date >= current_date - interval '3 days'
      ) as last_3_days_count
    from decision d
  ),

  filtered as (
    select *
    from escalation e
    where

      -- pelo menos uma necessidade
      (
        e.needs_post or
        e.needs_pre or
        e.needs_weekly or
        e.needs_quarterly or
        e.needs_semiannual or
        e.needs_construcional
      )

      -- silêncio adaptativo 6h
      and (
        e.last_response is null
        or e.last_response < now() - interval '6 hours'
      )

      -- não mandar 2x no dia
      and not exists (
        select 1
        from minds_notification_log l
        where l.athlete_id = e.athlete_id
        and l.sent_at::date = current_date
      )
  )

select
  f.athlete_id,
  f.athlete_name,
  f.athlete_phone,
  f.needs_post,
  f.needs_pre,
  f.needs_weekly,
  f.needs_quarterly,
  f.needs_semiannual,
  f.needs_construcional,
  case when f.last_3_days_count >= 2 then 1 else 0 end as escalation_level,
  case
    when f.needs_post then 1
    when f.needs_pre then 2
    when f.needs_weekly then 3
    when f.needs_quarterly then 4
    when f.needs_semiannual then 5
    when f.needs_construcional then 6
    else 99
  end as priority_rank
from filtered f
order by priority_rank;


end;$$;


ALTER FUNCTION "public"."rpc_minds_cron_flags"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_minds_cron_forecast"("p_now" timestamp without time zone) RETURNS TABLE("athlete_id" "text", "athlete_name" "text", "athlete_phone" "text", "action_type" "text", "priority_rank" integer, "due_at" timestamp without time zone)
    LANGUAGE "sql"
    AS $$

with base as (

select *
from rpc_minds_cron_priority()

)

select
athlete_id,
athlete_name,
athlete_phone,
action_type,
priority_rank,
p_now as due_at

from base

$$;


ALTER FUNCTION "public"."rpc_minds_cron_forecast"("p_now" timestamp without time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_minds_cron_priority"() RETURNS TABLE("athlete_id" "text", "athlete_name" "text", "athlete_phone" "text", "action_type" "text", "priority_rank" integer, "escalation_level" integer, "due_at" timestamp with time zone)
    LANGUAGE "sql"
    AS $$select
    a.athlete_id,
    a.athlete_name,
    a.athlete_phone,

    o.predicted_questionnaire as action_type,

    case
        when o.predicted_questionnaire = 'post' then 1
        when o.predicted_questionnaire = 'pre' then 2
        when o.predicted_questionnaire = 'weekly' then 3
        when o.predicted_questionnaire = 'construcional' then 4
        when o.predicted_questionnaire = 'quarterly' then 5
        when o.predicted_questionnaire = 'semiannual' then 6
    end as priority_rank,

    0 as escalation_level,

    now() as due_at

from public.minds_overview o
join public.api_athletes a using (athlete_id)

where

    -- precisa existir um questionário previsto
    o.predicted_questionnaire is not null

    -- atleta precisa ter telefone
    and a.athlete_phone is not null

    -- evita atletas inativos
    and (
        o.last_response is null
        or now() - o.last_response <= interval '14 days'
    )

    -- respeita horário comercial (exceto pós treino)
    and (
        o.predicted_questionnaire = 'post'
        or (
            extract(hour from now()) >= 8
            and extract(hour from now()) < 18
        )
    )

    -- evita duplicação no mesmo dia
    and not exists (
        select 1
        from public.minds_notification_log l
        where l.athlete_id = a.athlete_id
        and l.notification_type = o.predicted_questionnaire
        and l.sent_at >= date_trunc('day', now())
    )

order by
    priority_rank,
    a.athlete_name;$$;


ALTER FUNCTION "public"."rpc_minds_cron_priority"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_minds_cron_scheduler"() RETURNS TABLE("athlete_id" "text", "athlete_name" "text", "athlete_phone" "text", "needs_pre" boolean, "needs_post" boolean, "needs_weekly" boolean, "needs_quarterly" boolean, "needs_semiannual" boolean, "needs_construcional" boolean)
    LANGUAGE "plpgsql"
    AS $$
begin

  return query
  with base as (
    select
      a.athlete_id,
      a.athlete_name,
      a.athlete_phone
    from public.api_athletes a
  ),

  last_pre_post as (
    select
      d.athlete_id,
      max(d.reference_date) filter (where d.has_pre) as last_pre_date,
      max(d.reference_date) filter (where d.has_post) as last_post_date
    from public.api_daily_pre_post d
    group by d.athlete_id
  ),

  last_weekly as (
    select athlete_id, max(start_date) as last_week
    from public.weekly_analysis
    group by athlete_id
  ),

  last_quarterly as (
    select athlete_id, max(data) as last_quarter
    from public.acsi_analysis
    group by athlete_id
  ),

  last_semiannual as (
    select athlete_id, max(data) as last_semi
    from public.cbas_analysis
    group by athlete_id
  ),

  last_construcional as (
    select athlete_id, max(submitted_at::date) as last_cons
    from public.construcional_raw
    group by athlete_id
  )

  select
    b.athlete_id,
    b.athlete_name,
    b.athlete_phone,

    -- 🔵 PRE TREINO (se não respondeu hoje)
    (
      lp.last_pre_date is null
      or lp.last_pre_date < current_date
    ) as needs_pre,

    -- 🔴 POST TREINO (se último pre não tem post correspondente)
    (
      lp.last_pre_date is not null
      and (
        lp.last_post_date is null
        or lp.last_post_date < lp.last_pre_date
      )
    ) as needs_post,

    -- 🟡 SEMANAL (domingo)
    (
      lw.last_week is null
      or lw.last_week < current_date - interval '7 days'
    ) as needs_weekly,

    -- 🟣 TRIMESTRAL (90 dias)
    (
      lq.last_quarter is null
      or lq.last_quarter < current_date - interval '90 days'
    ) as needs_quarterly,

    -- 🟤 SEMESTRAL (180 dias)
    (
      ls.last_semi is null
      or ls.last_semi < current_date - interval '180 days'
    ) as needs_semiannual,

    -- ⚪ CONSTRUCIONAL (apenas 1x ou se quiser forçar anual)
    (
      lc.last_cons is null
    ) as needs_construcional

  from base b
  left join last_pre_post lp on lp.athlete_id = b.athlete_id
  left join last_weekly lw on lw.athlete_id = b.athlete_id
  left join last_quarterly lq on lq.athlete_id = b.athlete_id
  left join last_semiannual ls on ls.athlete_id = b.athlete_id
  left join last_construcional lc on lc.athlete_id = b.athlete_id;

end;
$$;


ALTER FUNCTION "public"."rpc_minds_cron_scheduler"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_update_user"("p_user_id" "text", "p_name" "text", "p_phone" "text", "p_role" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_result jsonb;
BEGIN
  UPDATE public.users_identity
  SET name = p_name,
      phone = p_phone,
      role = p_role,
      updated_at = now()
  WHERE user_id = p_user_id;

  -- Also update phone in credentials if it changed
  UPDATE public.user_credentials
  SET phone = p_phone,
      updated_at = now()
  WHERE user_id = p_user_id;

  SELECT to_jsonb(ui.*) INTO v_result FROM public.users_identity ui WHERE ui.user_id = p_user_id;
  
  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."rpc_update_user"("p_user_id" "text", "p_name" "text", "p_phone" "text", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_last_user_message_as_history"("p_user_id" "text", "p_title" "text" DEFAULT NULL::"text", "p_tags" "text"[] DEFAULT '{}'::"text"[], "p_saved_by" "text" DEFAULT 'command'::"text") RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
declare
  v_msg record;
  v_note_id bigint;
begin
  select *
  into v_msg
  from public.pingo_user_messages m
  where m.user_id = p_user_id
    and m.athlete_id is not null
  order by m.received_at desc
  limit 1;

  if not found then
    raise exception 'Nenhuma mensagem recente com athlete_id encontrado para este user_id.';
  end if;

  update public.pingo_user_messages
  set include_in_history = true,
      saved_at = now(),
      saved_by = p_saved_by
  where id = v_msg.id;

  insert into public.pingo_athlete_notes(
    athlete_id, user_id, source_message_id, title, note_text, tags, note_meta
  )
  values (
    v_msg.athlete_id,
    v_msg.user_id,
    v_msg.id,
    coalesce(p_title, 'Registro do usuário (chat)'),
    v_msg.message_text,
    coalesce(p_tags, '{}'::text[]),
    jsonb_build_object('origin','user_command','saved_by',p_saved_by)
  )
  returning id into v_note_id;

  return v_note_id;
end $$;


ALTER FUNCTION "public"."save_last_user_message_as_history"("p_user_id" "text", "p_title" "text", "p_tags" "text"[], "p_saved_by" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_user_message_as_history"("p_message_id" bigint, "p_title" "text" DEFAULT NULL::"text", "p_tags" "text"[] DEFAULT '{}'::"text"[], "p_saved_by" "text" DEFAULT 'command'::"text") RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
declare
  v_msg record;
  v_note_id bigint;
begin
  select * into v_msg
  from public.pingo_user_messages
  where id = p_message_id;

  if not found then
    raise exception 'Mensagem não encontrada: %', p_message_id;
  end if;

  update public.pingo_user_messages
  set include_in_history = true,
      saved_at = now(),
      saved_by = p_saved_by
  where id = v_msg.id;

  insert into public.pingo_athlete_notes(
    athlete_id, user_id, source_message_id,
    title, note_text, tags, note_meta
  )
  values (
    v_msg.athlete_id,
    v_msg.user_id,
    v_msg.id,
    coalesce(p_title, 'Registro do usuário (chat)'),
    v_msg.message_text,
    coalesce(p_tags,'{}'::text[]),
    jsonb_build_object('origin','user_command','saved_by',p_saved_by)
  )
  returning id into v_note_id;

  return v_note_id;
end $$;


ALTER FUNCTION "public"."save_user_message_as_history"("p_message_id" bigint, "p_title" "text", "p_tags" "text"[], "p_saved_by" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_similar_chat_notes"("p_athlete_id" "text", "p_query_embedding" "public"."vector", "p_limit" integer DEFAULT 8) RETURNS TABLE("note_id" bigint, "created_at" timestamp with time zone, "title" "text", "note_text" "text", "tags" "text"[], "distance" numeric)
    LANGUAGE "sql" STABLE
    AS $$
  with v as (
    select
      av.metadata->>'note_id' as note_id_txt,
      (av.embedding <-> p_query_embedding) as dist
    from public.analysis_vectors av
    where av.athlete_id = p_athlete_id
      and av.source = 'pingo_chat_note'
      and av.embedding is not null
      and av.metadata ? 'note_id'
    order by av.embedding <-> p_query_embedding
    limit greatest(1, least(p_limit, 20))
  )
  select
    n.id as note_id,
    n.created_at,
    n.title,
    n.note_text,
    n.tags,
    v.dist as distance
  from v
  join public.pingo_athlete_notes n
    on n.id = (v.note_id_txt)::bigint
  order by v.dist asc;
$$;


ALTER FUNCTION "public"."search_similar_chat_notes"("p_athlete_id" "text", "p_query_embedding" "public"."vector", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_minds_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$begin

perform net.http_post(
    url := 'https://autowebhook.opingo.com.br/webhook/Questionario-Minds',
    body := jsonb_build_object(
        'athlete_id', NEW.athlete_id,
        'athlete_name', NEW.athlete_name,
        'phone', NEW.athlete_phone,
        'questionnaire', NEW.questionnaire
    ),
    headers := jsonb_build_object(
        'Content-Type','application/json'
    )
);

return NEW;

end;$$;


ALTER FUNCTION "public"."send_minds_webhook"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_minds_webhook"("p_athlete_id" "text", "p_name" "text", "p_phone" "text", "p_questionnaire" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin

perform net.http_post(
    url := 'https://autowebhook.opingo.com.br/webhook/Questionario-Minds',
    body := jsonb_build_object(
        'athlete_id', p_athlete_id,
        'athlete_name', p_name,
        'phone', p_phone,
        'questionnaire', p_questionnaire
    ),
    headers := jsonb_build_object(
        'Content-Type','application/json'
    )
);

end;
$$;


ALTER FUNCTION "public"."send_minds_webhook"("p_athlete_id" "text", "p_name" "text", "p_phone" "text", "p_questionnaire" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_active_athlete"("p_user_id" "text", "p_athlete_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  a record;
begin
  select *
  into a
  from public.athlete_latest_view
  where athlete_id = p_athlete_id;

  if not found then
    raise exception 'Atleta não encontrado: %', p_athlete_id;
  end if;

  insert into public.pingo_chat_context(
    user_id, last_athlete_id, last_athlete_name, last_team_name, last_athlete_phone, last_coach_phone, meta
  )
  values (
    p_user_id, a.athlete_id, a.athlete_name, a.team_name, a.athlete_phone, a.coach_phone, '{}'::jsonb
  )
  on conflict (user_id) do update set
    last_athlete_id = excluded.last_athlete_id,
    last_athlete_name = excluded.last_athlete_name,
    last_team_name = excluded.last_team_name,
    last_athlete_phone = excluded.last_athlete_phone,
    last_coach_phone = excluded.last_coach_phone;

  insert into public.pingo_user_athletes(
    user_id, athlete_id, athlete_name, team_name, athlete_phone, coach_phone, last_used_at
  )
  values (
    p_user_id, a.athlete_id, a.athlete_name, a.team_name, a.athlete_phone, a.coach_phone, now()
  )
  on conflict (user_id, athlete_id) do update set
    athlete_name = excluded.athlete_name,
    team_name = excluded.team_name,
    athlete_phone = excluded.athlete_phone,
    coach_phone = excluded.coach_phone,
    last_used_at = now();

  return jsonb_build_object(
    'user_id', p_user_id,
    'athlete_id', a.athlete_id,
    'athlete_name', a.athlete_name,
    'team_name', a.team_name,
    'athlete_phone', a.athlete_phone,
    'coach_phone', a.coach_phone
  );
end $$;


ALTER FUNCTION "public"."set_active_athlete"("p_user_id" "text", "p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_created_day"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.created_day := new.created_at::date;
  return new;
end;
$$;


ALTER FUNCTION "public"."set_created_day"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_created_hour"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
new.created_hour := date_trunc('hour', new.created_at);
return new;
end;
$$;


ALTER FUNCTION "public"."set_created_hour"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_pingo_chat_context_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end $$;


ALTER FUNCTION "public"."set_pingo_chat_context_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_scoring_rules_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end $$;


ALTER FUNCTION "public"."set_scoring_rules_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."slugify"("text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $_$
BEGIN
  RETURN lower(
    regexp_replace(
      regexp_replace(trim($1), '\s+', '_', 'g'),
      '[^a-z0-9_]', '', 'g'
    )
  );
END;
$_$;


ALTER FUNCTION "public"."slugify"("text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_account_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin

update public.users
set account_active =
case
    when new.payment_status = 'active'
    and new.next_due_date >= now()::date
    then true
    else false
end
where user_id = new.user_id;

return new;

end;
$$;


ALTER FUNCTION "public"."sync_account_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_athlete_to_users_all"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into users_athletes (
    user_id,
    name,
    role,
    phone
  )
  values (
    'athlete:' || new.athlete_id,
    new.athlete_name,
    'athlete',
    new.athlete_phone
  )
  on conflict (user_id)
  do update set
    name = excluded.name,
    phone = excluded.phone;

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_athlete_to_users_all"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_coach_roles"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  delete from public.user_roles ur
  where
    ur.role = 'coach'::text
    and not exists (
      select 1
      from public.users_coaches uc
      where uc.user_id = ur.user_id
    );

  insert into public.user_roles (
    user_id,
    role
  )
  select
    uc.user_id,
    'coach'::text
  from
    public.users_coaches uc
  where
    not exists (
      select 1
      from public.user_roles ur
      where ur.user_id = uc.user_id
        and ur.role = 'coach'::text
    );
end;
$$;


ALTER FUNCTION "public"."sync_coach_roles"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_coach_roles_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.sync_coach_roles();
  return null;
end;
$$;


ALTER FUNCTION "public"."sync_coach_roles_trigger"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_coach_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
    v_phone text;
    v_user_id text;
    v_name text;
begin
    if new.coach_phone is null or new.coach_phone = '' then
        return new;
    end if;

    v_phone := new.coach_phone;
    v_name  := coalesce(new.coach_name, v_phone);

    -- 1️⃣ verifica se já existe usuário com esse telefone
    select user_id
    into v_user_id
    from public.users
    where phone = v_phone
    limit 1;

    -- 2️⃣ se não existir, cria
    if v_user_id is null then
        v_user_id := 'user:' || v_phone;

        insert into public.users (user_id, name, phone)
        values (v_user_id, v_name, v_phone);
    end if;

    -- 3️⃣ garante role coach
    insert into public.user_roles (user_id, role)
    values (v_user_id, 'coach')
    on conflict do nothing;

    -- 4️⃣ garante credencial
    insert into public.user_credentials (user_id, phone, password_hash, must_change)
    values (
        v_user_id,
        v_phone,
        crypt(v_phone, gen_salt('bf')),
        true
    )
    on conflict (user_id) do nothing;

    return new;
end;
$$;


ALTER FUNCTION "public"."sync_coach_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_master_to_user_roles"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into public.user_roles (user_id, role)
  values (new.master_id, 'master')
  on conflict (user_id, role) do nothing;

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_master_to_user_roles"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_masters_to_auth"("p_force_reset_password" boolean DEFAULT false) RETURNS TABLE("synced_identities" integer, "synced_credentials" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_synced_identity integer := 0;
  v_synced_cred integer := 0;
begin
  if to_regclass('public.masters') is null then
    raise exception 'Tabela public.masters não existe.';
  end if;

  if p_force_reset_password then
    insert into public.users_identity (
      user_id,
      phone,
      password_hash,
      must_change,
      created_at,
      name,
      role,
      athlete_id,
      updated_at
    )
    select
      coalesce(nullif(trim(m.master_id::text), ''), regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g')) as user_id,
      regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g') as phone,
      crypt(regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g'), gen_salt('bf')) as password_hash,
      true as must_change,
      coalesce(m.created_at, now()) as created_at,
      coalesce(nullif(trim(m.name::text), ''), regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g')) as name,
      'MASTER' as role,
      null as athlete_id,
      now() as updated_at
    from public.masters m
    where regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g') <> ''
    on conflict (user_id) do update
    set
      phone = excluded.phone,
      password_hash = excluded.password_hash,
      must_change = true,
      name = excluded.name,
      role = excluded.role,
      updated_at = now();
  else
    insert into public.users_identity (
      user_id,
      phone,
      password_hash,
      must_change,
      created_at,
      name,
      role,
      athlete_id,
      updated_at
    )
    select
      coalesce(nullif(trim(m.master_id::text), ''), regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g')) as user_id,
      regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g') as phone,
      crypt(regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g'), gen_salt('bf')) as password_hash,
      true as must_change,
      coalesce(m.created_at, now()) as created_at,
      coalesce(nullif(trim(m.name::text), ''), regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g')) as name,
      'MASTER' as role,
      null as athlete_id,
      now() as updated_at
    from public.masters m
    where regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g') <> ''
    on conflict (user_id) do update
    set
      phone = excluded.phone,
      name = excluded.name,
      role = excluded.role,
      updated_at = now();
  end if;

  get diagnostics v_synced_identity = row_count;

  if p_force_reset_password then
    insert into public.user_credentials (
      user_id,
      phone,
      password_hash,
      must_change,
      created_at,
      updated_at
    )
    select
      coalesce(nullif(trim(m.master_id::text), ''), regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g')) as user_id,
      regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g') as phone,
      crypt(regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g'), gen_salt('bf')) as password_hash,
      true as must_change,
      coalesce(m.created_at, now()) as created_at,
      now() as updated_at
    from public.masters m
    where regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g') <> ''
    on conflict (user_id) do update
    set
      phone = excluded.phone,
      password_hash = excluded.password_hash,
      must_change = true,
      updated_at = now();
  else
    insert into public.user_credentials (
      user_id,
      phone,
      password_hash,
      must_change,
      created_at,
      updated_at
    )
    select
      coalesce(nullif(trim(m.master_id::text), ''), regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g')) as user_id,
      regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g') as phone,
      crypt(regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g'), gen_salt('bf')) as password_hash,
      true as must_change,
      coalesce(m.created_at, now()) as created_at,
      now() as updated_at
    from public.masters m
    where regexp_replace(coalesce(m.phone::text, ''), '\D', '', 'g') <> ''
    on conflict (user_id) do update
    set
      phone = excluded.phone,
      updated_at = now();
  end if;

  get diagnostics v_synced_cred = row_count;

  return query
  select v_synced_identity, v_synced_cred;
end;
$$;


ALTER FUNCTION "public"."sync_masters_to_auth"("p_force_reset_password" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_masters_to_login"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_count integer := 0;
begin
  insert into public.users_identity (
    user_id,
    name,
    phone,
    role,
    athlete_id
  )
  select
    regexp_replace(coalesce(m.phone, ''), '\D', '', 'g') as user_id,
    m.name,
    regexp_replace(coalesce(m.phone, ''), '\D', '', 'g') as phone,
    'MASTER' as role,
    null as athlete_id
  from public.masters m
  where coalesce(m.active, true) = true
    and coalesce(trim(m.phone), '') <> ''
  on conflict (user_id) do update
  set
    name = excluded.name,
    phone = excluded.phone,
    role = excluded.role,
    athlete_id = excluded.athlete_id;

  insert into public.user_credentials (
    user_id,
    phone,
    password_hash,
    must_change
  )
  select
    regexp_replace(coalesce(m.phone, ''), '\D', '', 'g') as user_id,
    regexp_replace(coalesce(m.phone, ''), '\D', '', 'g') as phone,
    crypt(regexp_replace(coalesce(m.phone, ''), '\D', '', 'g'), gen_salt('bf')) as password_hash,
    true as must_change
  from public.masters m
  where coalesce(m.active, true) = true
    and coalesce(trim(m.phone), '') <> ''
  on conflict (user_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."sync_masters_to_login"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_queue_sent"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin

update public.minds_webhook_queue
set sent = true
where
    athlete_id = new.athlete_id
    and questionnaire = new.notification_type
    and sent = false;

return new;

end;
$$;


ALTER FUNCTION "public"."sync_queue_sent"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_registration_coach"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  perform public.ensure_coach_user(new.coach_name, new.coach_phone);
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_registration_coach"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_registration_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if public.norm_phone(new.athlete_phone) <> '' then
    perform public.refresh_auth_credential_by_phone(new.athlete_phone, false);
  end if;

  if public.norm_phone(new.coach_phone) <> '' then
    perform public.refresh_auth_credential_by_phone(new.coach_phone, false);
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_registration_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_user_from_athlete_registration"("p_athlete_id" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_name text;
  v_phone text;
  v_email text;
  v_enabled boolean;
  v_existing_phone text;
  v_existing_email text;
begin
  -- pega o cadastro mais recente do atleta
  select
    coalesce(
      nullif(btrim(ar.athlete_name), ''),
      nullif(btrim(ar.payload ->> 'REG_NAME | Nome completo'), ''),
      ar.athlete_id
    ),
    public.norm_phone(ar.athlete_phone),
    nullif(lower(btrim(ar.payload ->> 'REG_ATHLETE_EMAIL | E-mail do atleta')), ''),
    coalesce(ar.athlete_enabled, false)
  into
    v_name,
    v_phone,
    v_email,
    v_enabled
  from public.athlete_registration ar
  where ar.athlete_id = p_athlete_id
  order by ar.data desc nulls last, ar.inserted_at desc nulls last, ar.id desc
  limit 1;

  -- se não existir mais cadastro para esse athlete_id, não cria/atualiza nada
  if not found then
    return;
  end if;

  -- evita conflito por telefone já usado por outro usuário
  if v_phone is not null then
    select u.user_id
    into v_existing_phone
    from public.users u
    where u.user_id <> p_athlete_id
      and public.norm_phone(u.phone) = v_phone
    limit 1;

    if v_existing_phone is not null then
      v_phone := null;
    end if;
  end if;

  -- evita conflito por email já usado por outro usuário
  if v_email is not null then
    select u.user_id
    into v_existing_email
    from public.users u
    where u.user_id <> p_athlete_id
      and lower(u.email) = v_email
    limit 1;

    if v_existing_email is not null then
      v_email := null;
    end if;
  end if;

  insert into public.users (
    user_id,
    name,
    phone,
    email,
    master_id,
    created_at,
    updated_at,
    account_active
  )
  values (
    p_athlete_id,
    v_name,
    v_phone,
    v_email,
    null,
    now(),
    now(),
    v_enabled
  )
  on conflict (user_id) do update
  set
    name = excluded.name,
    phone = coalesce(excluded.phone, public.users.phone),
    email = coalesce(excluded.email, public.users.email),
    updated_at = now(),
    account_active = case
      when excluded.account_active = true then true
      else public.users.account_active
    end;
end;
$$;


ALTER FUNCTION "public"."sync_user_from_athlete_registration"("p_athlete_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_user_phone"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- só tenta atualizar se a coluna existir no NEW
  begin
    update users
    set phone = coalesce(
      (to_jsonb(new)->>'phone'),
      (to_jsonb(new)->>'phone_e164')
    )
    where user_id = new.athlete_id;
  exception
    when others then
      -- não quebra o fluxo se campo não existir
      null;
  end;

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_user_phone"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_users_from_athlete_registration"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
    v_coach_phone text;
begin

    -- normalizar telefone treinador
    v_coach_phone := phone_digits(new.coach_phone);

    ------------------------------------------------
    -- COACH
    ------------------------------------------------

    if v_coach_phone is not null then

        insert into users(user_id,name,phone)
        values(v_coach_phone,new.coach_name,new.coach_phone)

        on conflict (user_id)
        do update set
            name = excluded.name,
            phone = excluded.phone;

        insert into user_roles(user_id,role)
        values(v_coach_phone,'coach')
        on conflict do nothing;

    end if;


    ------------------------------------------------
    -- ATHLETE
    ------------------------------------------------

    insert into users(user_id,name,phone)
    values(new.athlete_id,new.athlete_name,new.athlete_phone)

    on conflict (user_id)
    do update set
        name = excluded.name,
        phone = excluded.phone;

    insert into user_roles(user_id,role)
    values(new.athlete_id,'athlete')
    on conflict do nothing;


    ------------------------------------------------
    -- BILLING (CRIAR ASSINATURA BASE)
    ------------------------------------------------

    insert into billing_subscriptions(
        user_id,
        payment_status
    )
    values(
        new.athlete_id,
        'pending'
    )
    on conflict (user_id) do nothing;


    return new;

end;
$$;


ALTER FUNCTION "public"."sync_users_from_athlete_registration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end $$;


ALTER FUNCTION "public"."touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_recalc_user_from_user_roles"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if tg_op = 'INSERT' then
    perform public.recalc_user_account_active(NEW.user_id);
    return NEW;

  elsif tg_op = 'UPDATE' then
    if OLD.user_id is distinct from NEW.user_id then
      perform public.recalc_user_account_active(OLD.user_id);
    end if;

    perform public.recalc_user_account_active(NEW.user_id);
    return NEW;

  else
    perform public.recalc_user_account_active(OLD.user_id);
    return OLD;
  end if;
end;
$$;


ALTER FUNCTION "public"."trg_recalc_user_from_user_roles"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_sync_users_from_athlete_registration"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if tg_op = 'INSERT' then
    perform public.sync_user_from_athlete_registration(new.athlete_id);
    return new;
  elsif tg_op = 'UPDATE' then
    perform public.sync_user_from_athlete_registration(new.athlete_id);

    if old.athlete_id is distinct from new.athlete_id then
      perform public.sync_user_from_athlete_registration(old.athlete_id);
    end if;

    return new;
  elsif tg_op = 'DELETE' then
    perform public.sync_user_from_athlete_registration(old.athlete_id);
    return old;
  end if;

  return null;
end;
$$;


ALTER FUNCTION "public"."trg_sync_users_from_athlete_registration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_athlete_private_notes_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_athlete_private_notes_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_pingo_last_state"("p_user_id" "text", "p_last_coach_phone" "text", "p_last_athlete_id" "text", "p_last_athlete_name" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  update pingo_chat_context
  set
    last_coach_phone = p_last_coach_phone,
    last_athlete_id = p_last_athlete_id,
    last_athlete_name = p_last_athlete_name,
    updated_at = now()
  where user_id = p_user_id;
end;
$$;


ALTER FUNCTION "public"."update_pingo_last_state"("p_user_id" "text", "p_last_coach_phone" "text", "p_last_athlete_id" "text", "p_last_athlete_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_user_account_status"() RETURNS "void"
    LANGUAGE "sql"
    AS $$

update users u
set account_active =
case
when b.payment_status = 'active'
and b.next_due_date >= now()::date
then true
else false
end
from billing_subscriptions b
where u.user_id = b.user_id;

$$;


ALTER FUNCTION "public"."update_user_account_status"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."construcional_analysis" (
    "id" bigint NOT NULL,
    "construcional_raw_id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "analyzed_at" timestamp with time zone DEFAULT "now"(),
    "repertorio_protetor" "text",
    "repertorio_risco" "text",
    "apoio_ambiental" "text",
    "claridade_metas" "text",
    "model_name" "text",
    "confidence" numeric,
    "explanation" "jsonb"
);


ALTER TABLE "public"."construcional_analysis" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_construcional_analysis"("p_construcional_raw_id" bigint, "p_athlete_id" "text", "p_repertorio_protetor" "text", "p_repertorio_risco" "text", "p_apoio_ambiental" "text", "p_claridade_metas" "text", "p_model_name" "text" DEFAULT NULL::"text", "p_confidence" numeric DEFAULT NULL::numeric, "p_explanation" "jsonb" DEFAULT NULL::"jsonb") RETURNS "public"."construcional_analysis"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_row construcional_analysis;
begin
  insert into construcional_analysis(
    construcional_raw_id, athlete_id,
    repertorio_protetor, repertorio_risco, apoio_ambiental, claridade_metas,
    model_name, confidence, explanation
  )
  values (
    p_construcional_raw_id, p_athlete_id,
    p_repertorio_protetor, p_repertorio_risco, p_apoio_ambiental, p_claridade_metas,
    p_model_name, p_confidence, p_explanation
  )
  returning * into v_row;

  update construcional_raw
  set status = 'analyzed', last_error = null
  where id = p_construcional_raw_id;

  return v_row;
end $$;


ALTER FUNCTION "public"."upsert_construcional_analysis"("p_construcional_raw_id" bigint, "p_athlete_id" "text", "p_repertorio_protetor" "text", "p_repertorio_risco" "text", "p_apoio_ambiental" "text", "p_claridade_metas" "text", "p_model_name" "text", "p_confidence" numeric, "p_explanation" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_construcional_analysis_bigint"("p_construcional_raw_id" bigint, "p_athlete_id" "text", "p_repertorio_protetor" "text", "p_repertorio_risco" "text", "p_apoio_ambiental" "text", "p_claridade_metas" "text", "p_model_name" "text" DEFAULT NULL::"text", "p_confidence" numeric DEFAULT NULL::numeric, "p_explanation" "jsonb" DEFAULT NULL::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into construcional_analysis(
    construcional_raw_id, athlete_id,
    repertorio_protetor, repertorio_risco, apoio_ambiental, claridade_metas,
    model_name, confidence, explanation
  )
  values (
    p_construcional_raw_id, p_athlete_id,
    p_repertorio_protetor, p_repertorio_risco, p_apoio_ambiental, p_claridade_metas,
    p_model_name, p_confidence, p_explanation
  );

  update construcional_raw
  set status = 'analyzed', last_error = null
  where id = p_construcional_raw_id;
end $$;


ALTER FUNCTION "public"."upsert_construcional_analysis_bigint"("p_construcional_raw_id" bigint, "p_athlete_id" "text", "p_repertorio_protetor" "text", "p_repertorio_risco" "text", "p_apoio_ambiental" "text", "p_claridade_metas" "text", "p_model_name" "text", "p_confidence" numeric, "p_explanation" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_pingo_scoring_output"("p_athlete_id" "text", "p_reference_date" "date", "p_attention_level" integer, "p_flag_count" integer, "p_flags" "jsonb", "p_rules_triggered" "jsonb" DEFAULT '[]'::"jsonb", "p_thresholds_used" "jsonb" DEFAULT '{}'::"jsonb", "p_summary" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into pingo_scoring_output(
    athlete_id, reference_date, attention_level, flag_count,
    flags, rules_triggered, thresholds_used, summary
  )
  values (
    p_athlete_id, p_reference_date, p_attention_level, p_flag_count,
    coalesce(p_flags, '[]'::jsonb),
    coalesce(p_rules_triggered, '[]'::jsonb),
    coalesce(p_thresholds_used, '{}'::jsonb),
    p_summary
  )
  on conflict (athlete_id, reference_date)
  do update set
    attention_level = excluded.attention_level,
    flag_count = excluded.flag_count,
    flags = excluded.flags,
    rules_triggered = excluded.rules_triggered,
    thresholds_used = excluded.thresholds_used,
    summary = excluded.summary,
    created_at = now();
end $$;


ALTER FUNCTION "public"."upsert_pingo_scoring_output"("p_athlete_id" "text", "p_reference_date" "date", "p_attention_level" integer, "p_flag_count" integer, "p_flags" "jsonb", "p_rules_triggered" "jsonb", "p_thresholds_used" "jsonb", "p_summary" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "integration"."outbox" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "schema_name" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "op" "text" NOT NULL,
    "pk" "jsonb",
    "old_row" "jsonb",
    "new_row" "jsonb",
    "txid" bigint DEFAULT "txid_current"() NOT NULL,
    "reserved_until" timestamp with time zone,
    "last_attempt_at" timestamp with time zone,
    "delivery_attempts" integer DEFAULT 0 NOT NULL,
    "delivered_at" timestamp with time zone,
    "last_error" "text",
    CONSTRAINT "outbox_op_check" CHECK (("op" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "integration"."outbox" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."acsi_analysis_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."acsi_analysis_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."acsi_analysis_id_seq" OWNED BY "public"."acsi_analysis"."id";



CREATE OR REPLACE VIEW "public"."acsi_analysis_view" WITH ("security_invoker"='true') AS
 SELECT "id",
    "athlete_id",
    "data",
    "media",
    "metas_preparacao",
    "relacao_treinador",
    "concentracao",
    "confianca_motivacao",
    "pico_pressao",
    "adversidade",
    "ausencia_preocupacao",
    "inserted_at",
    (("media" - "avg"("media") OVER (PARTITION BY "athlete_id")) / NULLIF("stddev_samp"("media") OVER (PARTITION BY "athlete_id"), (0)::numeric)) AS "media_z"
   FROM "public"."acsi_analysis" "a";


ALTER VIEW "public"."acsi_analysis_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."diet_daily" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "data" "date" NOT NULL,
    "adherence_score" numeric,
    "gi_distress" numeric,
    "inserted_at" timestamp with time zone DEFAULT "now"(),
    "kind" "text",
    "master_sheet_id" "text",
    "payload" "jsonb",
    "source" "text",
    "weight_kg" numeric
);


ALTER TABLE "public"."diet_daily" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."api_daily_pre_post" WITH ("security_invoker"='true') AS
 WITH "d" AS (
         SELECT "diet_daily"."athlete_id",
            "diet_daily"."kind",
            "diet_daily"."inserted_at",
            (("diet_daily"."inserted_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "ref_date",
            "diet_daily"."payload"
           FROM "public"."diet_daily"
          WHERE ("diet_daily"."kind" = ANY (ARRAY['daily_pre'::"text", 'daily_post'::"text"]))
        ), "pre" AS (
         SELECT "d"."athlete_id",
            "d"."ref_date",
            "d"."inserted_at" AS "pre_at"
           FROM "d"
          WHERE ("d"."kind" = 'daily_pre'::"text")
        ), "pos" AS (
         SELECT "d"."athlete_id",
            "d"."ref_date",
            "d"."inserted_at" AS "post_at"
           FROM "d"
          WHERE ("d"."kind" = 'daily_post'::"text")
        )
 SELECT COALESCE("pre"."athlete_id", "pos"."athlete_id") AS "athlete_id",
    COALESCE("pre"."ref_date", "pos"."ref_date") AS "reference_date",
    "pre"."pre_at",
    "pos"."post_at",
    ("pre"."pre_at" IS NOT NULL) AS "has_pre",
    ("pos"."post_at" IS NOT NULL) AS "has_post"
   FROM ("pre"
     FULL JOIN "pos" ON ((("pre"."athlete_id" = "pos"."athlete_id") AND ("pre"."ref_date" = "pos"."ref_date"))));


ALTER VIEW "public"."api_daily_pre_post" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pingo_scoring_output" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "reference_date" "date" NOT NULL,
    "attention_level" integer NOT NULL,
    "flag_count" integer NOT NULL,
    "flags" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "rules_triggered" "jsonb" DEFAULT '[]'::"jsonb",
    "thresholds_used" "jsonb" DEFAULT '{}'::"jsonb",
    "summary" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "kind" "text",
    "master_sheet_id" "text",
    "payload" "jsonb",
    "source" "text",
    "flag_generated_at" timestamp with time zone DEFAULT "now"(),
    "flag_valid_until" timestamp with time zone
);


ALTER TABLE "public"."pingo_scoring_output" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."api_flags_events" WITH ("security_invoker"='true') AS
 SELECT "pso"."id",
    "pso"."athlete_id",
    "ar"."athlete_name",
    "ar"."team_name",
    "ar"."athlete_phone",
    "pso"."reference_date",
    "pso"."attention_level",
    "pso"."flag_count",
    "pso"."flags",
    "pso"."rules_triggered",
    "pso"."thresholds_used"
   FROM ("public"."pingo_scoring_output" "pso"
     LEFT JOIN LATERAL ( SELECT "ar2"."athlete_name",
            "ar2"."team_name",
            "ar2"."athlete_phone"
           FROM "public"."athlete_registration" "ar2"
          WHERE ("ar2"."athlete_id" = "pso"."athlete_id")
          ORDER BY "ar2"."inserted_at" DESC NULLS LAST
         LIMIT 1) "ar" ON (true));


ALTER VIEW "public"."api_flags_events" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."api_scoring_latest" AS
 SELECT DISTINCT ON ("athlete_id") "id",
    "athlete_id",
    "reference_date",
    "attention_level",
    "flag_count",
    "flags",
    "rules_triggered",
    "thresholds_used",
    "summary",
    "created_at",
    "kind",
    "master_sheet_id",
    "payload",
    "source"
   FROM "public"."pingo_scoring_output"
  WHERE (("attention_level" > 0) AND ("created_at" >= ("now"() - '7 days'::interval)))
  ORDER BY "athlete_id", "created_at" DESC;


ALTER VIEW "public"."api_scoring_latest" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."api_teams" WITH ("security_invoker"='true') AS
 SELECT "team_name",
    "count"(DISTINCT "athlete_id") AS "athlete_count"
   FROM "public"."athlete_registration"
  WHERE ("team_name" IS NOT NULL)
  GROUP BY "team_name"
  ORDER BY "team_name";


ALTER VIEW "public"."api_teams" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "user_id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "phone" "text",
    "email" "text",
    "master_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "account_active" boolean DEFAULT false,
    "human_mode_until" timestamp with time zone
);


ALTER TABLE "public"."users" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."athlete_access_status" AS
 SELECT "reg"."athlete_id",
    "reg"."athlete_name",
    "reg"."athlete_enabled",
    "u"."account_active",
        CASE
            WHEN ("reg"."athlete_enabled" = true) THEN 'manual_release'::"text"
            WHEN ("u"."account_active" = true) THEN 'paid'::"text"
            ELSE 'blocked'::"text"
        END AS "access_status"
   FROM ("public"."athlete_registration" "reg"
     LEFT JOIN "public"."users" "u" ON (("u"."user_id" = "reg"."athlete_id")));


ALTER VIEW "public"."athlete_access_status" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pmcsq_analysis" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "data" "date",
    "clima_tarefa" numeric,
    "clima_ego" numeric,
    "coletivo" numeric,
    "clima_treino_desafiador" numeric,
    "clima_ego_preferido" numeric,
    "punicao_erros" numeric,
    "inserted_at" timestamp with time zone DEFAULT "now"(),
    "kind" "text",
    "master_sheet_id" "text",
    "payload" "jsonb",
    "source" "text"
);


ALTER TABLE "public"."pmcsq_analysis" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."restq_analysis" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "data" "date",
    "inserted_at" timestamp with time zone DEFAULT "now"(),
    "kind" "text",
    "master_sheet_id" "text",
    "payload" "jsonb",
    "trainer_id" "text",
    "source" "text",
    "general_stress" numeric,
    "emotional_stress" numeric,
    "social_stress" numeric,
    "fatigueREST" numeric,
    "lack_energy" numeric,
    "physical_complaints" numeric,
    "disturbed_breaks" numeric,
    "sleep_quality" numeric,
    "physical_recovery" numeric,
    "general_wellbeing" numeric,
    "self_efficacy" numeric,
    "being_in_shape" numeric,
    "stress_index" numeric,
    "recovery_index" numeric,
    "balance" numeric,
    "media" numeric
);


ALTER TABLE "public"."restq_analysis" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."athlete_event_days" WITH ("security_invoker"='true') AS
 SELECT "brums_analysis"."athlete_id",
    "brums_analysis"."data"
   FROM "public"."brums_analysis"
UNION
 SELECT "diet_daily"."athlete_id",
    "diet_daily"."data"
   FROM "public"."diet_daily"
UNION
 SELECT "acsi_analysis"."athlete_id",
    "acsi_analysis"."data"
   FROM "public"."acsi_analysis"
UNION
 SELECT "pmcsq_analysis"."athlete_id",
    "pmcsq_analysis"."data"
   FROM "public"."pmcsq_analysis"
UNION
 SELECT "restq_analysis"."athlete_id",
    "restq_analysis"."data"
   FROM "public"."restq_analysis"
UNION
 SELECT "weekly_analysis"."athlete_id",
    "weekly_analysis"."start_date" AS "data"
   FROM "public"."weekly_analysis";


ALTER VIEW "public"."athlete_event_days" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."athlete_latest_view" WITH ("security_invoker"='true') AS
 SELECT DISTINCT ON ("athlete_id") "athlete_id",
    "athlete_name",
    "team_name",
    "athlete_phone",
    "coach_phone",
    "inserted_at"
   FROM "public"."athlete_registration" "ar"
  WHERE ("athlete_id" IS NOT NULL)
  ORDER BY "athlete_id", "inserted_at" DESC;


ALTER VIEW "public"."athlete_latest_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."athlete_master_notes" (
    "athlete_id" "text" NOT NULL,
    "note_text" "text",
    "updated_by" "text",
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."athlete_master_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."athlete_private_notes" (
    "athlete_id" "text" NOT NULL,
    "author_user_id" "text" NOT NULL,
    "author_role" "text" NOT NULL,
    "note_scope" "text" NOT NULL,
    "note_text" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "athlete_private_notes_note_scope_check" CHECK (("note_scope" = ANY (ARRAY['MASTER_UNIVERSAL'::"text", 'COACH_UNIVERSAL'::"text"])))
);


ALTER TABLE "public"."athlete_private_notes" OWNER TO "postgres";


COMMENT ON TABLE "public"."athlete_private_notes" IS 'Private notes for athletes with MASTER_UNIVERSAL and COACH_UNIVERSAL scopes';



COMMENT ON COLUMN "public"."athlete_private_notes"."note_scope" IS 'MASTER_UNIVERSAL: visible to all masters; COACH_UNIVERSAL: visible to masters and coaches with access to athlete';



CREATE SEQUENCE IF NOT EXISTS "public"."athlete_registration_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."athlete_registration_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."athlete_registration_id_seq" OWNED BY "public"."athlete_registration"."id";



CREATE TABLE IF NOT EXISTS "public"."billing_subscriptions" (
    "user_id" "text" NOT NULL,
    "asaas_customer_id" "text",
    "asaas_subscription_id" "text",
    "payment_status" "text" DEFAULT 'pending'::"text",
    "next_due_date" "date",
    "last_payment" "date",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "plan" "text"
);


ALTER TABLE "public"."billing_subscriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."billing_subscriptions_backup" (
    "user_id" "text",
    "asaas_customer_id" "text",
    "asaas_subscription_id" "text",
    "payment_status" "text",
    "next_due_date" "date",
    "last_payment" "date",
    "created_at" timestamp without time zone,
    "updated_at" timestamp without time zone,
    "plan" "text"
);


ALTER TABLE "public"."billing_subscriptions_backup" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."brums_analysis_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."brums_analysis_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."brums_analysis_id_seq" OWNED BY "public"."brums_analysis"."id";



CREATE OR REPLACE VIEW "public"."brums_analysis_view" AS
 WITH "base" AS (
         SELECT "b"."id",
            "b"."athlete_id",
            "b"."data",
            "b"."dth",
            "b"."vigor",
            "b"."dth_minus",
            "b"."inserted_at",
            "b"."tension",
            "b"."depression",
            "b"."anger",
            "b"."fatigue",
            "b"."confusion",
            "b"."vigor" AS "vigor_num",
            "b"."dth" AS "dth_num"
           FROM "public"."brums_analysis" "b"
        ), "baseline" AS (
         SELECT "base"."athlete_id",
            "avg"("base"."vigor_num") AS "vigor_mean",
            "stddev"("base"."vigor_num") AS "vigor_sd",
            "avg"("base"."dth_num") AS "dth_mean",
            "stddev"("base"."dth_num") AS "dth_sd"
           FROM "base"
          GROUP BY "base"."athlete_id"
        ), "zscores" AS (
         SELECT "b"."id",
            "b"."athlete_id",
            "b"."data",
            "b"."dth",
            "b"."vigor",
            "b"."dth_minus",
            "b"."inserted_at",
            "b"."tension",
            "b"."depression",
            "b"."anger",
            "b"."fatigue",
            "b"."confusion",
            "b"."vigor_num",
            "b"."dth_num",
            (("b"."vigor_num" - "bl"."vigor_mean") / NULLIF("bl"."vigor_sd", (0)::numeric)) AS "vigor_z",
            (("b"."dth_num" - "bl"."dth_mean") / NULLIF("bl"."dth_sd", (0)::numeric)) AS "dth_z"
           FROM ("base" "b"
             LEFT JOIN "baseline" "bl" USING ("athlete_id"))
        ), "temporal" AS (
         SELECT "z"."id",
            "z"."athlete_id",
            "z"."data",
            "z"."dth",
            "z"."vigor",
            "z"."dth_minus",
            "z"."inserted_at",
            "z"."tension",
            "z"."depression",
            "z"."anger",
            "z"."fatigue",
            "z"."confusion",
            "z"."vigor_num",
            "z"."dth_num",
            "z"."vigor_z",
            "z"."dth_z",
            "lag"("z"."vigor_z") OVER (PARTITION BY "z"."athlete_id" ORDER BY "z"."data") AS "vigor_prev",
            "lag"("z"."dth_z") OVER (PARTITION BY "z"."athlete_id" ORDER BY "z"."data") AS "dth_prev",
            "stddev"("z"."vigor_z") OVER (PARTITION BY "z"."athlete_id" ORDER BY "z"."data" ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS "vigor_volatility",
            "stddev"("z"."dth_z") OVER (PARTITION BY "z"."athlete_id" ORDER BY "z"."data" ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS "dth_volatility",
            "count"(*) OVER (PARTITION BY "z"."athlete_id" ORDER BY "z"."data" ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS "brums_entries"
           FROM "zscores" "z"
        ), "derived" AS (
         SELECT "t"."id",
            "t"."athlete_id",
            "t"."data",
            "t"."dth",
            "t"."vigor",
            "t"."dth_minus",
            "t"."inserted_at",
            "t"."tension",
            "t"."depression",
            "t"."anger",
            "t"."fatigue",
            "t"."confusion",
            "t"."vigor_num",
            "t"."dth_num",
            "t"."vigor_z",
            "t"."dth_z",
            "t"."vigor_prev",
            "t"."dth_prev",
            "t"."vigor_volatility",
            "t"."dth_volatility",
            "t"."brums_entries",
            ("t"."vigor_z" - "t"."vigor_prev") AS "vigor_delta_1d",
            ("t"."dth_z" - "t"."dth_prev") AS "dth_delta_1d"
           FROM "temporal" "t"
        ), "profiles" AS (
         SELECT "d"."id",
            "d"."athlete_id",
            "d"."data",
            "d"."dth",
            "d"."vigor",
            "d"."dth_minus",
            "d"."inserted_at",
            "d"."tension",
            "d"."depression",
            "d"."anger",
            "d"."fatigue",
            "d"."confusion",
            "d"."vigor_num",
            "d"."dth_num",
            "d"."vigor_z",
            "d"."dth_z",
            "d"."vigor_prev",
            "d"."dth_prev",
            "d"."vigor_volatility",
            "d"."dth_volatility",
            "d"."brums_entries",
            "d"."vigor_delta_1d",
            "d"."dth_delta_1d",
                CASE
                    WHEN (("d"."vigor_z" > (0)::numeric) AND ("d"."dth_z" < (0)::numeric)) THEN true
                    ELSE false
                END AS "pattern_iceberg",
                CASE
                    WHEN (("d"."vigor_z" < ('-1'::integer)::numeric) AND ("d"."dth_z" > (1)::numeric)) THEN true
                    ELSE false
                END AS "pattern_burnout",
                CASE
                    WHEN (("d"."vigor_z" > (2)::numeric) AND ("d"."dth_z" < ('-1'::integer)::numeric)) THEN true
                    ELSE false
                END AS "pattern_hyperactivation",
                CASE
                    WHEN (("d"."vigor_z" < ('-1'::integer)::numeric) AND ("d"."dth_z" < ('-1'::integer)::numeric)) THEN true
                    ELSE false
                END AS "pattern_flat"
           FROM "derived" "d"
        )
 SELECT "athlete_id",
    "data",
    "inserted_at",
    "vigor",
    "tension",
    "depression",
    "anger",
    "fatigue",
    "confusion",
    "dth",
    "dth_minus",
    "round"("vigor_z", 2) AS "vigor_z",
    "round"("dth_z", 2) AS "dth_z",
    NULLIF("round"("vigor_delta_1d", 2), (0)::numeric) AS "vigor_delta_1d",
    NULLIF("round"("dth_delta_1d", 2), (0)::numeric) AS "dth_delta_1d",
    "round"("vigor_volatility", 2) AS "vigor_volatility",
    "round"("dth_volatility", 2) AS "dth_volatility",
    "brums_entries",
    "pattern_iceberg",
    "pattern_burnout",
    "pattern_hyperactivation",
    "pattern_flat"
   FROM "profiles";


ALTER VIEW "public"."brums_analysis_view" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."cbas_analysis_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."cbas_analysis_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."cbas_analysis_id_seq" OWNED BY "public"."cbas_analysis"."id";



CREATE OR REPLACE VIEW "public"."cbas_analysis_view" AS
 SELECT "athlete_id",
    "data",
    "tecnica",
    "planejamento",
    "motivacional",
    "relacao",
    "aversivos",
    "payload"
   FROM "public"."cbas_analysis";


ALTER VIEW "public"."cbas_analysis_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."coach_athletes" (
    "coach_id" "text" NOT NULL,
    "athlete_id" "text" NOT NULL,
    "master_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."coach_athletes" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."construcional_analysis_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."construcional_analysis_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."construcional_analysis_id_seq" OWNED BY "public"."construcional_analysis"."id";



CREATE OR REPLACE VIEW "public"."construcional_analysis_view" WITH ("security_invoker"='true') AS
 SELECT "id",
    "construcional_raw_id",
    "athlete_id",
    "analyzed_at",
    "repertorio_protetor",
    "repertorio_risco",
    "apoio_ambiental",
    "claridade_metas",
    "model_name",
    "confidence",
    "explanation"
   FROM "public"."construcional_analysis" "c";


ALTER VIEW "public"."construcional_analysis_view" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."construcional_raw_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."construcional_raw_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."construcional_raw_id_seq" OWNED BY "public"."construcional_raw"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."diet_daily_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."diet_daily_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."diet_daily_id_seq" OWNED BY "public"."diet_daily"."id";



CREATE TABLE IF NOT EXISTS "public"."gses_analysis" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "data" "date",
    "media" numeric,
    "inserted_at" timestamp with time zone DEFAULT "now"(),
    "kind" "text",
    "master_sheet_id" "text",
    "payload" "jsonb",
    "source" "text",
    "classification" "text"
);


ALTER TABLE "public"."gses_analysis" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."gses_analysis_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."gses_analysis_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."gses_analysis_id_seq" OWNED BY "public"."gses_analysis"."id";



CREATE OR REPLACE VIEW "public"."gses_analysis_view" AS
 SELECT "athlete_id",
    "data",
    "inserted_at",
    "media" AS "gses_media",
    "classification",
    "payload",
    "kind",
    "source",
    "master_sheet_id"
   FROM "public"."gses_analysis";


ALTER VIEW "public"."gses_analysis_view" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."horizons_snapshot_manifest" AS
 SELECT "n"."nspname" AS "schema_name",
    "c"."relname" AS "table_name",
        CASE
            WHEN ("c"."reltuples" < (0)::double precision) THEN NULL::bigint
            ELSE ("c"."reltuples")::bigint
        END AS "estimated_rows"
   FROM ("pg_class" "c"
     JOIN "pg_namespace" "n" ON (("n"."oid" = "c"."relnamespace")))
  WHERE (("n"."nspname" = 'public'::"name") AND ("c"."relkind" = ANY (ARRAY['r'::"char", 'p'::"char"])))
  ORDER BY "n"."nspname", "c"."relname";


ALTER VIEW "public"."horizons_snapshot_manifest" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."masters" (
    "master_id" "text" NOT NULL,
    "name" "text",
    "phone" "text",
    "email" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."masters" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."minds_adherence_dashboard" AS
 WITH "responses" AS (
         SELECT "brums_analysis"."athlete_id",
            'pre'::"text" AS "questionnaire",
            "brums_analysis"."inserted_at" AS "response_time"
           FROM "public"."brums_analysis"
        UNION ALL
         SELECT "weekly_analysis"."athlete_id",
            'weekly'::"text",
            "weekly_analysis"."inserted_at"
           FROM "public"."weekly_analysis"
        UNION ALL
         SELECT "acsi_analysis"."athlete_id",
            'quarterly'::"text",
            "acsi_analysis"."inserted_at"
           FROM "public"."acsi_analysis"
        UNION ALL
         SELECT "cbas_analysis"."athlete_id",
            'semiannual'::"text",
            "cbas_analysis"."inserted_at"
           FROM "public"."cbas_analysis"
        UNION ALL
         SELECT "construcional_raw"."athlete_id",
            'construcional'::"text",
            "construcional_raw"."submitted_at"
           FROM "public"."construcional_raw"
        ), "sent" AS (
         SELECT "minds_notification_log"."athlete_id",
            "minds_notification_log"."notification_type" AS "questionnaire",
            "minds_notification_log"."sent_at"
           FROM "public"."minds_notification_log"
        ), "joined" AS (
         SELECT "s"."athlete_id",
            "s"."questionnaire",
            "s"."sent_at",
            "min"("r"."response_time") AS "response_time"
           FROM ("sent" "s"
             LEFT JOIN "responses" "r" ON ((("r"."athlete_id" = "s"."athlete_id") AND ("r"."questionnaire" = "s"."questionnaire") AND ("r"."response_time" >= "s"."sent_at"))))
          GROUP BY "s"."athlete_id", "s"."questionnaire", "s"."sent_at"
        )
 SELECT "a"."athlete_id",
    "a"."athlete_name",
    "j"."questionnaire",
    "count"(*) AS "questionnaires_sent",
    "count"("j"."response_time") AS "questionnaires_answered",
    "count"(*) FILTER (WHERE (("j"."response_time")::"date" = ("j"."sent_at")::"date")) AS "answered_same_day",
    "count"(*) FILTER (WHERE (("j"."response_time")::"date" > ("j"."sent_at")::"date")) AS "answered_late",
    "count"(*) FILTER (WHERE ("j"."response_time" IS NULL)) AS "not_answered",
    "round"(((100.0 * ("count"("j"."response_time"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "adherence_percent"
   FROM ("public"."api_athletes" "a"
     LEFT JOIN "joined" "j" ON (("j"."athlete_id" = "a"."athlete_id")))
  GROUP BY "a"."athlete_id", "a"."athlete_name", "j"."questionnaire";


ALTER VIEW "public"."minds_adherence_dashboard" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."minds_athlete_delivery_state" (
    "athlete_id" "text" NOT NULL,
    "send_state" "text" DEFAULT 'active'::"text" NOT NULL,
    "auto_hibernated" boolean DEFAULT false NOT NULL,
    "reason" "text",
    "hibernated_at" timestamp with time zone,
    "reactivated_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "minds_athlete_delivery_state_chk" CHECK (("send_state" = ANY (ARRAY['active'::"text", 'hibernated'::"text"])))
);


ALTER TABLE "public"."minds_athlete_delivery_state" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."minds_engagement_timeline" AS
 WITH "responses" AS (
         SELECT "brums_analysis"."athlete_id",
            'pre'::"text" AS "questionnaire",
            "brums_analysis"."inserted_at" AS "response_time"
           FROM "public"."brums_analysis"
        UNION ALL
         SELECT "weekly_analysis"."athlete_id",
            'weekly'::"text",
            "weekly_analysis"."inserted_at"
           FROM "public"."weekly_analysis"
        UNION ALL
         SELECT "acsi_analysis"."athlete_id",
            'quarterly'::"text",
            "acsi_analysis"."inserted_at"
           FROM "public"."acsi_analysis"
        UNION ALL
         SELECT "cbas_analysis"."athlete_id",
            'semiannual'::"text",
            "cbas_analysis"."inserted_at"
           FROM "public"."cbas_analysis"
        UNION ALL
         SELECT "construcional_raw"."athlete_id",
            'construcional'::"text",
            "construcional_raw"."submitted_at"
           FROM "public"."construcional_raw"
        ), "sent" AS (
         SELECT "minds_notification_log"."athlete_id",
            "minds_notification_log"."notification_type" AS "questionnaire",
            "minds_notification_log"."sent_at"
           FROM "public"."minds_notification_log"
        ), "joined" AS (
         SELECT "s"."athlete_id",
            "s"."questionnaire",
            "s"."sent_at",
            "min"("r"."response_time") AS "response_time"
           FROM ("sent" "s"
             LEFT JOIN "responses" "r" ON ((("r"."athlete_id" = "s"."athlete_id") AND ("r"."questionnaire" = "s"."questionnaire") AND ("r"."response_time" >= "s"."sent_at"))))
          GROUP BY "s"."athlete_id", "s"."questionnaire", "s"."sent_at"
        )
 SELECT "a"."athlete_id",
    "a"."athlete_name",
    "j"."questionnaire",
    "j"."sent_at" AS "questionnaire_sent",
    "j"."response_time" AS "questionnaire_answered",
        CASE
            WHEN ("j"."response_time" IS NULL) THEN 'not_answered'::"text"
            WHEN (("j"."response_time")::"date" = ("j"."sent_at")::"date") THEN 'answered_same_day'::"text"
            ELSE 'answered_late'::"text"
        END AS "response_status",
    (EXTRACT(epoch FROM ("j"."response_time" - "j"."sent_at")) / (60)::numeric) AS "response_minutes"
   FROM ("joined" "j"
     JOIN "public"."api_athletes" "a" ON (("a"."athlete_id" = "j"."athlete_id")))
  ORDER BY "a"."athlete_name", "j"."sent_at" DESC;


ALTER VIEW "public"."minds_engagement_timeline" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."minds_next_notifications" AS
 SELECT "athlete_id",
    "athlete_name",
    "athlete_phone",
    "action_type",
    "priority_rank",
    "escalation_level",
    "due_at"
   FROM "public"."rpc_minds_cron_priority"() "rpc_minds_cron_priority"("athlete_id", "athlete_name", "athlete_phone", "action_type", "priority_rank", "escalation_level", "due_at");


ALTER VIEW "public"."minds_next_notifications" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."minds_notification_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."minds_notification_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."minds_notification_log_id_seq" OWNED BY "public"."minds_notification_log"."id";



CREATE TABLE IF NOT EXISTS "public"."minds_notification_queue" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "athlete_name" "text",
    "athlete_phone" "text",
    "action_type" "text" NOT NULL,
    "priority_rank" integer DEFAULT 1 NOT NULL,
    "escalation_level" integer DEFAULT 0,
    "due_at" timestamp with time zone DEFAULT "now"(),
    "team_name" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "max_attempts" integer DEFAULT 5 NOT NULL,
    "next_retry_at" timestamp with time zone,
    "last_error" "text",
    "request_id" bigint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sent_at" timestamp with time zone,
    "created_day" "date"
);


ALTER TABLE "public"."minds_notification_queue" OWNER TO "postgres";


ALTER TABLE "public"."minds_notification_queue" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."minds_notification_queue_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."restq_analysis_view" AS
 SELECT "id",
    "athlete_id",
    "data",
    "media",
    "inserted_at",
    "payload",
    "general_stress",
    "emotional_stress",
    "social_stress",
    "fatigueREST",
    "lack_energy",
    "physical_complaints",
    "disturbed_breaks",
    "sleep_quality",
    "physical_recovery",
    "general_wellbeing",
    "self_efficacy",
    "being_in_shape",
    "stress_index",
    "recovery_index",
    "balance",
    (("media" - "avg"("media") OVER (PARTITION BY "athlete_id")) / NULLIF("stddev_samp"("media") OVER (PARTITION BY "athlete_id"), (0)::numeric)) AS "media_z",
    (("stress_index" - "avg"("stress_index") OVER (PARTITION BY "athlete_id")) / NULLIF("stddev_samp"("stress_index") OVER (PARTITION BY "athlete_id"), (0)::numeric)) AS "stress_z",
    (("recovery_index" - "avg"("recovery_index") OVER (PARTITION BY "athlete_id")) / NULLIF("stddev_samp"("recovery_index") OVER (PARTITION BY "athlete_id"), (0)::numeric)) AS "recovery_z",
    (("balance" - "avg"("balance") OVER (PARTITION BY "athlete_id")) / NULLIF("stddev_samp"("balance") OVER (PARTITION BY "athlete_id"), (0)::numeric)) AS "balance_z"
   FROM "public"."restq_analysis" "r";


ALTER VIEW "public"."restq_analysis_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."training_load_daily" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "data" "date" NOT NULL,
    "rpe" numeric,
    "duration_min" numeric,
    "srpe_load" numeric,
    "kind" "text" DEFAULT 'daily_post'::"text",
    "payload" "jsonb",
    "source" "text" DEFAULT 'master_sheet'::"text",
    "master_sheet_id" "text",
    "inserted_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."training_load_daily" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."minds_overview" AS
 WITH "last_sent" AS (
         SELECT "minds_notification_log"."athlete_id",
            "max"("minds_notification_log"."sent_at") AS "last_sent",
            "count"(*) AS "total_sent"
           FROM "public"."minds_notification_log"
          GROUP BY "minds_notification_log"."athlete_id"
        ), "responses" AS (
         SELECT "minds_last_response"."athlete_id",
            "max"("minds_last_response"."last_response") AS "last_response"
           FROM "public"."minds_last_response"
          GROUP BY "minds_last_response"."athlete_id"
        ), "queue" AS (
         SELECT "minds_notification_queue"."athlete_id",
            "minds_notification_queue"."action_type",
            "minds_notification_queue"."status",
            "minds_notification_queue"."priority_rank",
            "minds_notification_queue"."next_retry_at"
           FROM "public"."minds_notification_queue"
          WHERE ("minds_notification_queue"."status" = 'pending'::"text")
        ), "last_pre" AS (
         SELECT DISTINCT ON ("brums_analysis"."athlete_id") "brums_analysis"."athlete_id",
            "brums_analysis"."data" AS "pre_date",
            "brums_analysis"."inserted_at" AS "pre_time"
           FROM "public"."brums_analysis"
          ORDER BY "brums_analysis"."athlete_id", "brums_analysis"."inserted_at" DESC
        ), "last_post" AS (
         SELECT "training_load_daily"."athlete_id",
            "max"("training_load_daily"."inserted_at") AS "post_date"
           FROM "public"."training_load_daily"
          WHERE ("training_load_daily"."kind" = 'daily_post'::"text")
          GROUP BY "training_load_daily"."athlete_id"
        ), "weekly" AS (
         SELECT "restq_analysis_view"."athlete_id",
            "max"("restq_analysis_view"."data") AS "last_week"
           FROM "public"."restq_analysis_view"
          GROUP BY "restq_analysis_view"."athlete_id"
        ), "construcional" AS (
         SELECT "construcional_analysis"."athlete_id",
            "max"("construcional_analysis"."analyzed_at") AS "last_construcional"
           FROM "public"."construcional_analysis"
          GROUP BY "construcional_analysis"."athlete_id"
        ), "quarterly" AS (
         SELECT "acsi_analysis_view"."athlete_id",
            "max"("acsi_analysis_view"."data") AS "last_quarter"
           FROM "public"."acsi_analysis_view"
          GROUP BY "acsi_analysis_view"."athlete_id"
        ), "semiannual" AS (
         SELECT "cbas_analysis_view"."athlete_id",
            "max"("cbas_analysis_view"."data") AS "last_semi"
           FROM "public"."cbas_analysis_view"
          GROUP BY "cbas_analysis_view"."athlete_id"
        ), "merged" AS (
         SELECT "a"."athlete_id",
            "a"."athlete_name",
            "r"."last_response",
            "ls"."last_sent",
            "ls"."total_sent",
            "q"."action_type",
            "q"."status",
            "q"."priority_rank",
            "q"."next_retry_at",
            "p"."pre_date",
            "p"."pre_time",
            "po"."post_date",
            "w"."last_week",
            "c"."last_construcional",
            "qt"."last_quarter",
            "s"."last_semi",
            (("p"."pre_time" IS NOT NULL) AND (("po"."post_date" IS NULL) OR ("po"."post_date" < "p"."pre_time"))) AS "waiting_post",
            (("p"."pre_time" IS NOT NULL) AND (("p"."pre_time" + '01:00:00'::interval) <= "now"())) AS "post_due",
            (EXTRACT(isodow FROM "now"()) = ANY (ARRAY[(6)::numeric, (7)::numeric])) AS "weekend",
            (("w"."last_week" IS NULL) OR ("w"."last_week" < (CURRENT_DATE - '6 days'::interval))) AS "weekly_due",
            (("c"."last_construcional" IS NULL) OR ("c"."last_construcional" < (CURRENT_DATE - '180 days'::interval))) AS "construcional_due",
            (("qt"."last_quarter" IS NULL) OR ("qt"."last_quarter" < (CURRENT_DATE - '90 days'::interval))) AS "quarterly_due",
            (("s"."last_semi" IS NULL) OR ("s"."last_semi" < (CURRENT_DATE - '180 days'::interval))) AS "semiannual_due"
           FROM ((((((((("public"."api_athletes" "a"
             LEFT JOIN "responses" "r" ON (("r"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "last_sent" "ls" ON (("ls"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "queue" "q" ON (("q"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "last_pre" "p" ON (("p"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "last_post" "po" ON (("po"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "weekly" "w" ON (("w"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "construcional" "c" ON (("c"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "quarterly" "qt" ON (("qt"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "semiannual" "s" ON (("s"."athlete_id" = "a"."athlete_id")))
        ), "decision" AS (
         SELECT "m"."athlete_id",
            "m"."athlete_name",
            "m"."last_response",
            "m"."last_sent",
            "m"."total_sent",
            "m"."action_type",
            "m"."status",
            "m"."priority_rank",
            "m"."next_retry_at",
            "m"."pre_date",
            "m"."pre_time",
            "m"."post_date",
            "m"."last_week",
            "m"."last_construcional",
            "m"."last_quarter",
            "m"."last_semi",
            "m"."waiting_post",
            "m"."post_due",
            "m"."weekend",
            "m"."weekly_due",
            "m"."construcional_due",
            "m"."quarterly_due",
            "m"."semiannual_due",
                CASE
                    WHEN ("m"."waiting_post" AND "m"."post_due") THEN 'post'::"text"
                    WHEN "m"."construcional_due" THEN 'construcional'::"text"
                    WHEN ("m"."weekend" AND "m"."weekly_due") THEN 'weekly'::"text"
                    WHEN "m"."quarterly_due" THEN 'quarterly'::"text"
                    WHEN "m"."semiannual_due" THEN 'semiannual'::"text"
                    WHEN ((NOT "m"."waiting_post") AND (NOT "m"."weekend")) THEN 'pre'::"text"
                    ELSE NULL::"text"
                END AS "predicted_questionnaire"
           FROM "merged" "m"
        )
 SELECT "athlete_id",
    "athlete_name",
    "last_response",
    "last_sent",
    "total_sent",
    "action_type" AS "queued_questionnaire",
    "status" AS "queue_status",
    "priority_rank",
    "next_retry_at",
        CASE
            WHEN ("last_response" IS NULL) THEN 'never responded'::"text"
            WHEN (("now"() - "last_response") > '7 days'::interval) THEN 'inactive'::"text"
            ELSE 'active'::"text"
        END AS "activity_status",
    "predicted_questionnaire",
    "pre_date",
    "pre_time",
    "post_date",
    "last_week",
    "last_construcional",
    "last_quarter",
    "last_semi"
   FROM "decision";


ALTER VIEW "public"."minds_overview" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."minds_questionnaire_state" (
    "athlete_id" "text" NOT NULL,
    "weekly_week_start" "date",
    "weekly_completed" boolean DEFAULT false,
    "pre_last_sent_at" timestamp with time zone,
    "pre_last_answer_at" timestamp with time zone,
    "post_last_sent_at" timestamp with time zone,
    "post_last_answer_at" timestamp with time zone,
    "quarterly_last_sent_at" timestamp with time zone,
    "quarterly_last_answer_at" timestamp with time zone,
    "semiannual_last_sent_at" timestamp with time zone,
    "semiannual_last_answer_at" timestamp with time zone,
    "construcional_last_sent_at" timestamp with time zone,
    "construcional_last_answer_at" timestamp with time zone,
    "last_notification_type" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."minds_questionnaire_state" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."minds_system_monitor" AS
 WITH "last_sent" AS (
         SELECT "minds_notification_log"."athlete_id",
            "max"("minds_notification_log"."sent_at") AS "last_sent",
            "count"(*) AS "total_sent"
           FROM "public"."minds_notification_log"
          GROUP BY "minds_notification_log"."athlete_id"
        ), "queue" AS (
         SELECT "minds_notification_queue"."athlete_id",
            "minds_notification_queue"."action_type",
            "minds_notification_queue"."status",
            "minds_notification_queue"."next_retry_at",
            "minds_notification_queue"."priority_rank"
           FROM "public"."minds_notification_queue"
          WHERE ("minds_notification_queue"."status" = 'pending'::"text")
        )
 SELECT "a"."athlete_id",
    "a"."athlete_name",
    "r"."last_response",
    "ls"."last_sent",
    "ls"."total_sent",
    "q"."action_type" AS "next_questionnaire",
    "q"."status" AS "queue_status",
    "q"."next_retry_at",
    "q"."priority_rank",
        CASE
            WHEN ("r"."last_response" IS NULL) THEN 'never responded'::"text"
            WHEN (("now"() - "r"."last_response") > '7 days'::interval) THEN 'inactive'::"text"
            ELSE 'active'::"text"
        END AS "activity_status",
    COALESCE("ds"."send_state", 'active'::"text") AS "send_state",
        CASE
            WHEN (COALESCE("ds"."send_state", 'active'::"text") = 'hibernated'::"text") THEN false
            ELSE true
        END AS "can_send",
    "ds"."auto_hibernated",
    "ds"."reason" AS "hibernation_reason",
    "ds"."hibernated_at",
    "ds"."reactivated_at"
   FROM (((("public"."api_athletes" "a"
     LEFT JOIN "public"."minds_last_response" "r" ON (("r"."athlete_id" = "a"."athlete_id")))
     LEFT JOIN "last_sent" "ls" ON (("ls"."athlete_id" = "a"."athlete_id")))
     LEFT JOIN "queue" "q" ON (("q"."athlete_id" = "a"."athlete_id")))
     LEFT JOIN "public"."minds_athlete_delivery_state" "ds" ON (("ds"."athlete_id" = "a"."athlete_id")));


ALTER VIEW "public"."minds_system_monitor" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."minds_training_pattern" AS
 WITH "base" AS (
         SELECT "training_load_daily"."athlete_id",
            "training_load_daily"."duration_min",
            "training_load_daily"."inserted_at"
           FROM "public"."training_load_daily"
          WHERE ("training_load_daily"."duration_min" IS NOT NULL)
        ), "pattern" AS (
         SELECT "base"."athlete_id",
            "avg"("base"."duration_min") AS "mean_minutes",
            "count"(*) AS "sessions"
           FROM "base"
          GROUP BY "base"."athlete_id"
        )
 SELECT "athlete_id",
    ("round"("mean_minutes"))::integer AS "mean_minutes",
    ("sessions" >= 5) AS "pattern_ready"
   FROM "pattern";


ALTER VIEW "public"."minds_training_pattern" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."minds_webhook_queue" (
    "id" bigint NOT NULL,
    "athlete_id" "text",
    "athlete_name" "text",
    "athlete_phone" "text",
    "questionnaire" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sent" boolean DEFAULT false,
    "created_hour" timestamp without time zone,
    "status" "text" DEFAULT 'pending'::"text",
    "retry_count" integer DEFAULT 0,
    "max_retries" integer DEFAULT 5,
    "available_at" timestamp with time zone DEFAULT "now"(),
    "processing_at" timestamp with time zone,
    "sent_at" timestamp with time zone,
    "last_error" "text",
    "request_id" bigint,
    "last_status_code" integer,
    "last_response_at" timestamp with time zone,
    "last_attempt_at" timestamp with time zone
);


ALTER TABLE "public"."minds_webhook_queue" OWNER TO "postgres";


ALTER TABLE "public"."minds_webhook_queue" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."minds_webhook_queue_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."pingo_athlete_notes" (
    "id" bigint NOT NULL,
    "athlete_id" "text" NOT NULL,
    "note" "text",
    "created_by" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "title" "text",
    "content" "text",
    "note_text" "text",
    "tags" "text"[],
    "confidence" numeric,
    "model_name" "text"
);


ALTER TABLE "public"."pingo_athlete_notes" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."pingo_athlete_notes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pingo_athlete_notes_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pingo_athlete_notes_id_seq" OWNED BY "public"."pingo_athlete_notes"."id";



CREATE TABLE IF NOT EXISTS "public"."pingo_chat_context" (
    "user_id" "text" NOT NULL,
    "last_athlete_id" "text",
    "last_athlete_name" "text",
    "last_team_name" "text",
    "last_athlete_phone" "text",
    "last_coach_phone" "text",
    "meta" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."pingo_chat_context" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."pingo_scoring_active" WITH ("security_invoker"='true') AS
 SELECT "id",
    "athlete_id",
    "reference_date",
    "attention_level",
    "flag_count",
    "flags",
    "rules_triggered",
    "thresholds_used",
    "summary",
    "created_at",
    "kind",
    "master_sheet_id",
    "payload",
    "source",
    "flag_generated_at",
    "flag_valid_until"
   FROM "public"."pingo_scoring_output"
  WHERE (("flag_valid_until" IS NULL) OR ("flag_valid_until" > "now"()));


ALTER VIEW "public"."pingo_scoring_active" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_training_load_base_world" AS
 SELECT "athlete_id",
    "data",
    "srpe_load" AS "load"
   FROM "public"."training_load_daily"
  WHERE (("srpe_load" IS NOT NULL) AND ("srpe_load" > (0)::numeric));


ALTER VIEW "public"."v_training_load_base_world" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_training_calendar_world" AS
 WITH "bounds" AS (
         SELECT "v_training_load_base_world"."athlete_id",
            (("max"("v_training_load_base_world"."data") - '60 days'::interval))::"date" AS "start_date",
            "max"("v_training_load_base_world"."data") AS "end_date"
           FROM "public"."v_training_load_base_world"
          GROUP BY "v_training_load_base_world"."athlete_id"
        ), "calendar" AS (
         SELECT "bounds"."athlete_id",
            ("generate_series"(("bounds"."start_date")::timestamp with time zone, ("bounds"."end_date")::timestamp with time zone, '1 day'::interval))::"date" AS "data"
           FROM "bounds"
        )
 SELECT "c"."athlete_id",
    "c"."data",
    COALESCE("b"."load", (0)::numeric) AS "load",
    ("b"."load" IS NOT NULL) AS "has_session"
   FROM ("calendar" "c"
     LEFT JOIN "public"."v_training_load_base_world" "b" ON ((("b"."athlete_id" = "c"."athlete_id") AND ("b"."data" = "c"."data"))));


ALTER VIEW "public"."v_training_calendar_world" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_training_metrics_world" AS
 WITH "base" AS (
         SELECT "v_training_calendar_world"."athlete_id",
            "v_training_calendar_world"."data",
            "v_training_calendar_world"."load",
            "v_training_calendar_world"."has_session"
           FROM "public"."v_training_calendar_world"
        ), "w7" AS (
         SELECT "base"."athlete_id",
            "base"."data",
            "sum"("base"."load") FILTER (WHERE (("base"."data" >= ("base"."data" - '6 days'::interval)) AND ("base"."data" <= "base"."data"))) AS "acute_load",
            "sum"(
                CASE
                    WHEN "base"."has_session" THEN 1
                    ELSE 0
                END) FILTER (WHERE (("base"."data" >= ("base"."data" - '6 days'::interval)) AND ("base"."data" <= "base"."data"))) AS "sessions_7",
            "avg"("base"."load") FILTER (WHERE (("base"."data" >= ("base"."data" - '6 days'::interval)) AND ("base"."data" <= "base"."data"))) AS "mean_7",
            "stddev_samp"("base"."load") FILTER (WHERE (("base"."data" >= ("base"."data" - '6 days'::interval)) AND ("base"."data" <= "base"."data"))) AS "sd_7"
           FROM "base"
          GROUP BY "base"."athlete_id", "base"."data"
        ), "w28" AS (
         SELECT "base"."athlete_id",
            "base"."data",
            "avg"("base"."load") FILTER (WHERE (("base"."data" >= ("base"."data" - '27 days'::interval)) AND ("base"."data" <= "base"."data"))) AS "mean_28",
            "sum"(
                CASE
                    WHEN "base"."has_session" THEN 1
                    ELSE 0
                END) FILTER (WHERE (("base"."data" >= ("base"."data" - '27 days'::interval)) AND ("base"."data" <= "base"."data"))) AS "sessions_28"
           FROM "base"
          GROUP BY "base"."athlete_id", "base"."data"
        )
 SELECT "b"."athlete_id",
    "b"."data",
    "b"."load",
    "w7"."sessions_7",
    "w28"."sessions_28",
    "round"("w7"."acute_load", 2) AS "acute_load",
    "round"(("w28"."mean_28" * (7)::numeric), 2) AS "chronic_load",
    "round"(
        CASE
            WHEN ("w7"."sessions_7" < 4) THEN NULL::numeric
            WHEN ("w28"."sessions_28" < 14) THEN NULL::numeric
            WHEN ("w28"."mean_28" IS NULL) THEN NULL::numeric
            ELSE ("w7"."acute_load" / ("w28"."mean_28" * (7)::numeric))
        END, 3) AS "acwr",
    "round"(
        CASE
            WHEN (("w7"."sd_7" IS NULL) OR ("w7"."sd_7" = (0)::numeric)) THEN NULL::numeric
            ELSE ("w7"."mean_7" / "w7"."sd_7")
        END, 2) AS "monotony",
    "round"(("w7"."acute_load" *
        CASE
            WHEN ("w7"."sd_7" = (0)::numeric) THEN NULL::numeric
            ELSE ("w7"."mean_7" / "w7"."sd_7")
        END), 2) AS "strain"
   FROM (("base" "b"
     JOIN "w7" ON ((("w7"."athlete_id" = "b"."athlete_id") AND ("w7"."data" = "b"."data"))))
     JOIN "w28" ON ((("w28"."athlete_id" = "b"."athlete_id") AND ("w28"."data" = "b"."data"))));


ALTER VIEW "public"."v_training_metrics_world" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."weight_analysis" AS
 WITH "base" AS (
         SELECT "d"."athlete_id",
            "d"."data",
            "d"."weight_kg",
            "d"."adherence_score",
            "t"."srpe_load" AS "training_load",
            "lag"("d"."weight_kg") OVER (PARTITION BY "d"."athlete_id" ORDER BY "d"."data") AS "prev_weight"
           FROM ("public"."diet_daily" "d"
             LEFT JOIN "public"."training_load_daily" "t" ON ((("d"."athlete_id" = "t"."athlete_id") AND ("d"."data" = "t"."data"))))
          WHERE ("d"."weight_kg" IS NOT NULL)
        ), "rolling" AS (
         SELECT "diet_daily"."athlete_id",
            "diet_daily"."data",
            "diet_daily"."weight_kg",
            "avg"("diet_daily"."weight_kg") OVER (PARTITION BY "diet_daily"."athlete_id" ORDER BY "diet_daily"."data" ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS "weight_avg_7obs",
            "stddev"("diet_daily"."weight_kg") OVER (PARTITION BY "diet_daily"."athlete_id" ORDER BY "diet_daily"."data" ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS "weight_volatility_7obs",
            "min"("diet_daily"."weight_kg") OVER (PARTITION BY "diet_daily"."athlete_id" ORDER BY "diet_daily"."data" ROWS BETWEEN 13 PRECEDING AND CURRENT ROW) AS "weight_min_14obs"
           FROM "public"."diet_daily"
          WHERE ("diet_daily"."weight_kg" IS NOT NULL)
        ), "stats" AS (
         SELECT "diet_daily"."athlete_id",
            "avg"("diet_daily"."weight_kg") AS "mean_weight",
            "stddev"("diet_daily"."weight_kg") AS "sd_weight"
           FROM "public"."diet_daily"
          WHERE ("diet_daily"."weight_kg" IS NOT NULL)
          GROUP BY "diet_daily"."athlete_id"
        )
 SELECT "b"."athlete_id",
    "b"."data",
    "b"."weight_kg",
    "round"(("b"."weight_kg" - "b"."prev_weight"), 2) AS "weight_delta",
    "round"(((("b"."weight_kg" - "b"."prev_weight") / NULLIF("b"."prev_weight", (0)::numeric)) * (100)::numeric), 2) AS "weight_delta_pct",
    "round"("r"."weight_avg_7obs", 2) AS "weight_avg_7obs",
    "round"("r"."weight_volatility_7obs", 2) AS "weight_volatility_7obs",
    "r"."weight_min_14obs",
    "round"((("b"."weight_kg" - "s"."mean_weight") / NULLIF("s"."sd_weight", (0)::numeric)), 2) AS "weight_zscore",
    "b"."training_load",
    "b"."adherence_score",
    "round"((("r"."weight_avg_7obs" - (COALESCE("b"."training_load", (0)::numeric) * 0.0008)) + (COALESCE("b"."adherence_score", (0)::numeric) * 0.003)), 2) AS "expected_weight",
    "round"(("b"."weight_kg" - (("r"."weight_avg_7obs" - (COALESCE("b"."training_load", (0)::numeric) * 0.0008)) + (COALESCE("b"."adherence_score", (0)::numeric) * 0.003))), 2) AS "weight_residual"
   FROM (("base" "b"
     LEFT JOIN "rolling" "r" ON ((("b"."athlete_id" = "r"."athlete_id") AND ("b"."data" = "r"."data"))))
     LEFT JOIN "stats" "s" ON (("b"."athlete_id" = "s"."athlete_id")))
  ORDER BY "b"."athlete_id", "b"."data";


ALTER VIEW "public"."weight_analysis" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."pingo_scoring_inputs_view_final" AS
 WITH "brums_last" AS (
         SELECT DISTINCT ON ("brums_analysis_view"."athlete_id") "brums_analysis_view"."athlete_id",
            "brums_analysis_view"."data" AS "brums_date",
            "brums_analysis_view"."inserted_at" AS "brums_inserted_at",
            NULLIF("round"("brums_analysis_view"."vigor", 2), (0)::numeric) AS "vigor",
            NULLIF("round"("brums_analysis_view"."tension", 2), (0)::numeric) AS "tension",
            NULLIF("round"("brums_analysis_view"."depression", 2), (0)::numeric) AS "depression",
            NULLIF("round"("brums_analysis_view"."anger", 2), (0)::numeric) AS "anger",
            NULLIF("round"("brums_analysis_view"."fatigue", 2), (0)::numeric) AS "fatigue",
            NULLIF("round"("brums_analysis_view"."confusion", 2), (0)::numeric) AS "confusion",
            NULLIF("round"("brums_analysis_view"."dth", 2), (0)::numeric) AS "dth",
            NULLIF("round"("brums_analysis_view"."dth_minus", 2), (0)::numeric) AS "dth_minus",
            NULLIF("round"("brums_analysis_view"."vigor_z", 2), (0)::numeric) AS "vigor_z",
            NULLIF("round"("brums_analysis_view"."dth_z", 2), (0)::numeric) AS "dth_z",
            NULLIF("round"("brums_analysis_view"."vigor_delta_1d", 2), (0)::numeric) AS "vigor_delta_1d",
            NULLIF("round"("brums_analysis_view"."dth_delta_1d", 2), (0)::numeric) AS "dth_delta_1d",
            NULLIF("round"("brums_analysis_view"."vigor_volatility", 2), (0)::numeric) AS "vigor_volatility",
            NULLIF("round"("brums_analysis_view"."dth_volatility", 2), (0)::numeric) AS "dth_volatility",
            "brums_analysis_view"."brums_entries",
            "brums_analysis_view"."pattern_iceberg",
            "brums_analysis_view"."pattern_burnout",
            "brums_analysis_view"."pattern_hyperactivation",
            "brums_analysis_view"."pattern_flat"
           FROM "public"."brums_analysis_view"
          ORDER BY "brums_analysis_view"."athlete_id", "brums_analysis_view"."data" DESC, "brums_analysis_view"."inserted_at" DESC
        ), "diet_last" AS (
         SELECT DISTINCT ON ("w"."athlete_id") "w"."athlete_id",
            "w"."data" AS "weight_date",
            NULLIF("round"("w"."weight_kg", 2), (0)::numeric) AS "weight_kg",
            NULLIF("round"("w"."weight_delta", 2), (0)::numeric) AS "weight_delta",
            NULLIF("round"("w"."weight_delta_pct", 2), (0)::numeric) AS "weight_delta_pct",
            NULLIF("round"("w"."weight_avg_7obs", 2), (0)::numeric) AS "weight_avg_7obs",
            NULLIF("round"("w"."weight_volatility_7obs", 2), (0)::numeric) AS "weight_volatility_7obs",
            NULLIF("round"("w"."weight_zscore", 2), (0)::numeric) AS "weight_zscore",
            NULLIF("round"("w"."expected_weight", 2), (0)::numeric) AS "expected_weight",
            NULLIF("round"("w"."weight_residual", 2), (0)::numeric) AS "weight_residual",
            NULLIF("round"("w"."training_load", 2), (0)::numeric) AS "weight_training_load",
            NULLIF("round"("w"."adherence_score", 2), (0)::numeric) AS "adherence_score",
            "d_1"."gi_distress",
            "d_1"."inserted_at" AS "diet_inserted_at"
           FROM ("public"."weight_analysis" "w"
             LEFT JOIN "public"."diet_daily" "d_1" ON ((("w"."athlete_id" = "d_1"."athlete_id") AND ("w"."data" = "d_1"."data"))))
          ORDER BY "w"."athlete_id", "w"."data" DESC
        ), "load_last" AS (
         SELECT DISTINCT ON ("v_training_metrics_world"."athlete_id") "v_training_metrics_world"."athlete_id",
            "v_training_metrics_world"."data" AS "week_start",
            NULLIF("round"("v_training_metrics_world"."load", 2), (0)::numeric) AS "daily_load",
            NULLIF("round"("v_training_metrics_world"."acwr", 3), (0)::numeric) AS "acwr",
            NULLIF("round"("v_training_metrics_world"."monotony", 2), (0)::numeric) AS "monotony",
            NULLIF("round"("v_training_metrics_world"."strain", 2), (0)::numeric) AS "strain"
           FROM "public"."v_training_metrics_world"
          ORDER BY "v_training_metrics_world"."athlete_id", "v_training_metrics_world"."data" DESC
        ), "acsi_last" AS (
         SELECT DISTINCT ON ("acsi_analysis"."athlete_id") "acsi_analysis"."athlete_id",
            NULLIF("round"("acsi_analysis"."media", 2), (0)::numeric) AS "acsi_media",
            NULLIF("round"("acsi_analysis"."metas_preparacao", 2), (0)::numeric) AS "metas_preparacao",
            NULLIF("round"("acsi_analysis"."relacao_treinador", 2), (0)::numeric) AS "relacao_treinador",
            NULLIF("round"("acsi_analysis"."concentracao", 2), (0)::numeric) AS "concentracao",
            NULLIF("round"("acsi_analysis"."confianca_motivacao", 2), (0)::numeric) AS "confianca_motivacao",
            NULLIF("round"("acsi_analysis"."pico_pressao", 2), (0)::numeric) AS "pico_pressao",
            NULLIF("round"("acsi_analysis"."adversidade", 2), (0)::numeric) AS "adversidade",
            NULLIF("round"("acsi_analysis"."ausencia_preocupacao", 2), (0)::numeric) AS "ausencia_preocupacao"
           FROM "public"."acsi_analysis"
          ORDER BY "acsi_analysis"."athlete_id", "acsi_analysis"."data" DESC
        ), "gses_last" AS (
         SELECT DISTINCT ON ("gses_analysis"."athlete_id") "gses_analysis"."athlete_id",
            NULLIF("round"("gses_analysis"."media", 2), (0)::numeric) AS "gses_media"
           FROM "public"."gses_analysis"
          ORDER BY "gses_analysis"."athlete_id", "gses_analysis"."data" DESC
        ), "restq_last" AS (
         SELECT DISTINCT ON ("restq_analysis"."athlete_id") "restq_analysis"."athlete_id",
            NULLIF("round"("restq_analysis"."media", 2), (0)::numeric) AS "restq_media",
            NULLIF("round"("restq_analysis"."general_stress", 2), (0)::numeric) AS "general_stress",
            NULLIF("round"("restq_analysis"."emotional_stress", 2), (0)::numeric) AS "emotional_stress",
            NULLIF("round"("restq_analysis"."social_stress", 2), (0)::numeric) AS "social_stress",
            NULLIF("round"("restq_analysis"."fatigueREST", 2), (0)::numeric) AS "fatigueREST",
            NULLIF("round"("restq_analysis"."lack_energy", 2), (0)::numeric) AS "lack_energy",
            NULLIF("round"("restq_analysis"."physical_complaints", 2), (0)::numeric) AS "physical_complaints",
            NULLIF("round"("restq_analysis"."disturbed_breaks", 2), (0)::numeric) AS "disturbed_breaks",
            NULLIF("round"("restq_analysis"."sleep_quality", 2), (0)::numeric) AS "sleep_quality",
            NULLIF("round"("restq_analysis"."physical_recovery", 2), (0)::numeric) AS "physical_recovery",
            NULLIF("round"("restq_analysis"."general_wellbeing", 2), (0)::numeric) AS "general_wellbeing",
            NULLIF("round"("restq_analysis"."self_efficacy", 2), (0)::numeric) AS "self_efficacy",
            NULLIF("round"("restq_analysis"."being_in_shape", 2), (0)::numeric) AS "being_in_shape",
            NULLIF("round"("restq_analysis"."stress_index", 3), (0)::numeric) AS "stress_index",
            NULLIF("round"("restq_analysis"."recovery_index", 3), (0)::numeric) AS "recovery_index",
            NULLIF("round"("restq_analysis"."balance", 3), (0)::numeric) AS "balance"
           FROM "public"."restq_analysis"
          ORDER BY "restq_analysis"."athlete_id", "restq_analysis"."data" DESC
        ), "pmcsq_last" AS (
         SELECT DISTINCT ON ("pmcsq_analysis"."athlete_id") "pmcsq_analysis"."athlete_id",
            NULLIF("round"("pmcsq_analysis"."clima_tarefa", 2), (0)::numeric) AS "clima_tarefa",
            NULLIF("round"("pmcsq_analysis"."clima_ego", 2), (0)::numeric) AS "clima_ego",
            NULLIF("round"("pmcsq_analysis"."coletivo", 2), (0)::numeric) AS "coletivo",
            NULLIF("round"("pmcsq_analysis"."clima_treino_desafiador", 2), (0)::numeric) AS "clima_treino_desafiador",
            NULLIF("round"("pmcsq_analysis"."clima_ego_preferido", 2), (0)::numeric) AS "clima_ego_preferido",
            NULLIF("round"("pmcsq_analysis"."punicao_erros", 2), (0)::numeric) AS "punicao_erros"
           FROM "public"."pmcsq_analysis"
          ORDER BY "pmcsq_analysis"."athlete_id", "pmcsq_analysis"."data" DESC
        ), "cbas_last" AS (
         SELECT DISTINCT ON ("cbas_analysis_view"."athlete_id") "cbas_analysis_view"."athlete_id",
            NULLIF("round"("cbas_analysis_view"."tecnica", 2), (0)::numeric) AS "cbas_tecnica",
            NULLIF("round"("cbas_analysis_view"."planejamento", 2), (0)::numeric) AS "cbas_planejamento",
            NULLIF("round"("cbas_analysis_view"."motivacional", 2), (0)::numeric) AS "cbas_motivacional",
            NULLIF("round"("cbas_analysis_view"."relacao", 2), (0)::numeric) AS "cbas_relacao",
            NULLIF("round"("cbas_analysis_view"."aversivos", 2), (0)::numeric) AS "cbas_aversivos"
           FROM "public"."cbas_analysis_view"
          ORDER BY "cbas_analysis_view"."athlete_id", "cbas_analysis_view"."data" DESC
        ), "construcional_last" AS (
         SELECT DISTINCT ON ("construcional_analysis"."athlete_id") "construcional_analysis"."athlete_id",
            "construcional_analysis"."repertorio_protetor",
            "construcional_analysis"."repertorio_risco",
            "construcional_analysis"."apoio_ambiental",
            "construcional_analysis"."claridade_metas"
           FROM "public"."construcional_analysis"
          ORDER BY "construcional_analysis"."athlete_id", "construcional_analysis"."analyzed_at" DESC
        ), "base_athletes" AS (
         SELECT "brums_last"."athlete_id"
           FROM "brums_last"
        UNION
         SELECT "diet_last"."athlete_id"
           FROM "diet_last"
        UNION
         SELECT "load_last"."athlete_id"
           FROM "load_last"
        UNION
         SELECT "acsi_last"."athlete_id"
           FROM "acsi_last"
        UNION
         SELECT "gses_last"."athlete_id"
           FROM "gses_last"
        UNION
         SELECT "restq_last"."athlete_id"
           FROM "restq_last"
        UNION
         SELECT "pmcsq_last"."athlete_id"
           FROM "pmcsq_last"
        UNION
         SELECT "cbas_last"."athlete_id"
           FROM "cbas_last"
        UNION
         SELECT "construcional_last"."athlete_id"
           FROM "construcional_last"
        )
 SELECT "ba"."athlete_id",
    CURRENT_DATE AS "reference_date",
    "b"."brums_date",
    "b"."brums_inserted_at",
    "b"."vigor",
    "b"."tension",
    "b"."depression",
    "b"."anger",
    "b"."fatigue",
    "b"."confusion",
    "b"."dth",
    "b"."dth_minus",
    "b"."vigor_z",
    "b"."dth_z",
    "b"."vigor_delta_1d",
    "b"."dth_delta_1d",
    "b"."vigor_volatility",
    "b"."dth_volatility",
    "b"."brums_entries",
    "b"."pattern_iceberg",
    "b"."pattern_burnout",
    "b"."pattern_hyperactivation",
    "b"."pattern_flat",
    "d"."weight_date",
    "d"."weight_kg",
    "d"."weight_delta",
    "d"."weight_delta_pct",
    "d"."weight_avg_7obs",
    "d"."weight_volatility_7obs",
    "d"."weight_zscore",
    "d"."expected_weight",
    "d"."weight_residual",
    "d"."weight_training_load",
    "d"."adherence_score",
    "d"."gi_distress",
    "d"."diet_inserted_at",
    "l"."week_start",
    "l"."daily_load",
    "l"."acwr",
    "l"."monotony",
    "l"."strain",
    "a"."acsi_media",
    "a"."metas_preparacao",
    "a"."relacao_treinador",
    "a"."concentracao",
    "a"."confianca_motivacao",
    "a"."pico_pressao",
    "a"."adversidade",
    "a"."ausencia_preocupacao",
    "g"."gses_media",
    "r"."restq_media",
    "r"."general_stress",
    "r"."emotional_stress",
    "r"."social_stress",
    "r"."fatigueREST",
    "r"."lack_energy",
    "r"."physical_complaints",
    "r"."disturbed_breaks",
    "r"."sleep_quality",
    "r"."physical_recovery",
    "r"."general_wellbeing",
    "r"."self_efficacy",
    "r"."being_in_shape",
    "r"."stress_index",
    "r"."recovery_index",
    "r"."balance",
    "m"."clima_tarefa",
    "m"."clima_ego",
    "m"."coletivo",
    "m"."clima_treino_desafiador",
    "m"."clima_ego_preferido",
    "m"."punicao_erros",
    "cb"."cbas_tecnica",
    "cb"."cbas_planejamento",
    "cb"."cbas_motivacional",
    "cb"."cbas_relacao",
    "cb"."cbas_aversivos",
    "c"."repertorio_protetor",
    "c"."repertorio_risco",
    "c"."apoio_ambiental",
    "c"."claridade_metas"
   FROM ((((((((("base_athletes" "ba"
     LEFT JOIN "brums_last" "b" USING ("athlete_id"))
     LEFT JOIN "diet_last" "d" USING ("athlete_id"))
     LEFT JOIN "load_last" "l" USING ("athlete_id"))
     LEFT JOIN "acsi_last" "a" USING ("athlete_id"))
     LEFT JOIN "gses_last" "g" USING ("athlete_id"))
     LEFT JOIN "restq_last" "r" USING ("athlete_id"))
     LEFT JOIN "pmcsq_last" "m" USING ("athlete_id"))
     LEFT JOIN "cbas_last" "cb" USING ("athlete_id"))
     LEFT JOIN "construcional_last" "c" USING ("athlete_id"));


ALTER VIEW "public"."pingo_scoring_inputs_view_final" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."pingo_scoring_output_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pingo_scoring_output_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pingo_scoring_output_id_seq" OWNED BY "public"."pingo_scoring_output"."id";



CREATE TABLE IF NOT EXISTS "public"."pingo_user_athletes" (
    "user_id" "text" NOT NULL,
    "athlete_id" "text" NOT NULL,
    "athlete_name" "text",
    "team_name" "text",
    "athlete_phone" "text",
    "coach_phone" "text",
    "pinned" boolean DEFAULT false NOT NULL,
    "last_used_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."pingo_user_athletes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pingo_user_messages" (
    "id" bigint NOT NULL,
    "user_id" "text" NOT NULL,
    "athlete_id" "text",
    "message_text" "text" NOT NULL,
    "message_type" "text" DEFAULT 'text'::"text" NOT NULL,
    "message_meta" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "include_in_history" boolean DEFAULT false NOT NULL,
    "saved_at" timestamp with time zone,
    "saved_by" "text"
);


ALTER TABLE "public"."pingo_user_messages" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."pingo_user_messages_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pingo_user_messages_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pingo_user_messages_id_seq" OWNED BY "public"."pingo_user_messages"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."pmcsq_analysis_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pmcsq_analysis_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pmcsq_analysis_id_seq" OWNED BY "public"."pmcsq_analysis"."id";



CREATE OR REPLACE VIEW "public"."pmcsq_analysis_view" WITH ("security_invoker"='true') AS
 SELECT "id",
    "athlete_id",
    "data",
    "clima_tarefa",
    "clima_ego",
    "coletivo",
    "clima_treino_desafiador",
    "clima_ego_preferido",
    "punicao_erros",
    "inserted_at",
    (("clima_tarefa" - "avg"("clima_tarefa") OVER (PARTITION BY "athlete_id")) / NULLIF("stddev_samp"("clima_tarefa") OVER (PARTITION BY "athlete_id"), (0)::numeric)) AS "clima_tarefa_z",
    (("clima_ego" - "avg"("clima_ego") OVER (PARTITION BY "athlete_id")) / NULLIF("stddev_samp"("clima_ego") OVER (PARTITION BY "athlete_id"), (0)::numeric)) AS "clima_ego_z"
   FROM "public"."pmcsq_analysis" "p";


ALTER VIEW "public"."pmcsq_analysis_view" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."restq_analysis_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."restq_analysis_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."restq_analysis_id_seq" OWNED BY "public"."restq_analysis"."id";



CREATE TABLE IF NOT EXISTS "public"."scoring_rules" (
    "key" "text" NOT NULL,
    "source_url" "text" NOT NULL,
    "content" "jsonb" NOT NULL,
    "etag" "text",
    "sha" "text",
    "version" integer,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."scoring_rules" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."training_load_daily_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."training_load_daily_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."training_load_daily_id_seq" OWNED BY "public"."training_load_daily"."id";



CREATE TABLE IF NOT EXISTS "public"."user_credentials" (
    "user_id" "text" NOT NULL,
    "phone" "text" NOT NULL,
    "password_hash" "text" NOT NULL,
    "must_change" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "role" "text",
    "name" "text",
    "athlete_id" "text",
    "source_kind" "text",
    "source_ref" "text"
);


ALTER TABLE "public"."user_credentials" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_roles" (
    "user_id" "text" NOT NULL,
    "role" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "user_roles_role_check" CHECK (("role" = ANY (ARRAY['master'::"text", 'coach'::"text", 'athlete'::"text"])))
);


ALTER TABLE "public"."user_roles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."users_all" AS
 WITH "reg" AS (
         SELECT "ar"."athlete_id" AS "user_id",
            "bool_or"(COALESCE("ar"."athlete_enabled", false)) AS "athlete_enabled",
            true AS "is_athlete"
           FROM "public"."athlete_registration" "ar"
          GROUP BY "ar"."athlete_id"
        ), "role_base" AS (
         SELECT "ur"."user_id",
            "string_agg"(DISTINCT "ur"."role", ','::"text" ORDER BY "ur"."role") AS "base_roles",
            "bool_or"(("ur"."role" = 'master'::"text")) AS "is_master",
            "bool_or"(("ur"."role" = 'coach'::"text")) AS "is_coach"
           FROM "public"."user_roles" "ur"
          GROUP BY "ur"."user_id"
        ), "users_clean" AS (
         SELECT "u"."user_id",
            "u"."name",
            "u"."phone",
            "u"."email",
            "u"."master_id",
            "u"."created_at",
            "u"."updated_at",
            "u"."account_active",
            "u"."human_mode_until",
            NULLIF("regexp_replace"(COALESCE("u"."phone", ''::"text"), '\D'::"text", ''::"text", 'g'::"text"), ''::"text") AS "phone_digits"
           FROM "public"."users" "u"
        ), "masters_clean" AS (
         SELECT "m"."master_id",
            "m"."name",
            "m"."phone",
            "m"."email",
            "m"."created_at",
            NULLIF("regexp_replace"(COALESCE("m"."phone", ''::"text"), '\D'::"text", ''::"text", 'g'::"text"), ''::"text") AS "phone_digits"
           FROM "public"."masters" "m"
        ), "masters_union" AS (
         SELECT "m"."master_id" AS "user_id",
            "m"."name",
                CASE
                    WHEN ("m"."phone_digits" IS NULL) THEN NULL::"text"
                    WHEN (("length"("m"."phone_digits") = 12) AND ("left"("m"."phone_digits", 2) = '55'::"text")) THEN ((('+'::"text" || "left"("m"."phone_digits", 4)) || '9'::"text") || "right"("m"."phone_digits", 8))
                    WHEN ("length"("m"."phone_digits") = 10) THEN ((('+55'::"text" || "left"("m"."phone_digits", 2)) || '9'::"text") || "right"("m"."phone_digits", 8))
                    WHEN ("length"("m"."phone_digits") = 11) THEN ('+55'::"text" || "m"."phone_digits")
                    WHEN (("length"("m"."phone_digits") = 13) AND ("left"("m"."phone_digits", 2) = '55'::"text")) THEN ('+'::"text" || "m"."phone_digits")
                    ELSE ('+'::"text" || "m"."phone_digits")
                END AS "phone",
            "m"."email",
            NULL::"text" AS "master_id",
            'master'::"text" AS "roles",
            "m"."created_at",
            true AS "account_active",
            NULL::timestamp with time zone AS "human_mode_until"
           FROM "masters_clean" "m"
        )
 SELECT "u"."user_id",
    "u"."name",
        CASE
            WHEN ("u"."phone_digits" IS NULL) THEN NULL::"text"
            WHEN (("length"("u"."phone_digits") = 12) AND ("left"("u"."phone_digits", 2) = '55'::"text")) THEN ((('+'::"text" || "left"("u"."phone_digits", 4)) || '9'::"text") || "right"("u"."phone_digits", 8))
            WHEN ("length"("u"."phone_digits") = 10) THEN ((('+55'::"text" || "left"("u"."phone_digits", 2)) || '9'::"text") || "right"("u"."phone_digits", 8))
            WHEN ("length"("u"."phone_digits") = 11) THEN ('+55'::"text" || "u"."phone_digits")
            WHEN (("length"("u"."phone_digits") = 13) AND ("left"("u"."phone_digits", 2) = '55'::"text")) THEN ('+'::"text" || "u"."phone_digits")
            ELSE ('+'::"text" || "u"."phone_digits")
        END AS "phone",
    "u"."email",
    "u"."master_id",
    "concat_ws"(','::"text", NULLIF("rb"."base_roles", ''::"text"),
        CASE
            WHEN ("reg"."is_athlete" AND (COALESCE("rb"."base_roles", ''::"text") !~ '(^|,)athlete(,|$)'::"text")) THEN 'athlete'::"text"
            ELSE NULL::"text"
        END) AS "roles",
    "u"."created_at",
        CASE
            WHEN COALESCE("rb"."is_master", false) THEN true
            WHEN COALESCE("rb"."is_coach", false) THEN true
            WHEN COALESCE("reg"."athlete_enabled", false) THEN true
            ELSE COALESCE("u"."account_active", false)
        END AS "account_active",
    "u"."human_mode_until"
   FROM (("users_clean" "u"
     LEFT JOIN "role_base" "rb" ON (("rb"."user_id" = "u"."user_id")))
     LEFT JOIN "reg" ON (("reg"."user_id" = "u"."user_id")))
UNION ALL
 SELECT "mu"."user_id",
    "mu"."name",
    "mu"."phone",
    "mu"."email",
    "mu"."master_id",
    "mu"."roles",
    "mu"."created_at",
    "mu"."account_active",
    "mu"."human_mode_until"
   FROM "masters_union" "mu";


ALTER VIEW "public"."users_all" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."users_athletes" WITH ("security_invoker"='true') AS
 SELECT DISTINCT "public"."only_digits"(("payload" ->> 'REG_DOC | Documento (CPF)'::"text")) AS "user_id",
    ("payload" ->> 'REG_NAME | Nome completo'::"text") AS "name",
    "public"."normalize_phone"(("payload" ->> 'REG_ATHLETE_PHONE | Telefone do atleta (WhatsApp, com DDD)'::"text")) AS "phone",
    'athlete'::"text" AS "role"
   FROM "public"."athlete_registration"
  WHERE (("payload" ? 'REG_DOC | Documento (CPF)'::"text") AND ("public"."only_digits"(("payload" ->> 'REG_DOC | Documento (CPF)'::"text")) <> ''::"text"));


ALTER VIEW "public"."users_athletes" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."users_coaches" AS
 WITH "coach_phones_raw" AS (
         SELECT DISTINCT NULLIF("regexp_replace"(COALESCE("ar"."coach_phone", ''::"text"), '\D'::"text", ''::"text", 'g'::"text"), ''::"text") AS "phone_digits"
           FROM "public"."athlete_registration" "ar"
          WHERE (("ar"."kind" = 'registration'::"text") AND ("ar"."athlete_enabled" IS TRUE) AND (NULLIF(TRIM(BOTH FROM "ar"."coach_phone"), ''::"text") IS NOT NULL))
        ), "coach_phones" AS (
         SELECT DISTINCT
                CASE
                    WHEN ("coach_phones_raw"."phone_digits" IS NULL) THEN NULL::"text"
                    WHEN (("length"("coach_phones_raw"."phone_digits") = 12) AND ("left"("coach_phones_raw"."phone_digits", 2) = '55'::"text")) THEN (("left"("coach_phones_raw"."phone_digits", 4) || '9'::"text") || "right"("coach_phones_raw"."phone_digits", 8))
                    WHEN ("length"("coach_phones_raw"."phone_digits") = 10) THEN ((('55'::"text" || "left"("coach_phones_raw"."phone_digits", 2)) || '9'::"text") || "right"("coach_phones_raw"."phone_digits", 8))
                    WHEN ("length"("coach_phones_raw"."phone_digits") = 11) THEN ('55'::"text" || "coach_phones_raw"."phone_digits")
                    WHEN (("length"("coach_phones_raw"."phone_digits") = 13) AND ("left"("coach_phones_raw"."phone_digits", 2) = '55'::"text")) THEN "coach_phones_raw"."phone_digits"
                    ELSE "coach_phones_raw"."phone_digits"
                END AS "phone_key"
           FROM "coach_phones_raw"
        ), "users_raw" AS (
         SELECT "u_1"."user_id",
            "u_1"."name",
            "u_1"."phone",
            NULLIF("regexp_replace"(COALESCE("u_1"."phone", ''::"text"), '\D'::"text", ''::"text", 'g'::"text"), ''::"text") AS "phone_digits"
           FROM "public"."users" "u_1"
        ), "users_normalized" AS (
         SELECT "u_1"."user_id",
            "u_1"."name",
            "u_1"."phone",
                CASE
                    WHEN ("u_1"."phone_digits" IS NULL) THEN NULL::"text"
                    WHEN (("length"("u_1"."phone_digits") = 12) AND ("left"("u_1"."phone_digits", 2) = '55'::"text")) THEN (("left"("u_1"."phone_digits", 4) || '9'::"text") || "right"("u_1"."phone_digits", 8))
                    WHEN ("length"("u_1"."phone_digits") = 10) THEN ((('55'::"text" || "left"("u_1"."phone_digits", 2)) || '9'::"text") || "right"("u_1"."phone_digits", 8))
                    WHEN ("length"("u_1"."phone_digits") = 11) THEN ('55'::"text" || "u_1"."phone_digits")
                    WHEN (("length"("u_1"."phone_digits") = 13) AND ("left"("u_1"."phone_digits", 2) = '55'::"text")) THEN "u_1"."phone_digits"
                    ELSE "u_1"."phone_digits"
                END AS "phone_key"
           FROM "users_raw" "u_1"
        )
 SELECT DISTINCT "u"."user_id",
    "u"."name",
    "u"."phone",
    'coach'::"text" AS "role"
   FROM ("users_normalized" "u"
     JOIN "coach_phones" "cp" ON (("cp"."phone_key" = "u"."phone_key")))
  WHERE ("u"."phone_key" IS NOT NULL);


ALTER VIEW "public"."users_coaches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users_identity" (
    "user_id" "text" NOT NULL,
    "phone" "text",
    "email" "text",
    "password_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "must_change" boolean DEFAULT true,
    "name" "text",
    "role" "text",
    "athlete_id" "text",
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."users_identity" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_training_ewma_world" AS
 WITH RECURSIVE "ordered" AS (
         SELECT "v_training_load_base_world"."athlete_id",
            "v_training_load_base_world"."data",
            "v_training_load_base_world"."load",
            "row_number"() OVER (PARTITION BY "v_training_load_base_world"."athlete_id" ORDER BY "v_training_load_base_world"."data") AS "rn"
           FROM "public"."v_training_load_base_world"
        ), "rec" AS (
         SELECT "ordered"."athlete_id",
            "ordered"."data",
            "ordered"."load",
            "ordered"."rn",
            ("ordered"."load")::double precision AS "ewma_acute",
            ("ordered"."load")::double precision AS "ewma_chronic"
           FROM "ordered"
          WHERE ("ordered"."rn" = 1)
        UNION ALL
         SELECT "o"."athlete_id",
            "o"."data",
            "o"."load",
            "o"."rn",
            (("r"."ewma_acute" * ("exp"((((- ("o"."data" - "r"."data")))::numeric / 7.0)))::double precision) + (("o"."load" * ((1)::numeric - "exp"((((- ("o"."data" - "r"."data")))::numeric / 7.0)))))::double precision) AS "ewma_acute",
            (("r"."ewma_chronic" * ("exp"((((- ("o"."data" - "r"."data")))::numeric / 28.0)))::double precision) + (("o"."load" * ((1)::numeric - "exp"((((- ("o"."data" - "r"."data")))::numeric / 28.0)))))::double precision) AS "ewma_chronic"
           FROM ("ordered" "o"
             JOIN "rec" "r" ON ((("r"."athlete_id" = "o"."athlete_id") AND ("o"."rn" = ("r"."rn" + 1)))))
        )
 SELECT "athlete_id",
    "data",
    "load",
    "round"(("ewma_acute")::numeric, 2) AS "ewma_acute",
    "round"(("ewma_chronic")::numeric, 2) AS "ewma_chronic",
    "round"(
        CASE
            WHEN ("ewma_chronic" = (0)::double precision) THEN NULL::numeric
            ELSE (("ewma_acute" / "ewma_chronic"))::numeric
        END, 3) AS "ewma_acwr"
   FROM "rec";


ALTER VIEW "public"."v_training_ewma_world" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_training_risk_world" AS
 SELECT "m"."athlete_id",
    "m"."data" AS "reference_date",
    "m"."acwr",
    "e"."ewma_acwr",
    "m"."monotony",
    "m"."strain",
    "round"(((COALESCE("m"."acwr", (1)::numeric) + COALESCE("e"."ewma_acwr", (1)::numeric)) / (2)::numeric), 2) AS "risk_score",
        CASE
            WHEN ("m"."acwr" > 1.5) THEN 'high'::"text"
            WHEN ("m"."acwr" > 1.3) THEN 'moderate'::"text"
            WHEN ("m"."acwr" < 0.8) THEN 'underload'::"text"
            ELSE 'optimal'::"text"
        END AS "risk_level"
   FROM ("public"."v_training_metrics_world" "m"
     LEFT JOIN "public"."v_training_ewma_world" "e" ON ((("e"."athlete_id" = "m"."athlete_id") AND ("e"."data" <= "m"."data"))));


ALTER VIEW "public"."v_training_risk_world" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."weekly_analysis_view" WITH ("security_invoker"='true') AS
 SELECT "id",
    "athlete_id",
    "start_date",
    "desempenho",
    "adesao_nutricional",
    "dieta_comentarios",
    "cansaco_acao",
    "semana_comentarios",
    "eventos",
    "inserted_at",
    (("desempenho" - "avg"("desempenho") OVER (PARTITION BY "athlete_id")) / NULLIF("stddev_samp"("desempenho") OVER (PARTITION BY "athlete_id"), (0)::numeric)) AS "desempenho_z",
    (("adesao_nutricional" - "avg"("adesao_nutricional") OVER (PARTITION BY "athlete_id")) / NULLIF("stddev_samp"("adesao_nutricional") OVER (PARTITION BY "athlete_id"), (0)::numeric)) AS "adesao_z"
   FROM "public"."weekly_analysis" "w";


ALTER VIEW "public"."weekly_analysis_view" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_liga_minds_athlete_score" AS
 WITH "athletes" AS (
         SELECT "a"."athlete_id",
            "a"."athlete_name",
            "a"."team_name",
            "a"."athlete_phone",
            "a"."photo_url",
            "a"."instagram"
           FROM "public"."api_athletes" "a"
        ), "timeline" AS (
         SELECT "t"."athlete_id",
            "t"."athlete_name",
            "t"."questionnaire",
            "t"."questionnaire_sent",
            "t"."questionnaire_answered",
            "t"."response_status",
            "t"."response_minutes"
           FROM "public"."minds_engagement_timeline" "t"
        ), "sent_stats" AS (
         SELECT "timeline"."athlete_id",
            "timeline"."questionnaire",
            "count"(*) AS "sent_count",
            "count"(*) FILTER (WHERE ("timeline"."questionnaire_answered" IS NOT NULL)) AS "answered_count",
            "count"(*) FILTER (WHERE ("timeline"."response_status" = 'answered_same_day'::"text")) AS "same_day_count",
            "count"(*) FILTER (WHERE ("timeline"."response_status" = 'answered_late'::"text")) AS "late_count",
            "count"(*) FILTER (WHERE ("timeline"."response_status" = 'not_answered'::"text")) AS "not_answered_count",
            "round"(((100.0 * ("count"(*) FILTER (WHERE ("timeline"."questionnaire_answered" IS NOT NULL)))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "adherence_percent"
           FROM "timeline"
          GROUP BY "timeline"."athlete_id", "timeline"."questionnaire"
        ), "repeat_unanswered" AS (
         SELECT "timeline"."athlete_id",
            "timeline"."questionnaire",
            "count"(*) FILTER (WHERE ("timeline"."questionnaire_answered" IS NULL)) AS "unanswered_sends"
           FROM "timeline"
          GROUP BY "timeline"."athlete_id", "timeline"."questionnaire"
        ), "repeat_penalty" AS (
         SELECT "repeat_unanswered"."athlete_id",
            COALESCE("sum"(
                CASE
                    WHEN ("repeat_unanswered"."unanswered_sends" <= 1) THEN (0)::bigint
                    ELSE ("repeat_unanswered"."unanswered_sends" - 1)
                END), (0)::numeric) AS "repeated_unanswered_sends"
           FROM "repeat_unanswered"
          GROUP BY "repeat_unanswered"."athlete_id"
        ), "engagement_block" AS (
         SELECT "a"."athlete_id",
            "round"(COALESCE("avg"(
                CASE "s"."questionnaire"
                    WHEN 'pre'::"text" THEN ("s"."adherence_percent" * 0.10)
                    WHEN 'post'::"text" THEN ("s"."adherence_percent" * 0.10)
                    WHEN 'weekly'::"text" THEN ("s"."adherence_percent" * 0.06)
                    WHEN 'quarterly'::"text" THEN ("s"."adherence_percent" * 0.04)
                    WHEN 'semiannual'::"text" THEN ("s"."adherence_percent" * 0.04)
                    WHEN 'construcional'::"text" THEN ("s"."adherence_percent" * 0.06)
                    ELSE (0)::numeric
                END), (0)::numeric), 2) AS "engagement_score_raw",
            COALESCE("sum"("s"."sent_count"), (0)::numeric) AS "questionnaires_sent_total",
            COALESCE("sum"("s"."answered_count"), (0)::numeric) AS "questionnaires_answered_total",
            COALESCE("sum"("s"."same_day_count"), (0)::numeric) AS "same_day_total",
            COALESCE("sum"("s"."late_count"), (0)::numeric) AS "late_total",
            COALESCE("sum"("s"."not_answered_count"), (0)::numeric) AS "not_answered_total"
           FROM ("athletes" "a"
             LEFT JOIN "sent_stats" "s" ON (("s"."athlete_id" = "a"."athlete_id")))
          GROUP BY "a"."athlete_id"
        ), "speed_block" AS (
         SELECT "timeline"."athlete_id",
            "round"(LEAST((10)::numeric, COALESCE(((((("count"(*) FILTER (WHERE ("timeline"."response_status" = 'answered_same_day'::"text")))::numeric * 1.0) + (("count"(*) FILTER (WHERE ("timeline"."response_status" = 'answered_late'::"text")))::numeric * 0.4)) / (NULLIF("count"(*), 0))::numeric) * (10)::numeric), (0)::numeric)), 2) AS "response_speed_score"
           FROM "timeline"
          GROUP BY "timeline"."athlete_id"
        ), "behavior_block" AS (
         SELECT "b"."athlete_id",
            COALESCE("b"."max_consecutive_days", (0)::bigint) AS "streak_days",
                CASE
                    WHEN (COALESCE("b"."max_consecutive_days", (0)::bigint) >= 10) THEN 10
                    WHEN (COALESCE("b"."max_consecutive_days", (0)::bigint) >= 6) THEN 8
                    WHEN (COALESCE("b"."max_consecutive_days", (0)::bigint) >= 3) THEN 5
                    WHEN (COALESCE("b"."max_consecutive_days", (0)::bigint) >= 1) THEN 2
                    ELSE 0
                END AS "consistency_score"
           FROM "public"."minds_behavior_analytics" "b"
        ), "flags_block" AS (
         SELECT "f"."athlete_id",
            "count"(*) AS "flag_days",
            COALESCE("sum"("f"."flag_count"), (0)::bigint) AS "total_flag_count",
            COALESCE("max"("f"."flag_count"), 0) AS "max_flag_count",
            COALESCE("avg"(("f"."attention_level")::numeric), (0)::numeric) AS "avg_attention_level",
            COALESCE("max"("f"."attention_level"), 0) AS "max_attention_level",
            "count"(*) FILTER (WHERE ("f"."attention_level" >= 2)) AS "high_attention_days"
           FROM "public"."api_flags_events" "f"
          GROUP BY "f"."athlete_id"
        ), "stability_block" AS (
         SELECT "a"."athlete_id",
            "round"(GREATEST((0)::numeric, ((((20)::numeric - ((COALESCE("f"."total_flag_count", (0)::bigint))::numeric * 1.5)) - ((COALESCE("f"."high_attention_days", (0)::bigint) * 2))::numeric) - ((COALESCE("f"."max_attention_level", 0))::numeric * 1.5))), 2) AS "stability_score"
           FROM ("athletes" "a"
             LEFT JOIN "flags_block" "f" ON (("f"."athlete_id" = "a"."athlete_id")))
        ), "brums_last" AS (
         SELECT DISTINCT ON ("b"."athlete_id") "b"."athlete_id",
            "b"."data",
            "b"."vigor",
            "b"."fatigue",
            "b"."dth",
            "b"."pattern_burnout",
            "b"."pattern_flat",
            "b"."pattern_hyperactivation"
           FROM "public"."brums_analysis_view" "b"
          ORDER BY "b"."athlete_id", "b"."data" DESC, "b"."inserted_at" DESC
        ), "mood_block" AS (
         SELECT "brums_last"."athlete_id",
            "round"(GREATEST((0)::numeric, LEAST((10)::numeric, ((((((10)::numeric + (COALESCE("brums_last"."vigor", (0)::numeric) * 0.2)) - (COALESCE("brums_last"."fatigue", (0)::numeric) * 0.6)) - (COALESCE("brums_last"."dth", (0)::numeric) * 0.15)) - (
                CASE
                    WHEN COALESCE("brums_last"."pattern_burnout", false) THEN 3
                    ELSE 0
                END)::numeric) - (
                CASE
                    WHEN COALESCE("brums_last"."pattern_flat", false) THEN 2
                    ELSE 0
                END)::numeric))), 2) AS "mood_score"
           FROM "brums_last"
        ), "restq_last" AS (
         SELECT DISTINCT ON ("r"."athlete_id") "r"."athlete_id",
            "r"."data",
            "r"."sleep_quality",
            "r"."recovery_index",
            "r"."stress_index",
            "r"."lack_energy",
            "r"."physical_complaints",
            "r"."balance"
           FROM "public"."restq_analysis_view" "r"
          ORDER BY "r"."athlete_id", "r"."data" DESC, "r"."inserted_at" DESC
        ), "recovery_block" AS (
         SELECT "restq_last"."athlete_id",
            "round"(GREATEST((0)::numeric, LEAST((10)::numeric, (((((((5)::numeric + (COALESCE("restq_last"."sleep_quality", (0)::numeric) * 0.6)) + (COALESCE("restq_last"."recovery_index", (0)::numeric) * 0.8)) + (COALESCE("restq_last"."balance", (0)::numeric) * 0.5)) - (COALESCE("restq_last"."stress_index", (0)::numeric) * 0.8)) - (COALESCE("restq_last"."lack_energy", (0)::numeric) * 0.5)) - (COALESCE("restq_last"."physical_complaints", (0)::numeric) * 0.5)))), 2) AS "recovery_score"
           FROM "restq_last"
        ), "diet_last" AS (
         SELECT DISTINCT ON ("d"."athlete_id") "d"."athlete_id",
            "d"."data",
            "d"."adherence_score",
            "d"."gi_distress",
            "d"."weight_kg"
           FROM "public"."diet_daily" "d"
          ORDER BY "d"."athlete_id", "d"."data" DESC, "d"."inserted_at" DESC
        ), "weekly_last" AS (
         SELECT DISTINCT ON ("w"."athlete_id") "w"."athlete_id",
            "w"."start_date",
            "w"."adesao_nutricional",
            "w"."desempenho"
           FROM "public"."weekly_analysis_view" "w"
          ORDER BY "w"."athlete_id", "w"."start_date" DESC, "w"."inserted_at" DESC
        ), "nutrition_block" AS (
         SELECT "a"."athlete_id",
            "round"(GREATEST((0)::numeric, LEAST((5)::numeric, (((COALESCE("d"."adherence_score", (0)::numeric) * 0.03) + (COALESCE("w"."adesao_nutricional", (0)::numeric) * 0.2)) - (COALESCE("d"."gi_distress", (0)::numeric) * 0.5)))), 2) AS "nutrition_score"
           FROM (("athletes" "a"
             LEFT JOIN "diet_last" "d" ON (("d"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "weekly_last" "w" ON (("w"."athlete_id" = "a"."athlete_id")))
        ), "load_last" AS (
         SELECT DISTINCT ON ("l"."athlete_id") "l"."athlete_id",
            "l"."data",
            "l"."acwr",
            "l"."monotony",
            "l"."strain"
           FROM "public"."v_training_metrics_world" "l"
          ORDER BY "l"."athlete_id", "l"."data" DESC
        ), "load_risk_last" AS (
         SELECT DISTINCT ON ("r"."athlete_id") "r"."athlete_id",
            "r"."reference_date",
            "r"."ewma_acwr",
            "r"."risk_score",
            "r"."risk_level"
           FROM "public"."v_training_risk_world" "r"
          ORDER BY "r"."athlete_id", "r"."reference_date" DESC
        ), "load_block" AS (
         SELECT "a"."athlete_id",
            "round"(GREATEST((0)::numeric, LEAST((5)::numeric, ((((((5 -
                CASE
                    WHEN ("l"."acwr" IS NULL) THEN 0
                    WHEN ("l"."acwr" > 1.5) THEN 2
                    WHEN ("l"."acwr" > 1.3) THEN 1
                    WHEN ("l"."acwr" < 0.8) THEN 1
                    ELSE 0
                END))::numeric -
                CASE
                    WHEN ("lr"."ewma_acwr" IS NULL) THEN (0)::numeric
                    WHEN ("lr"."ewma_acwr" > 1.5) THEN 1.5
                    WHEN ("lr"."ewma_acwr" > 1.3) THEN 0.8
                    ELSE (0)::numeric
                END) -
                CASE
                    WHEN (("l"."monotony" IS NOT NULL) AND ("l"."monotony" > 2.5)) THEN 0.8
                    ELSE (0)::numeric
                END) -
                CASE
                    WHEN (("l"."strain" IS NOT NULL) AND ("l"."strain" > (6000)::numeric)) THEN 0.8
                    ELSE (0)::numeric
                END) -
                CASE
                    WHEN ("lr"."risk_level" = 'high'::"text") THEN (1)::numeric
                    WHEN ("lr"."risk_level" = 'moderate'::"text") THEN 0.5
                    ELSE (0)::numeric
                END))), 2) AS "load_score"
           FROM (("athletes" "a"
             LEFT JOIN "load_last" "l" ON (("l"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "load_risk_last" "lr" ON (("lr"."athlete_id" = "a"."athlete_id")))
        ), "badge_block" AS (
         SELECT "a"."athlete_id",
            ((((
                CASE
                    WHEN (COALESCE("bc"."streak_days", (0)::bigint) >= 10) THEN 1
                    ELSE 0
                END +
                CASE
                    WHEN (COALESCE("eb"."same_day_total", (0)::numeric) >= (5)::numeric) THEN 1
                    ELSE 0
                END) +
                CASE
                    WHEN (COALESCE("sb"."stability_score", (0)::numeric) >= (16)::numeric) THEN 1
                    ELSE 0
                END) +
                CASE
                    WHEN (COALESCE("nb"."nutrition_score", (0)::numeric) >= (4)::numeric) THEN 1
                    ELSE 0
                END) +
                CASE
                    WHEN (COALESCE("lb"."load_score", (0)::numeric) >= (4)::numeric) THEN 1
                    ELSE 0
                END) AS "badges_count",
                CASE
                    WHEN (COALESCE("bc"."streak_days", (0)::bigint) >= 10) THEN 'Guardião da Rotina'::"text"
                    WHEN (COALESCE("sb"."stability_score", (0)::numeric) >= (16)::numeric) THEN 'Muralha Verde'::"text"
                    WHEN (COALESCE("eb"."same_day_total", (0)::numeric) >= (5)::numeric) THEN 'Resposta Relâmpago'::"text"
                    WHEN (COALESCE("nb"."nutrition_score", (0)::numeric) >= (4)::numeric) THEN 'Nutri em Dia'::"text"
                    WHEN (COALESCE("lb"."load_score", (0)::numeric) >= (4)::numeric) THEN 'Carga Inteligente'::"text"
                    ELSE 'Em evolução'::"text"
                END AS "current_badge"
           FROM ((((("athletes" "a"
             LEFT JOIN "behavior_block" "bc" ON (("bc"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "engagement_block" "eb" ON (("eb"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "stability_block" "sb" ON (("sb"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "nutrition_block" "nb" ON (("nb"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "load_block" "lb" ON (("lb"."athlete_id" = "a"."athlete_id")))
        ), "final_base" AS (
         SELECT "a"."athlete_id",
            "a"."athlete_name",
            "a"."team_name",
            "a"."athlete_phone",
            "a"."photo_url",
            "a"."instagram",
            "round"(COALESCE("eb"."engagement_score_raw", (0)::numeric), 2) AS "engagement_score",
            "round"(COALESCE("sp"."response_speed_score", (0)::numeric), 2) AS "response_speed_score",
            "round"((COALESCE("bb"."consistency_score", 0))::numeric, 2) AS "consistency_score",
            "round"(COALESCE("sb"."stability_score", (0)::numeric), 2) AS "stability_score",
            "round"(COALESCE("mb"."mood_score", (0)::numeric), 2) AS "mood_score",
            "round"(COALESCE("rb"."recovery_score", (0)::numeric), 2) AS "recovery_score",
            "round"(COALESCE("nb"."nutrition_score", (0)::numeric), 2) AS "nutrition_score",
            "round"(COALESCE("lb"."load_score", (0)::numeric), 2) AS "load_score",
            COALESCE("bb"."streak_days", (0)::bigint) AS "streak_days",
            COALESCE("bp"."badges_count", 0) AS "badges_count",
            "bp"."current_badge",
            COALESCE("eb"."questionnaires_sent_total", (0)::numeric) AS "questionnaires_sent_total",
            COALESCE("eb"."questionnaires_answered_total", (0)::numeric) AS "questionnaires_answered_total",
            COALESCE("eb"."same_day_total", (0)::numeric) AS "same_day_total",
            COALESCE("eb"."late_total", (0)::numeric) AS "late_total",
            COALESCE("eb"."not_answered_total", (0)::numeric) AS "not_answered_total",
            COALESCE("rp"."repeated_unanswered_sends", (0)::numeric) AS "repeated_unanswered_sends",
            "round"(GREATEST((0)::numeric, ((((((((COALESCE("eb"."engagement_score_raw", (0)::numeric) + COALESCE("sp"."response_speed_score", (0)::numeric)) + (COALESCE("bb"."consistency_score", 0))::numeric) + COALESCE("sb"."stability_score", (0)::numeric)) + COALESCE("mb"."mood_score", (0)::numeric)) + COALESCE("rb"."recovery_score", (0)::numeric)) + COALESCE("nb"."nutrition_score", (0)::numeric)) + COALESCE("lb"."load_score", (0)::numeric)) - LEAST((COALESCE("rp"."repeated_unanswered_sends", (0)::numeric) * 1.5), (12)::numeric))), 2) AS "total_score_raw"
           FROM (((((((((("athletes" "a"
             LEFT JOIN "engagement_block" "eb" ON (("eb"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "speed_block" "sp" ON (("sp"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "behavior_block" "bb" ON (("bb"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "stability_block" "sb" ON (("sb"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "mood_block" "mb" ON (("mb"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "recovery_block" "rb" ON (("rb"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "nutrition_block" "nb" ON (("nb"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "load_block" "lb" ON (("lb"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "badge_block" "bp" ON (("bp"."athlete_id" = "a"."athlete_id")))
             LEFT JOIN "repeat_penalty" "rp" ON (("rp"."athlete_id" = "a"."athlete_id")))
        ), "final_scored" AS (
         SELECT "fb"."athlete_id",
            "fb"."athlete_name",
            "fb"."team_name",
            "fb"."athlete_phone",
            "fb"."photo_url",
            "fb"."instagram",
            "fb"."engagement_score",
            "fb"."response_speed_score",
            "fb"."consistency_score",
            "fb"."stability_score",
            "fb"."mood_score",
            "fb"."recovery_score",
            "fb"."nutrition_score",
            "fb"."load_score",
            "fb"."streak_days",
            "fb"."badges_count",
            "fb"."current_badge",
            "fb"."questionnaires_sent_total",
            "fb"."questionnaires_answered_total",
            "fb"."same_day_total",
            "fb"."late_total",
            "fb"."not_answered_total",
            "fb"."repeated_unanswered_sends",
            "fb"."total_score_raw",
            "round"(LEAST("fb"."total_score_raw", (100)::numeric), 2) AS "total_score",
            (((((((COALESCE("fb"."questionnaires_answered_total", (0)::numeric) * (10)::numeric) + (COALESCE("fb"."same_day_total", (0)::numeric) * (5)::numeric)) + ((COALESCE("fb"."streak_days", (0)::bigint) * 4))::numeric) + ((COALESCE("fb"."badges_count", 0) * 20))::numeric) + ("floor"(COALESCE("fb"."stability_score", (0)::numeric)) * (2)::numeric)) - (COALESCE("fb"."repeated_unanswered_sends", (0)::numeric) * (5)::numeric)))::integer AS "xp_total"
           FROM "final_base" "fb"
        ), "ranked" AS (
         SELECT "fs"."athlete_id",
            "fs"."athlete_name",
            "fs"."team_name",
            "fs"."athlete_phone",
            "fs"."photo_url",
            "fs"."instagram",
            "fs"."engagement_score",
            "fs"."response_speed_score",
            "fs"."consistency_score",
            "fs"."stability_score",
            "fs"."mood_score",
            "fs"."recovery_score",
            "fs"."nutrition_score",
            "fs"."load_score",
            "fs"."streak_days",
            "fs"."badges_count",
            "fs"."current_badge",
            "fs"."questionnaires_sent_total",
            "fs"."questionnaires_answered_total",
            "fs"."same_day_total",
            "fs"."late_total",
            "fs"."not_answered_total",
            "fs"."repeated_unanswered_sends",
            "fs"."total_score_raw",
            "fs"."total_score",
            "fs"."xp_total",
            "dense_rank"() OVER (ORDER BY "fs"."total_score" DESC, "fs"."xp_total" DESC, "fs"."streak_days" DESC, "fs"."athlete_name") AS "position_overall",
            "dense_rank"() OVER (PARTITION BY "fs"."team_name" ORDER BY "fs"."total_score" DESC, "fs"."xp_total" DESC, "fs"."streak_days" DESC, "fs"."athlete_name") AS "position_team",
            "lag"("fs"."total_score") OVER (PARTITION BY "fs"."athlete_id" ORDER BY "fs"."total_score") AS "prev_score_dummy"
           FROM "final_scored" "fs"
        )
 SELECT "athlete_id",
    "athlete_name",
    "team_name",
    "athlete_phone",
    "photo_url",
    "instagram",
    "total_score",
    "xp_total",
    "engagement_score",
    "response_speed_score",
    "consistency_score",
    "stability_score",
    "mood_score",
    "recovery_score",
    "nutrition_score",
    "load_score",
    "streak_days",
    "badges_count",
    "current_badge",
    "questionnaires_sent_total",
    "questionnaires_answered_total",
    "same_day_total",
    "late_total",
    "not_answered_total",
    "repeated_unanswered_sends",
    "position_overall",
    "position_team",
        CASE
            WHEN ("total_score" >= (85)::numeric) THEN 'elite'::"text"
            WHEN ("total_score" >= (70)::numeric) THEN 'subindo'::"text"
            WHEN ("total_score" >= (50)::numeric) THEN 'estavel'::"text"
            ELSE 'em_risco'::"text"
        END AS "trend"
   FROM "ranked";


ALTER VIEW "public"."v_liga_minds_athlete_score" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_liga_minds_athlete_score_current_month" AS
 SELECT "athlete_id",
    "athlete_name",
    "team_name",
    "athlete_phone",
    "photo_url",
    "instagram",
    "total_score",
    "xp_total",
    "engagement_score",
    "response_speed_score",
    "consistency_score",
    "stability_score",
    "mood_score",
    "recovery_score",
    "nutrition_score",
    "load_score",
    "streak_days",
    "badges_count",
    "current_badge",
    "badge_list",
    "questionnaires_sent_total",
    "questionnaires_answered_total",
    "same_day_total",
    "late_total",
    "unresolved_total",
    "repeated_unanswered_sends",
    "total_flag_count",
    "max_flag_count",
    "avg_attention_level",
    "high_attention_days",
    "avg_vigor",
    "avg_fatigue",
    "avg_dth",
    "avg_sleep_quality",
    "avg_recovery_index",
    "avg_stress_index",
    "avg_lack_energy",
    "avg_physical_complaints",
    "avg_acwr",
    "avg_ewma_acwr",
    "avg_monotony",
    "avg_strain",
    "high_load_risk_days",
    "position_overall",
    "position_team",
    "trend"
   FROM "public"."rpc_liga_minds_athlete_score"(("date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone))::"date", CURRENT_DATE) "rpc_liga_minds_athlete_score"("athlete_id", "athlete_name", "team_name", "athlete_phone", "photo_url", "instagram", "total_score", "xp_total", "engagement_score", "response_speed_score", "consistency_score", "stability_score", "mood_score", "recovery_score", "nutrition_score", "load_score", "streak_days", "badges_count", "current_badge", "badge_list", "questionnaires_sent_total", "questionnaires_answered_total", "same_day_total", "late_total", "unresolved_total", "repeated_unanswered_sends", "total_flag_count", "max_flag_count", "avg_attention_level", "high_attention_days", "avg_vigor", "avg_fatigue", "avg_dth", "avg_sleep_quality", "avg_recovery_index", "avg_stress_index", "avg_lack_energy", "avg_physical_complaints", "avg_acwr", "avg_ewma_acwr", "avg_monotony", "avg_strain", "high_load_risk_days", "position_overall", "position_team", "trend");


ALTER VIEW "public"."v_liga_minds_athlete_score_current_month" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_liga_minds_team_score" AS
 WITH "athlete_scores" AS (
         SELECT "v_liga_minds_athlete_score"."athlete_id",
            "v_liga_minds_athlete_score"."athlete_name",
            "v_liga_minds_athlete_score"."team_name",
            "v_liga_minds_athlete_score"."athlete_phone",
            "v_liga_minds_athlete_score"."photo_url",
            "v_liga_minds_athlete_score"."instagram",
            "v_liga_minds_athlete_score"."total_score",
            "v_liga_minds_athlete_score"."xp_total",
            "v_liga_minds_athlete_score"."engagement_score",
            "v_liga_minds_athlete_score"."response_speed_score",
            "v_liga_minds_athlete_score"."consistency_score",
            "v_liga_minds_athlete_score"."stability_score",
            "v_liga_minds_athlete_score"."mood_score",
            "v_liga_minds_athlete_score"."recovery_score",
            "v_liga_minds_athlete_score"."nutrition_score",
            "v_liga_minds_athlete_score"."load_score",
            "v_liga_minds_athlete_score"."streak_days",
            "v_liga_minds_athlete_score"."badges_count",
            "v_liga_minds_athlete_score"."current_badge",
            "v_liga_minds_athlete_score"."questionnaires_sent_total",
            "v_liga_minds_athlete_score"."questionnaires_answered_total",
            "v_liga_minds_athlete_score"."same_day_total",
            "v_liga_minds_athlete_score"."late_total",
            "v_liga_minds_athlete_score"."not_answered_total",
            "v_liga_minds_athlete_score"."repeated_unanswered_sends",
            "v_liga_minds_athlete_score"."position_overall",
            "v_liga_minds_athlete_score"."position_team",
            "v_liga_minds_athlete_score"."trend"
           FROM "public"."v_liga_minds_athlete_score"
        ), "team_base" AS (
         SELECT "athlete_scores"."team_name",
            "count"(*) AS "athletes_count",
            "round"("avg"("athlete_scores"."total_score"), 2) AS "avg_athlete_score",
            "sum"("athlete_scores"."xp_total") AS "total_xp",
            "round"("avg"("athlete_scores"."engagement_score"), 2) AS "adherence_team_score",
            "round"("avg"("athlete_scores"."stability_score"), 2) AS "stability_team_score",
            "round"("avg"("athlete_scores"."consistency_score"), 2) AS "streak_team_score",
            "min"("athlete_scores"."position_overall") AS "best_overall_position"
           FROM "athlete_scores"
          WHERE ("athlete_scores"."team_name" IS NOT NULL)
          GROUP BY "athlete_scores"."team_name"
        ), "team_top_athlete" AS (
         SELECT DISTINCT ON ("athlete_scores"."team_name") "athlete_scores"."team_name",
            "athlete_scores"."athlete_name" AS "top_athlete_name",
            "athlete_scores"."total_score" AS "top_athlete_score"
           FROM "athlete_scores"
          WHERE ("athlete_scores"."team_name" IS NOT NULL)
          ORDER BY "athlete_scores"."team_name", "athlete_scores"."total_score" DESC, "athlete_scores"."xp_total" DESC, "athlete_scores"."athlete_name"
        ), "team_final" AS (
         SELECT "tb"."team_name",
            "tb"."athletes_count",
            "tb"."avg_athlete_score",
            "tb"."total_xp",
            "tb"."adherence_team_score",
            "tb"."stability_team_score",
            "tb"."streak_team_score",
            "ta"."top_athlete_name",
            "ta"."top_athlete_score",
            "round"(((((("tb"."avg_athlete_score" * 0.50) + ("tb"."adherence_team_score" * 0.20)) + ("tb"."stability_team_score" * 0.15)) + ("tb"."streak_team_score" * 0.10)) + (LEAST((("tb"."total_xp")::numeric / 1000.0), (5)::numeric) * 0.05)), 2) AS "team_score"
           FROM ("team_base" "tb"
             LEFT JOIN "team_top_athlete" "ta" ON (("ta"."team_name" = "tb"."team_name")))
        )
 SELECT "team_name",
    "athletes_count",
    "avg_athlete_score",
    "total_xp",
    "adherence_team_score",
    "stability_team_score",
    "streak_team_score",
    "top_athlete_name",
    "top_athlete_score",
    "team_score",
    "dense_rank"() OVER (ORDER BY "team_score" DESC, "total_xp" DESC, "team_name") AS "team_position"
   FROM "team_final" "tf";


ALTER VIEW "public"."v_liga_minds_team_score" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_liga_minds_team_score_current_month" AS
 SELECT "team_name",
    "athletes_count",
    "avg_athlete_score",
    "total_xp",
    "adherence_team_score",
    "stability_team_score",
    "streak_team_score",
    "low_repeat_penalty_score",
    "team_score",
    "top_athlete_name",
    "top_athlete_score",
    "team_position"
   FROM "public"."rpc_liga_minds_team_score"(("date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone))::"date", CURRENT_DATE) "rpc_liga_minds_team_score"("team_name", "athletes_count", "avg_athlete_score", "total_xp", "adherence_team_score", "stability_team_score", "streak_team_score", "low_repeat_penalty_score", "team_score", "top_athlete_name", "top_athlete_score", "team_position");


ALTER VIEW "public"."v_liga_minds_team_score_current_month" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_pingo_alertas_command_center" AS
 WITH "latest_registration" AS (
         SELECT DISTINCT ON ("ar"."athlete_id") "ar"."athlete_id",
            "ar"."athlete_name",
            "ar"."team_name",
            "ar"."athlete_phone",
            "ar"."inserted_at"
           FROM "public"."athlete_registration" "ar"
          ORDER BY "ar"."athlete_id", "ar"."inserted_at" DESC NULLS LAST
        ), "normalized_pso" AS (
         SELECT "pso_1"."id",
            "pso_1"."athlete_id",
            "pso_1"."reference_date",
            "pso_1"."attention_level",
            "pso_1"."flag_count",
                CASE
                    WHEN ("pso_1"."flags" IS NULL) THEN '[]'::"jsonb"
                    WHEN ("jsonb_typeof"("pso_1"."flags") = 'array'::"text") THEN "pso_1"."flags"
                    WHEN (("jsonb_typeof"("pso_1"."flags") = 'string'::"text") AND ("left"("ltrim"(("pso_1"."flags" #>> '{}'::"text"[])), 1) = '['::"text")) THEN (("pso_1"."flags" #>> '{}'::"text"[]))::"jsonb"
                    WHEN ("jsonb_typeof"("pso_1"."flags") = 'string'::"text") THEN "jsonb_build_array"("to_jsonb"(("pso_1"."flags" #>> '{}'::"text"[])))
                    ELSE "jsonb_build_array"("pso_1"."flags")
                END AS "flags_json",
                CASE
                    WHEN ("pso_1"."rules_triggered" IS NULL) THEN '[]'::"jsonb"
                    WHEN ("jsonb_typeof"("pso_1"."rules_triggered") = 'array'::"text") THEN "pso_1"."rules_triggered"
                    WHEN (("jsonb_typeof"("pso_1"."rules_triggered") = 'string'::"text") AND ("left"("ltrim"(("pso_1"."rules_triggered" #>> '{}'::"text"[])), 1) = '['::"text")) THEN (("pso_1"."rules_triggered" #>> '{}'::"text"[]))::"jsonb"
                    WHEN (("jsonb_typeof"("pso_1"."rules_triggered") = 'string'::"text") AND ("left"("ltrim"(("pso_1"."rules_triggered" #>> '{}'::"text"[])), 1) = '{'::"text")) THEN "jsonb_build_array"((("pso_1"."rules_triggered" #>> '{}'::"text"[]))::"jsonb")
                    WHEN ("jsonb_typeof"("pso_1"."rules_triggered") = 'object'::"text") THEN "jsonb_build_array"("pso_1"."rules_triggered")
                    ELSE '[]'::"jsonb"
                END AS "rules_triggered_json",
                CASE
                    WHEN ("pso_1"."thresholds_used" IS NULL) THEN '{}'::"jsonb"
                    WHEN ("jsonb_typeof"("pso_1"."thresholds_used") = 'object'::"text") THEN "pso_1"."thresholds_used"
                    WHEN (("jsonb_typeof"("pso_1"."thresholds_used") = 'string'::"text") AND ("left"("ltrim"(("pso_1"."thresholds_used" #>> '{}'::"text"[])), 1) = '{'::"text")) THEN (("pso_1"."thresholds_used" #>> '{}'::"text"[]))::"jsonb"
                    ELSE '{}'::"jsonb"
                END AS "thresholds_used_json"
           FROM "public"."pingo_scoring_output" "pso_1"
        )
 SELECT "pso"."id",
    "pso"."athlete_id",
    "lr"."athlete_name",
    "lr"."team_name",
    "lr"."athlete_phone",
    "pso"."reference_date",
    "pso"."attention_level",
    "pso"."flag_count",
    "pso"."flags_json" AS "flags",
    "pso"."rules_triggered_json" AS "rules_triggered",
    "pso"."thresholds_used_json" AS "thresholds_used",
    "jsonb_array_length"("pso"."flags_json") AS "flags_count_json",
        CASE
            WHEN ("jsonb_array_length"("pso"."flags_json") > 0) THEN ("pso"."flags_json" ->> 0)
            ELSE NULL::"text"
        END AS "primary_flag",
        CASE
            WHEN ("jsonb_array_length"("pso"."rules_triggered_json") > 0) THEN (("pso"."rules_triggered_json" -> 0) ->> 'class'::"text")
            ELSE NULL::"text"
        END AS "primary_rule_class",
        CASE
            WHEN ("jsonb_array_length"("pso"."rules_triggered_json") > 0) THEN (("pso"."rules_triggered_json" -> 0) ->> 'flag'::"text")
            ELSE NULL::"text"
        END AS "primary_rule_flag",
        CASE
            WHEN ("jsonb_array_length"("pso"."rules_triggered_json") > 0) THEN (("pso"."rules_triggered_json" -> 0) ->> 'description'::"text")
            ELSE NULL::"text"
        END AS "primary_rule_description",
        CASE
            WHEN ("jsonb_array_length"("pso"."rules_triggered_json") > 0) THEN (("pso"."rules_triggered_json" -> 0) ->> 'source'::"text")
            ELSE NULL::"text"
        END AS "primary_rule_source",
        CASE
            WHEN ("jsonb_array_length"("pso"."rules_triggered_json") > 0) THEN (("pso"."rules_triggered_json" -> 0) ->> 'condition'::"text")
            ELSE NULL::"text"
        END AS "primary_rule_condition",
    (NULLIF((("pso"."rules_triggered_json" -> 0) ->> 'weight'::"text"), ''::"text"))::numeric AS "primary_rule_weight",
    ("pso"."thresholds_used_json" ->> 'vigor'::"text") AS "vigor_band",
    ("pso"."thresholds_used_json" ->> 'dth'::"text") AS "dth_band",
    (NULLIF(("pso"."thresholds_used_json" ->> 'adherence_low_days'::"text"), ''::"text"))::integer AS "adherence_low_days",
    (NULLIF(("pso"."thresholds_used_json" ->> 'dth_high_days'::"text"), ''::"text"))::integer AS "dth_high_days",
    (NULLIF(("pso"."thresholds_used_json" ->> 'vigor_low_days'::"text"), ''::"text"))::integer AS "vigor_low_days",
    (NULLIF(("pso"."thresholds_used_json" ->> 'vigor_volatility_7d'::"text"), ''::"text"))::numeric AS "vigor_volatility_7d",
    (NULLIF(("pso"."thresholds_used_json" ->> 'vigor_delta_1d'::"text"), ''::"text"))::numeric AS "vigor_delta_1d",
        CASE "pso"."attention_level"
            WHEN 0 THEN 'Sem alerta'::"text"
            WHEN 1 THEN 'Atenção leve'::"text"
            WHEN 2 THEN 'Atenção moderada'::"text"
            WHEN 3 THEN 'Atenção alta'::"text"
            ELSE 'Indefinido'::"text"
        END AS "attention_label"
   FROM ("normalized_pso" "pso"
     LEFT JOIN "latest_registration" "lr" ON (("lr"."athlete_id" = "pso"."athlete_id")));


ALTER VIEW "public"."v_pingo_alertas_command_center" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."weekly_analysis_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."weekly_analysis_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."weekly_analysis_id_seq" OWNED BY "public"."weekly_analysis"."id";



ALTER TABLE ONLY "public"."acsi_analysis" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."acsi_analysis_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."athlete_registration" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."athlete_registration_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."brums_analysis" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."brums_analysis_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."cbas_analysis" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."cbas_analysis_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."construcional_analysis" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."construcional_analysis_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."construcional_raw" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."construcional_raw_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."diet_daily" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."diet_daily_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."gses_analysis" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."gses_analysis_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."minds_notification_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."minds_notification_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pingo_athlete_notes" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pingo_athlete_notes_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pingo_scoring_output" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pingo_scoring_output_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pingo_user_messages" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pingo_user_messages_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pmcsq_analysis" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pmcsq_analysis_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."restq_analysis" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."restq_analysis_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."training_load_daily" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."training_load_daily_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."weekly_analysis" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."weekly_analysis_id_seq"'::"regclass");



ALTER TABLE ONLY "integration"."outbox"
    ADD CONSTRAINT "outbox_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."acsi_analysis"
    ADD CONSTRAINT "acsi_analysis_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."athlete_master_notes"
    ADD CONSTRAINT "athlete_master_notes_pkey" PRIMARY KEY ("athlete_id");



ALTER TABLE ONLY "public"."athlete_private_notes"
    ADD CONSTRAINT "athlete_private_notes_pkey" PRIMARY KEY ("athlete_id", "note_scope", "author_user_id");



ALTER TABLE ONLY "public"."athlete_registration"
    ADD CONSTRAINT "athlete_registration_athlete_id_key" UNIQUE ("athlete_id");



ALTER TABLE ONLY "public"."athlete_registration"
    ADD CONSTRAINT "athlete_registration_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."billing_subscriptions"
    ADD CONSTRAINT "billing_subscriptions_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."brums_analysis"
    ADD CONSTRAINT "brums_analysis_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cbas_analysis"
    ADD CONSTRAINT "cbas_analysis_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."coach_athletes"
    ADD CONSTRAINT "coach_athletes_pkey" PRIMARY KEY ("coach_id", "athlete_id");



ALTER TABLE ONLY "public"."construcional_analysis"
    ADD CONSTRAINT "construcional_analysis_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."construcional_raw"
    ADD CONSTRAINT "construcional_raw_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."diet_daily"
    ADD CONSTRAINT "diet_daily_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gses_analysis"
    ADD CONSTRAINT "gses_analysis_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."masters"
    ADD CONSTRAINT "masters_pkey" PRIMARY KEY ("master_id");



ALTER TABLE ONLY "public"."minds_athlete_delivery_state"
    ADD CONSTRAINT "minds_athlete_delivery_state_pkey" PRIMARY KEY ("athlete_id");



ALTER TABLE ONLY "public"."minds_notification_log"
    ADD CONSTRAINT "minds_notification_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."minds_notification_queue"
    ADD CONSTRAINT "minds_notification_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."minds_questionnaire_state"
    ADD CONSTRAINT "minds_questionnaire_state_pkey" PRIMARY KEY ("athlete_id");



ALTER TABLE ONLY "public"."minds_webhook_queue"
    ADD CONSTRAINT "minds_webhook_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pingo_athlete_notes"
    ADD CONSTRAINT "pingo_athlete_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pingo_chat_context"
    ADD CONSTRAINT "pingo_chat_context_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."pingo_scoring_output"
    ADD CONSTRAINT "pingo_scoring_output_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pingo_user_athletes"
    ADD CONSTRAINT "pingo_user_athletes_pkey" PRIMARY KEY ("user_id", "athlete_id");



ALTER TABLE ONLY "public"."pingo_user_messages"
    ADD CONSTRAINT "pingo_user_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pmcsq_analysis"
    ADD CONSTRAINT "pmcsq_analysis_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."restq_analysis"
    ADD CONSTRAINT "restq_analysis_athlete_date_uniq" UNIQUE ("athlete_id", "data");



ALTER TABLE ONLY "public"."restq_analysis"
    ADD CONSTRAINT "restq_analysis_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scoring_rules"
    ADD CONSTRAINT "scoring_rules_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."training_load_daily"
    ADD CONSTRAINT "training_load_daily_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_credentials"
    ADD CONSTRAINT "user_credentials_phone_key" UNIQUE ("phone");



ALTER TABLE ONLY "public"."user_credentials"
    ADD CONSTRAINT "user_credentials_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("user_id", "role");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."users_identity"
    ADD CONSTRAINT "users_identity_phone_key" UNIQUE ("phone");



ALTER TABLE ONLY "public"."users_identity"
    ADD CONSTRAINT "users_identity_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_phone_key" UNIQUE ("phone");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."weekly_analysis"
    ADD CONSTRAINT "weekly_analysis_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_outbox_pending" ON "integration"."outbox" USING "btree" ("delivered_at", "reserved_until", "occurred_at");



CREATE INDEX "idx_outbox_table_time" ON "integration"."outbox" USING "btree" ("schema_name", "table_name", "occurred_at" DESC);



CREATE INDEX "idx_outbox_txid" ON "integration"."outbox" USING "btree" ("txid");



CREATE INDEX "acsi_analysis_athlete_date_idx" ON "public"."acsi_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "athlete_registration_athlete_id_idx" ON "public"."athlete_registration" USING "btree" ("athlete_id", "inserted_at" DESC);



CREATE UNIQUE INDEX "brums_analysis_athlete_data_uniq" ON "public"."brums_analysis" USING "btree" ("athlete_id", "data");



CREATE INDEX "brums_analysis_athlete_date_idx" ON "public"."brums_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "cbas_analysis_athlete_date_idx" ON "public"."cbas_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "construcional_analysis_athlete_idx" ON "public"."construcional_analysis" USING "btree" ("athlete_id", "analyzed_at" DESC);



CREATE INDEX "construcional_raw_athlete_submitted_idx" ON "public"."construcional_raw" USING "btree" ("athlete_id", "submitted_at" DESC);



CREATE INDEX "diet_daily_athlete_date_idx" ON "public"."diet_daily" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "gses_analysis_athlete_date_idx" ON "public"."gses_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "idx_acsi_analysis_athlete_date" ON "public"."acsi_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "idx_athlete_private_notes_athlete" ON "public"."athlete_private_notes" USING "btree" ("athlete_id");



CREATE INDEX "idx_athlete_private_notes_author" ON "public"."athlete_private_notes" USING "btree" ("author_user_id");



CREATE INDEX "idx_athlete_private_notes_scope" ON "public"."athlete_private_notes" USING "btree" ("note_scope");



CREATE INDEX "idx_athlete_registration_coach_phone_digits" ON "public"."athlete_registration" USING "btree" ("regexp_replace"(COALESCE("coach_phone", ''::"text"), '\D'::"text", ''::"text", 'g'::"text"));



CREATE INDEX "idx_athlete_registration_latest" ON "public"."athlete_registration" USING "btree" ("athlete_id", "inserted_at" DESC);



CREATE INDEX "idx_brums_analysis_athlete_date" ON "public"."brums_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "idx_cbas_analysis_athlete_date" ON "public"."cbas_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "idx_diet_daily_athlete_date" ON "public"."diet_daily" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "idx_gses_analysis_athlete_date" ON "public"."gses_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "idx_madds_send_state" ON "public"."minds_athlete_delivery_state" USING "btree" ("send_state");



CREATE INDEX "idx_minds_log_athlete_type_day" ON "public"."minds_notification_log" USING "btree" ("athlete_id", "notification_type", "sent_at");



CREATE INDEX "idx_minds_queue_athlete_action_day" ON "public"."minds_notification_queue" USING "btree" ("athlete_id", "action_type", "created_at");



CREATE INDEX "idx_minds_queue_scan" ON "public"."minds_notification_queue" USING "btree" ("status", "due_at", "next_retry_at", "priority_rank", "created_at");



CREATE INDEX "idx_minds_queue_status_due" ON "public"."minds_notification_queue" USING "btree" ("status", "due_at", "next_retry_at");



CREATE INDEX "idx_minds_webhook_queue_athlete" ON "public"."minds_webhook_queue" USING "btree" ("athlete_id");



CREATE INDEX "idx_minds_webhook_queue_created" ON "public"."minds_webhook_queue" USING "btree" ("created_at");



CREATE INDEX "idx_mwq_dispatch" ON "public"."minds_webhook_queue" USING "btree" ("status", "available_at", "created_at");



CREATE INDEX "idx_mwq_pending_worker" ON "public"."minds_webhook_queue" USING "btree" ("status", "retry_count", "available_at", "created_at");



CREATE INDEX "idx_mwq_request_id" ON "public"."minds_webhook_queue" USING "btree" ("request_id");



CREATE INDEX "idx_mwq_worker" ON "public"."minds_webhook_queue" USING "btree" ("status", "available_at", "created_at");



CREATE INDEX "idx_pmcsq_analysis_athlete_date" ON "public"."pmcsq_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "idx_pso_alerts_main" ON "public"."pingo_scoring_output" USING "btree" ("attention_level", "reference_date" DESC, "athlete_id");



CREATE INDEX "idx_restq_analysis_athlete_date" ON "public"."restq_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "idx_training_load_daily_athlete_date" ON "public"."training_load_daily" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "idx_user_credentials_athlete_id" ON "public"."user_credentials" USING "btree" ("athlete_id");



CREATE INDEX "idx_user_credentials_phone" ON "public"."user_credentials" USING "btree" ("phone");



CREATE INDEX "idx_user_credentials_role" ON "public"."user_credentials" USING "btree" ("role");



CREATE INDEX "idx_users_identity_phone" ON "public"."users_identity" USING "btree" ("phone");



CREATE INDEX "idx_users_phone_digits" ON "public"."users" USING "btree" ("public"."only_digits"("phone"));



CREATE INDEX "idx_weekly_analysis_athlete_start" ON "public"."weekly_analysis" USING "btree" ("athlete_id", "start_date" DESC);



CREATE INDEX "minds_notification_log_athlete_day_idx" ON "public"."minds_notification_log" USING "btree" ("athlete_id", "notification_type", "sent_at" DESC);



CREATE INDEX "minds_notification_log_idx" ON "public"."minds_notification_log" USING "btree" ("athlete_id", "notification_type", "sent_at");



CREATE UNIQUE INDEX "pingo_scoring_output_unique_idx" ON "public"."pingo_scoring_output" USING "btree" ("athlete_id", "reference_date");



CREATE INDEX "pingo_user_athletes_user_idx" ON "public"."pingo_user_athletes" USING "btree" ("user_id", "pinned" DESC, "last_used_at" DESC);



CREATE INDEX "pingo_user_messages_athlete_idx" ON "public"."pingo_user_messages" USING "btree" ("athlete_id", "received_at" DESC);



CREATE INDEX "pingo_user_messages_history_idx" ON "public"."pingo_user_messages" USING "btree" ("athlete_id", "include_in_history", "saved_at" DESC);



CREATE INDEX "pingo_user_messages_user_idx" ON "public"."pingo_user_messages" USING "btree" ("user_id", "received_at" DESC);



CREATE INDEX "pmcsq_analysis_athlete_date_idx" ON "public"."pmcsq_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "restq_analysis_athlete_data_idx" ON "public"."restq_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE INDEX "restq_analysis_athlete_date_idx" ON "public"."restq_analysis" USING "btree" ("athlete_id", "data" DESC);



CREATE UNIQUE INDEX "training_load_daily_athlete_data_key" ON "public"."training_load_daily" USING "btree" ("athlete_id", "data");



CREATE INDEX "training_load_daily_athlete_date_idx" ON "public"."training_load_daily" USING "btree" ("athlete_id", "data" DESC);



CREATE UNIQUE INDEX "uq_minds_queue_daily" ON "public"."minds_notification_queue" USING "btree" ("athlete_id", "action_type", "created_day");



CREATE UNIQUE INDEX "uq_minds_webhook_unique" ON "public"."minds_webhook_queue" USING "btree" ("athlete_id", "questionnaire", "created_hour");



CREATE UNIQUE INDEX "uq_user_roles_user_id_role" ON "public"."user_roles" USING "btree" ("user_id", "role");



CREATE INDEX "weekly_analysis_athlete_week_idx" ON "public"."weekly_analysis" USING "btree" ("athlete_id", "start_date" DESC);



CREATE OR REPLACE TRIGGER "trg_athlete_private_notes_updated_at" BEFORE UPDATE ON "public"."athlete_private_notes" FOR EACH ROW EXECUTE FUNCTION "public"."update_athlete_private_notes_updated_at"();



CREATE OR REPLACE TRIGGER "trg_clean_zero_flags" BEFORE INSERT OR UPDATE ON "public"."pingo_scoring_output" FOR EACH ROW EXECUTE FUNCTION "public"."clean_zero_flags"();



CREATE OR REPLACE TRIGGER "trg_guard_hibernated_minds_notification_queue" BEFORE INSERT ON "public"."minds_notification_queue" FOR EACH ROW EXECUTE FUNCTION "public"."guard_hibernated_minds_notification_queue"();



CREATE OR REPLACE TRIGGER "trg_guard_hibernated_minds_webhook_queue" BEFORE INSERT ON "public"."minds_webhook_queue" FOR EACH ROW EXECUTE FUNCTION "public"."guard_hibernated_minds_webhook_queue"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."acsi_analysis" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."athlete_master_notes" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."athlete_private_notes" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."athlete_registration" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."billing_subscriptions" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."billing_subscriptions_backup" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."brums_analysis" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."cbas_analysis" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."coach_athletes" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."construcional_analysis" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."construcional_raw" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."diet_daily" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."gses_analysis" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."masters" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."minds_notification_log" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."minds_notification_queue" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."minds_questionnaire_state" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."minds_webhook_queue" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."pingo_athlete_notes" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."pingo_chat_context" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."pingo_scoring_output" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."pingo_user_athletes" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."pingo_user_messages" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."pmcsq_analysis" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."restq_analysis" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."scoring_rules" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."training_load_daily" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."user_credentials" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."user_roles" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."users_identity" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_integration_outbox" AFTER INSERT OR DELETE OR UPDATE ON "public"."weekly_analysis" FOR EACH ROW EXECUTE FUNCTION "integration"."capture_change"();



CREATE OR REPLACE TRIGGER "trg_pingo_chat_context_updated_at" BEFORE UPDATE ON "public"."pingo_chat_context" FOR EACH ROW EXECUTE FUNCTION "public"."set_pingo_chat_context_updated_at"();



CREATE OR REPLACE TRIGGER "trg_recalc_user_from_user_roles" AFTER INSERT OR DELETE OR UPDATE ON "public"."user_roles" FOR EACH ROW EXECUTE FUNCTION "public"."trg_recalc_user_from_user_roles"();



CREATE OR REPLACE TRIGGER "trg_scoring_rules_updated_at" BEFORE UPDATE ON "public"."scoring_rules" FOR EACH ROW EXECUTE FUNCTION "public"."set_scoring_rules_updated_at"();



CREATE OR REPLACE TRIGGER "trg_set_created_day" BEFORE INSERT ON "public"."minds_notification_queue" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_day"();



CREATE OR REPLACE TRIGGER "trg_set_created_hour" BEFORE INSERT ON "public"."minds_webhook_queue" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_hour"();



CREATE OR REPLACE TRIGGER "trg_sync_account_status" AFTER INSERT OR UPDATE ON "public"."billing_subscriptions" FOR EACH ROW EXECUTE FUNCTION "public"."sync_account_status"();



CREATE OR REPLACE TRIGGER "trg_sync_coach_roles_athlete_registration" AFTER INSERT OR DELETE OR UPDATE OF "coach_phone", "kind", "athlete_enabled" ON "public"."athlete_registration" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_coach_roles_trigger"();



CREATE OR REPLACE TRIGGER "trg_sync_coach_roles_users" AFTER INSERT OR DELETE OR UPDATE OF "phone" ON "public"."users" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_coach_roles_trigger"();



CREATE OR REPLACE TRIGGER "trg_sync_master_to_user_roles" AFTER INSERT ON "public"."masters" FOR EACH ROW EXECUTE FUNCTION "public"."sync_master_to_user_roles"();



CREATE OR REPLACE TRIGGER "trg_sync_queue_sent" AFTER INSERT ON "public"."minds_notification_log" FOR EACH ROW EXECUTE FUNCTION "public"."sync_queue_sent"();



CREATE OR REPLACE TRIGGER "trg_sync_registration_coach" AFTER INSERT OR UPDATE OF "coach_name", "coach_phone" ON "public"."athlete_registration" FOR EACH ROW EXECUTE FUNCTION "public"."sync_registration_coach"();



CREATE OR REPLACE TRIGGER "trg_sync_registration_user" AFTER INSERT ON "public"."athlete_registration" FOR EACH ROW EXECUTE FUNCTION "public"."sync_registration_user"();



CREATE OR REPLACE TRIGGER "trg_sync_users_from_athlete_registration" AFTER INSERT OR DELETE OR UPDATE ON "public"."athlete_registration" FOR EACH ROW EXECUTE FUNCTION "public"."trg_sync_users_from_athlete_registration"();



CREATE OR REPLACE TRIGGER "trigger_send_minds_webhook" AFTER INSERT ON "public"."minds_webhook_queue" FOR EACH ROW WHEN (("new"."status" = 'pending'::"text")) EXECUTE FUNCTION "public"."send_minds_webhook"();



ALTER TABLE ONLY "public"."construcional_analysis"
    ADD CONSTRAINT "construcional_analysis_construcional_raw_id_fkey" FOREIGN KEY ("construcional_raw_id") REFERENCES "public"."construcional_raw"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "fk_users_master" FOREIGN KEY ("master_id") REFERENCES "public"."users"("user_id") ON DELETE SET NULL;



CREATE POLICY "allow_only_active_users" ON "public"."users" FOR SELECT USING (("account_active" = true));



ALTER TABLE "public"."athlete_private_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."athlete_registration" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "backend_full_access" ON "public"."athlete_registration" USING (true) WITH CHECK (true);



CREATE POLICY "read_allowed_athletes" ON "public"."athlete_registration" FOR SELECT USING ("public"."is_athlete_allowed"("athlete_id"));



CREATE POLICY "user_roles_read_all" ON "public"."user_roles" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users_read_all" ON "public"."users" FOR SELECT TO "authenticated", "anon" USING (true);





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "service_role";











































































































































































REVOKE ALL ON FUNCTION "integration"."ack_changes_for_horizons"("p_event_ids" "uuid"[], "p_success" boolean, "p_error" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "integration"."capture_change"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "integration"."export_table_json"("p_schema_name" "text", "p_table_name" "text", "p_limit" integer, "p_offset" integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION "integration"."get_primary_key_json"("p_schema_name" "text", "p_table_name" "text", "p_row" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "integration"."install_outbox_triggers"("p_target_schema" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "integration"."pull_changes_for_horizons"("p_limit" integer, "p_reserve_minutes" integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION "integration"."remove_outbox_triggers"("p_target_schema" "text") FROM PUBLIC;



GRANT ALL ON FUNCTION "public"."api_athlete_bundle"("p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."api_athlete_bundle"("p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_athlete_bundle"("p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."api_get_athlete_bundle"("p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."api_get_athlete_bundle"("p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_get_athlete_bundle"("p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."api_get_athlete_snapshot"("p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."api_get_athlete_snapshot"("p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_get_athlete_snapshot"("p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."api_latest_row_json"("p_relation" "text", "p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."api_latest_row_json"("p_relation" "text", "p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_latest_row_json"("p_relation" "text", "p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."attach_note_embedding"("p_note_id" bigint, "p_embedding" "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."attach_note_embedding"("p_note_id" bigint, "p_embedding" "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."attach_note_embedding"("p_note_id" bigint, "p_embedding" "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."clean_zero_flags"() TO "anon";
GRANT ALL ON FUNCTION "public"."clean_zero_flags"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clean_zero_flags"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_athlete_note"("p_athlete_id" "text", "p_note_text" "text", "p_user_id" "text", "p_source_message_id" bigint, "p_title" "text", "p_tags" "text"[], "p_confidence" numeric, "p_model_name" "text", "p_note_meta" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_athlete_note"("p_athlete_id" "text", "p_note_text" "text", "p_user_id" "text", "p_source_message_id" bigint, "p_title" "text", "p_tags" "text"[], "p_confidence" numeric, "p_model_name" "text", "p_note_meta" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_athlete_note"("p_athlete_id" "text", "p_note_text" "text", "p_user_id" "text", "p_source_message_id" bigint, "p_title" "text", "p_tags" "text"[], "p_confidence" numeric, "p_model_name" "text", "p_note_meta" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_full_user"("p_user_id" "text", "p_name" "text", "p_phone" "text", "p_email" "text", "p_password_hash" "text", "p_master_id" "text", "p_coach_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_full_user"("p_user_id" "text", "p_name" "text", "p_phone" "text", "p_email" "text", "p_password_hash" "text", "p_master_id" "text", "p_coach_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_full_user"("p_user_id" "text", "p_name" "text", "p_phone" "text", "p_email" "text", "p_password_hash" "text", "p_master_id" "text", "p_coach_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."crypt"("pass" "text", "salt" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."crypt"("pass" "text", "salt" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crypt"("pass" "text", "salt" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."digest"("data" "text", "alg" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."digest"("data" "text", "alg" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."digest"("data" "text", "alg" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."dispatch_next_minds_webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."dispatch_next_minds_webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."dispatch_next_minds_webhook"() TO "service_role";



GRANT ALL ON FUNCTION "public"."ensure_coach_user"("p_coach_name" "text", "p_coach_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_coach_user"("p_coach_name" "text", "p_coach_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_coach_user"("p_coach_name" "text", "p_coach_phone" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."find_athletes"("p_query" "text", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."find_athletes"("p_query" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."find_athletes"("p_query" "text", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."gen_salt"("type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."gen_salt"("type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gen_salt"("type" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_all_coaches"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_all_coaches"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_all_coaches"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_all_teams_with_athletes"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_all_teams_with_athletes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_all_teams_with_athletes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_athlete_full_analysis"("p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_athlete_full_analysis"("p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_athlete_full_analysis"("p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_athletes_by_coach"("p_coach_phone" "text", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_athletes_by_coach"("p_coach_phone" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_athletes_by_coach"("p_coach_phone" "text", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_coach_bundle"("p_phone" "text", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_coach_bundle"("p_phone" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_coach_bundle"("p_phone" "text", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_coaches_by_master"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_coaches_by_master"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_coaches_by_master"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_coaches_by_master"("p_master_phone" "text", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_coaches_by_master"("p_master_phone" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_coaches_by_master"("p_master_phone" "text", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_master_data"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_master_data"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_master_data"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pingo_chat_bundle"("p_user_id" "text", "p_notes_limit" integer, "p_msgs_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_pingo_chat_bundle"("p_user_id" "text", "p_notes_limit" integer, "p_msgs_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pingo_chat_bundle"("p_user_id" "text", "p_notes_limit" integer, "p_msgs_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pingo_chat_context"("p_user_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_pingo_chat_context"("p_user_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pingo_chat_context"("p_user_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_recent_notes"("p_athlete_id" "text", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_recent_notes"("p_athlete_id" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_recent_notes"("p_athlete_id" "text", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_recent_user_messages"("p_athlete_id" "text", "p_limit" integer, "p_only_history" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_recent_user_messages"("p_athlete_id" "text", "p_limit" integer, "p_only_history" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_recent_user_messages"("p_athlete_id" "text", "p_limit" integer, "p_only_history" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_team_analysis"("p_coach_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_team_analysis"("p_coach_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_team_analysis"("p_coach_phone" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_team_analysis_compact"("p_coach_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_team_analysis_compact"("p_coach_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_team_analysis_compact"("p_coach_phone" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_hibernated_minds_notification_queue"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_hibernated_minds_notification_queue"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_hibernated_minds_notification_queue"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_hibernated_minds_webhook_queue"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_hibernated_minds_webhook_queue"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_hibernated_minds_webhook_queue"() TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."hibernate_athlete"("p_athlete_id" "text", "p_reason" "text", "p_auto" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."hibernate_athlete"("p_athlete_id" "text", "p_reason" "text", "p_auto" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hibernate_athlete"("p_athlete_id" "text", "p_reason" "text", "p_auto" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "service_role";



REVOKE ALL ON FUNCTION "public"."horizons_ack_changes"("p_event_ids" "uuid"[], "p_success" boolean, "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."horizons_ack_changes"("p_event_ids" "uuid"[], "p_success" boolean, "p_error" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."horizons_ack_changes"("p_event_ids" "uuid"[], "p_success" boolean, "p_error" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."horizons_ack_changes"("p_event_ids" "uuid"[], "p_success" boolean, "p_error" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."horizons_export_table_json"("p_schema_name" "text", "p_table_name" "text", "p_limit" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."horizons_export_table_json"("p_schema_name" "text", "p_table_name" "text", "p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."horizons_export_table_json"("p_schema_name" "text", "p_table_name" "text", "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."horizons_export_table_json"("p_schema_name" "text", "p_table_name" "text", "p_limit" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."horizons_pull_changes"("p_limit" integer, "p_reserve_minutes" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."horizons_pull_changes"("p_limit" integer, "p_reserve_minutes" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."horizons_pull_changes"("p_limit" integer, "p_reserve_minutes" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."horizons_pull_changes"("p_limit" integer, "p_reserve_minutes" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_analysis_vector"("p_athlete_id" "text", "p_data" "date", "p_source" "text", "p_embedding" "public"."vector", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."insert_analysis_vector"("p_athlete_id" "text", "p_data" "date", "p_source" "text", "p_embedding" "public"."vector", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_analysis_vector"("p_athlete_id" "text", "p_data" "date", "p_source" "text", "p_embedding" "public"."vector", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_athlete_allowed"("p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."is_athlete_allowed"("p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_athlete_allowed"("p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."list_user_athletes"("p_user_id" "text", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."list_user_athletes"("p_user_id" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_user_athletes"("p_user_id" "text", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."log_user_message"("p_user_id" "text", "p_message_text" "text", "p_message_type" "text", "p_message_meta" "jsonb", "p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."log_user_message"("p_user_id" "text", "p_message_text" "text", "p_message_type" "text", "p_message_meta" "jsonb", "p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_user_message"("p_user_id" "text", "p_message_text" "text", "p_message_type" "text", "p_message_meta" "jsonb", "p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."minds_run_engine_v4"() TO "anon";
GRANT ALL ON FUNCTION "public"."minds_run_engine_v4"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."minds_run_engine_v4"() TO "service_role";



GRANT ALL ON FUNCTION "public"."norm_phone"("p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."norm_phone"("p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."norm_phone"("p_phone" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."norm_role"("p_role" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."norm_role"("p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."norm_role"("p_role" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_phone"("raw" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_phone"("raw" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_phone"("raw" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."only_digits"("p_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."only_digits"("p_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."only_digits"("p_text" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."patch_pingo_chat_context"("p_user_id" "text", "p_patch" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."patch_pingo_chat_context"("p_user_id" "text", "p_patch" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."patch_pingo_chat_context"("p_user_id" "text", "p_patch" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."phone_digits"("p" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."phone_digits"("p" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."phone_digits"("p" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."pin_user_athlete"("p_user_id" "text", "p_athlete_id" "text", "p_pinned" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."pin_user_athlete"("p_user_id" "text", "p_athlete_id" "text", "p_pinned" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."pin_user_athlete"("p_user_id" "text", "p_athlete_id" "text", "p_pinned" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."reactivate_athlete"("p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reactivate_athlete"("p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reactivate_athlete"("p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rebuild_auth_credentials"("p_reset_password" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."rebuild_auth_credentials"("p_reset_password" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."rebuild_auth_credentials"("p_reset_password" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."recalc_user_account_active"("p_user_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."recalc_user_account_active"("p_user_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalc_user_account_active"("p_user_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reconcile_minds_webhook_responses"() TO "anon";
GRANT ALL ON FUNCTION "public"."reconcile_minds_webhook_responses"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reconcile_minds_webhook_responses"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_auth_credential_by_phone"("p_phone" "text", "p_reset_password" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_auth_credential_by_phone"("p_phone" "text", "p_reset_password" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_auth_credential_by_phone"("p_phone" "text", "p_reset_password" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."register_athlete_with_coach"("p_master_id" "text", "p_athlete_name" "text", "p_athlete_phone" "text", "p_coach_name" "text", "p_coach_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."register_athlete_with_coach"("p_master_id" "text", "p_athlete_name" "text", "p_athlete_phone" "text", "p_coach_name" "text", "p_coach_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_athlete_with_coach"("p_master_id" "text", "p_athlete_name" "text", "p_athlete_phone" "text", "p_coach_name" "text", "p_coach_phone" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."requeue_stale_minds_webhooks"() TO "anon";
GRANT ALL ON FUNCTION "public"."requeue_stale_minds_webhooks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."requeue_stale_minds_webhooks"() TO "service_role";



GRANT ALL ON FUNCTION "public"."resolve_role_from_user_roles"("p_default_role" "text", "p_user_id" "text", "p_phone" "text", "p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_role_from_user_roles"("p_default_role" "text", "p_user_id" "text", "p_phone" "text", "p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_role_from_user_roles"("p_default_role" "text", "p_user_id" "text", "p_phone" "text", "p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."retry_minds_webhooks"() TO "anon";
GRANT ALL ON FUNCTION "public"."retry_minds_webhooks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."retry_minds_webhooks"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_change_password"("p_user_id" "text", "p_old_pass" "text", "p_new_pass" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_change_password"("p_user_id" "text", "p_old_pass" "text", "p_new_pass" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_change_password"("p_user_id" "text", "p_old_pass" "text", "p_new_pass" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_create_user"("p_name" "text", "p_phone" "text", "p_role" "text", "p_password" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_create_user"("p_name" "text", "p_phone" "text", "p_role" "text", "p_password" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_create_user"("p_name" "text", "p_phone" "text", "p_role" "text", "p_password" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_delete_user"("p_user_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_delete_user"("p_user_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_delete_user"("p_user_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_liga_minds_athlete_score"("p_start_date" "date", "p_end_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_liga_minds_athlete_score"("p_start_date" "date", "p_end_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_liga_minds_athlete_score"("p_start_date" "date", "p_end_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_liga_minds_podium"("p_start_date" "date", "p_end_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_liga_minds_podium"("p_start_date" "date", "p_end_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_liga_minds_podium"("p_start_date" "date", "p_end_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_liga_minds_team_score"("p_start_date" "date", "p_end_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_liga_minds_team_score"("p_start_date" "date", "p_end_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_liga_minds_team_score"("p_start_date" "date", "p_end_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_login_phone"("p_phone" "text", "p_pass" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_login_phone"("p_phone" "text", "p_pass" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_login_phone"("p_phone" "text", "p_pass" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_minds_all_coaches_teams"() TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_minds_all_coaches_teams"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_minds_all_coaches_teams"() TO "service_role";



GRANT ALL ON TABLE "public"."acsi_analysis" TO "anon";
GRANT ALL ON TABLE "public"."acsi_analysis" TO "authenticated";
GRANT ALL ON TABLE "public"."acsi_analysis" TO "service_role";



GRANT ALL ON TABLE "public"."athlete_registration" TO "anon";
GRANT ALL ON TABLE "public"."athlete_registration" TO "authenticated";
GRANT ALL ON TABLE "public"."athlete_registration" TO "service_role";



GRANT ALL ON TABLE "public"."api_athletes" TO "anon";
GRANT ALL ON TABLE "public"."api_athletes" TO "authenticated";
GRANT ALL ON TABLE "public"."api_athletes" TO "service_role";



GRANT ALL ON TABLE "public"."brums_analysis" TO "anon";
GRANT ALL ON TABLE "public"."brums_analysis" TO "authenticated";
GRANT ALL ON TABLE "public"."brums_analysis" TO "service_role";



GRANT ALL ON TABLE "public"."cbas_analysis" TO "anon";
GRANT ALL ON TABLE "public"."cbas_analysis" TO "authenticated";
GRANT ALL ON TABLE "public"."cbas_analysis" TO "service_role";



GRANT ALL ON TABLE "public"."construcional_raw" TO "anon";
GRANT ALL ON TABLE "public"."construcional_raw" TO "authenticated";
GRANT ALL ON TABLE "public"."construcional_raw" TO "service_role";



GRANT ALL ON TABLE "public"."weekly_analysis" TO "anon";
GRANT ALL ON TABLE "public"."weekly_analysis" TO "authenticated";
GRANT ALL ON TABLE "public"."weekly_analysis" TO "service_role";



GRANT ALL ON TABLE "public"."minds_last_response" TO "anon";
GRANT ALL ON TABLE "public"."minds_last_response" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_last_response" TO "service_role";



GRANT ALL ON TABLE "public"."minds_notification_log" TO "anon";
GRANT ALL ON TABLE "public"."minds_notification_log" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_notification_log" TO "service_role";



GRANT ALL ON TABLE "public"."minds_behavior_analytics" TO "anon";
GRANT ALL ON TABLE "public"."minds_behavior_analytics" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_behavior_analytics" TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_minds_behavior_analytics"() TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_minds_behavior_analytics"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_minds_behavior_analytics"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_minds_behavior_engine_v3"() TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_minds_behavior_engine_v3"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_minds_behavior_engine_v3"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_minds_cron_flags"() TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_minds_cron_flags"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_minds_cron_flags"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_minds_cron_forecast"("p_now" timestamp without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_minds_cron_forecast"("p_now" timestamp without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_minds_cron_forecast"("p_now" timestamp without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_minds_cron_priority"() TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_minds_cron_priority"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_minds_cron_priority"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_minds_cron_scheduler"() TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_minds_cron_scheduler"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_minds_cron_scheduler"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_update_user"("p_user_id" "text", "p_name" "text", "p_phone" "text", "p_role" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_update_user"("p_user_id" "text", "p_name" "text", "p_phone" "text", "p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_update_user"("p_user_id" "text", "p_name" "text", "p_phone" "text", "p_role" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."save_last_user_message_as_history"("p_user_id" "text", "p_title" "text", "p_tags" "text"[], "p_saved_by" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."save_last_user_message_as_history"("p_user_id" "text", "p_title" "text", "p_tags" "text"[], "p_saved_by" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_last_user_message_as_history"("p_user_id" "text", "p_title" "text", "p_tags" "text"[], "p_saved_by" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."save_user_message_as_history"("p_message_id" bigint, "p_title" "text", "p_tags" "text"[], "p_saved_by" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."save_user_message_as_history"("p_message_id" bigint, "p_title" "text", "p_tags" "text"[], "p_saved_by" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_user_message_as_history"("p_message_id" bigint, "p_title" "text", "p_tags" "text"[], "p_saved_by" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."search_similar_chat_notes"("p_athlete_id" "text", "p_query_embedding" "public"."vector", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."search_similar_chat_notes"("p_athlete_id" "text", "p_query_embedding" "public"."vector", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_similar_chat_notes"("p_athlete_id" "text", "p_query_embedding" "public"."vector", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."send_minds_webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."send_minds_webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_minds_webhook"() TO "service_role";



GRANT ALL ON FUNCTION "public"."send_minds_webhook"("p_athlete_id" "text", "p_name" "text", "p_phone" "text", "p_questionnaire" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."send_minds_webhook"("p_athlete_id" "text", "p_name" "text", "p_phone" "text", "p_questionnaire" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_minds_webhook"("p_athlete_id" "text", "p_name" "text", "p_phone" "text", "p_questionnaire" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_active_athlete"("p_user_id" "text", "p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."set_active_athlete"("p_user_id" "text", "p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_active_athlete"("p_user_id" "text", "p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_created_day"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_created_day"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_created_day"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_created_hour"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_created_hour"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_created_hour"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_pingo_chat_context_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_pingo_chat_context_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_pingo_chat_context_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_scoring_rules_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_scoring_rules_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_scoring_rules_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."slugify"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."slugify"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."slugify"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_account_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_account_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_account_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_athlete_to_users_all"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_athlete_to_users_all"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_athlete_to_users_all"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_coach_roles"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_coach_roles"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_coach_roles"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_coach_roles_trigger"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_coach_roles_trigger"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_coach_roles_trigger"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_coach_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_coach_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_coach_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_master_to_user_roles"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_master_to_user_roles"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_master_to_user_roles"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_masters_to_auth"("p_force_reset_password" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sync_masters_to_auth"("p_force_reset_password" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_masters_to_auth"("p_force_reset_password" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_masters_to_login"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_masters_to_login"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_masters_to_login"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_queue_sent"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_queue_sent"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_queue_sent"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_registration_coach"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_registration_coach"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_registration_coach"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_registration_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_registration_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_registration_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_user_from_athlete_registration"("p_athlete_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."sync_user_from_athlete_registration"("p_athlete_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_user_from_athlete_registration"("p_athlete_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_user_phone"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_user_phone"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_user_phone"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_users_from_athlete_registration"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_users_from_athlete_registration"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_users_from_athlete_registration"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_recalc_user_from_user_roles"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_recalc_user_from_user_roles"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_recalc_user_from_user_roles"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_sync_users_from_athlete_registration"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_sync_users_from_athlete_registration"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_sync_users_from_athlete_registration"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_athlete_private_notes_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_athlete_private_notes_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_athlete_private_notes_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_pingo_last_state"("p_user_id" "text", "p_last_coach_phone" "text", "p_last_athlete_id" "text", "p_last_athlete_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_pingo_last_state"("p_user_id" "text", "p_last_coach_phone" "text", "p_last_athlete_id" "text", "p_last_athlete_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_pingo_last_state"("p_user_id" "text", "p_last_coach_phone" "text", "p_last_athlete_id" "text", "p_last_athlete_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_account_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_account_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_account_status"() TO "service_role";



GRANT ALL ON TABLE "public"."construcional_analysis" TO "anon";
GRANT ALL ON TABLE "public"."construcional_analysis" TO "authenticated";
GRANT ALL ON TABLE "public"."construcional_analysis" TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_construcional_analysis"("p_construcional_raw_id" bigint, "p_athlete_id" "text", "p_repertorio_protetor" "text", "p_repertorio_risco" "text", "p_apoio_ambiental" "text", "p_claridade_metas" "text", "p_model_name" "text", "p_confidence" numeric, "p_explanation" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_construcional_analysis"("p_construcional_raw_id" bigint, "p_athlete_id" "text", "p_repertorio_protetor" "text", "p_repertorio_risco" "text", "p_apoio_ambiental" "text", "p_claridade_metas" "text", "p_model_name" "text", "p_confidence" numeric, "p_explanation" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_construcional_analysis"("p_construcional_raw_id" bigint, "p_athlete_id" "text", "p_repertorio_protetor" "text", "p_repertorio_risco" "text", "p_apoio_ambiental" "text", "p_claridade_metas" "text", "p_model_name" "text", "p_confidence" numeric, "p_explanation" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_construcional_analysis_bigint"("p_construcional_raw_id" bigint, "p_athlete_id" "text", "p_repertorio_protetor" "text", "p_repertorio_risco" "text", "p_apoio_ambiental" "text", "p_claridade_metas" "text", "p_model_name" "text", "p_confidence" numeric, "p_explanation" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_construcional_analysis_bigint"("p_construcional_raw_id" bigint, "p_athlete_id" "text", "p_repertorio_protetor" "text", "p_repertorio_risco" "text", "p_apoio_ambiental" "text", "p_claridade_metas" "text", "p_model_name" "text", "p_confidence" numeric, "p_explanation" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_construcional_analysis_bigint"("p_construcional_raw_id" bigint, "p_athlete_id" "text", "p_repertorio_protetor" "text", "p_repertorio_risco" "text", "p_apoio_ambiental" "text", "p_claridade_metas" "text", "p_model_name" "text", "p_confidence" numeric, "p_explanation" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_pingo_scoring_output"("p_athlete_id" "text", "p_reference_date" "date", "p_attention_level" integer, "p_flag_count" integer, "p_flags" "jsonb", "p_rules_triggered" "jsonb", "p_thresholds_used" "jsonb", "p_summary" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_pingo_scoring_output"("p_athlete_id" "text", "p_reference_date" "date", "p_attention_level" integer, "p_flag_count" integer, "p_flags" "jsonb", "p_rules_triggered" "jsonb", "p_thresholds_used" "jsonb", "p_summary" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_pingo_scoring_output"("p_athlete_id" "text", "p_reference_date" "date", "p_attention_level" integer, "p_flag_count" integer, "p_flags" "jsonb", "p_rules_triggered" "jsonb", "p_thresholds_used" "jsonb", "p_summary" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "service_role";












GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "service_role";















GRANT ALL ON SEQUENCE "public"."acsi_analysis_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."acsi_analysis_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."acsi_analysis_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."acsi_analysis_view" TO "anon";
GRANT ALL ON TABLE "public"."acsi_analysis_view" TO "authenticated";
GRANT ALL ON TABLE "public"."acsi_analysis_view" TO "service_role";



GRANT ALL ON TABLE "public"."diet_daily" TO "anon";
GRANT ALL ON TABLE "public"."diet_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."diet_daily" TO "service_role";



GRANT ALL ON TABLE "public"."api_daily_pre_post" TO "anon";
GRANT ALL ON TABLE "public"."api_daily_pre_post" TO "authenticated";
GRANT ALL ON TABLE "public"."api_daily_pre_post" TO "service_role";



GRANT ALL ON TABLE "public"."pingo_scoring_output" TO "anon";
GRANT ALL ON TABLE "public"."pingo_scoring_output" TO "authenticated";
GRANT ALL ON TABLE "public"."pingo_scoring_output" TO "service_role";



GRANT ALL ON TABLE "public"."api_flags_events" TO "anon";
GRANT ALL ON TABLE "public"."api_flags_events" TO "authenticated";
GRANT ALL ON TABLE "public"."api_flags_events" TO "service_role";



GRANT ALL ON TABLE "public"."api_scoring_latest" TO "anon";
GRANT ALL ON TABLE "public"."api_scoring_latest" TO "authenticated";
GRANT ALL ON TABLE "public"."api_scoring_latest" TO "service_role";



GRANT ALL ON TABLE "public"."api_teams" TO "anon";
GRANT ALL ON TABLE "public"."api_teams" TO "authenticated";
GRANT ALL ON TABLE "public"."api_teams" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";



GRANT ALL ON TABLE "public"."athlete_access_status" TO "anon";
GRANT ALL ON TABLE "public"."athlete_access_status" TO "authenticated";
GRANT ALL ON TABLE "public"."athlete_access_status" TO "service_role";



GRANT ALL ON TABLE "public"."pmcsq_analysis" TO "anon";
GRANT ALL ON TABLE "public"."pmcsq_analysis" TO "authenticated";
GRANT ALL ON TABLE "public"."pmcsq_analysis" TO "service_role";



GRANT ALL ON TABLE "public"."restq_analysis" TO "anon";
GRANT ALL ON TABLE "public"."restq_analysis" TO "authenticated";
GRANT ALL ON TABLE "public"."restq_analysis" TO "service_role";



GRANT ALL ON TABLE "public"."athlete_event_days" TO "anon";
GRANT ALL ON TABLE "public"."athlete_event_days" TO "authenticated";
GRANT ALL ON TABLE "public"."athlete_event_days" TO "service_role";



GRANT ALL ON TABLE "public"."athlete_latest_view" TO "anon";
GRANT ALL ON TABLE "public"."athlete_latest_view" TO "authenticated";
GRANT ALL ON TABLE "public"."athlete_latest_view" TO "service_role";



GRANT ALL ON TABLE "public"."athlete_master_notes" TO "anon";
GRANT ALL ON TABLE "public"."athlete_master_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."athlete_master_notes" TO "service_role";



GRANT ALL ON TABLE "public"."athlete_private_notes" TO "anon";
GRANT ALL ON TABLE "public"."athlete_private_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."athlete_private_notes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."athlete_registration_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."athlete_registration_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."athlete_registration_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."billing_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."billing_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."billing_subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."billing_subscriptions_backup" TO "anon";
GRANT ALL ON TABLE "public"."billing_subscriptions_backup" TO "authenticated";
GRANT ALL ON TABLE "public"."billing_subscriptions_backup" TO "service_role";



GRANT ALL ON SEQUENCE "public"."brums_analysis_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."brums_analysis_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."brums_analysis_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."brums_analysis_view" TO "anon";
GRANT ALL ON TABLE "public"."brums_analysis_view" TO "authenticated";
GRANT ALL ON TABLE "public"."brums_analysis_view" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cbas_analysis_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cbas_analysis_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cbas_analysis_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cbas_analysis_view" TO "anon";
GRANT ALL ON TABLE "public"."cbas_analysis_view" TO "authenticated";
GRANT ALL ON TABLE "public"."cbas_analysis_view" TO "service_role";



GRANT ALL ON TABLE "public"."coach_athletes" TO "anon";
GRANT ALL ON TABLE "public"."coach_athletes" TO "authenticated";
GRANT ALL ON TABLE "public"."coach_athletes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."construcional_analysis_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."construcional_analysis_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."construcional_analysis_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."construcional_analysis_view" TO "anon";
GRANT ALL ON TABLE "public"."construcional_analysis_view" TO "authenticated";
GRANT ALL ON TABLE "public"."construcional_analysis_view" TO "service_role";



GRANT ALL ON SEQUENCE "public"."construcional_raw_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."construcional_raw_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."construcional_raw_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."diet_daily_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."diet_daily_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."diet_daily_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."gses_analysis" TO "anon";
GRANT ALL ON TABLE "public"."gses_analysis" TO "authenticated";
GRANT ALL ON TABLE "public"."gses_analysis" TO "service_role";



GRANT ALL ON SEQUENCE "public"."gses_analysis_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."gses_analysis_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gses_analysis_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."gses_analysis_view" TO "anon";
GRANT ALL ON TABLE "public"."gses_analysis_view" TO "authenticated";
GRANT ALL ON TABLE "public"."gses_analysis_view" TO "service_role";



GRANT ALL ON TABLE "public"."horizons_snapshot_manifest" TO "anon";
GRANT ALL ON TABLE "public"."horizons_snapshot_manifest" TO "authenticated";
GRANT ALL ON TABLE "public"."horizons_snapshot_manifest" TO "service_role";



GRANT ALL ON TABLE "public"."masters" TO "anon";
GRANT ALL ON TABLE "public"."masters" TO "authenticated";
GRANT ALL ON TABLE "public"."masters" TO "service_role";



GRANT ALL ON TABLE "public"."minds_adherence_dashboard" TO "anon";
GRANT ALL ON TABLE "public"."minds_adherence_dashboard" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_adherence_dashboard" TO "service_role";



GRANT ALL ON TABLE "public"."minds_athlete_delivery_state" TO "anon";
GRANT ALL ON TABLE "public"."minds_athlete_delivery_state" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_athlete_delivery_state" TO "service_role";



GRANT ALL ON TABLE "public"."minds_engagement_timeline" TO "anon";
GRANT ALL ON TABLE "public"."minds_engagement_timeline" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_engagement_timeline" TO "service_role";



GRANT ALL ON TABLE "public"."minds_next_notifications" TO "anon";
GRANT ALL ON TABLE "public"."minds_next_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_next_notifications" TO "service_role";



GRANT ALL ON SEQUENCE "public"."minds_notification_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."minds_notification_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."minds_notification_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."minds_notification_queue" TO "anon";
GRANT ALL ON TABLE "public"."minds_notification_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_notification_queue" TO "service_role";



GRANT ALL ON SEQUENCE "public"."minds_notification_queue_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."minds_notification_queue_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."minds_notification_queue_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."restq_analysis_view" TO "anon";
GRANT ALL ON TABLE "public"."restq_analysis_view" TO "authenticated";
GRANT ALL ON TABLE "public"."restq_analysis_view" TO "service_role";



GRANT ALL ON TABLE "public"."training_load_daily" TO "anon";
GRANT ALL ON TABLE "public"."training_load_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."training_load_daily" TO "service_role";



GRANT ALL ON TABLE "public"."minds_overview" TO "anon";
GRANT ALL ON TABLE "public"."minds_overview" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_overview" TO "service_role";



GRANT ALL ON TABLE "public"."minds_questionnaire_state" TO "anon";
GRANT ALL ON TABLE "public"."minds_questionnaire_state" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_questionnaire_state" TO "service_role";



GRANT ALL ON TABLE "public"."minds_system_monitor" TO "anon";
GRANT ALL ON TABLE "public"."minds_system_monitor" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_system_monitor" TO "service_role";



GRANT ALL ON TABLE "public"."minds_training_pattern" TO "anon";
GRANT ALL ON TABLE "public"."minds_training_pattern" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_training_pattern" TO "service_role";



GRANT ALL ON TABLE "public"."minds_webhook_queue" TO "anon";
GRANT ALL ON TABLE "public"."minds_webhook_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."minds_webhook_queue" TO "service_role";



GRANT ALL ON SEQUENCE "public"."minds_webhook_queue_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."minds_webhook_queue_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."minds_webhook_queue_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pingo_athlete_notes" TO "anon";
GRANT ALL ON TABLE "public"."pingo_athlete_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."pingo_athlete_notes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pingo_athlete_notes_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pingo_athlete_notes_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pingo_athlete_notes_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pingo_chat_context" TO "anon";
GRANT ALL ON TABLE "public"."pingo_chat_context" TO "authenticated";
GRANT ALL ON TABLE "public"."pingo_chat_context" TO "service_role";



GRANT ALL ON TABLE "public"."pingo_scoring_active" TO "anon";
GRANT ALL ON TABLE "public"."pingo_scoring_active" TO "authenticated";
GRANT ALL ON TABLE "public"."pingo_scoring_active" TO "service_role";



GRANT ALL ON TABLE "public"."v_training_load_base_world" TO "anon";
GRANT ALL ON TABLE "public"."v_training_load_base_world" TO "authenticated";
GRANT ALL ON TABLE "public"."v_training_load_base_world" TO "service_role";



GRANT ALL ON TABLE "public"."v_training_calendar_world" TO "anon";
GRANT ALL ON TABLE "public"."v_training_calendar_world" TO "authenticated";
GRANT ALL ON TABLE "public"."v_training_calendar_world" TO "service_role";



GRANT ALL ON TABLE "public"."v_training_metrics_world" TO "anon";
GRANT ALL ON TABLE "public"."v_training_metrics_world" TO "authenticated";
GRANT ALL ON TABLE "public"."v_training_metrics_world" TO "service_role";



GRANT ALL ON TABLE "public"."weight_analysis" TO "anon";
GRANT ALL ON TABLE "public"."weight_analysis" TO "authenticated";
GRANT ALL ON TABLE "public"."weight_analysis" TO "service_role";



GRANT ALL ON TABLE "public"."pingo_scoring_inputs_view_final" TO "anon";
GRANT ALL ON TABLE "public"."pingo_scoring_inputs_view_final" TO "authenticated";
GRANT ALL ON TABLE "public"."pingo_scoring_inputs_view_final" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pingo_scoring_output_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pingo_scoring_output_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pingo_scoring_output_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pingo_user_athletes" TO "anon";
GRANT ALL ON TABLE "public"."pingo_user_athletes" TO "authenticated";
GRANT ALL ON TABLE "public"."pingo_user_athletes" TO "service_role";



GRANT ALL ON TABLE "public"."pingo_user_messages" TO "anon";
GRANT ALL ON TABLE "public"."pingo_user_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."pingo_user_messages" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pingo_user_messages_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pingo_user_messages_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pingo_user_messages_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pmcsq_analysis_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pmcsq_analysis_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pmcsq_analysis_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pmcsq_analysis_view" TO "anon";
GRANT ALL ON TABLE "public"."pmcsq_analysis_view" TO "authenticated";
GRANT ALL ON TABLE "public"."pmcsq_analysis_view" TO "service_role";



GRANT ALL ON SEQUENCE "public"."restq_analysis_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."restq_analysis_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."restq_analysis_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."scoring_rules" TO "anon";
GRANT ALL ON TABLE "public"."scoring_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."scoring_rules" TO "service_role";



GRANT ALL ON SEQUENCE "public"."training_load_daily_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."training_load_daily_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."training_load_daily_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."user_credentials" TO "service_role";



GRANT ALL ON TABLE "public"."user_roles" TO "anon";
GRANT ALL ON TABLE "public"."user_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_roles" TO "service_role";



GRANT ALL ON TABLE "public"."users_all" TO "anon";
GRANT ALL ON TABLE "public"."users_all" TO "authenticated";
GRANT ALL ON TABLE "public"."users_all" TO "service_role";



GRANT ALL ON TABLE "public"."users_athletes" TO "anon";
GRANT ALL ON TABLE "public"."users_athletes" TO "authenticated";
GRANT ALL ON TABLE "public"."users_athletes" TO "service_role";



GRANT ALL ON TABLE "public"."users_coaches" TO "anon";
GRANT ALL ON TABLE "public"."users_coaches" TO "authenticated";
GRANT ALL ON TABLE "public"."users_coaches" TO "service_role";



GRANT ALL ON TABLE "public"."users_identity" TO "anon";
GRANT ALL ON TABLE "public"."users_identity" TO "authenticated";
GRANT ALL ON TABLE "public"."users_identity" TO "service_role";



GRANT ALL ON TABLE "public"."v_training_ewma_world" TO "anon";
GRANT ALL ON TABLE "public"."v_training_ewma_world" TO "authenticated";
GRANT ALL ON TABLE "public"."v_training_ewma_world" TO "service_role";



GRANT ALL ON TABLE "public"."v_training_risk_world" TO "anon";
GRANT ALL ON TABLE "public"."v_training_risk_world" TO "authenticated";
GRANT ALL ON TABLE "public"."v_training_risk_world" TO "service_role";



GRANT ALL ON TABLE "public"."weekly_analysis_view" TO "anon";
GRANT ALL ON TABLE "public"."weekly_analysis_view" TO "authenticated";
GRANT ALL ON TABLE "public"."weekly_analysis_view" TO "service_role";



GRANT ALL ON TABLE "public"."v_liga_minds_athlete_score" TO "anon";
GRANT ALL ON TABLE "public"."v_liga_minds_athlete_score" TO "authenticated";
GRANT ALL ON TABLE "public"."v_liga_minds_athlete_score" TO "service_role";



GRANT ALL ON TABLE "public"."v_liga_minds_athlete_score_current_month" TO "anon";
GRANT ALL ON TABLE "public"."v_liga_minds_athlete_score_current_month" TO "authenticated";
GRANT ALL ON TABLE "public"."v_liga_minds_athlete_score_current_month" TO "service_role";



GRANT ALL ON TABLE "public"."v_liga_minds_team_score" TO "anon";
GRANT ALL ON TABLE "public"."v_liga_minds_team_score" TO "authenticated";
GRANT ALL ON TABLE "public"."v_liga_minds_team_score" TO "service_role";



GRANT ALL ON TABLE "public"."v_liga_minds_team_score_current_month" TO "anon";
GRANT ALL ON TABLE "public"."v_liga_minds_team_score_current_month" TO "authenticated";
GRANT ALL ON TABLE "public"."v_liga_minds_team_score_current_month" TO "service_role";



GRANT ALL ON TABLE "public"."v_pingo_alertas_command_center" TO "anon";
GRANT ALL ON TABLE "public"."v_pingo_alertas_command_center" TO "authenticated";
GRANT ALL ON TABLE "public"."v_pingo_alertas_command_center" TO "service_role";



GRANT ALL ON SEQUENCE "public"."weekly_analysis_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."weekly_analysis_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."weekly_analysis_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































