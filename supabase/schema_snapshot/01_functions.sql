CREATE OR REPLACE FUNCTION public.api_athlete_bundle(p_athlete_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.api_get_athlete_bundle(p_athlete_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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

---------------------------------------------------------
-- 1 PROFILE (DADOS DO ATLETA)
---------------------------------------------------------

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

---------------------------------------------------------
-- 2 LATEST METRICS
---------------------------------------------------------

SELECT *
INTO v_latest_metrics
FROM pingo_scoring_inputs_view_final
WHERE athlete_id = p_athlete_id
ORDER BY reference_date DESC
LIMIT 1;

---------------------------------------------------------
-- 3 TREINO (FONTE ÚNICA)
---------------------------------------------------------

SELECT data,load
INTO v_latest_training
FROM v_training_calendar_world
WHERE athlete_id = p_athlete_id
AND has_session = TRUE
ORDER BY data DESC
LIMIT 1;

---------------------------------------------------------
-- 4 STATUS
---------------------------------------------------------

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

---------------------------------------------------------
-- 5 KPIS
---------------------------------------------------------

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

---------------------------------------------------------
-- 6 CHARTS
---------------------------------------------------------

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

---------------------------------------------------------
-- 7 TIMELINE
---------------------------------------------------------

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

---------------------------------------------------------
-- 8 DERIVED METRICS (CALCULADAS AQUI)
---------------------------------------------------------

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

---------------------------------------------------------
-- RETURN FINAL
---------------------------------------------------------

RETURN jsonb_build_object(

'profile',v_profile,
'status',v_status,
'kpis',v_kpis,
'charts',v_charts,
'timeline_events',COALESCE(v_timeline,'[]'::jsonb),
'derived_metrics',v_derived

);

END;
$function$
;

CREATE OR REPLACE FUNCTION public.api_get_athlete_snapshot(p_athlete_id text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
AS $function$

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

$function$
;

CREATE OR REPLACE FUNCTION public.api_latest_row_json(p_relation text, p_athlete_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.array_to_halfvec(integer[], integer, boolean)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_halfvec$function$
;

CREATE OR REPLACE FUNCTION public.array_to_halfvec(real[], integer, boolean)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_halfvec$function$
;

CREATE OR REPLACE FUNCTION public.array_to_halfvec(double precision[], integer, boolean)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_halfvec$function$
;

CREATE OR REPLACE FUNCTION public.array_to_halfvec(numeric[], integer, boolean)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_halfvec$function$
;

CREATE OR REPLACE FUNCTION public.array_to_sparsevec(double precision[], integer, boolean)
 RETURNS sparsevec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_sparsevec$function$
;

CREATE OR REPLACE FUNCTION public.array_to_sparsevec(integer[], integer, boolean)
 RETURNS sparsevec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_sparsevec$function$
;

CREATE OR REPLACE FUNCTION public.array_to_sparsevec(real[], integer, boolean)
 RETURNS sparsevec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_sparsevec$function$
;

CREATE OR REPLACE FUNCTION public.array_to_sparsevec(numeric[], integer, boolean)
 RETURNS sparsevec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_sparsevec$function$
;

CREATE OR REPLACE FUNCTION public.array_to_vector(real[], integer, boolean)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_vector$function$
;

CREATE OR REPLACE FUNCTION public.array_to_vector(numeric[], integer, boolean)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_vector$function$
;

CREATE OR REPLACE FUNCTION public.array_to_vector(double precision[], integer, boolean)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_vector$function$
;

CREATE OR REPLACE FUNCTION public.array_to_vector(integer[], integer, boolean)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$array_to_vector$function$
;

CREATE OR REPLACE FUNCTION public.attach_note_embedding(p_note_id bigint, p_embedding vector)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.binary_quantize(vector)
 RETURNS bit
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$binary_quantize$function$
;

CREATE OR REPLACE FUNCTION public.binary_quantize(halfvec)
 RETURNS bit
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_binary_quantize$function$
;

CREATE OR REPLACE FUNCTION public.can_dispatch_minds_webhook(p_phone text, p_account_key text)
 RETURNS TABLE(can_dispatch boolean, reason text, retry_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.claim_pingo_webhook_reactivation_candidate(p_cooldown_hours integer DEFAULT 72, p_min_hours_after_questionnaire integer DEFAULT 12, p_probability numeric DEFAULT 0.65, p_global_gap_minutes integer DEFAULT 25, p_daily_cap integer DEFAULT 10, p_active_hour_start integer DEFAULT 9, p_active_hour_end integer DEFAULT 20, p_timezone text DEFAULT 'America/Sao_Paulo'::text)
 RETURNS TABLE(attempt_id bigint, athlete_id text, athlete_name text, athlete_phone text, phone_digits text, last_questionnaire_sent_at timestamp with time zone, last_response_at timestamp with time zone, webhook_payload jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_local_hour integer;
  v_last_created timestamptz;
  v_gap_minutes integer;
  v_today_count integer;
begin
  v_local_hour := extract(hour from (now() at time zone p_timezone))::int;
  if v_local_hour < p_active_hour_start or v_local_hour >= p_active_hour_end then
    return;
  end if;

  if random() > greatest(0, least(1, coalesce(p_probability, 0.65))) then
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext('pingo_reactivation_pacing'));

  v_gap_minutes := coalesce(p_global_gap_minutes, 25) + floor(random() * 15)::int;
  select max(created_at) into v_last_created
  from public.minds_reactivation_attempts
  where attempt_type = 'webhook_reactivation';

  if v_last_created is not null
     and v_last_created > now() - make_interval(mins => v_gap_minutes) then
    return;
  end if;

  select count(*) into v_today_count
  from public.minds_reactivation_attempts
  where attempt_type = 'webhook_reactivation'
    and (created_at at time zone p_timezone)::date = (now() at time zone p_timezone)::date;

  if v_today_count >= greatest(1, coalesce(p_daily_cap, 10)) then
    return;
  end if;

  return query
  with base as (
    select distinct on (ar.athlete_id)
      ar.athlete_id, ar.athlete_name, ar.athlete_phone,
      public.minds_digits(ar.athlete_phone) as phone_digits,
      greatest(
        coalesce(qs.pre_last_sent_at, 'epoch'::timestamptz),
        coalesce(qs.post_last_sent_at, 'epoch'::timestamptz),
        coalesce(qs.quarterly_last_sent_at, 'epoch'::timestamptz),
        coalesce(qs.semiannual_last_sent_at, 'epoch'::timestamptz),
        coalesce(qs.construcional_last_sent_at, 'epoch'::timestamptz)
      ) as last_sent_at,
      greatest(
        coalesce(qs.pre_last_answer_at, 'epoch'::timestamptz),
        coalesce(qs.post_last_answer_at, 'epoch'::timestamptz),
        coalesce(qs.quarterly_last_answer_at, 'epoch'::timestamptz),
        coalesce(qs.semiannual_last_answer_at, 'epoch'::timestamptz),
        coalesce(qs.construcional_last_answer_at, 'epoch'::timestamptz),
        coalesce(ws.last_user_message_at, 'epoch'::timestamptz)
      ) as last_response_at
    from public.athlete_registration ar
    left join public.minds_questionnaire_state qs on qs.athlete_id = ar.athlete_id
    left join public.minds_whatsapp_session ws on ws.athlete_id = ar.athlete_id
    where ar.athlete_phone is not null
      and public.minds_digits(ar.athlete_phone) <> ''
    order by ar.athlete_id, ar.inserted_at desc nulls last
  ),
  candidates as (
    select b.*
    from base b
    where b.last_sent_at > '2000-01-01'::timestamptz
      and b.last_sent_at < now() - make_interval(hours => p_min_hours_after_questionnaire)
      and b.last_response_at < b.last_sent_at
      and not exists (
        select 1 from public.minds_reactivation_attempts m
        where m.athlete_id = b.athlete_id
          and m.created_at > now() - make_interval(hours => p_cooldown_hours)
      )
    order by random()
    limit 1                       -- HARD CAP: 1 por execucao
  ),
  inserted as (
    insert into public.minds_reactivation_attempts (
      athlete_id, athlete_name, athlete_phone, phone_digits,
      attempt_type, status, template_name, created_at, metadata
    )
    select
      c.athlete_id, c.athlete_name, c.athlete_phone, c.phone_digits,
      'webhook_reactivation', 'claimed', 'oi_sumido_pingo_chat_webhook', now(),
      jsonb_build_object(
        'last_questionnaire_sent_at', c.last_sent_at,
        'last_response_at', c.last_response_at,
        'route', 'PINGO Chat -> Pingo - Atleta',
        'controlled', true,
        'pacing', jsonb_build_object(
          'gap_minutes_used', v_gap_minutes,
          'daily_count_before', v_today_count,
          'local_hour', v_local_hour
        )
      )
    from candidates c
    returning *
  )
  select
    i.id, i.athlete_id, i.athlete_name, i.athlete_phone, i.phone_digits,
    (i.metadata->>'last_questionnaire_sent_at')::timestamptz,
    (i.metadata->>'last_response_at')::timestamptz,
    jsonb_build_object(
      'event', 'messages.upsert',
      'instance', 'PingoAI',
      'data', jsonb_build_object(
        'key', jsonb_build_object(
          'remoteJid', i.phone_digits || '@s.whatsapp.net',
          'remoteJidAlt', i.phone_digits || '@s.whatsapp.net',
          'fromMe', false,
          'id', 'PINGO_REACT_' || i.id::text || '_' || floor(extract(epoch from now()))::text,
          'participant', '',
          'addressingMode', 'pn'
        ),
        'pushName', coalesce(i.athlete_name, 'Atleta'),
        'status', 'SERVER_ACK',
        'message', jsonb_build_object('conversation', 'PINGO_REATIVACAO_OI_SUMIDO'),
        'messageType', 'conversation',
        'messageTimestamp', floor(extract(epoch from now()))::bigint,
        'source', 'pingo_controlled_reactivation',
        'reactivationAttemptId', i.id
      ),
      'sender', i.phone_digits || '@s.whatsapp.net',
      'server_url', 'internal_pg_net_controlled_webhook',
      'date_time', now()
    )
  from inserted i;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.clean_zero_flags()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.cosine_distance(halfvec, halfvec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_cosine_distance$function$
;

CREATE OR REPLACE FUNCTION public.cosine_distance(vector, vector)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$cosine_distance$function$
;

CREATE OR REPLACE FUNCTION public.cosine_distance(sparsevec, sparsevec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_cosine_distance$function$
;

CREATE OR REPLACE FUNCTION public.create_athlete_note(p_athlete_id text, p_note_text text, p_user_id text DEFAULT NULL::text, p_source_message_id bigint DEFAULT NULL::bigint, p_title text DEFAULT NULL::text, p_tags text[] DEFAULT '{}'::text[], p_confidence numeric DEFAULT NULL::numeric, p_model_name text DEFAULT NULL::text, p_note_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.create_full_user(p_user_id text, p_name text, p_phone text, p_email text, p_password_hash text, p_master_id text, p_coach_id text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.crypt(pass text, salt text)
 RETURNS text
 LANGUAGE sql
AS $function$
select encode(digest(pass || salt, 'sha256'), 'hex');
$function$
;

CREATE OR REPLACE FUNCTION public.digest(data text, alg text)
 RETURNS bytea
 LANGUAGE sql
AS $function$
select decode(md5(data), 'hex');
$function$
;

CREATE OR REPLACE FUNCTION public.dispatch_minds_webhook_batch(p_max integer DEFAULT 15)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.dispatch_next_minds_webhook()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.ensure_coach_user(p_coach_name text, p_coach_phone text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.find_athletes(p_query text DEFAULT NULL::text, p_limit integer DEFAULT 10)
 RETURNS TABLE(athlete_id text, athlete_name text, team_name text, athlete_phone text, coach_phone text, last_seen timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.gen_salt(type text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_all_coaches()
 RETURNS TABLE(user_id text, coach_name text, coach_phone text, role text)
 LANGUAGE sql
 STABLE
AS $function$
  select
    uc.user_id::text as user_id,
    uc.name::text as coach_name,
    uc.phone::text as coach_phone,
    uc.role::text as role
  from public.users_coaches uc
  order by uc.name;
$function$
;

CREATE OR REPLACE FUNCTION public.get_all_teams_with_athletes()
 RETURNS json
 LANGUAGE sql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_athlete_full_analysis(p_athlete_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_athletes_by_coach(p_coach_phone text, p_limit integer DEFAULT 60)
 RETURNS TABLE(athlete_id text, athlete_name text, team_name text, athlete_phone text, coach_phone text, last_seen timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_coach_bundle(p_phone text, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_coaches_by_master(p_master_phone text DEFAULT NULL::text, p_limit integer DEFAULT 100)
 RETURNS TABLE(user_id text, coach_name text, coach_phone text, role text)
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_coaches_by_master()
 RETURNS TABLE(user_id text, coach_name text, coach_phone text, role text)
 LANGUAGE sql
 STABLE
AS $function$
  select
    uc.user_id::text as user_id,
    uc.name::text as coach_name,
    uc.phone::text as coach_phone,
    uc.role::text as role
  from public.users_coaches uc
  order by uc.name;
$function$
;

CREATE OR REPLACE FUNCTION public.get_master_data()
 RETURNS TABLE(athlete_id text, athlete_name text, team_name text, athlete_phone text, coach_phone text, inserted_at timestamp with time zone, athlete_count bigint)
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_pingo_chat_bundle(p_user_id text, p_notes_limit integer DEFAULT 8, p_msgs_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.get_pingo_chat_context(p_user_id text)
 RETURNS TABLE(user_id text, last_athlete_id text, last_athlete_name text, last_team_name text, last_athlete_phone text, last_coach_phone text, meta jsonb, updated_at timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_recent_notes(p_athlete_id text, p_limit integer DEFAULT 10)
 RETURNS TABLE(id bigint, created_at timestamp with time zone, title text, note_text text, confidence numeric, model_name text)
 LANGUAGE sql
 STABLE
AS $function$
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
                                                          $function$
;

CREATE OR REPLACE FUNCTION public.get_recent_user_messages(p_athlete_id text, p_limit integer DEFAULT 15, p_only_history boolean DEFAULT false)
 RETURNS TABLE(id bigint, received_at timestamp with time zone, message_text text, include_in_history boolean, saved_at timestamp with time zone, saved_by text)
 LANGUAGE sql
 STABLE
AS $function$
  select
    m.id, m.received_at, m.message_text, m.include_in_history, m.saved_at, m.saved_by
  from public.pingo_user_messages m
  where m.athlete_id = p_athlete_id
    and (case when p_only_history then m.include_in_history else true end)
  order by m.received_at desc
  limit greatest(1, least(p_limit, 50));
$function$
;

CREATE OR REPLACE FUNCTION public.get_team_analysis(p_coach_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_team_analysis_compact(p_coach_phone text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.guard_hibernated_minds_notification_queue()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.guard_hibernated_minds_webhook_queue()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_send_state text;
begin
  select coalesce(s.send_state, 'active')
    into v_send_state
  from public.minds_athlete_delivery_state s
  where s.athlete_id = new.athlete_id;

  if v_send_state = 'hibernated'
     and coalesce(new.questionnaire, '') <> 'reactivation' then
    new.status := 'hibernated';
    new.available_at := null;
    new.last_error := 'athlete hibernated';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.halfvec(halfvec, integer, boolean)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_accum(double precision[], halfvec)
 RETURNS double precision[]
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_accum$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_add(halfvec, halfvec)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_add$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_avg(double precision[])
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_avg$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_cmp(halfvec, halfvec)
 RETURNS integer
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_cmp$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_combine(double precision[], double precision[])
 RETURNS double precision[]
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_combine$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_concat(halfvec, halfvec)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_concat$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_eq(halfvec, halfvec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_eq$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_ge(halfvec, halfvec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_ge$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_gt(halfvec, halfvec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_gt$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_in(cstring, oid, integer)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_in$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_l2_squared_distance(halfvec, halfvec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_l2_squared_distance$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_le(halfvec, halfvec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_le$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_lt(halfvec, halfvec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_lt$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_mul(halfvec, halfvec)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_mul$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_ne(halfvec, halfvec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_ne$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_negative_inner_product(halfvec, halfvec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_negative_inner_product$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_out(halfvec)
 RETURNS cstring
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_out$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_recv(internal, oid, integer)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_recv$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_send(halfvec)
 RETURNS bytea
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_send$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_spherical_distance(halfvec, halfvec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_spherical_distance$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_sub(halfvec, halfvec)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_sub$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_to_float4(halfvec, integer, boolean)
 RETURNS real[]
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_to_float4$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_to_sparsevec(halfvec, integer, boolean)
 RETURNS sparsevec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_to_sparsevec$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_to_vector(halfvec, integer, boolean)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_to_vector$function$
;

CREATE OR REPLACE FUNCTION public.halfvec_typmod_in(cstring[])
 RETURNS integer
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_typmod_in$function$
;

CREATE OR REPLACE FUNCTION public.hamming_distance(bit, bit)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$hamming_distance$function$
;

CREATE OR REPLACE FUNCTION public.hibernate_athlete(p_athlete_id text, p_reason text DEFAULT NULL::text, p_auto boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.hnsw_bit_support(internal)
 RETURNS internal
 LANGUAGE c
AS '$libdir/vector', $function$hnsw_bit_support$function$
;

CREATE OR REPLACE FUNCTION public.hnsw_halfvec_support(internal)
 RETURNS internal
 LANGUAGE c
AS '$libdir/vector', $function$hnsw_halfvec_support$function$
;

CREATE OR REPLACE FUNCTION public.hnsw_sparsevec_support(internal)
 RETURNS internal
 LANGUAGE c
AS '$libdir/vector', $function$hnsw_sparsevec_support$function$
;

CREATE OR REPLACE FUNCTION public.hnswhandler(internal)
 RETURNS index_am_handler
 LANGUAGE c
AS '$libdir/vector', $function$hnswhandler$function$
;

CREATE OR REPLACE FUNCTION public.horizons_ack_changes(p_event_ids uuid[], p_success boolean DEFAULT true, p_error text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
  select integration.ack_changes_for_horizons(p_event_ids, p_success, p_error);
$function$
;

CREATE OR REPLACE FUNCTION public.horizons_export_table_json(p_schema_name text, p_table_name text, p_limit integer DEFAULT 1000, p_offset integer DEFAULT 0)
 RETURNS SETOF jsonb
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
  select *
  from integration.export_table_json(
    p_schema_name,
    p_table_name,
    p_limit,
    p_offset
  );
$function$
;

CREATE OR REPLACE FUNCTION public.horizons_pull_changes(p_limit integer DEFAULT 500, p_reserve_minutes integer DEFAULT 5)
 RETURNS TABLE(event_id uuid, occurred_at timestamp with time zone, schema_name text, table_name text, op text, pk jsonb, old_row jsonb, new_row jsonb, txid bigint)
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
  select *
  from integration.pull_changes_for_horizons(p_limit, p_reserve_minutes);
$function$
;

CREATE OR REPLACE FUNCTION public.inner_product(halfvec, halfvec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_inner_product$function$
;

CREATE OR REPLACE FUNCTION public.inner_product(vector, vector)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$inner_product$function$
;

CREATE OR REPLACE FUNCTION public.inner_product(sparsevec, sparsevec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_inner_product$function$
;

CREATE OR REPLACE FUNCTION public.insert_analysis_vector(p_athlete_id text, p_data date, p_source text, p_embedding vector, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.is_athlete_allowed(p_athlete_id text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.ivfflat_bit_support(internal)
 RETURNS internal
 LANGUAGE c
AS '$libdir/vector', $function$ivfflat_bit_support$function$
;

CREATE OR REPLACE FUNCTION public.ivfflat_halfvec_support(internal)
 RETURNS internal
 LANGUAGE c
AS '$libdir/vector', $function$ivfflat_halfvec_support$function$
;

CREATE OR REPLACE FUNCTION public.ivfflathandler(internal)
 RETURNS index_am_handler
 LANGUAGE c
AS '$libdir/vector', $function$ivfflathandler$function$
;

CREATE OR REPLACE FUNCTION public.jaccard_distance(bit, bit)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$jaccard_distance$function$
;

CREATE OR REPLACE FUNCTION public.l1_distance(halfvec, halfvec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_l1_distance$function$
;

CREATE OR REPLACE FUNCTION public.l1_distance(vector, vector)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$l1_distance$function$
;

CREATE OR REPLACE FUNCTION public.l1_distance(sparsevec, sparsevec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_l1_distance$function$
;

CREATE OR REPLACE FUNCTION public.l2_distance(sparsevec, sparsevec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_l2_distance$function$
;

CREATE OR REPLACE FUNCTION public.l2_distance(halfvec, halfvec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_l2_distance$function$
;

CREATE OR REPLACE FUNCTION public.l2_distance(vector, vector)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$l2_distance$function$
;

CREATE OR REPLACE FUNCTION public.l2_norm(halfvec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_l2_norm$function$
;

CREATE OR REPLACE FUNCTION public.l2_norm(sparsevec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_l2_norm$function$
;

CREATE OR REPLACE FUNCTION public.l2_normalize(halfvec)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_l2_normalize$function$
;

CREATE OR REPLACE FUNCTION public.l2_normalize(vector)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$l2_normalize$function$
;

CREATE OR REPLACE FUNCTION public.l2_normalize(sparsevec)
 RETURNS sparsevec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_l2_normalize$function$
;

CREATE OR REPLACE FUNCTION public.list_user_athletes(p_user_id text, p_limit integer DEFAULT 20)
 RETURNS TABLE(athlete_id text, athlete_name text, team_name text, athlete_phone text, coach_phone text, pinned boolean, last_used_at timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
  select
    athlete_id, athlete_name, team_name, athlete_phone, coach_phone, pinned, last_used_at
  from public.pingo_user_athletes
  where user_id = p_user_id
  order by pinned desc, last_used_at desc
  limit greatest(1, least(p_limit, 50));
$function$
;

CREATE OR REPLACE FUNCTION public.log_user_message(p_user_id text, p_message_text text, p_message_type text DEFAULT 'text'::text, p_message_meta jsonb DEFAULT '{}'::jsonb, p_athlete_id text DEFAULT NULL::text)
 RETURNS TABLE(message_id bigint, athlete_id text)
 LANGUAGE plpgsql
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.mark_pingo_webhook_reactivation_injected(p_attempt_id bigint, p_status_code integer DEFAULT NULL::integer, p_webhook_response jsonb DEFAULT NULL::jsonb, p_error text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.minds_reactivation_attempts%rowtype;
begin
  update public.minds_reactivation_attempts
  set status = case when p_error is null then 'sent_to_webhook' else 'failed' end,
      injected_at = case when p_error is null then now() else injected_at end,
      attempted_at = case when p_error is null then coalesce(attempted_at, now()) else attempted_at end,
      webhook_status_code = p_status_code,
      webhook_response = p_webhook_response,
      last_error = p_error
  where id = p_attempt_id
  returning * into v_row;

  return coalesce(to_jsonb(v_row), '{}'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_after_webhook_queue_sent()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
begin
  if coalesce(new.sent, false) = true
     and coalesce(old.sent, false) = false
     and new.status = 'sent' then
    perform public.minds_mark_queue_item_sent(new.id, null);
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_auto_hibernate_inactive_athletes(p_inactive_days integer DEFAULT 15)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_count integer := 0;
begin
  with responses as (
    select athlete_id, max(created_at) as responded_at from public.weekly_analysis group by athlete_id
    union all select athlete_id, max(created_at) from public.brums_analysis group by athlete_id
    union all select athlete_id, max(created_at) from public.diet_daily group by athlete_id
    union all select athlete_id, max(created_at) from public.training_load_daily group by athlete_id
    union all select athlete_id, max(created_at) from public.acsi_analysis group by athlete_id
    union all select athlete_id, max(created_at) from public.gses_analysis group by athlete_id
    union all select athlete_id, max(created_at) from public.pmcsq_analysis group by athlete_id
    union all select athlete_id, max(created_at) from public.restq_analysis group by athlete_id
    union all select athlete_id, max(created_at) from public.cbas_analysis group by athlete_id
    union all select athlete_id, max(created_at) from public.construcional_raw group by athlete_id
    union all select athlete_id, max(last_user_message_at) from public.minds_whatsapp_session group by athlete_id
  ),
  last_response as (
    select athlete_id, max(responded_at) as last_response_at
    from responses
    group by athlete_id
  ),
  candidates as (
    select
      a.athlete_id,
      greatest(
        coalesce(lr.last_response_at, '1900-01-01'::timestamptz),
        coalesce(a.created_at, a.inserted_at, '1900-01-01'::timestamptz)
      ) as last_activity_at
    from public.athlete_registration a
    left join last_response lr on lr.athlete_id = a.athlete_id
    left join public.minds_athlete_delivery_state ds on ds.athlete_id = a.athlete_id
    where coalesce(a.athlete_enabled, true) = true
      and a.athlete_phone is not null
      and coalesce(ds.send_state, 'active') <> 'hibernated'
      and greatest(
        coalesce(lr.last_response_at, '1900-01-01'::timestamptz),
        coalesce(a.created_at, a.inserted_at, '1900-01-01'::timestamptz)
      ) < now() - make_interval(days => greatest(coalesce(p_inactive_days, 15), 1))
  )
  insert into public.minds_athlete_delivery_state (
    athlete_id,
    send_state,
    auto_hibernated,
    reason,
    hibernated_at,
    updated_at
  )
  select
    athlete_id,
    'hibernated',
    true,
    'auto hibernated: no athlete response for ' || greatest(coalesce(p_inactive_days, 15), 1)::text || ' days',
    now(),
    now()
  from candidates
  on conflict (athlete_id)
  do update set
    send_state = 'hibernated',
    auto_hibernated = true,
    reason = excluded.reason,
    hibernated_at = now(),
    updated_at = now()
  where public.minds_athlete_delivery_state.send_state <> 'hibernated';

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_bridge_whatsapp_flow_response_to_pingo_observation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_kind text;
  v_source_submission_id text;
  v_reference_date date;
begin
  v_kind := case lower(coalesce(new.questionnaire, ''))
    when 'pre' then 'daily_pre'
    when 'post' then 'daily_post'
    when 'weekly' then 'weekly'
    when 'quarterly' then 'quarterly'
    when 'semiannual' then 'semiannual'
    when 'construcional' then 'construcional'
    else 'whatsapp'
  end;

  v_source_submission_id := coalesce(
    nullif(new.message_id, ''),
    nullif(new.flow_token, ''),
    new.id::text
  );

  v_reference_date := coalesce(
    nullif(new.response_json ->> 'reference_date', '')::date,
    nullif(new.response_json ->> 'data', '')::date,
    (new.received_at at time zone 'America/Sao_Paulo')::date,
    current_date
  );

  insert into public.pingo_observations (
    athlete_id,
    kind,
    instrument_kind,
    reference_date,
    observed_at,
    submitted_at,
    source,
    source_submission_id,
    source_dedup_key,
    raw_payload,
    data_quality_status,
    processing_status,
    metadata_json
  ) values (
    new.athlete_id,
    v_kind,
    v_kind,
    v_reference_date,
    coalesce(new.received_at, now()),
    coalesce(new.received_at, now()),
    'meta_whatsapp_flow',
    v_source_submission_id,
    concat_ws('|', 'meta_whatsapp_flow', v_kind, coalesce(new.athlete_id, ''), v_reference_date::text, v_source_submission_id),
    jsonb_build_object(
      'minds_whatsapp_flow_response_id', new.id,
      'phone', new.phone,
      'questionnaire', new.questionnaire,
      'flow_token', new.flow_token,
      'flow_id', new.flow_id,
      'message_id', new.message_id,
      'response_json', coalesce(new.response_json, '{}'::jsonb),
      'raw_payload', coalesce(new.raw_payload, '{}'::jsonb)
    ),
    case when new.athlete_id is null or btrim(new.athlete_id) = '' then 'invalid_missing_athlete' else 'unvalidated' end,
    'received',
    jsonb_build_object(
      'bridge', 'minds_whatsapp_flow_responses_to_pingo_observations',
      'bridge_version', '2026-06-01',
      'source_table', 'minds_whatsapp_flow_responses',
      'source_id', new.id
    )
  )
  on conflict (source_dedup_key) do nothing;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_call_adherence_reporter(p_report_date date DEFAULT ((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date, p_force boolean DEFAULT false)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'vault', 'pg_catalog'
AS $function$
declare
  v_secret text;
  v_request_id bigint;
begin
  select decrypted_secret
    into v_secret
  from vault.decrypted_secrets
  where name = 'MINDS_DISPATCH_SECRET'
  limit 1;

  select net.http_post(
    url := 'https://ujbhgocpgsdefrwanlsm.supabase.co/functions/v1/minds-adherence-reporter',
    body := jsonb_build_object(
      'report_date', p_report_date,
      'webhook_url', 'https://autowebhook.opingo.com.br/webhook/Adesao_MINDS',
      'force', p_force,
      'send_webhook', true
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-minds-dispatch-secret', coalesce(v_secret, '')
    ),
    timeout_milliseconds := 25000
  ) into v_request_id;

  return v_request_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_call_questionnaire_dispatcher(p_limit integer DEFAULT 25)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'vault', 'pg_catalog'
AS $function$
declare
  v_secret text;
  v_request_id bigint;
begin
  select decrypted_secret
    into v_secret
  from vault.decrypted_secrets
  where name = 'MINDS_DISPATCH_SECRET'
  limit 1;

  if nullif(trim(coalesce(v_secret,'')), '') is null then
    raise exception 'missing Vault secret MINDS_DISPATCH_SECRET. Add it in Supabase Vault with the same value used by the Edge Function.';
  end if;

  select net.http_post(
    url := 'https://ujbhgocpgsdefrwanlsm.supabase.co/functions/v1/minds-questionnaire-dispatcher',
    body := jsonb_build_object('limit', greatest(coalesce(p_limit, 25), 1)),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-minds-dispatch-secret', v_secret
    ),
    timeout_milliseconds := 25000
  ) into v_request_id;

  return v_request_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_create_reactivation_token(p_athlete_id text, p_athlete_phone text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_token text;
begin
  if nullif(trim(p_athlete_id), '') is null then
    raise exception 'missing athlete_id';
  end if;

  update public.minds_reactivation_tokens
     set status = 'replaced', updated_at = now()
   where athlete_id = p_athlete_id
     and status = 'active'
     and used_at is null;

  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  insert into public.minds_reactivation_tokens (athlete_id, athlete_phone, token)
  values (p_athlete_id, p_athlete_phone, v_token);

  return v_token;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_cron_plan_and_enqueue()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_requeued integer := 0;
  v_plan jsonb;
  v_enqueued integer := 0;
  v_reactivation_enqueued integer := 0;
begin
  v_requeued := public.minds_requeue_stale_webhook_processing(10, 200);

  v_plan := public.minds_plan_next_notifications(0, 16, 60, 60, 11, 500);
  v_enqueued := public.minds_enqueue_due_planned_notifications(100);
  v_reactivation_enqueued := public.minds_enqueue_reactivation_webhooks(25);

  return jsonb_build_object(
    'ok', true,
    'requeued_stale_processing', v_requeued,
    'planned', v_plan,
    'enqueued_questionnaires', v_enqueued,
    'enqueued_reactivation', v_reactivation_enqueued,
    'post_business_hours_brt', '08:00-20:00',
    'ran_at', now()
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_daily_team_adherence_snapshots(p_report_date date DEFAULT ((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
with athletes as (
  select distinct on (public.minds_norm_athlete_id(ar.athlete_id::text))
    public.minds_norm_athlete_id(ar.athlete_id::text) as athlete_id,
    coalesce(nullif(trim(ar.athlete_name), ''), 'Sem nome') as athlete_name,
    nullif(trim(coalesce(ar.athlete_phone, '')), '') as athlete_phone,
    coalesce(nullif(trim(ar.team_name), ''), 'Sem equipe') as team_name,
    coalesce(ar.athlete_enabled, true) as athlete_enabled,
    ar.updated_at,
    ar.created_at
  from public.athlete_registration ar
  where public.minds_norm_athlete_id(ar.athlete_id::text) is not null
  order by public.minds_norm_athlete_id(ar.athlete_id::text), ar.updated_at desc nulls last, ar.created_at desc nulls last
),
eligible_athletes as (
  select *
  from athletes
  where athlete_enabled is true
    and athlete_phone is not null
),
sent_today as (
  select
    public.minds_norm_athlete_id(q.athlete_id::text) as athlete_id,
    q.questionnaire,
    min(q.sent_at) as first_sent_at,
    max(q.sent_at) as last_sent_at,
    count(*)::int as sent_count
  from public.minds_webhook_queue q
  where q.sent = true
    and q.status = 'sent'
    and q.last_status_code = 200
    and public.minds_norm_athlete_id(q.athlete_id::text) is not null
    and (q.sent_at at time zone 'America/Sao_Paulo')::date = p_report_date
  group by public.minds_norm_athlete_id(q.athlete_id::text), q.questionnaire
),
pre_sent as (
  select * from sent_today where questionnaire = 'pre'
),
pre_answers_today as (
  select
    public.minds_norm_athlete_id(b.athlete_id::text) as athlete_id,
    min(b.inserted_at) as first_answer_at,
    max(b.inserted_at) as last_answer_at,
    count(*)::int as answer_count
  from public.brums_analysis b
  where public.minds_norm_athlete_id(b.athlete_id::text) is not null
    and (b.inserted_at at time zone 'America/Sao_Paulo')::date = p_report_date
  group by public.minds_norm_athlete_id(b.athlete_id::text)
),
post_answers_today as (
  select
    public.minds_norm_athlete_id(t.athlete_id::text) as athlete_id,
    min(t.inserted_at) as first_answer_at,
    max(t.inserted_at) as last_answer_at,
    count(*)::int as answer_count
  from public.training_load_daily t
  where public.minds_norm_athlete_id(t.athlete_id::text) is not null
    and t.kind = 'daily_post'
    and (t.inserted_at at time zone 'America/Sao_Paulo')::date = p_report_date
  group by public.minds_norm_athlete_id(t.athlete_id::text)
),
team_names as (
  select distinct team_name from eligible_athletes
),
team_payloads as (
  select
    tn.team_name,
    jsonb_build_object(
      'source', 'MINDS',
      'report_type', 'daily_team_adherence',
      'report_date', p_report_date,
      'team_name', tn.team_name,
      'generated_at', now(),
      'timezone', 'America/Sao_Paulo',
      'summary', jsonb_build_object(
        'eligible_athletes_with_phone', (
          select count(*)::int from eligible_athletes a where a.team_name = tn.team_name
        ),
        'pre_sent_count', (
          select count(*)::int
          from pre_sent ps
          join eligible_athletes a on a.athlete_id = ps.athlete_id
          where a.team_name = tn.team_name
        ),
        'pre_answered_count', (
          select count(*)::int
          from pre_sent ps
          join eligible_athletes a on a.athlete_id = ps.athlete_id
          join pre_answers_today pa on pa.athlete_id = ps.athlete_id and pa.last_answer_at >= ps.first_sent_at
          where a.team_name = tn.team_name
        ),
        'pre_pending_count', (
          select count(*)::int
          from pre_sent ps
          join eligible_athletes a on a.athlete_id = ps.athlete_id
          left join pre_answers_today pa on pa.athlete_id = ps.athlete_id and pa.last_answer_at >= ps.first_sent_at
          where a.team_name = tn.team_name
            and pa.athlete_id is null
        ),
        'pre_response_rate_percent', (
          select round(
            (count(*) filter (where pa.athlete_id is not null)::numeric / nullif(count(*), 0)) * 100,
            2
          )
          from pre_sent ps
          join eligible_athletes a on a.athlete_id = ps.athlete_id
          left join pre_answers_today pa on pa.athlete_id = ps.athlete_id and pa.last_answer_at >= ps.first_sent_at
          where a.team_name = tn.team_name
        ),
        'sent_by_questionnaire', (
          select coalesce(jsonb_object_agg(questionnaire, total order by questionnaire), '{}'::jsonb)
          from (
            select st.questionnaire, sum(st.sent_count)::int as total
            from sent_today st
            join eligible_athletes a on a.athlete_id = st.athlete_id
            where a.team_name = tn.team_name
            group by st.questionnaire
          ) x
        ),
        'post_answers_today_count', (
          select count(*)::int
          from post_answers_today pa
          join eligible_athletes a on a.athlete_id = pa.athlete_id
          where a.team_name = tn.team_name
        )
      ),
      'pre_responded', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'athlete_id', a.athlete_id,
          'athlete_name', a.athlete_name,
          'athlete_phone', a.athlete_phone,
          'pre_sent_at', ps.first_sent_at,
          'pre_answered_at', pa.last_answer_at,
          'answer_count', pa.answer_count
        ) order by pa.last_answer_at desc, a.athlete_name), '[]'::jsonb)
        from pre_sent ps
        join eligible_athletes a on a.athlete_id = ps.athlete_id
        join pre_answers_today pa on pa.athlete_id = ps.athlete_id and pa.last_answer_at >= ps.first_sent_at
        where a.team_name = tn.team_name
      ),
      'pre_not_responded', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'athlete_id', a.athlete_id,
          'athlete_name', a.athlete_name,
          'athlete_phone', a.athlete_phone,
          'pre_sent_at', ps.first_sent_at
        ) order by ps.first_sent_at desc, a.athlete_name), '[]'::jsonb)
        from pre_sent ps
        join eligible_athletes a on a.athlete_id = ps.athlete_id
        left join pre_answers_today pa on pa.athlete_id = ps.athlete_id and pa.last_answer_at >= ps.first_sent_at
        where a.team_name = tn.team_name
          and pa.athlete_id is null
      ),
      'questionnaire_sent_details', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'athlete_id', a.athlete_id,
          'athlete_name', a.athlete_name,
          'athlete_phone', a.athlete_phone,
          'questionnaire', st.questionnaire,
          'sent_count', st.sent_count,
          'first_sent_at', st.first_sent_at,
          'last_sent_at', st.last_sent_at
        ) order by st.questionnaire, st.last_sent_at desc, a.athlete_name), '[]'::jsonb)
        from sent_today st
        join eligible_athletes a on a.athlete_id = st.athlete_id
        where a.team_name = tn.team_name
      )
    ) as payload
  from team_names tn
)
select coalesce(jsonb_agg(payload order by team_name), '[]'::jsonb)
from team_payloads
where coalesce((payload #>> '{summary,pre_sent_count}')::int, 0) > 0
   or coalesce((payload #>> '{summary,post_answers_today_count}')::int, 0) > 0
   or payload->'questionnaire_sent_details' <> '[]'::jsonb;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_digits(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select regexp_replace(coalesce(p_text, ''), '[^0-9]', '', 'g')
$function$
;

CREATE OR REPLACE FUNCTION public.minds_enqueue_due_notifications(p_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_count integer := 0;
begin
  insert into public.minds_webhook_queue (
    athlete_id, athlete_name, athlete_phone, questionnaire,
    sent, status, retry_count, max_retries, available_at, created_at
  )
  select
    n.athlete_id, n.athlete_name, n.athlete_phone, n.action_type,
    false, 'pending', 0, 5,
    greatest(coalesce(n.due_at, now()), now()), now()
  from public.minds_next_notifications n
  left join public.minds_athlete_delivery_state ds on ds.athlete_id = n.athlete_id
  where n.due_at <= now()
    and n.action_type in ('pre','post','weekly','quarterly','semiannual')
    and nullif(trim(coalesce(n.athlete_phone,'')), '') is not null
    and coalesce(ds.send_state, 'active') <> 'hibernated'
    and not exists (
      select 1
      from public.minds_webhook_queue q
      where q.athlete_id = n.athlete_id
        and q.questionnaire = n.action_type
        and coalesce(q.sent, false) = false
        and coalesce(q.status, 'pending') in ('pending','queued','retry','processing')
    )
    and not exists (
      select 1
      from public.minds_webhook_queue q2
      where q2.athlete_id = n.athlete_id
        and q2.questionnaire = n.action_type
        and q2.created_hour = date_trunc('hour', now())
    )
  order by n.due_at asc, n.priority_rank asc nulls last
  limit greatest(coalesce(p_limit, 100), 1)
  on conflict (athlete_id, questionnaire, created_hour) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_enqueue_due_planned_notifications(p_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_count integer := 0;
  v_base timestamptz;
  v_batch_size int := 10;    -- itens por degrau (afrouxado, oficial aguenta)
  v_step_min   int := 5;     -- minutos entre degraus
begin
  select greatest(coalesce(max(available_at), now()), now())
    into v_base
  from public.minds_webhook_queue
  where status='pending' and sent=false;

  with due as (
    select p.*,
           row_number() over (order by p.due_at asc, p.priority_rank asc) as rn
    from public.minds_planned_notifications p
    left join public.minds_athlete_delivery_state ds on ds.athlete_id = p.athlete_id
    where p.status = 'planned'
      and p.due_at <= now()
      and p.action_type in ('pre','post','weekly','quarterly','semiannual')
      and nullif(trim(coalesce(p.athlete_phone,'')), '') is not null
      and coalesce(ds.send_state, 'active') <> 'hibernated'
      and (
        p.action_type <> 'post'
        or (extract(hour from now() at time zone 'America/Sao_Paulo') >= 8
            and extract(hour from now() at time zone 'America/Sao_Paulo') < 20)
      )
      and not exists (
        select 1 from public.minds_webhook_queue q
        where q.athlete_id = p.athlete_id and q.questionnaire = p.action_type
          and coalesce(q.sent,false)=false
          and coalesce(q.status,'pending') in ('pending','queued','retry','processing')
      )
      and not exists (
        select 1 from public.minds_webhook_queue q2
        where q2.athlete_id = p.athlete_id and q2.questionnaire = p.action_type
          and q2.created_hour = date_trunc('hour', now())
      )
    order by p.due_at asc, p.priority_rank asc
    limit greatest(coalesce(p_limit, 100), 1)
  ),
  inserted as (
    insert into public.minds_webhook_queue (
      athlete_id, athlete_name, athlete_phone, questionnaire,
      sent, status, retry_count, max_retries, available_at, created_at
    )
    select
      athlete_id, athlete_name, athlete_phone, action_type,
      false, 'pending', 0, 5,
      v_base + make_interval(mins => (floor((rn-1)/v_batch_size::numeric)*v_step_min)::int),
      now()
    from due
    on conflict (athlete_id, questionnaire, created_hour) do nothing
    returning athlete_id, questionnaire
  )
  update public.minds_planned_notifications p
     set status='enqueued', enqueued_at=now(), updated_at=now()
    from inserted i
   where p.athlete_id=i.athlete_id and p.action_type=i.questionnaire
     and p.status='planned' and p.due_at<=now();

  get diagnostics v_count = row_count;

  update public.minds_planned_notifications p
     set status='duplicate', updated_at=now()
   where p.status='planned' and p.due_at<=now()
     and p.action_type in ('pre','post','weekly','quarterly','semiannual')
     and exists (select 1 from public.minds_webhook_queue q
                 where q.athlete_id=p.athlete_id and q.questionnaire=p.action_type
                   and q.created_hour=date_trunc('hour', now()));
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_enqueue_reactivation_webhooks(p_limit integer DEFAULT 25)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_count integer := 0;
begin
  with candidates as (
    select distinct on (a.athlete_id)
      a.id as attempt_id,
      a.athlete_id,
      a.athlete_name,
      a.athlete_phone,
      a.template_name,
      a.created_at
    from public.minds_reactivation_attempts a
    left join public.minds_athlete_delivery_state ds on ds.athlete_id = a.athlete_id
    where coalesce(a.status, 'queued') in ('queued','pending')
      and nullif(trim(coalesce(a.athlete_phone,'')), '') is not null
      and coalesce(ds.send_state, 'hibernated') = 'hibernated'
      and not exists (
        select 1
        from public.minds_webhook_queue q
        where q.athlete_id = a.athlete_id
          and q.questionnaire = 'reactivation'
          and coalesce(q.sent, false) = false
          and coalesce(q.status, 'pending') in ('pending','queued','retry','processing')
      )
    order by a.athlete_id, a.created_at asc
    limit greatest(coalesce(p_limit, 25), 1)
  ), inserted as (
    insert into public.minds_webhook_queue (
      athlete_id,
      athlete_name,
      athlete_phone,
      questionnaire,
      sent,
      status,
      retry_count,
      max_retries,
      available_at,
      created_at
    )
    select
      athlete_id,
      athlete_name,
      athlete_phone,
      'reactivation',
      false,
      'pending',
      0,
      5,
      now(),
      now()
    from candidates
    returning athlete_id
  )
  update public.minds_reactivation_attempts a
     set status = 'enqueued',
         attempted_at = now(),
         last_error = null
    from inserted i
   where a.athlete_id = i.athlete_id
     and coalesce(a.status, 'queued') in ('queued','pending');

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_health_check()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  h record;
  v_alerts integer := 0;
begin
  select * into h from public.minds_health;

  if h.cron_falhas_1h > 3 then
    insert into public.minds_health_alerts(severity, metric, value, message)
    values ('CRITICO','cron_falhas_1h', h.cron_falhas_1h::text,
            'Crons falhando agora — pode ser bug de logica, requer atencao humana.');
    v_alerts := v_alerts + 1;
  end if;

  if h.em_processamento > 50 then
    insert into public.minds_health_alerts(severity, metric, value, message)
    values ('CRITICO','em_processamento', h.em_processamento::text,
            'Muitos itens presos em processing — fila pode estar travada.');
    v_alerts := v_alerts + 1;
  end if;

  if h.planned_atrasado > 20 then
    insert into public.minds_health_alerts(severity, metric, value, message)
    values ('CRITICO','planned_atrasado', h.planned_atrasado::text,
            'Planner com muitos itens atrasados — disparo pode ter parado.');
    v_alerts := v_alerts + 1;
  end if;

  if h.envios_fora_janela_7d > 0 then
    insert into public.minds_health_alerts(severity, metric, value, message)
    values ('ATENCAO','envios_fora_janela', h.envios_fora_janela_7d::text,
            'Houve envios fora da janela 08-21h BRT nos ultimos 7 dias.');
    v_alerts := v_alerts + 1;
  end if;

  if h.http_erro_2h > 5 then
    insert into public.minds_health_alerts(severity, metric, value, message)
    values ('ATENCAO','http_erro_2h', h.http_erro_2h::text,
            'Varios erros HTTP recentes no webhook — verificar secret/endpoint.');
    v_alerts := v_alerts + 1;
  end if;

  return jsonb_build_object('ok', true, 'status', h.status_geral, 'novos_alertas', v_alerts, 'checado_em', now());
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_mark_queue_item_sent(p_queue_id bigint, p_template_name text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_row public.minds_webhook_queue%rowtype;
  v_template text;
begin
  select * into v_row
  from public.minds_webhook_queue
  where id = p_queue_id;

  if not found then
    return;
  end if;

  v_template := coalesce(
    p_template_name,
    case v_row.questionnaire
      when 'pre' then 'minds_pre_checkin_v2'
      when 'post' then 'minds_post_checkin_v2'
      when 'weekly' then 'minds_weekly_checkin_v2'
      when 'quarterly' then 'minds_quarterly_checkin_v1'
      when 'semiannual' then 'minds_semiannual_checkin_v1'
      when 'reactivation' then 'minds_reactivation_v1'
      else v_row.questionnaire
    end
  );

  perform public.minds_mark_template_sent(v_row.athlete_id, v_template);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_mark_template_sent(p_athlete_id text, p_template_name text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_phone text;
  v_kind text;
begin
  if nullif(trim(p_athlete_id), '') is null then
    return;
  end if;

  select public.normalize_br_phone(ar.athlete_phone)
    into v_phone
  from public.athlete_registration ar
  where ar.athlete_id = p_athlete_id
  order by ar.updated_at desc nulls last, ar.created_at desc nulls last
  limit 1;

  v_kind := case
    when p_template_name ilike '%pre%' then 'pre'
    when p_template_name ilike '%post%' then 'post'
    when p_template_name ilike '%weekly%' then 'weekly'
    when p_template_name ilike '%quarterly%' then 'quarterly'
    when p_template_name ilike '%semiannual%' then 'semiannual'
    else null
  end;

  insert into public.minds_whatsapp_session (
    athlete_id,
    phone,
    last_template_sent_at,
    last_template_name,
    updated_at
  )
  values (
    p_athlete_id,
    coalesce(v_phone, ''),
    now(),
    p_template_name,
    now()
  )
  on conflict (athlete_id)
  do update set
    last_template_sent_at = now(),
    last_template_name = p_template_name,
    updated_at = now();

  insert into public.minds_questionnaire_state (
    athlete_id,
    pre_last_sent_at,
    post_last_sent_at,
    weekly_week_start,
    weekly_completed,
    quarterly_last_sent_at,
    semiannual_last_sent_at,
    last_notification_type,
    updated_at
  )
  values (
    p_athlete_id,
    case when v_kind = 'pre' then now() else null end,
    case when v_kind = 'post' then now() else null end,
    case when v_kind = 'weekly' then date_trunc('week', now() at time zone 'America/Sao_Paulo')::date else null end,
    case when v_kind = 'weekly' then false else null end,
    case when v_kind = 'quarterly' then now() else null end,
    case when v_kind = 'semiannual' then now() else null end,
    v_kind,
    now()
  )
  on conflict (athlete_id) do update set
    pre_last_sent_at = case when v_kind = 'pre' then now() else public.minds_questionnaire_state.pre_last_sent_at end,
    post_last_sent_at = case when v_kind = 'post' then now() else public.minds_questionnaire_state.post_last_sent_at end,
    weekly_week_start = case when v_kind = 'weekly' then date_trunc('week', now() at time zone 'America/Sao_Paulo')::date else public.minds_questionnaire_state.weekly_week_start end,
    weekly_completed = case when v_kind = 'weekly' then false else public.minds_questionnaire_state.weekly_completed end,
    quarterly_last_sent_at = case when v_kind = 'quarterly' then now() else public.minds_questionnaire_state.quarterly_last_sent_at end,
    semiannual_last_sent_at = case when v_kind = 'semiannual' then now() else public.minds_questionnaire_state.semiannual_last_sent_at end,
    last_notification_type = coalesce(v_kind, public.minds_questionnaire_state.last_notification_type),
    updated_at = now();
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_norm_athlete_id(p_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when nullif(regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g'), '') is null then null
    when length(regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g')) <= 11 then lpad(regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g'), 11, '0')
    else regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g')
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_pingo_v4_bridge_emit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare
  cfg public.minds_pingo_v4_bridge_config%rowtype;
  request_id bigint;
  body jsonb;
begin
  select * into cfg
  from public.minds_pingo_v4_bridge_config
  where id is true;

  if cfg.enabled is not true then
    return new;
  end if;

  if nullif(btrim(coalesce(cfg.target_url, '')), '') is null then
    insert into public.minds_pingo_v4_bridge_events(source_table, source_id, athlete_id, status, error_message, payload)
    values (tg_table_name, coalesce(new.id::text, null), coalesce(new.athlete_id::text, null), 'skipped', 'missing_target_url', to_jsonb(new));
    return new;
  end if;

  if nullif(btrim(coalesce(cfg.webhook_secret, '')), '') is null then
    insert into public.minds_pingo_v4_bridge_events(source_table, source_id, athlete_id, status, error_message, payload)
    values (tg_table_name, coalesce(new.id::text, null), coalesce(new.athlete_id::text, null), 'skipped', 'missing_webhook_secret', to_jsonb(new));
    return new;
  end if;

  body := jsonb_build_object(
    'source_table', tg_table_name,
    'record', to_jsonb(new)
  );

  select net.http_post(
    url := cfg.target_url,
    body := body,
    params := '{}'::jsonb,
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-pingo-webhook-secret', cfg.webhook_secret
    ),
    timeout_milliseconds := cfg.timeout_milliseconds
  ) into request_id;

  insert into public.minds_pingo_v4_bridge_events(source_table, source_id, athlete_id, request_id, status, payload)
  values (tg_table_name, coalesce(new.id::text, null), coalesce(new.athlete_id::text, null), request_id, 'queued', body);

  return new;
exception when others then
  insert into public.minds_pingo_v4_bridge_events(source_table, source_id, athlete_id, status, error_message, payload)
  values (tg_table_name, coalesce(new.id::text, null), coalesce(new.athlete_id::text, null), 'error', sqlerrm, to_jsonb(new));
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_pingo_v4_bridge_touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at := now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_plan_next_notifications(p_days_ahead integer DEFAULT 0, p_default_pre_hour integer DEFAULT 16, p_pre_offset_minutes integer DEFAULT 60, p_post_after_pre_minutes integer DEFAULT 60, p_standard_hour integer DEFAULT 11, p_limit integer DEFAULT 500)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_count integer := 0;
  v_default_pre_hour integer := least(greatest(coalesce(p_default_pre_hour, 16), 6), 22);
  v_pre_offset interval := make_interval(mins => greatest(coalesce(p_pre_offset_minutes, 60), 0));
  v_post_after_pre interval := make_interval(mins => greatest(coalesce(p_post_after_pre_minutes, 60), 0));
  v_standard_hour integer := least(greatest(coalesce(p_standard_hour, 11), 8), 20);
  v_limit integer := greatest(coalesce(p_limit, 500), 1);
  v_target_date date := ((now() at time zone 'America/Sao_Paulo')::date + greatest(coalesce(p_days_ahead, 0), 0));
begin
  perform public.minds_sync_questionnaire_state_from_answers();

  update public.minds_planned_notifications
     set status = 'superseded', updated_at = now()
   where status = 'planned'
     and (due_at at time zone 'America/Sao_Paulo')::date = v_target_date;

  with latest_athletes as (
    select distinct on (public.minds_norm_athlete_id(ar.athlete_id::text))
      public.minds_norm_athlete_id(ar.athlete_id::text) as athlete_id,
      coalesce(nullif(trim(ar.athlete_name), ''), 'atleta') as athlete_name,
      ar.athlete_phone,
      coalesce(ar.athlete_enabled, true) as athlete_enabled,
      ar.created_at,
      ar.updated_at
    from public.athlete_registration ar
    where nullif(trim(coalesce(ar.athlete_id, '')), '') is not null
      and public.minds_norm_athlete_id(ar.athlete_id::text) is not null
    order by public.minds_norm_athlete_id(ar.athlete_id::text), ar.updated_at desc nulls last, ar.created_at desc nulls last
  ),
  active_athletes as (
    select a.*
    from latest_athletes a
    left join public.minds_athlete_delivery_state ds
      on public.minds_norm_athlete_id(ds.athlete_id::text) = a.athlete_id
    where a.athlete_enabled = true
      and nullif(trim(coalesce(a.athlete_phone, '')), '') is not null
      and coalesce(ds.send_state, 'active') <> 'hibernated'
    order by a.athlete_id
    limit v_limit
  ),
  pre_history as (
    select public.minds_norm_athlete_id(athlete_id::text) as athlete_id,
           percentile_cont(0.5) within group (
             order by extract(hour from created_at at time zone 'America/Sao_Paulo') * 60
                    + extract(minute from created_at at time zone 'America/Sao_Paulo')
           )::int as median_minute
    from public.brums_analysis
    where created_at >= now() - interval '60 days'
      and public.minds_norm_athlete_id(athlete_id::text) is not null
    group by public.minds_norm_athlete_id(athlete_id::text)
  ),
  last_pre as (
    select distinct on (public.minds_norm_athlete_id(athlete_id::text))
      public.minds_norm_athlete_id(athlete_id::text) as athlete_id,
      data as pre_date,
      inserted_at as pre_time
    from public.brums_analysis
    where public.minds_norm_athlete_id(athlete_id::text) is not null
    order by public.minds_norm_athlete_id(athlete_id::text), inserted_at desc nulls last, created_at desc nulls last
  ),
  last_post as (
    select public.minds_norm_athlete_id(athlete_id::text) as athlete_id,
           max(inserted_at) as post_date
    from public.training_load_daily
    where kind = 'daily_post'
      and public.minds_norm_athlete_id(athlete_id::text) is not null
    group by public.minds_norm_athlete_id(athlete_id::text)
  ),
  weekly as (
    select public.minds_norm_athlete_id(athlete_id::text) as athlete_id,
           max(data) as last_week
    from public.restq_analysis_view
    where public.minds_norm_athlete_id(athlete_id::text) is not null
    group by public.minds_norm_athlete_id(athlete_id::text)
  ),
  quarterly as (
    select public.minds_norm_athlete_id(athlete_id::text) as athlete_id,
           max(data) as last_quarter
    from public.acsi_analysis_view
    where public.minds_norm_athlete_id(athlete_id::text) is not null
    group by public.minds_norm_athlete_id(athlete_id::text)
  ),
  semiannual as (
    select public.minds_norm_athlete_id(athlete_id::text) as athlete_id,
           max(data) as last_semi
    from public.cbas_analysis_view
    where public.minds_norm_athlete_id(athlete_id::text) is not null
    group by public.minds_norm_athlete_id(athlete_id::text)
  ),
  qs_norm as (
    select distinct on (public.minds_norm_athlete_id(athlete_id::text))
      public.minds_norm_athlete_id(athlete_id::text) as athlete_id,
      pre_last_sent_at,
      pre_last_answer_at,
      post_last_sent_at,
      post_last_answer_at
    from public.minds_questionnaire_state
    where public.minds_norm_athlete_id(athlete_id::text) is not null
    order by public.minds_norm_athlete_id(athlete_id::text), updated_at desc nulls last
  ),
  base as (
    select
      a.athlete_id,
      a.athlete_name,
      a.athlete_phone,
      coalesce(ph.median_minute, v_default_pre_hour * 60) as pre_answer_minute,
      lp.pre_time,
      lpo.post_date,
      w.last_week,
      q.last_quarter,
      s.last_semi,
      qs.pre_last_sent_at,
      qs.pre_last_answer_at,
      qs.post_last_sent_at,
      qs.post_last_answer_at,
      extract(isodow from v_target_date) in (6, 7) as weekend,
      ((w.last_week is null) or (w.last_week < (v_target_date - interval '6 days'))) as weekly_due,
      ((q.last_quarter is null) or (q.last_quarter < (v_target_date - interval '90 days'))) as quarterly_due,
      ((s.last_semi is null) or (s.last_semi < (v_target_date - interval '180 days'))) as semiannual_due,
      ((lp.pre_time is not null) and ((lpo.post_date is null) or (lpo.post_date < lp.pre_time))) as waiting_post,
      ((lp.pre_time is not null) and ((lp.pre_time + v_post_after_pre) <= now())) as post_due
    from active_athletes a
    left join pre_history ph on ph.athlete_id = a.athlete_id
    left join last_pre lp on lp.athlete_id = a.athlete_id
    left join last_post lpo on lpo.athlete_id = a.athlete_id
    left join weekly w on w.athlete_id = a.athlete_id
    left join quarterly q on q.athlete_id = a.athlete_id
    left join semiannual s on s.athlete_id = a.athlete_id
    left join qs_norm qs on qs.athlete_id = a.athlete_id
  ),
  decision as (
    select
      *,
      case
        when waiting_post and post_due then 'post'
        when weekend and weekly_due then 'weekly'
        when quarterly_due then 'quarterly'
        when semiannual_due then 'semiannual'
        when (not waiting_post) and (not weekend) then 'pre'
        else null
      end as predicted_questionnaire
    from base
  ),
  planned as (
    select
      athlete_id,
      athlete_name,
      athlete_phone,
      predicted_questionnaire as action_type,
      case
        when predicted_questionnaire = 'post' then 1
        when predicted_questionnaire = 'pre' then 2
        when predicted_questionnaire = 'weekly' then 3
        when predicted_questionnaire = 'quarterly' then 5
        when predicted_questionnaire = 'semiannual' then 6
      end as priority_rank,
      0::int as escalation_level,
      case
        when predicted_questionnaire = 'post' then greatest(coalesce(pre_time + v_post_after_pre, now()), now())
        when predicted_questionnaire = 'pre' then (
          (v_target_date::timestamp
            + make_interval(mins => greatest(pre_answer_minute - extract(epoch from v_pre_offset)::int / 60, 8 * 60)))
          at time zone 'America/Sao_Paulo'
        )
        else (v_target_date::timestamp + make_interval(hours => v_standard_hour)) at time zone 'America/Sao_Paulo'
      end as due_at,
      pre_time
    from decision
    where predicted_questionnaire is not null
      and (
        predicted_questionnaire <> 'pre'
        or pre_last_sent_at is null
        or coalesce(pre_last_answer_at, '1900-01-01'::timestamptz) >= pre_last_sent_at
        or pre_last_sent_at < now() - interval '20 hours'
      )
      and (
        predicted_questionnaire <> 'post'
        or pre_last_sent_at is not null
        or pre_time is not null
      )
      and not exists (
        select 1
        from public.minds_notification_log l
        where public.minds_norm_athlete_id(l.athlete_id::text) = decision.athlete_id
          and l.notification_type = decision.predicted_questionnaire
          and l.sent_at >= date_trunc('day', now())
          and (
            decision.predicted_questionnaire <> 'post'
            or l.sent_at >= decision.pre_time
          )
      )
      and not exists (
        select 1
        from public.minds_webhook_queue q
        where public.minds_norm_athlete_id(q.athlete_id::text) = decision.athlete_id
          and q.questionnaire = decision.predicted_questionnaire
          and coalesce(q.sent, false) = false
          and coalesce(q.status, 'pending') in ('pending','queued','retry','processing')
      )
  )
  insert into public.minds_planned_notifications (
    athlete_id, athlete_name, athlete_phone, action_type, priority_rank, escalation_level, due_at, planning_source, status
  )
  select
    athlete_id, athlete_name, athlete_phone, action_type, priority_rank, escalation_level, due_at, 'existing_intervals_v2_post_after_each_pre_norm_id', 'planned'
  from planned
  where due_at >= now() - interval '30 minutes'
  order by priority_rank asc, due_at asc, athlete_name asc
  on conflict do nothing;

  get diagnostics v_count = row_count;

  return jsonb_build_object(
    'ok', true,
    'planned_count', v_count,
    'target_date', v_target_date,
    'rules', jsonb_build_object(
      'post', 'after every latest pre answer; allow more than one post per day if there is a new pre after the previous post',
      'pre', 'weekdays only when not waiting post',
      'weekly', 'weekend and last weekly older than 6 days',
      'quarterly', 'last quarterly older than 90 days',
      'semiannual', 'last semiannual older than 180 days',
      'athlete_id', 'normalized with digits only and lpad to 11 digits when needed'
    ),
    'priorities', jsonb_build_object('post',1,'pre',2,'weekly',3,'quarterly',5,'semiannual',6),
    'pre_offset_minutes', greatest(coalesce(p_pre_offset_minutes, 60), 0),
    'post_after_pre_minutes', greatest(coalesce(p_post_after_pre_minutes, 60), 0),
    'standard_hour', v_standard_hour
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_prepare_questionnaire_dispatch(p_athlete_id text, p_athlete_name text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_questionnaire text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_athlete_id text := nullif(trim(p_athlete_id), '');
  v_name text := coalesce(nullif(trim(p_athlete_name), ''), 'atleta');
  v_phone text := public.normalize_br_phone(p_phone);
  v_questionnaire text := lower(trim(coalesce(p_questionnaire, '')));
  v_state text;
  v_window_open boolean := false;
  v_template text;
  v_link text;
  v_message text;
  v_send_mode text;
begin
  if v_athlete_id is null then
    return jsonb_build_object(
      'should_send', false,
      'send_mode', 'skip',
      'reason', 'missing_athlete_id'
    );
  end if;

  if v_phone is null or v_phone = '' then
    select public.normalize_br_phone(ar.athlete_phone), coalesce(nullif(trim(ar.athlete_name), ''), v_name)
      into v_phone, v_name
    from public.athlete_registration ar
    where ar.athlete_id = v_athlete_id
    order by ar.updated_at desc nulls last, ar.created_at desc nulls last
    limit 1;
  end if;

  if v_phone is null or v_phone = '' then
    return jsonb_build_object(
      'should_send', false,
      'send_mode', 'skip',
      'reason', 'missing_phone',
      'athlete_id', v_athlete_id,
      'athlete_name', v_name,
      'questionnaire', v_questionnaire
    );
  end if;

  if v_questionnaire not in ('pre','post','weekly','quarterly','semiannual') then
    return jsonb_build_object(
      'should_send', false,
      'send_mode', 'skip',
      'reason', 'invalid_or_disabled_questionnaire',
      'athlete_id', v_athlete_id,
      'athlete_name', v_name,
      'phone', v_phone,
      'questionnaire', v_questionnaire
    );
  end if;

  select coalesce(ds.send_state, 'active')
    into v_state
  from public.minds_athlete_delivery_state ds
  where ds.athlete_id = v_athlete_id;

  v_state := coalesce(v_state, 'active');

  if v_state = 'hibernated' then
    return jsonb_build_object(
      'should_send', false,
      'send_mode', 'skip',
      'reason', 'athlete_hibernated',
      'athlete_id', v_athlete_id,
      'athlete_name', v_name,
      'phone', v_phone,
      'questionnaire', v_questionnaire,
      'delivery_state', v_state
    );
  end if;

  v_template := case v_questionnaire
    when 'pre' then 'minds_pre_checkin_v2'
    when 'post' then 'minds_post_checkin_v2'
    when 'weekly' then 'minds_weekly_checkin_v2'
    when 'quarterly' then 'minds_quarterly_checkin_v1'
    when 'semiannual' then 'minds_semiannual_checkin_v1'
  end;

  v_link := case v_questionnaire
    when 'pre' then 'https://forms.gle/DLUhfXp7sUDGUgMh6'
    when 'post' then 'https://forms.gle/3FBsQBKgSSH5RM4K9'
    when 'weekly' then 'https://forms.gle/LwJ5GWRDDKa9R5VdA'
    when 'quarterly' then 'https://forms.gle/Y1CmWSnz58mLJzVd6'
    when 'semiannual' then 'https://forms.gle/Ar36RpjqFRsZpMEJ8'
  end;

  v_message := case v_questionnaire
    when 'pre' then format('Pingo por aqui, %s. Seu registro pre-treino esta liberado. Faca seu Pingo aqui: %s', v_name, v_link)
    when 'post' then format('Pingo passando aqui, %s. Seu registro pos-treino esta disponivel. Faca seu Pingo aqui: %s', v_name, v_link)
    when 'weekly' then format('Pingo por aqui, %s. Seu fechamento semanal esta disponivel. Faca seu Pingo aqui: %s', v_name, v_link)
    when 'quarterly' then format('Pingo passando aqui, %s. Sua revisao trimestral esta disponivel. Faca seu Pingo aqui: %s', v_name, v_link)
    when 'semiannual' then format('Pingo por aqui, %s. Sua revisao semestral esta disponivel. Faca seu Pingo aqui: %s', v_name, v_link)
  end;

  v_window_open := public.minds_window_is_open(v_athlete_id, v_phone);
  v_send_mode := case when v_window_open then 'service' else 'template' end;

  return jsonb_build_object(
    'should_send', true,
    'send_mode', v_send_mode,
    'reason', 'ok',
    'window_open', v_window_open,
    'athlete_id', v_athlete_id,
    'athlete_name', v_name,
    'phone', v_phone,
    'questionnaire', v_questionnaire,
    'template_name', v_template,
    'template_language', 'pt_BR',
    'template_variable_1', v_name,
    'service_message', v_message,
    'link', v_link,
    'delivery_state', v_state
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_queue_reactivation_attempts(p_limit integer DEFAULT 25, p_template_name text DEFAULT 'minds_reactivation_v1'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_count integer := 0;
begin
  insert into public.minds_reactivation_attempts (
    athlete_id,
    athlete_name,
    athlete_phone,
    attempt_type,
    status,
    template_name,
    created_at
  )
  select
    c.athlete_id,
    c.athlete_name,
    c.athlete_phone,
    'reactivation',
    'queued',
    p_template_name,
    now()
  from public.minds_reactivation_candidates(30, 30, p_limit) c;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_reactivate_by_token(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.minds_reactivation_tokens%rowtype;
begin
  select * into v_row
    from public.minds_reactivation_tokens
   where token = p_token
   limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  if v_row.status <> 'active' or v_row.used_at is not null then
    return jsonb_build_object('ok', false, 'error', 'token_already_used_or_inactive', 'athlete_id', v_row.athlete_id);
  end if;

  if v_row.expires_at < now() then
    update public.minds_reactivation_tokens
       set status = 'expired', updated_at = now()
     where id = v_row.id;
    return jsonb_build_object('ok', false, 'error', 'expired_token', 'athlete_id', v_row.athlete_id);
  end if;

  update public.athlete_registration
     set athlete_enabled = true,
         updated_at = now()
   where athlete_id = v_row.athlete_id;

  insert into public.minds_athlete_delivery_state (
    athlete_id,
    send_state,
    auto_hibernated,
    reason,
    reactivated_at,
    updated_at
  ) values (
    v_row.athlete_id,
    'active',
    false,
    'reactivated by token',
    now(),
    now()
  )
  on conflict (athlete_id) do update set
    send_state = 'active',
    auto_hibernated = false,
    reason = 'reactivated by token',
    reactivated_at = now(),
    updated_at = now();

  update public.minds_reactivation_tokens
     set status = 'used', used_at = now(), updated_at = now()
   where id = v_row.id;

  update public.minds_webhook_queue
     set status = 'pending',
         sent = false,
         last_error = null,
         available_at = now(),
         processing_at = null
   where athlete_id = v_row.athlete_id
     and status = 'hibernated';

  update public.minds_planned_notifications
     set status = 'planned', updated_at = now()
   where athlete_id = v_row.athlete_id
     and status in ('hibernated','superseded')
     and due_at >= now() - interval '2 hours';

  return jsonb_build_object('ok', true, 'athlete_id', v_row.athlete_id, 'reactivated_at', now());
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_reactivation_candidates(p_min_hibernated_days integer DEFAULT 30, p_cooldown_days integer DEFAULT 30, p_limit integer DEFAULT 25)
 RETURNS TABLE(athlete_id text, athlete_name text, athlete_phone text, hibernated_at timestamp with time zone, last_attempt_at timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
  select
    a.athlete_id,
    a.athlete_name,
    a.athlete_phone,
    ds.hibernated_at,
    max(ra.created_at) as last_attempt_at
  from public.minds_athlete_delivery_state ds
  join public.athlete_registration a on a.athlete_id = ds.athlete_id
  left join public.minds_reactivation_attempts ra on ra.athlete_id = ds.athlete_id
  where ds.send_state = 'hibernated'
    and ds.auto_hibernated = true
    and ds.hibernated_at <= now() - make_interval(days => greatest(coalesce(p_min_hibernated_days, 30), 1))
    and coalesce(a.athlete_enabled, true) = true
    and a.athlete_phone is not null
  group by a.athlete_id, a.athlete_name, a.athlete_phone, ds.hibernated_at
  having max(ra.created_at) is null
      or max(ra.created_at) <= now() - make_interval(days => greatest(coalesce(p_cooldown_days, 30), 1))
  order by ds.hibernated_at asc
  limit greatest(coalesce(p_limit, 25), 1);
$function$
;

CREATE OR REPLACE FUNCTION public.minds_register_whatsapp_inbound(p_phone text, p_athlete_id text DEFAULT NULL::text)
 RETURNS TABLE(athlete_id text, phone text, window_expires_at timestamp with time zone, reactivated boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_phone text := public.normalize_br_phone(p_phone);
  v_athlete_id text := nullif(trim(p_athlete_id), '');
  v_previous_state text;
begin
  if v_phone is null or v_phone = '' then
    return;
  end if;

  if v_athlete_id is null then
    select ar.athlete_id
      into v_athlete_id
    from public.athlete_registration ar
    where public.normalize_br_phone(ar.athlete_phone) = v_phone
    order by ar.updated_at desc nulls last, ar.created_at desc nulls last
    limit 1;
  end if;

  if v_athlete_id is null then
    return;
  end if;

  select s.send_state
    into v_previous_state
  from public.minds_athlete_delivery_state s
  where s.athlete_id = v_athlete_id;

  insert into public.minds_whatsapp_session (
    athlete_id,
    phone,
    last_user_message_at,
    window_expires_at,
    inbound_count,
    updated_at
  )
  values (
    v_athlete_id,
    v_phone,
    now(),
    now() + interval '24 hours',
    1,
    now()
  )
  on conflict (athlete_id)
  do update set
    phone = excluded.phone,
    last_user_message_at = now(),
    window_expires_at = now() + interval '24 hours',
    inbound_count = public.minds_whatsapp_session.inbound_count + 1,
    updated_at = now();

  perform public.reactivate_minds_athlete(v_athlete_id);

  return query
  select
    v_athlete_id,
    v_phone,
    now() + interval '24 hours',
    coalesce(v_previous_state, 'active') <> 'active';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_requeue_stale_webhook_processing(p_stale_minutes integer DEFAULT 10, p_limit integer DEFAULT 200)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_count integer := 0;
begin
  with stale as (
    select id
    from public.minds_webhook_queue
    where coalesce(sent, false) = false
      and status = 'processing'
      and coalesce(processing_at, created_at) < now() - make_interval(mins => greatest(coalesce(p_stale_minutes, 10), 1))
    order by coalesce(processing_at, created_at) asc
    limit greatest(coalesce(p_limit, 200), 1)
  )
  update public.minds_webhook_queue q
     set status = case
                    when coalesce(q.retry_count, 0) >= coalesce(q.max_retries, 5) then 'failed'
                    else 'retry'
                  end,
         available_at = case
                          when coalesce(q.retry_count, 0) >= coalesce(q.max_retries, 5) then null
                          else now()
                        end,
         processing_at = null,
         last_error = coalesce(nullif(q.last_error, ''), 'requeued stale processing item')
    from stale s
   where q.id = s.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_run_engine_v4()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.minds_save_whatsapp_flow_response(p_phone text, p_athlete_id text DEFAULT NULL::text, p_questionnaire text DEFAULT NULL::text, p_flow_token text DEFAULT NULL::text, p_flow_id text DEFAULT NULL::text, p_message_id text DEFAULT NULL::text, p_response jsonb DEFAULT '{}'::jsonb, p_raw_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_phone text := public.normalize_br_phone(p_phone);
  v_athlete_id text := nullif(trim(coalesce(p_athlete_id, p_response->>'athlete_id')), '');
  v_questionnaire text := lower(nullif(trim(coalesce(p_questionnaire, p_response->>'questionnaire')), ''));
  v_flow_token text := nullif(trim(coalesce(p_flow_token, p_response->>'flow_token')), '');
  v_id bigint;
begin
  if v_phone is null or v_phone = '' then
    return jsonb_build_object(
      'ok', false,
      'reason', 'missing_phone'
    );
  end if;

  if v_athlete_id is null then
    select ar.athlete_id
      into v_athlete_id
    from public.athlete_registration ar
    where public.normalize_br_phone(ar.athlete_phone) = v_phone
    order by ar.updated_at desc nulls last, ar.created_at desc nulls last
    limit 1;
  end if;

  if v_questionnaire is null and v_flow_token is not null then
    if v_flow_token ilike 'pre_%' then
      v_questionnaire := 'pre';
    elsif v_flow_token ilike 'post_%' then
      v_questionnaire := 'post';
    end if;
  end if;

  if v_questionnaire not in ('pre', 'post') then
    return jsonb_build_object(
      'ok', false,
      'reason', 'invalid_questionnaire',
      'phone', v_phone,
      'athlete_id', v_athlete_id,
      'questionnaire', v_questionnaire
    );
  end if;

  -- Abre/renova janela de 24h e reativa atleta, se aplicável.
  perform public.minds_register_whatsapp_inbound(v_phone, v_athlete_id);

  insert into public.minds_whatsapp_flow_responses (
    athlete_id,
    phone,
    questionnaire,
    flow_token,
    flow_id,
    message_id,
    response_json,
    raw_payload,
    received_at
  )
  values (
    v_athlete_id,
    v_phone,
    v_questionnaire,
    v_flow_token,
    nullif(trim(p_flow_id), ''),
    nullif(trim(p_message_id), ''),
    coalesce(p_response, '{}'::jsonb),
    coalesce(p_raw_payload, '{}'::jsonb),
    now()
  )
  returning id into v_id;

  -- Mantém compatibilidade com a tabela de estado do motor, se ela existir/estiver sendo usada.
  insert into public.minds_questionnaire_state (
    athlete_id,
    updated_at
  )
  values (
    v_athlete_id,
    now()
  )
  on conflict (athlete_id)
  do update set
    pre_last_answer_at = case when v_questionnaire = 'pre' then now() else public.minds_questionnaire_state.pre_last_answer_at end,
    post_last_answer_at = case when v_questionnaire = 'post' then now() else public.minds_questionnaire_state.post_last_answer_at end,
    updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'id', v_id,
    'athlete_id', v_athlete_id,
    'phone', v_phone,
    'questionnaire', v_questionnaire,
    'flow_token', v_flow_token
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_self_heal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
declare
  v_reconciled integer := 0;
  v_requeued integer := 0;
  v_fixed_sent integer := 0;
  v_total integer := 0;
  v_got_lock boolean;
begin
  -- lock nao-bloqueante: se outra execucao esta rodando, sai limpo
  v_got_lock := pg_try_advisory_lock(hashtext('minds_self_heal'));
  if not v_got_lock then
    return jsonb_build_object('ok', true, 'skipped', 'already_running', 'ran_at', now());
  end if;

  begin
    v_reconciled := public.reconcile_minds_webhook_responses();
  exception when others then
    insert into public.minds_self_heal_log(action, affected, details)
    values ('reconcile_error', 0, sqlerrm);
  end;
  if v_reconciled > 0 then
    insert into public.minds_self_heal_log(action, affected) values ('reconciled_responses', v_reconciled);
  end if;

  begin
    v_requeued := public.requeue_stale_minds_webhooks();
  exception when others then
    insert into public.minds_self_heal_log(action, affected, details)
    values ('requeue_error', 0, sqlerrm);
  end;
  if v_requeued > 0 then
    insert into public.minds_self_heal_log(action, affected) values ('requeued_stale', v_requeued);
  end if;

  update public.minds_webhook_queue
     set sent = false
   where sent = true
     and status in ('failed','archived_failed','cancelled','pending','hibernated');
  get diagnostics v_fixed_sent = row_count;
  if v_fixed_sent > 0 then
    insert into public.minds_self_heal_log(action, affected) values ('fixed_sent_inconsistency', v_fixed_sent);
  end if;

  v_total := coalesce(v_reconciled,0) + coalesce(v_requeued,0) + coalesce(v_fixed_sent,0);

  perform pg_advisory_unlock(hashtext('minds_self_heal'));

  return jsonb_build_object(
    'ok', true, 'ran_at', now(),
    'reconciled', v_reconciled, 'requeued_stale', v_requeued,
    'fixed_sent_inconsistency', v_fixed_sent, 'total_actions', v_total
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_send_daily_team_adherence_snapshots(p_report_date date DEFAULT ((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date, p_webhook_url text DEFAULT 'https://autowebhook.opingo.com.br/webhook/Adesao_MINDS'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
declare
  v_payloads jsonb;
  v_payload jsonb;
  v_request_id bigint;
  v_sent_count integer := 0;
  v_team_name text;
begin
  v_payloads := public.minds_daily_team_adherence_snapshots(p_report_date);

  for v_payload in select value from jsonb_array_elements(v_payloads)
  loop
    v_team_name := coalesce(v_payload->>'team_name', 'Sem equipe');

    begin
      insert into public.minds_daily_team_adherence_dispatch_log (
        report_date,
        team_name,
        webhook_url,
        payload
      ) values (
        p_report_date,
        v_team_name,
        p_webhook_url,
        v_payload
      )
      on conflict (report_date, team_name, webhook_url) do nothing;

      if found then
        select net.http_post(
          url := p_webhook_url,
          body := v_payload,
          headers := jsonb_build_object('Content-Type', 'application/json'),
          timeout_milliseconds := 25000
        ) into v_request_id;

        update public.minds_daily_team_adherence_dispatch_log
           set request_id = v_request_id
         where report_date = p_report_date
           and team_name = v_team_name
           and webhook_url = p_webhook_url;

        v_sent_count := v_sent_count + 1;
      end if;
    exception when others then
      insert into public.minds_daily_team_adherence_dispatch_log (
        report_date,
        team_name,
        webhook_url,
        payload
      ) values (
        p_report_date,
        v_team_name,
        p_webhook_url,
        v_payload || jsonb_build_object('dispatch_error', sqlerrm)
      )
      on conflict (report_date, team_name, webhook_url) do update
      set payload = excluded.payload;
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'report_date', p_report_date,
    'webhook_url', p_webhook_url,
    'teams_in_snapshot', jsonb_array_length(v_payloads),
    'webhooks_sent_new', v_sent_count,
    'generated_at', now()
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_sync_questionnaire_state_from_answers()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_count integer := 0;
begin
  with latest as (
    select athlete_id,
           max(created_at) filter (where kind = 'pre') as pre_answer_at,
           max(created_at) filter (where kind = 'post') as post_answer_at
    from (
      select athlete_id, 'pre'::text as kind, created_at from public.brums_analysis
      union all
      select athlete_id, 'pre'::text as kind, created_at from public.diet_daily
      union all
      select athlete_id, 'post'::text as kind, created_at from public.training_load_daily
    ) x
    group by athlete_id
  )
  insert into public.minds_questionnaire_state (
    athlete_id,
    pre_last_answer_at,
    post_last_answer_at,
    updated_at
  )
  select athlete_id, pre_answer_at, post_answer_at, now()
  from latest
  on conflict (athlete_id) do update set
    pre_last_answer_at = greatest(
      coalesce(public.minds_questionnaire_state.pre_last_answer_at, '1900-01-01'::timestamptz),
      coalesce(excluded.pre_last_answer_at, '1900-01-01'::timestamptz)
    ),
    post_last_answer_at = greatest(
      coalesce(public.minds_questionnaire_state.post_last_answer_at, '1900-01-01'::timestamptz),
      coalesce(excluded.post_last_answer_at, '1900-01-01'::timestamptz)
    ),
    updated_at = now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_touch_whatsapp_template_config_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.minds_window_is_open(p_athlete_id text, p_phone text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select exists (
    select 1
    from public.minds_whatsapp_session s
    where (
      s.athlete_id = p_athlete_id
      or (
        p_phone is not null
        and public.normalize_br_phone(s.phone) = public.normalize_br_phone(p_phone)
      )
    )
    and s.window_expires_at > now()
  );
$function$
;

CREATE OR REPLACE FUNCTION public.norm_phone(p_phone text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p_phone is null then null
    when nullif(regexp_replace(p_phone, '\D', '', 'g'), '') is null then null
    else '+' || regexp_replace(p_phone, '\D', '', 'g')
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.norm_role(p_role text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.normalize_br_phone(p_phone text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p_phone is null then null
    else regexp_replace(p_phone, '[^0-9]', '', 'g')
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.normalize_phone(raw text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.only_digits(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select nullif(regexp_replace(coalesce(p_text, ''), '\D', '', 'g'), '');
$function$
;

CREATE OR REPLACE FUNCTION public.patch_pingo_chat_context(p_user_id text, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.phone_digits(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
select regexp_replace(p,'[^0-9]','','g');
$function$
;

CREATE OR REPLACE FUNCTION public.pin_user_athlete(p_user_id text, p_athlete_id text, p_pinned boolean DEFAULT true)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  update public.pingo_user_athletes
  set pinned = p_pinned
  where user_id = p_user_id and athlete_id = p_athlete_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.pingo_access_can_see_athlete(p_access jsonb, p_athlete_id text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_level text := coalesce(p_access ->> 'level', 'unknown');
begin
  if v_level = 'master' then
    return true;
  end if;

  if v_level = 'athlete' then
    return coalesce(p_access ->> 'athlete_id', '') = p_athlete_id;
  end if;

  if v_level = 'coach' then
    return coalesce(p_access -> 'accessible_athletes', '[]'::jsonb) ? p_athlete_id;
  end if;

  return false;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_auto_enqueue_processing_job()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  insert into public.pingo_processing_jobs(
    observation_id,
    job_type,
    status,
    queued_at,
    input_snapshot_json
  ) values (
    new.id,
    'pingo_v4_signature_engine',
    'queued',
    now(),
    jsonb_build_object(
      'observation_id', new.id,
      'athlete_id', new.athlete_id,
      'kind', new.kind,
      'reference_date', new.reference_date,
      'source', new.source
    )
  )
  on conflict (observation_id, job_type) do nothing;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_claim_next_processing_job(p_worker_id text DEFAULT NULL::text)
 RETURNS SETOF pingo_processing_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return query
  update public.pingo_processing_jobs j
  set
    status = 'running',
    started_at = now(),
    failed_at = null,
    error_detail = null,
    claimed_by = coalesce(nullif(p_worker_id, ''), 'github_worker'),
    claim_token = gen_random_uuid(),
    attempt_count = coalesce(j.attempt_count, 0) + 1,
    updated_at = now()
  where j.id = (
    select q.id
    from public.pingo_processing_jobs q
    where q.status = 'queued'
      and coalesce(q.attempt_count, 0) < coalesce(q.max_attempts, 3)
    order by q.queued_at asc, q.created_at asc
    for update skip locked
    limit 1
  )
  returning j.*;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_create_master_user(p_master_name text, p_phone text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.pingo_master_users%rowtype;
begin
  if nullif(btrim(p_phone), '') is null then
    raise exception 'phone_required';
  end if;

  if nullif(btrim(p_password), '') is null then
    raise exception 'password_required';
  end if;

  insert into public.pingo_master_users(master_name, phone_raw, password_hash, active)
  values (p_master_name, p_phone, public.pingo_hash_password(p_password), true)
  on conflict (phone_e164)
  do update set
    master_name = excluded.master_name,
    password_hash = excluded.password_hash,
    active = true,
    updated_at = now()
  returning * into v_row;

  return jsonb_build_object(
    'ok', true,
    'master_id', v_row.id,
    'phone_e164', v_row.phone_e164,
    'master_name', v_row.master_name
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_digits_only(p_phone text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_get_setting(p_key text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select value from public.pingo_settings where key = p_key
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_hash_password(p_password text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select crypt(coalesce(p_password, ''), gen_salt('bf', 10));
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_ingest_observation(p_athlete_id text, p_kind text, p_raw_payload jsonb DEFAULT '{}'::jsonb, p_instrument_kind text DEFAULT NULL::text, p_instrument_version text DEFAULT NULL::text, p_reference_date date DEFAULT CURRENT_DATE, p_source text DEFAULT 'pingo_site'::text, p_source_submission_id text DEFAULT NULL::text, p_source_dedup_key text DEFAULT NULL::text, p_observed_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_source_sheet_name text DEFAULT NULL::text, p_source_row_index integer DEFAULT NULL::integer, p_appscript_version text DEFAULT 'pingo_site_secure_runtime_1.0.0'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_obs public.pingo_observations%rowtype;
  v_job public.pingo_processing_jobs%rowtype;
  v_dedup text;
  v_source text := coalesce(nullif(btrim(p_source), ''), 'pingo_site');
  v_payload jsonb := coalesce(p_raw_payload, '{}'::jsonb);
  v_reference_date date := coalesce(p_reference_date, current_date);
  v_submission_id text;
  v_payload_hash text;
begin
  if nullif(btrim(p_athlete_id), '') is null then
    raise exception 'athlete_id_required';
  end if;

  if nullif(btrim(p_kind), '') is null then
    raise exception 'kind_required';
  end if;

  v_submission_id := coalesce(
    nullif(p_source_submission_id, ''),
    nullif(v_payload ->> 'submission_id', ''),
    nullif(v_payload ->> 'SUBMISSION_ID', ''),
    nullif(v_payload ->> 'response_id', ''),
    nullif(v_payload ->> 'RESPONSE_ID', '')
  );

  v_payload_hash := encode(digest(v_payload::text, 'sha256'), 'hex');
  v_dedup := coalesce(
    nullif(p_source_dedup_key, ''),
    concat_ws('|', v_source, p_kind, p_athlete_id, v_reference_date::text, coalesce(v_submission_id, v_payload_hash))
  );

  insert into public.pingo_observations(
    athlete_id,
    kind,
    instrument_kind,
    instrument_version,
    reference_date,
    observed_at,
    submitted_at,
    source,
    source_sheet_name,
    source_row_index,
    source_submission_id,
    source_dedup_key,
    raw_payload,
    data_quality_status,
    processing_status,
    appscript_version
  ) values (
    p_athlete_id,
    p_kind,
    coalesce(nullif(p_instrument_kind, ''), p_kind),
    p_instrument_version,
    v_reference_date,
    coalesce(p_observed_at, now()),
    now(),
    v_source,
    p_source_sheet_name,
    p_source_row_index,
    v_submission_id,
    v_dedup,
    v_payload,
    'unvalidated',
    'received',
    p_appscript_version
  )
  on conflict (source_dedup_key)
  do update set
    raw_payload = excluded.raw_payload,
    observed_at = excluded.observed_at,
    submitted_at = excluded.submitted_at,
    data_quality_status = 'unvalidated',
    processing_status = case
      when public.pingo_observations.processing_status = 'processed' then public.pingo_observations.processing_status
      else 'received'
    end,
    updated_at = now()
  returning * into v_obs;

  insert into public.pingo_processing_jobs(
    observation_id,
    job_type,
    status,
    queued_at,
    input_snapshot_json
  ) values (
    v_obs.id,
    'pingo_v4_signature_engine',
    'queued',
    now(),
    jsonb_build_object(
      'observation_id', v_obs.id,
      'athlete_id', v_obs.athlete_id,
      'kind', v_obs.kind,
      'reference_date', v_obs.reference_date,
      'source', v_obs.source
    )
  )
  on conflict (observation_id, job_type)
  do update set
    status = case
      when public.pingo_processing_jobs.status in ('failed', 'cancelled') then 'queued'
      else public.pingo_processing_jobs.status
    end,
    input_snapshot_json = excluded.input_snapshot_json,
    updated_at = now()
  returning * into v_job;

  return jsonb_build_object(
    'ok', true,
    'observation', to_jsonb(v_obs),
    'job', to_jsonb(v_job)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_mark_authorized_action_failed(p_action_id uuid, p_error_detail text, p_delivery_response jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_action public.pingo_authorized_actions%rowtype;
begin
  update public.pingo_authorized_actions
  set
    status = 'failed',
    failed_at = now(),
    delivery_attempt_count = coalesce(delivery_attempt_count, 0) + 1,
    delivery_response_json = coalesce(p_delivery_response, '{}'::jsonb),
    error_detail = left(coalesce(p_error_detail, 'unknown_error'), 8000),
    updated_at = now()
  where id = p_action_id
  returning * into v_action;

  if v_action.id is null then
    raise exception 'action_not_found';
  end if;

  return jsonb_build_object('ok', true, 'action', to_jsonb(v_action));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_mark_authorized_action_sent(p_action_id uuid, p_delivery_response jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_action public.pingo_authorized_actions%rowtype;
begin
  update public.pingo_authorized_actions
  set
    status = 'sent',
    sent_at = coalesce(sent_at, now()),
    delivery_attempt_count = coalesce(delivery_attempt_count, 0) + 1,
    delivery_response_json = coalesce(p_delivery_response, '{}'::jsonb),
    error_detail = null,
    updated_at = now()
  where id = p_action_id
  returning * into v_action;

  if v_action.id is null then
    raise exception 'action_not_found';
  end if;

  return jsonb_build_object('ok', true, 'action', to_jsonb(v_action));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_mark_job_completed(p_job_id uuid, p_result_json jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_job public.pingo_processing_jobs%rowtype;
begin
  update public.pingo_processing_jobs
  set
    status = 'completed',
    completed_at = now(),
    failed_at = null,
    error_detail = null,
    result_json = coalesce(p_result_json, '{}'::jsonb),
    updated_at = now()
  where id = p_job_id
  returning * into v_job;

  if v_job.id is null then
    raise exception 'job_not_found';
  end if;

  update public.pingo_observations
  set processing_status = 'processed', updated_at = now()
  where id = v_job.observation_id;

  return jsonb_build_object('ok', true, 'job', to_jsonb(v_job));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_mark_job_failed(p_job_id uuid, p_error_detail text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_job public.pingo_processing_jobs%rowtype;
begin
  update public.pingo_processing_jobs
  set
    status = 'failed',
    failed_at = now(),
    error_detail = left(coalesce(p_error_detail, 'unknown_error'), 8000),
    updated_at = now()
  where id = p_job_id
  returning * into v_job;

  if v_job.id is null then
    raise exception 'job_not_found';
  end if;

  update public.pingo_observations
  set processing_status = 'failed', updated_at = now()
  where id = v_job.observation_id;

  return jsonb_build_object('ok', true, 'job', to_jsonb(v_job));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_normalize_br_phone(p_phone text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  d text;
begin
  d := ltrim(public.pingo_digits_only(p_phone), '0');

  if d = '' then
    return null;
  end if;

  -- Brasil com DDI, celular/fixo: +55 + DDD + numero
  if left(d, 2) = '55' and length(d) in (12, 13) then
    return '+' || d;
  end if;

  -- Brasil sem DDI: DDD + numero
  if length(d) in (10, 11) then
    return '+55' || d;
  end if;

  -- Telefone internacional ja com DDI, sem +
  if length(d) >= 12 then
    return '+' || d;
  end if;

  return d;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_password_matches(p_password text, p_hash text, p_phone_raw text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  pass text := coalesce(p_password, '');
  stored text := coalesce(p_hash, '');
begin
  if btrim(pass) = '' then
    return false;
  end if;

  -- Hash seguro via pgcrypto/crypt: $2a$, $2b$, $2y$, $1$, etc.
  if stored ~ '^\$[0-9a-zA-Z]+\$' then
    return crypt(pass, stored) = stored;
  end if;

  -- Compatibilidade legada: senha em texto puro ou senha = telefone.
  -- Use apenas durante transicao. Novos usuarios devem usar pingo_hash_password().
  if stored <> '' and stored = pass then
    return true;
  end if;

  if public.pingo_digits_only(stored) <> ''
     and public.pingo_digits_only(stored) = public.pingo_digits_only(pass) then
    return true;
  end if;

  if p_phone_raw is not null
     and public.pingo_digits_only(p_phone_raw) <> ''
     and public.pingo_digits_only(p_phone_raw) = public.pingo_digits_only(pass) then
    return true;
  end if;

  return false;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_phone_match_score(p_input text, p_stored text)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  a text := public.pingo_digits_only(p_input);
  b text := public.pingo_digits_only(p_stored);
  ea text := public.pingo_normalize_br_phone(p_input);
  eb text := public.pingo_normalize_br_phone(p_stored);
begin
  if a = '' or b = '' then
    return 0;
  end if;

  if ea is not null and eb is not null and ea = eb then
    return 1.00;
  end if;

  if a = b then
    return 0.98;
  end if;

  if length(a) >= 11 and length(b) >= 11 and right(a, 11) = right(b, 11) then
    return 0.95;
  end if;

  if length(a) >= 10 and length(b) >= 10 and right(a, 10) = right(b, 10) then
    return 0.88;
  end if;

  if length(a) >= 9 and length(b) >= 9 and right(a, 9) = right(b, 9) then
    return 0.72;
  end if;

  return 0;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_prepare_observation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  submission_id text;
  payload_hash text;
begin
  if new.reference_date is null then
    new.reference_date := current_date;
  end if;

  if new.submitted_at is null then
    new.submitted_at := now();
  end if;

  if new.observed_at is null then
    new.observed_at := new.submitted_at;
  end if;

  if new.source is null or btrim(new.source) = '' then
    new.source := 'pingo_site';
  end if;

  if new.instrument_kind is null or btrim(new.instrument_kind) = '' then
    new.instrument_kind := new.kind;
  end if;

  if new.raw_payload is null then
    new.raw_payload := '{}'::jsonb;
  end if;

  submission_id := coalesce(
    nullif(new.source_submission_id, ''),
    nullif(new.raw_payload ->> 'submission_id', ''),
    nullif(new.raw_payload ->> 'SUBMISSION_ID', ''),
    nullif(new.raw_payload ->> 'response_id', ''),
    nullif(new.raw_payload ->> 'RESPONSE_ID', '')
  );

  if new.source_submission_id is null and submission_id is not null then
    new.source_submission_id := submission_id;
  end if;

  if new.source_dedup_key is null or btrim(new.source_dedup_key) = '' then
    payload_hash := encode(digest(coalesce(new.raw_payload::text, '{}'), 'sha256'), 'hex');
    new.source_dedup_key := concat_ws('|',
      new.source,
      new.kind,
      new.athlete_id,
      new.reference_date::text,
      coalesce(submission_id, payload_hash)
    );
  end if;

  new.updated_at := now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_requeue_stale_jobs(p_minutes integer DEFAULT 30)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_count integer;
begin
  update public.pingo_processing_jobs
  set
    status = 'queued',
    started_at = null,
    claimed_by = null,
    claim_token = null,
    error_detail = coalesce(error_detail, 'requeued_after_stale_running_state'),
    updated_at = now()
  where status = 'running'
    and started_at < now() - make_interval(mins => greatest(coalesce(p_minutes, 30), 1));

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_resolve_access(p_phone text, p_password text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_master record;
  v_coach record;
  v_athlete record;
  v_athletes jsonb;
  v_teams jsonb;
begin
  -- MASTER: exige senha.
  select m.*, public.pingo_phone_match_score(p_phone, m.phone_raw) as score
  into v_master
  from public.pingo_master_users m
  where m.active = true
    and public.pingo_phone_match_score(p_phone, m.phone_raw) >= 0.95
  order by public.pingo_phone_match_score(p_phone, m.phone_raw) desc, m.created_at desc
  limit 1;

  if v_master.id is not null
     and public.pingo_password_matches(p_password, v_master.password_hash, v_master.phone_raw) then
    return jsonb_build_object(
      'level', 'master',
      'match_confidence', v_master.score,
      'master_id', v_master.id,
      'master_name', v_master.master_name,
      'accessible_athletes', 'all',
      'accessible_coaches', 'all',
      'source', 'pingo_master_users'
    );
  end if;

  -- COACH: exige senha. Compatibilidade legada permite senha igual ao telefone.
  select c.*, public.pingo_phone_match_score(p_phone, c.phone_raw) as score
  into v_coach
  from public.pingo_access_coaches c
  where c.active = true
    and public.pingo_phone_match_score(p_phone, c.phone_raw) >= 0.85
  order by public.pingo_phone_match_score(p_phone, c.phone_raw) desc, c.created_at desc
  limit 1;

  if v_coach.coach_id is not null
     and public.pingo_password_matches(p_password, v_coach.password_hash, v_coach.phone_raw) then
    select coalesce(jsonb_agg(distinct l.athlete_id), '[]'::jsonb)
    into v_athletes
    from public.pingo_coach_athlete_links l
    where l.coach_id = v_coach.coach_id
      and l.active = true;

    select coalesce(jsonb_agg(distinct x.team_name), '[]'::jsonb)
    into v_teams
    from (
      select nullif(v_coach.team_name, '') as team_name
      union
      select nullif(l.team_name, '') as team_name
      from public.pingo_coach_athlete_links l
      where l.coach_id = v_coach.coach_id
        and l.active = true
    ) x
    where x.team_name is not null;

    return jsonb_build_object(
      'level', 'coach',
      'match_confidence', v_coach.score,
      'coach_id', v_coach.coach_id,
      'coach_name', v_coach.coach_name,
      'team_name', v_coach.team_name,
      'teams', v_teams,
      'accessible_athletes', v_athletes,
      'source', 'pingo_access_coaches'
    );
  end if;

  -- ATHLETE: telefone basta se nao houver password_hash; se houver, senha passa a ser exigida.
  select a.*, public.pingo_phone_match_score(p_phone, a.phone_raw) as score
  into v_athlete
  from public.pingo_access_athletes a
  where a.active = true
    and public.pingo_phone_match_score(p_phone, a.phone_raw) >= 0.72
  order by public.pingo_phone_match_score(p_phone, a.phone_raw) desc, a.created_at desc
  limit 1;

  if v_athlete.athlete_id is not null
     and (
       coalesce(v_athlete.password_hash, '') = ''
       or public.pingo_password_matches(p_password, v_athlete.password_hash, v_athlete.phone_raw)
     ) then
    return jsonb_build_object(
      'level', 'athlete',
      'match_confidence', v_athlete.score,
      'athlete_id', v_athlete.athlete_id,
      'athlete_name', v_athlete.athlete_name,
      'team_name', v_athlete.team_name,
      'accessible_athletes', jsonb_build_array(v_athlete.athlete_id),
      'source', 'pingo_access_athletes'
    );
  end if;

  return jsonb_build_object(
    'level', 'unknown',
    'match_confidence', 0,
    'accessible_athletes', '[]'::jsonb
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_resolve_access_by_phone(p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  m record;
  c record;
  a record;
  athlete_list jsonb;
begin
  -- MASTER
  select
    *,
    public.pingo_phone_match_score(p_phone, phone_raw) as score
  into m
  from public.pingo_master_users
  where active
  order by public.pingo_phone_match_score(p_phone, phone_raw) desc
  limit 1;

  if m.id is not null and m.score >= 0.95 then
    return jsonb_build_object(
      'level', 'master',
      'match_confidence', m.score,
      'master_id', m.id,
      'master_name', m.master_name,
      'accessible_athletes', 'all',
      'accessible_coaches', 'all'
    );
  end if;

  -- TREINADOR
  select
    *,
    public.pingo_phone_match_score(p_phone, phone_raw) as score
  into c
  from public.pingo_access_coaches
  where active
  order by public.pingo_phone_match_score(p_phone, phone_raw) desc
  limit 1;

  if c.coach_id is not null and c.score >= 0.85 then
    select coalesce(jsonb_agg(athlete_id), '[]'::jsonb)
    into athlete_list
    from public.pingo_coach_athlete_links
    where coach_id = c.coach_id
      and active;

    return jsonb_build_object(
      'level', 'coach',
      'match_confidence', c.score,
      'coach_id', c.coach_id,
      'coach_name', c.coach_name,
      'accessible_athletes', athlete_list
    );
  end if;

  -- ATLETA
  select
    *,
    public.pingo_phone_match_score(p_phone, phone_raw) as score
  into a
  from public.pingo_access_athletes
  where active
  order by public.pingo_phone_match_score(p_phone, phone_raw) desc
  limit 1;

  if a.athlete_id is not null and a.score >= 0.72 then
    return jsonb_build_object(
      'level', 'athlete',
      'match_confidence', a.score,
      'athlete_id', a.athlete_id,
      'athlete_name', a.athlete_name,
      'accessible_athletes', jsonb_build_array(a.athlete_id)
    );
  end if;

  return jsonb_build_object(
    'level', 'unknown',
    'match_confidence', 0,
    'accessible_athletes', '[]'::jsonb
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at := now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_sync_access_from_athlete_registration()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_coach_id uuid;
  v_athletes integer := 0;
  v_coaches integer := 0;
  v_links integer := 0;
begin
  -- Atletas
  for r in
    select distinct on (athlete_id)
      athlete_id::text as athlete_id,
      athlete_name,
      athlete_phone,
      nullif(team_name, '') as team_name,
      coalesce(athlete_enabled, true) as athlete_enabled
    from public.athlete_registration
    where athlete_id is not null
      and athlete_id::text <> ''
      and athlete_phone is not null
      and public.pingo_digits_only(athlete_phone) <> ''
    order by athlete_id, inserted_at desc nulls last, created_at desc nulls last
  loop
    insert into public.pingo_access_athletes(
      athlete_id,
      athlete_name,
      phone_raw,
      team_name,
      active,
      source
    ) values (
      r.athlete_id,
      r.athlete_name,
      r.athlete_phone,
      r.team_name,
      r.athlete_enabled,
      'athlete_registration'
    )
    on conflict (athlete_id) do update set
      athlete_name = excluded.athlete_name,
      phone_raw = excluded.phone_raw,
      team_name = excluded.team_name,
      active = excluded.active,
      source = excluded.source,
      updated_at = now();

    v_athletes := v_athletes + 1;
  end loop;

  -- Treinadores e links
  for r in
    select
      nullif(coach_name, '') as coach_name,
      coach_phone,
      nullif(team_name, '') as team_name,
      athlete_id::text as athlete_id
    from public.athlete_registration
    where athlete_id is not null
      and athlete_id::text <> ''
      and coach_phone is not null
      and public.pingo_digits_only(coach_phone) <> ''
  loop
    select c.coach_id
    into v_coach_id
    from public.pingo_access_coaches c
    where c.phone_e164 = public.pingo_normalize_br_phone(r.coach_phone)
      and coalesce(c.team_name, '') = coalesce(r.team_name, '')
    limit 1;

    if v_coach_id is null then
      insert into public.pingo_access_coaches(
        coach_name,
        phone_raw,
        team_name,
        password_hash,
        active,
        source
      ) values (
        r.coach_name,
        r.coach_phone,
        r.team_name,
        public.pingo_digits_only(r.coach_phone), -- compatibilidade legada: senha = telefone. Troque depois.
        true,
        'athlete_registration'
      )
      returning coach_id into v_coach_id;
      v_coaches := v_coaches + 1;
    end if;

    insert into public.pingo_coach_athlete_links(coach_id, athlete_id, team_name, active)
    values (v_coach_id, r.athlete_id, r.team_name, true)
    on conflict (coach_id, athlete_id) do update set
      team_name = excluded.team_name,
      active = true,
      updated_at = now();

    v_links := v_links + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'athletes_upserted', v_athletes,
    'coaches_created', v_coaches,
    'links_upserted', v_links
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_v4_athlete_counts(p_athlete_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
with
brums_dates as (
  select data::date as d
  from public.brums_analysis
  where athlete_id::text = p_athlete_id

  union

  select reference_date::date as d
  from public.pingo_observations
  where athlete_id::text = p_athlete_id
    and kind = 'daily_pre'
    and reference_date is not null
),
restq_dates as (
  select data::date as d
  from public.restq_analysis
  where athlete_id::text = p_athlete_id

  union

  select reference_date::date as d
  from public.pingo_observations
  where athlete_id::text = p_athlete_id
    and kind = 'weekly'
    and reference_date is not null
),
acsi_dates as (
  select data::date as d
  from public.acsi_analysis
  where athlete_id::text = p_athlete_id

  union

  select reference_date::date as d
  from public.pingo_observations
  where athlete_id::text = p_athlete_id
    and kind = 'quarterly'
    and reference_date is not null
),
gses_dates as (
  select data::date as d
  from public.gses_analysis
  where athlete_id::text = p_athlete_id

  union

  select reference_date::date as d
  from public.pingo_observations
  where athlete_id::text = p_athlete_id
    and kind = 'quarterly'
    and reference_date is not null
),
pmcsq_dates as (
  select data::date as d
  from public.pmcsq_analysis
  where athlete_id::text = p_athlete_id

  union

  select reference_date::date as d
  from public.pingo_observations
  where athlete_id::text = p_athlete_id
    and kind = 'quarterly'
    and reference_date is not null
),
cbas_dates as (
  select data::date as d
  from public.cbas_analysis
  where athlete_id::text = p_athlete_id

  union

  select reference_date::date as d
  from public.pingo_observations
  where athlete_id::text = p_athlete_id
    and kind = 'semiannual'
    and reference_date is not null
),
construcional_dates as (
  select submitted_at::date as d
  from public.construcional_raw
  where athlete_id::text = p_athlete_id

  union

  select reference_date::date as d
  from public.pingo_observations
  where athlete_id::text = p_athlete_id
    and kind = 'construcional'
    and reference_date is not null
),
training_dates as (
  select data::date as d
  from public.training_load_daily
  where athlete_id::text = p_athlete_id

  union

  select reference_date::date as d
  from public.pingo_observations
  where athlete_id::text = p_athlete_id
    and kind = 'daily_post'
    and reference_date is not null
)
select jsonb_build_object(
  'brums', (select count(*) from brums_dates),
  'restq', (select count(*) from restq_dates),
  'acsi', (select count(*) from acsi_dates),
  'gses', (select count(*) from gses_dates),
  'pmcsq', (select count(*) from pmcsq_dates),
  'cbas', (select count(*) from cbas_dates),
  'construcional', (select count(*) from construcional_dates),
  'training_load', (select count(*) from training_dates)
);
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_v4_evidence_from_counts(p_counts jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  brums_count int := coalesce((p_counts ->> 'brums')::int, 0);
  restq_count int := coalesce((p_counts ->> 'restq')::int, 0);
  acsi_count int := coalesce((p_counts ->> 'acsi')::int, 0);
  gses_count int := coalesce((p_counts ->> 'gses')::int, 0);
  pmcsq_count int := coalesce((p_counts ->> 'pmcsq')::int, 0);
  cbas_count int := coalesce((p_counts ->> 'cbas')::int, 0);
  construcional_count int := coalesce((p_counts ->> 'construcional')::int, 0);

  has_trace_t1 boolean := false;
  has_context_t1 boolean := false;

  level text;
  label text;
  subtype text;
  confidence_cap numeric;
begin
  has_trace_t1 := acsi_count >= 1 and gses_count >= 1 and pmcsq_count >= 1;
  has_context_t1 := pmcsq_count >= 1 or cbas_count >= 1 or construcional_count >= 1;

  if brums_count >= 20 then
    level := 'E3';
    label := 'sinal_operacional_idiografico';

    if restq_count >= 4 and has_trace_t1 then
      subtype := 'E3_full';
    else
      subtype := 'E3_lite';
    end if;

  elsif brums_count >= 10 then
    level := 'E2';
    label := 'tendencia_provisoria';
    subtype := 'E2_brums_10_19';

  elsif brums_count >= 5 and restq_count >= 2 then
    level := 'E2';
    label := 'tendencia_provisoria';
    subtype := 'E2_brums_restq';

  elsif brums_count >= 5 then
    level := 'E1';
    label := 'hipotese_funcional_inicial';
    subtype := 'E1_brums_inicial';

  elsif has_trace_t1 then
    level := 'E1';
    label := 'mapa_inicial_de_hipoteses_funcionais';
    subtype := 'E1_trace_t1';

  elsif has_context_t1 then
    level := 'E1';
    label := 'hipotese_contextual_inicial';
    subtype := 'E1_contextual';

  else
    level := 'E0';
    label := 'dado_insuficiente';
    subtype := 'E0_minimo_nao_atingido';
  end if;

  confidence_cap := case level
    when 'E0' then 0.10
    when 'E1' then 0.35
    when 'E2' then 0.60
    when 'E3' then 0.80
    when 'E4' then 0.95
    else 0.10
  end;

  return jsonb_build_object(
    'evidence_level', level,
    'evidence_label', label,
    'evidence_subtype', subtype,
    'confidence_cap', confidence_cap,
    'counts', p_counts,
    'permissions', jsonb_build_object(
      'can_generate_hypothesis', level in ('E1', 'E2', 'E3', 'E4'),
      'can_generate_trend', level in ('E2', 'E3', 'E4'),
      'can_generate_semaphore', level in ('E3', 'E4'),
      'can_claim_predictive_validity', level = 'E4',
      'human_review_required', true
    )
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_v4_json_num(p_payload jsonb, p_key text)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v text;
begin
  if p_payload is null then
    return null;
  end if;

  v := p_payload ->> p_key;

  if v is null or btrim(v) = '' then
    return null;
  end if;

  return replace(v, ',', '.')::numeric;

exception when others then
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_v4_process_next_job()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_job record;
  v_obs record;

  v_score_json jsonb := '{}'::jsonb;
  v_features_json jsonb := '{}'::jsonb;
  v_counts jsonb := '{}'::jsonb;
  v_evidence jsonb := '{}'::jsonb;

  v_evidence_level text;
  v_evidence_label text;
  v_evidence_subtype text;

  v_allowed_output_type text;
  v_can_report boolean := false;
  v_can_semaphore boolean := false;

  v_score_id uuid;
  v_feature_id uuid;
  v_evidence_id uuid;
  v_output_id uuid;

  v_action_type text;
  v_priority text;
begin
  select *
  into v_job
  from public.pingo_processing_jobs
  where status = 'queued'
  order by queued_at asc
  limit 1
  for update skip locked;

  if not found then
    return jsonb_build_object(
      'ok', true,
      'processed', false,
      'reason', 'no_queued_jobs'
    );
  end if;

  update public.pingo_processing_jobs
  set
    status = 'running',
    started_at = now(),
    updated_at = now()
  where id = v_job.id;

  select *
  into v_obs
  from public.pingo_observations
  where id = v_job.observation_id;

  if not found then
    update public.pingo_processing_jobs
    set
      status = 'failed',
      failed_at = now(),
      error_detail = 'observation_not_found',
      updated_at = now()
    where id = v_job.id;

    return jsonb_build_object(
      'ok', false,
      'processed', false,
      'job_id', v_job.id,
      'error', 'observation_not_found'
    );
  end if;

  -- Score por instrumento
  if v_obs.kind = 'daily_pre' or v_obs.instrument_kind = 'brums' then
    v_score_json := public.pingo_v4_score_brums(v_obs.raw_payload);
  else
    v_score_json := jsonb_build_object(
      'instrument', coalesce(v_obs.instrument_version, v_obs.instrument_kind, v_obs.kind),
      'status', 'raw_observation_captured',
      'note', 'processor_minimo_ainda_nao_calcula_este_instrumento'
    );
  end if;

  insert into public.pingo_instrument_scores_v1 (
    observation_id,
    athlete_id,
    reference_date,
    kind,
    instrument_kind,
    instrument_version,
    scoring_version,
    score_json,
    score_status,
    warnings
  )
  values (
    v_obs.id,
    v_obs.athlete_id,
    v_obs.reference_date,
    v_obs.kind,
    coalesce(v_obs.instrument_kind, 'unknown'),
    v_obs.instrument_version,
    'pingo_v4_processor_sql_0.1.0',
    v_score_json,
    case
      when v_score_json ? 'dth' then 'computed'
      else 'partial'
    end,
    '[]'::jsonb
  )
  returning id into v_score_id;

  -- Features iniciais, principalmente BRUMS
  v_features_json := jsonb_build_object(
    'brums_tension_high',
      case
        when v_score_json ->> 'tension' is not null then least(greatest(((v_score_json ->> 'tension')::numeric / 16.0), 0), 1)
        else null
      end,
    'brums_vigor_preserved',
      case
        when v_score_json ->> 'vigor' is not null then least(greatest(((v_score_json ->> 'vigor')::numeric / 16.0), 0), 1)
        else null
      end,
    'brums_fatigue_high',
      case
        when v_score_json ->> 'fatigue' is not null then least(greatest(((v_score_json ->> 'fatigue')::numeric / 16.0), 0), 1)
        else null
      end,
    'brums_dth_high',
      case
        when v_score_json ->> 'dth' is not null then least(greatest(((v_score_json ->> 'dth')::numeric / 80.0), 0), 1)
        else null
      end
  );

  insert into public.pingo_features_v1 (
    observation_id,
    job_id,
    athlete_id,
    reference_date,
    feature_version,
    features_json,
    feature_quality,
    missing_inputs,
    warnings
  )
  values (
    v_obs.id,
    v_job.id,
    v_obs.athlete_id,
    v_obs.reference_date,
    'pingo_features_sql_0.1.0',
    v_features_json,
    case
      when v_obs.kind = 'daily_pre' then 'partial'
      else 'insufficient'
    end,
    '[]'::jsonb,
    '[]'::jsonb
  )
  returning id into v_feature_id;

  -- Evidence gate
  v_counts := public.pingo_v4_athlete_counts(v_obs.athlete_id);
  v_evidence := public.pingo_v4_evidence_from_counts(v_counts);

  v_evidence_level := v_evidence ->> 'evidence_level';
  v_evidence_label := v_evidence ->> 'evidence_label';
  v_evidence_subtype := v_evidence ->> 'evidence_subtype';

  insert into public.pingo_evidence_state_v1 (
    observation_id,
    job_id,
    athlete_id,
    reference_date,
    evidence_version,
    evidence_level,
    evidence_label,
    brums_count,
    restq_count,
    acsi_count,
    gses_count,
    pmcsq_count,
    cbas_count,
    can_generate_hypothesis,
    can_generate_trend,
    can_generate_semaphore,
    can_claim_predictive_validity,
    human_review_required,
    maturity_json,
    limitations_json
  )
  values (
    v_obs.id,
    v_job.id,
    v_obs.athlete_id,
    v_obs.reference_date,
    'pingo_evidence_sql_0.1.0',
    v_evidence_level,
    v_evidence_label,
    coalesce((v_counts ->> 'brums')::int, 0),
    coalesce((v_counts ->> 'restq')::int, 0),
    coalesce((v_counts ->> 'acsi')::int, 0),
    coalesce((v_counts ->> 'gses')::int, 0),
    coalesce((v_counts ->> 'pmcsq')::int, 0),
    coalesce((v_counts ->> 'cbas')::int, 0),
    coalesce(((v_evidence -> 'permissions') ->> 'can_generate_hypothesis')::boolean, false),
    coalesce(((v_evidence -> 'permissions') ->> 'can_generate_trend')::boolean, false),
    coalesce(((v_evidence -> 'permissions') ->> 'can_generate_semaphore')::boolean, false),
    false,
    true,
    v_evidence,
    '[]'::jsonb
  )
  returning id into v_evidence_id;

  -- Assinatura mínima
  if v_evidence_level = 'E0' then
    insert into public.pingo_signature_scores_v1 (
      observation_id,
      job_id,
      athlete_id,
      reference_date,
      signature_version,
      signature_key,
      signature_label,
      signature_score,
      confidence_score,
      evidence_level,
      supporting_features,
      contradicting_features,
      interpretation_status,
      human_review_required
    )
    values (
      v_obs.id,
      v_job.id,
      v_obs.athlete_id,
      v_obs.reference_date,
      'pingo_signatures_sql_0.1.0',
      'insuficiente_para_assinatura',
      'Dado insuficiente para assinatura funcional',
      null,
      0.0,
      v_evidence_level,
      '[]'::jsonb,
      '[]'::jsonb,
      'not_allowed',
      true
    );
  else
    insert into public.pingo_signature_scores_v1 (
      observation_id,
      job_id,
      athlete_id,
      reference_date,
      signature_version,
      signature_key,
      signature_label,
      signature_score,
      confidence_score,
      evidence_level,
      supporting_features,
      contradicting_features,
      interpretation_status,
      human_review_required
    )
    values (
      v_obs.id,
      v_job.id,
      v_obs.athlete_id,
      v_obs.reference_date,
      'pingo_signatures_sql_0.1.0',
      'hipotese_inicial_indeterminada',
      'Hipótese inicial indeterminada',
      null,
      case
        when v_evidence_level = 'E1' then 0.20
        when v_evidence_level = 'E2' then 0.40
        when v_evidence_level = 'E3' then 0.60
        else 0.10
      end,
      v_evidence_level,
      '[]'::jsonb,
      '[]'::jsonb,
      case
        when v_evidence_level = 'E3' then 'operational'
        else 'provisional'
      end,
      true
    );
  end if;

  -- Output policy
  v_allowed_output_type := case v_evidence_level
    when 'E0' then 'data_insufficient'
    when 'E1' then 'initial_hypothesis'
    when 'E2' then 'provisional_trend'
    when 'E3' then 'operational_signal'
    when 'E4' then 'validated_criterion_future'
    else 'data_insufficient'
  end;

  v_can_report := v_evidence_level in ('E1', 'E2', 'E3', 'E4');
  v_can_semaphore := v_evidence_level in ('E3', 'E4');

  insert into public.pingo_output_decisions_v1 (
    observation_id,
    job_id,
    athlete_id,
    reference_date,
    output_policy_version,
    evidence_level,
    allowed_output_type,
    can_send_whatsapp,
    can_notify_team,
    can_generate_report,
    can_generate_semaphore,
    prohibited_language,
    allowed_language,
    decision_json,
    human_review_required
  )
  values (
    v_obs.id,
    v_job.id,
    v_obs.athlete_id,
    v_obs.reference_date,
    'pingo_output_policy_sql_0.1.0',
    v_evidence_level,
    v_allowed_output_type,
    false,
    v_evidence_level in ('E2', 'E3', 'E4'),
    v_can_report,
    v_can_semaphore,
    '[
      "diagnostico",
      "predicao_validada",
      "classificacao_fixa_de_atleta",
      "reducao_de_carga_automatica",
      "risco_clinico_automatico"
    ]'::jsonb,
    jsonb_build_array(
      v_evidence_label,
      'apoio_a_decisao_humana',
      'sem_validade_diagnostica',
      'sem_validade_preditiva_no_estado_atual'
    ),
    jsonb_build_object(
      'evidence_subtype', v_evidence_subtype,
      'counts', v_counts
    ),
    true
  )
  returning id into v_output_id;

  -- Authorized action
  if v_evidence_level = 'E0' then
    v_action_type := 'ask_missing_data';
    v_priority := 'normal';
  elsif v_evidence_level = 'E3' then
    v_action_type := 'notify_human_review';
    v_priority := 'high';
  else
    v_action_type := 'notify_human_review';
    v_priority := 'normal';
  end if;

  insert into public.pingo_authorized_actions (
    observation_id,
    job_id,
    output_decision_id,
    athlete_id,
    reference_date,
    action_type,
    channel,
    priority,
    requires_human_approval,
    action_payload,
    status
  )
  values (
    v_obs.id,
    v_job.id,
    v_output_id,
    v_obs.athlete_id,
    v_obs.reference_date,
    v_action_type,
    'dashboard',
    v_priority,
    v_evidence_level <> 'E0',
    jsonb_build_object(
      'reason', v_evidence_label,
      'evidence_level', v_evidence_level,
      'evidence_subtype', v_evidence_subtype
    ),
    'pending'
  );

  update public.pingo_observations
  set
    processing_status = 'processed',
    updated_at = now()
  where id = v_obs.id;

  update public.pingo_processing_jobs
  set
    status = 'completed',
    completed_at = now(),
    result_json = jsonb_build_object(
      'score_id', v_score_id,
      'feature_id', v_feature_id,
      'evidence_id', v_evidence_id,
      'output_decision_id', v_output_id,
      'evidence', v_evidence
    ),
    updated_at = now()
  where id = v_job.id;

  return jsonb_build_object(
    'ok', true,
    'processed', true,
    'job_id', v_job.id,
    'observation_id', v_obs.id,
    'athlete_id', v_obs.athlete_id,
    'kind', v_obs.kind,
    'evidence_level', v_evidence_level,
    'evidence_subtype', v_evidence_subtype,
    'allowed_output_type', v_allowed_output_type
  );

exception when others then
  update public.pingo_processing_jobs
  set
    status = 'failed',
    failed_at = now(),
    error_detail = sqlerrm,
    updated_at = now()
  where id = v_job.id;

  return jsonb_build_object(
    'ok', false,
    'processed', false,
    'job_id', v_job.id,
    'error', sqlerrm
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_v4_queue_observation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.pingo_processing_jobs (
    observation_id,
    job_type,
    status,
    input_snapshot_json
  )
  values (
    new.id,
    'pingo_v4_signature_engine',
    'queued',
    jsonb_build_object(
      'observation_id', new.id,
      'athlete_id', new.athlete_id,
      'kind', new.kind,
      'instrument_kind', new.instrument_kind,
      'reference_date', new.reference_date,
      'source', new.source
    )
  )
  on conflict (observation_id, job_type) do nothing;

  update public.pingo_observations
  set processing_status = 'queued'
  where id = new.id
    and processing_status = 'received';

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_v4_score_brums(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
with vals as (
  select
    i,
    public.pingo_v4_json_num(
      p_payload,
      'BRUMS_Q' || lpad(i::text, 2, '0')
    ) as val
  from generate_series(1, 24) as i
),
scales as (
  select
    case when count(val) filter (where i between 1 and 4) = 4
      then sum(val) filter (where i between 1 and 4)
      else null end as tension,

    case when count(val) filter (where i between 5 and 8) = 4
      then sum(val) filter (where i between 5 and 8)
      else null end as depression,

    case when count(val) filter (where i between 9 and 12) = 4
      then sum(val) filter (where i between 9 and 12)
      else null end as anger,

    case when count(val) filter (where i between 13 and 16) = 4
      then sum(val) filter (where i between 13 and 16)
      else null end as vigor,

    case when count(val) filter (where i between 17 and 20) = 4
      then sum(val) filter (where i between 17 and 20)
      else null end as fatigue,

    case when count(val) filter (where i between 21 and 24) = 4
      then sum(val) filter (where i between 21 and 24)
      else null end as confusion,

    count(val) as answered_items
  from vals
),
final as (
  select
    *,
    case
      when tension is not null
       and depression is not null
       and anger is not null
       and fatigue is not null
       and confusion is not null
      then tension + depression + anger + fatigue + confusion
      else null
    end as dth
  from scales
)
select jsonb_build_object(
  'instrument', 'BRUMS_24_LOCAL_V1',
  'answered_items', answered_items,
  'tension', tension,
  'depression', depression,
  'anger', anger,
  'vigor', vigor,
  'fatigue', fatigue,
  'confusion', confusion,
  'dth', dth,
  'dth_minus',
    case
      when dth is not null and vigor is not null then dth - vigor
      else null
    end
)
from final;
$function$
;

CREATE OR REPLACE FUNCTION public.pingo_v4_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reactivate_athlete(p_athlete_id text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.reactivate_minds_athlete(p_athlete_id text, p_reason text DEFAULT 'reactivated by inbound whatsapp message'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
begin
  if nullif(trim(p_athlete_id), '') is null then
    return;
  end if;

  insert into public.minds_athlete_delivery_state (
    athlete_id,
    send_state,
    auto_hibernated,
    reason,
    reactivated_at,
    updated_at
  )
  values (
    p_athlete_id,
    'active',
    false,
    p_reason,
    now(),
    now()
  )
  on conflict (athlete_id)
  do update set
    send_state = 'active',
    auto_hibernated = false,
    reason = excluded.reason,
    reactivated_at = now(),
    updated_at = now();
end;
$function$
;

CREATE OR REPLACE FUNCTION public.rebuild_auth_credentials(p_reset_password boolean DEFAULT true)
 RETURNS TABLE(phones_processed integer, credentials_created integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.recalc_user_account_active(p_user_id text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.reconcile_minds_webhook_responses()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.reconcile_pingo_reactivation_responses()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare
  v_count integer := 0;
begin
  update public.minds_reactivation_attempts a
  set webhook_status_code = r.status_code,
      webhook_response = jsonb_build_object(
        'status_code', r.status_code,
        'content', left(coalesce(r.content, ''), 2000)
      ),
      status = case
                 when r.status_code between 200 and 299 then a.status
                 else 'failed'
               end,
      last_error = case
                     when r.status_code between 200 and 299 then a.last_error
                     else 'http_' || r.status_code::text
                   end
  from net._http_response r
  where (a.metadata->>'pg_net_request_id')::bigint = r.id
    and a.webhook_status_code is null
    and a.attempt_type = 'webhook_reactivation'
    and a.metadata ? 'pg_net_request_id';

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.refresh_auth_credential_by_phone(p_phone text, p_reset_password boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.register_athlete_with_coach(p_master_id text, p_athlete_name text, p_athlete_phone text, p_coach_name text, p_coach_phone text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.requeue_stale_minds_webhooks()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_pingo_chat_sender(p_phone text, p_message text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_digits text;
  v_e164 text;
  v_user jsonb;
  v_athlete record;
  v_attempt_id bigint;
  v_is_internal_reactivation boolean;
begin
  v_digits := public.minds_digits(p_phone);
  v_e164 := case when v_digits <> '' then '+' || v_digits else null end;

  v_is_internal_reactivation := coalesce(trim(p_message), '') in (
    'PINGO_REATIVACAO_OI_SUMIDO',
    'PINGO_REATIVACAO_CHECK_NUMERO'
  );

  if v_digits <> '' and not v_is_internal_reactivation then
    select id into v_attempt_id
    from public.minds_reactivation_attempts
    where phone_digits = v_digits
      and status in ('claimed','injected','sent_to_webhook','sent_by_pingo','waiting_reply')
      and created_at >= now() - interval '14 days'
    order by created_at desc
    limit 1;

    if v_attempt_id is not null then
      update public.minds_reactivation_attempts
      set status = 'replied',
          replied_at = now(),
          reply_phone = v_e164,
          reply_text = left(coalesce(p_message, ''), 1000)
      where id = v_attempt_id;
    end if;
  end if;

  -- 1) Cadastro normal (mesmo shape do no "Users").
  select to_jsonb(u)
  into v_user
  from (
    select * from public.users_all
    where public.minds_digits(phone) = v_digits
    limit 1
  ) u;

  if v_user is not null then
    return v_user || jsonb_build_object(
      'role', coalesce(v_user->>'roles', 'visitor'),
      'resolved_from', 'users_all',
      'incoming_phone_digits', v_digits,
      'reactivation_reply_marked', v_attempt_id is not null
    );
  end if;

  -- 2) Fallback: athlete_registration. user_id = athlete_id => snapshot ok.
  select ar.athlete_id, ar.athlete_name, ar.athlete_phone,
         ar.coach_phone, ar.team_name, ar.inserted_at
  into v_athlete
  from public.athlete_registration ar
  where public.minds_digits(ar.athlete_phone) = v_digits
  order by ar.inserted_at desc nulls last
  limit 1;

  if found then
    return jsonb_build_object(
      'user_id', v_athlete.athlete_id,
      'name', v_athlete.athlete_name,
      'phone', coalesce(v_e164, v_athlete.athlete_phone),
      'email', null,
      'master_id', null,
      'roles', 'athlete',
      'role', 'athlete',
      'created_at', v_athlete.inserted_at,
      'account_active', true,
      'human_mode_until', null,
      'athlete_id', v_athlete.athlete_id,
      'athlete_name', v_athlete.athlete_name,
      'athlete_phone', v_athlete.athlete_phone,
      'coach_phone', v_athlete.coach_phone,
      'team_name', v_athlete.team_name,
      'resolved_from', 'athlete_registration_phone',
      'incoming_phone_digits', v_digits,
      'not_yet_in_users_all', true,
      'reactivation_reply_marked', v_attempt_id is not null
    );
  end if;

  -- 3) Desconhecido => visitor.
  return jsonb_build_object(
    'user_id', v_digits, 'name', null, 'phone', v_e164,
    'email', null, 'master_id', null,
    'roles', 'visitor', 'role', 'visitor',
    'created_at', null, 'account_active', false, 'human_mode_until', null,
    'resolved_from', 'unknown_phone',
    'incoming_phone_digits', v_digits,
    'reactivation_reply_marked', v_attempt_id is not null
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_role_from_user_roles(p_default_role text, p_user_id text, p_phone text, p_athlete_id text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.retry_minds_webhooks()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_done integer;
begin
  v_done := public.dispatch_minds_webhook_batch(50);
  return v_done;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.rpc_change_password(p_user_id text, p_old_pass text, p_new_pass text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.rpc_create_user(p_name text, p_phone text, p_role text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.rpc_delete_user(p_user_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  -- Constraints usually handle cascade, but let's be explicit
  DELETE FROM public.user_credentials WHERE user_id = p_user_id;
  DELETE FROM public.users_identity WHERE user_id = p_user_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.rpc_liga_minds_athlete_score(p_start_date date DEFAULT (date_trunc('month'::text, (CURRENT_DATE)::timestamp with time zone))::date, p_end_date date DEFAULT CURRENT_DATE)
 RETURNS TABLE(athlete_id text, athlete_name text, team_name text, athlete_phone text, photo_url text, instagram text, total_score numeric, xp_total integer, engagement_score numeric, response_speed_score numeric, consistency_score numeric, stability_score numeric, mood_score numeric, recovery_score numeric, nutrition_score numeric, load_score numeric, streak_days bigint, badges_count integer, current_badge text, badge_list text[], questionnaires_sent_total bigint, questionnaires_answered_total bigint, same_day_total bigint, late_total bigint, unresolved_total bigint, repeated_unanswered_sends bigint, total_flag_count bigint, max_flag_count integer, avg_attention_level numeric, high_attention_days bigint, avg_vigor numeric, avg_fatigue numeric, avg_dth numeric, avg_sleep_quality numeric, avg_recovery_index numeric, avg_stress_index numeric, avg_lack_energy numeric, avg_physical_complaints numeric, avg_acwr numeric, avg_ewma_acwr numeric, avg_monotony numeric, avg_strain numeric, high_load_risk_days bigint, position_overall bigint, position_team bigint, trend text)
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.rpc_liga_minds_podium(p_start_date date DEFAULT (date_trunc('month'::text, (CURRENT_DATE)::timestamp with time zone))::date, p_end_date date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.rpc_liga_minds_team_score(p_start_date date DEFAULT (date_trunc('month'::text, (CURRENT_DATE)::timestamp with time zone))::date, p_end_date date DEFAULT CURRENT_DATE)
 RETURNS TABLE(team_name text, athletes_count bigint, avg_athlete_score numeric, total_xp bigint, adherence_team_score numeric, stability_team_score numeric, streak_team_score numeric, low_repeat_penalty_score numeric, team_score numeric, top_athlete_name text, top_athlete_score numeric, team_position bigint)
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.rpc_login_phone(p_phone text, p_pass text)
 RETURNS TABLE(user_id text, role text, athlete_id text, must_change boolean, name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.rpc_minds_all_coaches_teams()
 RETURNS jsonb
 LANGUAGE sql
AS $function$with responses as (

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

-- normalização simples do nome do treinador
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
using (coach_name,coach_phone)$function$
;

CREATE OR REPLACE FUNCTION public.rpc_minds_behavior_analytics()
 RETURNS SETOF minds_behavior_analytics
 LANGUAGE sql
AS $function$

select *
from minds_behavior_analytics

$function$
;

CREATE OR REPLACE FUNCTION public.rpc_minds_behavior_engine_v3()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$with responses as (

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

);$function$
;

CREATE OR REPLACE FUNCTION public.rpc_minds_cron_flags()
 RETURNS TABLE(athlete_id text, athlete_name text, athlete_phone text, needs_post boolean, needs_pre boolean, needs_weekly boolean, needs_quarterly boolean, needs_semiannual boolean, needs_construcional boolean, escalation_level integer, priority_rank integer)
 LANGUAGE plpgsql
AS $function$begin

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


end;$function$
;

CREATE OR REPLACE FUNCTION public.rpc_minds_cron_forecast(p_now timestamp without time zone)
 RETURNS TABLE(athlete_id text, athlete_name text, athlete_phone text, action_type text, priority_rank integer, due_at timestamp without time zone)
 LANGUAGE sql
AS $function$

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

$function$
;

CREATE OR REPLACE FUNCTION public.rpc_minds_cron_priority()
 RETURNS TABLE(athlete_id text, athlete_name text, athlete_phone text, action_type text, priority_rank integer, escalation_level integer, due_at timestamp with time zone)
 LANGUAGE sql
AS $function$
select
    a.athlete_id,
    a.athlete_name,
    a.athlete_phone,
    o.predicted_questionnaire as action_type,
    case
        when o.predicted_questionnaire = 'post' then 1
        when o.predicted_questionnaire = 'pre' then 2
        when o.predicted_questionnaire = 'weekly' then 3
        when o.predicted_questionnaire = 'quarterly' then 5
        when o.predicted_questionnaire = 'semiannual' then 6
    end as priority_rank,
    0 as escalation_level,
    now() as due_at
from public.minds_overview o
join public.api_athletes a using (athlete_id)
where
    o.predicted_questionnaire is not null
    and o.predicted_questionnaire <> 'construcional'
    and a.athlete_phone is not null
    and (
        o.last_response is null
        or now() - o.last_response <= interval '14 days'
    )
    and (
        o.predicted_questionnaire = 'post'
        or (
            extract(hour from now()) >= 8
            and extract(hour from now()) < 18
        )
    )
    and not exists (
        select 1
        from public.minds_notification_log l
        where l.athlete_id = a.athlete_id
          and l.notification_type = o.predicted_questionnaire
          and l.sent_at >= date_trunc('day', now())
    )
order by
    priority_rank,
    a.athlete_name;
$function$
;

CREATE OR REPLACE FUNCTION public.rpc_minds_cron_scheduler()
 RETURNS TABLE(athlete_id text, athlete_name text, athlete_phone text, needs_pre boolean, needs_post boolean, needs_weekly boolean, needs_quarterly boolean, needs_semiannual boolean, needs_construcional boolean)
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.rpc_update_user(p_user_id text, p_name text, p_phone text, p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.run_pingo_reactivation_tick(p_cooldown_hours integer DEFAULT 72, p_min_hours_after_questionnaire integer DEFAULT 12, p_probability numeric DEFAULT 0.65, p_global_gap_minutes integer DEFAULT 25, p_daily_cap integer DEFAULT 10, p_active_hour_start integer DEFAULT 9, p_active_hour_end integer DEFAULT 20, p_timezone text DEFAULT 'America/Sao_Paulo'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare
  v_url text;
  rec record;
  v_req_id bigint;
  v_result jsonb := jsonb_build_object('claimed', 0);
begin
  v_url := public.pingo_get_setting('pingo_chat_webhook_url');
  if v_url is null or v_url like '%SEU-N8N-HOST%' then
    return jsonb_build_object('skipped', 'webhook_url_not_configured');
  end if;

  for rec in
    select * from public.claim_pingo_webhook_reactivation_candidate(
      p_cooldown_hours, p_min_hours_after_questionnaire, p_probability,
      p_global_gap_minutes, p_daily_cap, p_active_hour_start, p_active_hour_end, p_timezone
    )
  loop
    begin
      v_req_id := net.http_post(
        url := v_url,
        body := rec.webhook_payload,
        params := '{}'::jsonb,
        headers := jsonb_build_object('Content-Type', 'application/json'),
        timeout_milliseconds := 8000
      );

      update public.minds_reactivation_attempts
      set status = 'sent_to_webhook',
          injected_at = now(),
          attempted_at = coalesce(attempted_at, now()),
          metadata = metadata || jsonb_build_object('pg_net_request_id', v_req_id)
      where id = rec.attempt_id;

      v_result := jsonb_build_object(
        'claimed', 1, 'attempt_id', rec.attempt_id, 'pg_net_request_id', v_req_id
      );
    exception when others then
      perform public.mark_pingo_webhook_reactivation_injected(
        rec.attempt_id, null, null, 'pg_net_error: ' || sqlerrm
      );
      v_result := jsonb_build_object(
        'claimed', 1, 'attempt_id', rec.attempt_id, 'error', sqlerrm
      );
    end;
  end loop;

  return v_result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.save_last_user_message_as_history(p_user_id text, p_title text DEFAULT NULL::text, p_tags text[] DEFAULT '{}'::text[], p_saved_by text DEFAULT 'command'::text)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.save_user_message_as_history(p_message_id bigint, p_title text DEFAULT NULL::text, p_tags text[] DEFAULT '{}'::text[], p_saved_by text DEFAULT 'command'::text)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.search_similar_chat_notes(p_athlete_id text, p_query_embedding vector, p_limit integer DEFAULT 8)
 RETURNS TABLE(note_id bigint, created_at timestamp with time zone, title text, note_text text, tags text[], distance numeric)
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.send_minds_webhook(p_athlete_id text, p_name text, p_phone text, p_questionnaire text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.send_minds_webhook()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$begin

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

end;$function$
;

CREATE OR REPLACE FUNCTION public.set_active_athlete(p_user_id text, p_athlete_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.set_created_day()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.created_day := new.created_at::date;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_created_hour()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
new.created_hour := date_trunc('hour', new.created_at);
return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_pingo_chat_context_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.set_scoring_rules_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.slugify(text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
BEGIN
  RETURN lower(
    regexp_replace(
      regexp_replace(trim($1), '\s+', '_', 'g'),
      '[^a-z0-9_]', '', 'g'
    )
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec(sparsevec, integer, boolean)
 RETURNS sparsevec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_cmp(sparsevec, sparsevec)
 RETURNS integer
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_cmp$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_eq(sparsevec, sparsevec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_eq$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_ge(sparsevec, sparsevec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_ge$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_gt(sparsevec, sparsevec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_gt$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_in(cstring, oid, integer)
 RETURNS sparsevec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_in$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_l2_squared_distance(sparsevec, sparsevec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_l2_squared_distance$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_le(sparsevec, sparsevec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_le$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_lt(sparsevec, sparsevec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_lt$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_ne(sparsevec, sparsevec)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_ne$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_negative_inner_product(sparsevec, sparsevec)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_negative_inner_product$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_out(sparsevec)
 RETURNS cstring
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_out$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_recv(internal, oid, integer)
 RETURNS sparsevec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_recv$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_send(sparsevec)
 RETURNS bytea
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_send$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_to_halfvec(sparsevec, integer, boolean)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_to_halfvec$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_to_vector(sparsevec, integer, boolean)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_to_vector$function$
;

CREATE OR REPLACE FUNCTION public.sparsevec_typmod_in(cstring[])
 RETURNS integer
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$sparsevec_typmod_in$function$
;

CREATE OR REPLACE FUNCTION public.subvector(vector, integer, integer)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$subvector$function$
;

CREATE OR REPLACE FUNCTION public.subvector(halfvec, integer, integer)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_subvector$function$
;

CREATE OR REPLACE FUNCTION public.sync_account_status()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.sync_athlete_to_users_all()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.sync_coach_roles()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.sync_coach_roles_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.sync_coach_roles();
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sync_coach_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.sync_master_to_user_roles()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  insert into public.user_roles (user_id, role)
  values (new.master_id, 'master')
  on conflict (user_id, role) do nothing;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sync_masters_to_auth(p_force_reset_password boolean DEFAULT false)
 RETURNS TABLE(synced_identities integer, synced_credentials integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.sync_masters_to_login()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.sync_queue_sent()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin

update public.minds_webhook_queue
set sent = true
where
    athlete_id = new.athlete_id
    and questionnaire = new.notification_type
    and sent = false;

return new;

end;
$function$
;

CREATE OR REPLACE FUNCTION public.sync_registration_coach()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform public.ensure_coach_user(new.coach_name, new.coach_phone);
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sync_registration_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if public.norm_phone(new.athlete_phone) <> '' then
    perform public.refresh_auth_credential_by_phone(new.athlete_phone, false);
  end if;

  if public.norm_phone(new.coach_phone) <> '' then
    perform public.refresh_auth_credential_by_phone(new.coach_phone, false);
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sync_user_from_athlete_registration(p_athlete_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.sync_user_phone()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.sync_users_from_athlete_registration()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.trg_recalc_user_from_user_roles()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.trg_sync_users_from_athlete_registration()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.update_athlete_private_notes_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.update_pingo_last_state(p_user_id text, p_last_coach_phone text, p_last_athlete_id text, p_last_athlete_name text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  update pingo_chat_context
  set
    last_coach_phone = p_last_coach_phone,
    last_athlete_id = p_last_athlete_id,
    last_athlete_name = p_last_athlete_name,
    updated_at = now()
  where user_id = p_user_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_user_account_status()
 RETURNS void
 LANGUAGE sql
AS $function$

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

$function$
;

CREATE OR REPLACE FUNCTION public.upsert_construcional_analysis(p_construcional_raw_id bigint, p_athlete_id text, p_repertorio_protetor text, p_repertorio_risco text, p_apoio_ambiental text, p_claridade_metas text, p_model_name text DEFAULT NULL::text, p_confidence numeric DEFAULT NULL::numeric, p_explanation jsonb DEFAULT NULL::jsonb)
 RETURNS construcional_analysis
 LANGUAGE plpgsql
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.upsert_construcional_analysis_bigint(p_construcional_raw_id bigint, p_athlete_id text, p_repertorio_protetor text, p_repertorio_risco text, p_apoio_ambiental text, p_claridade_metas text, p_model_name text DEFAULT NULL::text, p_confidence numeric DEFAULT NULL::numeric, p_explanation jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.upsert_pingo_scoring_output(p_athlete_id text, p_reference_date date, p_attention_level integer, p_flag_count integer, p_flags jsonb, p_rules_triggered jsonb DEFAULT '[]'::jsonb, p_thresholds_used jsonb DEFAULT '{}'::jsonb, p_summary text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.vector(vector, integer, boolean)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector$function$
;

CREATE OR REPLACE FUNCTION public.vector_accum(double precision[], vector)
 RETURNS double precision[]
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_accum$function$
;

CREATE OR REPLACE FUNCTION public.vector_add(vector, vector)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_add$function$
;

CREATE OR REPLACE FUNCTION public.vector_avg(double precision[])
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_avg$function$
;

CREATE OR REPLACE FUNCTION public.vector_cmp(vector, vector)
 RETURNS integer
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_cmp$function$
;

CREATE OR REPLACE FUNCTION public.vector_combine(double precision[], double precision[])
 RETURNS double precision[]
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_combine$function$
;

CREATE OR REPLACE FUNCTION public.vector_concat(vector, vector)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_concat$function$
;

CREATE OR REPLACE FUNCTION public.vector_dims(halfvec)
 RETURNS integer
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$halfvec_vector_dims$function$
;

CREATE OR REPLACE FUNCTION public.vector_dims(vector)
 RETURNS integer
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_dims$function$
;

CREATE OR REPLACE FUNCTION public.vector_eq(vector, vector)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_eq$function$
;

CREATE OR REPLACE FUNCTION public.vector_ge(vector, vector)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_ge$function$
;

CREATE OR REPLACE FUNCTION public.vector_gt(vector, vector)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_gt$function$
;

CREATE OR REPLACE FUNCTION public.vector_in(cstring, oid, integer)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_in$function$
;

CREATE OR REPLACE FUNCTION public.vector_l2_squared_distance(vector, vector)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_l2_squared_distance$function$
;

CREATE OR REPLACE FUNCTION public.vector_le(vector, vector)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_le$function$
;

CREATE OR REPLACE FUNCTION public.vector_lt(vector, vector)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_lt$function$
;

CREATE OR REPLACE FUNCTION public.vector_mul(vector, vector)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_mul$function$
;

CREATE OR REPLACE FUNCTION public.vector_ne(vector, vector)
 RETURNS boolean
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_ne$function$
;

CREATE OR REPLACE FUNCTION public.vector_negative_inner_product(vector, vector)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_negative_inner_product$function$
;

CREATE OR REPLACE FUNCTION public.vector_norm(vector)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_norm$function$
;

CREATE OR REPLACE FUNCTION public.vector_out(vector)
 RETURNS cstring
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_out$function$
;

CREATE OR REPLACE FUNCTION public.vector_recv(internal, oid, integer)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_recv$function$
;

CREATE OR REPLACE FUNCTION public.vector_send(vector)
 RETURNS bytea
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_send$function$
;

CREATE OR REPLACE FUNCTION public.vector_spherical_distance(vector, vector)
 RETURNS double precision
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_spherical_distance$function$
;

CREATE OR REPLACE FUNCTION public.vector_sub(vector, vector)
 RETURNS vector
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_sub$function$
;

CREATE OR REPLACE FUNCTION public.vector_to_float4(vector, integer, boolean)
 RETURNS real[]
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_to_float4$function$
;

CREATE OR REPLACE FUNCTION public.vector_to_halfvec(vector, integer, boolean)
 RETURNS halfvec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_to_halfvec$function$
;

CREATE OR REPLACE FUNCTION public.vector_to_sparsevec(vector, integer, boolean)
 RETURNS sparsevec
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_to_sparsevec$function$
;

CREATE OR REPLACE FUNCTION public.vector_typmod_in(cstring[])
 RETURNS integer
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS '$libdir/vector', $function$vector_typmod_in$function$
;

