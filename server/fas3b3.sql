
-- =====================================================================
-- FAS 3B-3: TRÄNING OCH UTVECKLING PÅ SERVERN
-- Förmågor och ålder för personer i laget ändras nu bara av servern:
--  * träningsracet (måndag 20:00) körs av kor-race med lagets order
--    (personernas traningsval, skickas med personal_synka);
--  * personalens väntande träning slår igenom söndag 20:00;
--  * vid ny säsong åldras alla (+5 erfarenhet, förfall efter 30 år, pension).
-- Resultaten sparas i traning_resultat, som klienten visar.
-- =====================================================================
alter table public.lag_tillstand add column if not exists traning jsonb not null default '{}'::jsonb;

create table if not exists public.traning_resultat (
  team_id uuid not null references public.teams(id) on delete cascade,
  vecka int not null,
  sasong int,
  resultat jsonb not null,
  ateranvant boolean not null default false,
  skapad timestamptz not null default now(),
  primary key (team_id, vecka)
);
alter table public.traning_resultat enable row level security;
drop policy if exists "Managers läser sina träningsresultat" on public.traning_resultat;
create policy "Managers läser sina träningsresultat" on public.traning_resultat
  for select using (exists (select 1 from public.teams t where t.id = team_id and t.user_id = auth.uid()));

-- Veckans klocka (svensk tid): träning måndag 20:00, uppdatering söndag 20:00.
create or replace function public.traning_klocka()
returns jsonb language sql stable as $$
  with s as (select (date_trunc('week', now() at time zone 'Europe/Stockholm')) as m)
  select jsonb_build_object(
    'vecka', public.personal_vecka(),
    'traning_dags', now() >= (s.m + interval '20 hours') at time zone 'Europe/Stockholm',
    'uppdatering_dags', now() >= (s.m + interval '6 days 20 hours') at time zone 'Europe/Stockholm',
    'sasong', (select season_number from public.season_state limit 1))
  from s;
$$;
grant execute on function public.traning_klocka() to authenticated, service_role;

-- Klientens trupp in, serverns godkända trupp ut.
-- p_personal: { forare: [], mekanikerLista: [], ingenjorLista: [], teamPrincipal, chefMekanikerId, chefIngenjorId }
create or replace function public.personal_synka(p_personal jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  r public.lag_tillstand;
  v_gammal jsonb;
  v_start boolean;
  v_tier int;
  v_sasong int;
  v_vecka int := public.personal_vecka();
  v_junior int := public.personal_veckor_sedan_start();
  v_ny jsonb := jsonb_build_object('forare', '[]'::jsonb, 'mekanikerLista', '[]'::jsonb, 'ingenjorLista', '[]'::jsonb, 'teamPrincipal', null);
  v_avvisade jsonb := '[]'::jsonb;
  v_sedda text[] := '{}';
  v_max jsonb := '{"forare": 14, "mekanikerLista": 22, "ingenjorLista": 22}'::jsonb;
  v_lista text;
  v_kat text;
  c jsonb; s jsonb; bas jsonb; g jsonb; ut jsonb;
  v_age int; v_basage int; v_utrymme int; v_per int; v_veckor int;
  v_ursprung text;
  v_personer jsonb;
  v_borttagna jsonb := '[]'::jsonb;
  v_traning jsonb;
  v_val jsonb := '[]'::jsonb;
  v_antal jsonb := '{}'::jsonb;
  v_mal int;
  v_x jsonb;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  if jsonb_typeof(p_personal) <> 'object' or pg_column_size(p_personal) > 600000 then raise exception 'Ogiltig trupp'; end if;
  r := public.lag_tillstand_las(v_lag);
  v_gammal := r.personal;
  v_start := v_gammal is null;
  select coalesce(d.tier, 4) into v_tier from public.teams t left join public.divisions d on d.id = t.division_id where t.id = v_lag;
  select season_number into v_sasong from public.season_state limit 1;
  v_sasong := coalesce(v_sasong, 1);

  foreach v_lista in array array['forare', 'mekanikerLista', 'ingenjorLista', 'teamPrincipal'] loop
    v_kat := case v_lista when 'forare' then 'forare' when 'mekanikerLista' then 'mekaniker' when 'ingenjorLista' then 'ingenjor' else 'principal' end;
    v_personer := case when v_lista = 'teamPrincipal'
                    then (case when jsonb_typeof(p_personal->'teamPrincipal') = 'object' then jsonb_build_array(p_personal->'teamPrincipal') else '[]'::jsonb end)
                    else (case when jsonb_typeof(p_personal->v_lista) = 'array' then p_personal->v_lista else '[]'::jsonb end) end;
    for c in select x from jsonb_array_elements(v_personer) x loop
      if jsonb_typeof(c) <> 'object' or coalesce(c->>'id', '') = '' or c->>'id' = any(v_sedda) then continue; end if;
      if v_lista <> 'teamPrincipal' and jsonb_array_length(v_ny->v_lista) >= (v_max->>v_lista)::int then
        v_avvisade := v_avvisade || jsonb_build_object('id', c->>'id', 'namn', c->>'namn', 'orsak', 'för många i truppen');
        continue;
      end if;
      if v_lista = 'teamPrincipal' and jsonb_typeof(v_ny->'teamPrincipal') = 'object' then continue; end if;

      -- Underlag: serverns egen kopia, annars personens ursprung.
      s := null; bas := null; v_ursprung := null;
      if not v_start then
        if v_lista = 'teamPrincipal' then
          if v_gammal->'teamPrincipal'->>'id' = c->>'id' then s := v_gammal->'teamPrincipal'; end if;
        else
          select x into s from jsonb_array_elements(coalesce(v_gammal->v_lista, '[]'::jsonb)) x where x->>'id' = c->>'id';
        end if;
      end if;
      if s is null then
        select l.person into bas from public.leveranser l
        where l.team_id = v_lag and l.typ = 'kopt' and l.person_id = c->>'id' and l.kategori = v_kat
        order by l.id desc limit 1;
        if bas is not null then v_ursprung := 'kopt'; end if;
        if bas is null then
          select u.person into bas from public.personal_ursprung u
          where u.team_id = v_lag and u.person_id = c->>'id' and u.kategori = v_kat
          order by u.id desc limit 1;
          if bas is not null then v_ursprung := 'frikop'; end if;
        end if;
        if bas is null then
          select f.person into bas from public.fria_agenter f
          where f.anstalld_av = v_lag and f.kategori = v_kat and f.person->>'id' = c->>'id'
          order by f.anstalld_at desc nulls last limit 1;
          if bas is not null then v_ursprung := 'fri'; end if;
        end if;
        -- Såld/friköpt men ännu inte tillämpad i klienten: tas bort i tysthet.
        if bas is null and exists (select 1 from public.leveranser l where l.team_id = v_lag and l.typ in ('salt', 'frikopt') and l.person_id = c->>'id') then
          continue;
        end if;
      end if;

      if s is null and bas is null and not v_start and exists (
           select 1 from jsonb_array_elements(coalesce(v_gammal->'borttagna', '[]'::jsonb)) b where b->>'id' = c->>'id') then
        continue;
      end if;

      v_age := greatest(15, least(70, public.personal_tal(c, 'age', 20)::int));
      if s is not null then
        -- Förmågor och ålder ändras bara av servern (träning, åldrande).
        v_age := public.personal_tal(s, 'age', v_age)::int;
        g := jsonb_build_object('stats', coalesce(s->'stats', '{}'::jsonb), 'anvant', 0);
        ut := jsonb_build_object('_v0', s->'_v0', '_anv', s->'_anv', '_s', s->'_s',
                                 'kontrakt', public.personal_granska_kontrakt(v_kat, c->'contract', s->'contract', public.personal_formaga(v_kat, g->'stats'), v_tier),
                                 'skadadTillRace', s->'skadadTillRace', 'style', coalesce(s->'style', c->'style'), 'vantandeTraning', s->'vantandeTraning');
      elsif bas is not null then
        v_basage := public.personal_tal(bas, 'age', v_age)::int;
        v_age := greatest(v_basage, least(v_age, v_basage + 1));
        g := public.personal_granska_stats(v_kat, c->'stats', public.personal_stats_fran_marknad(v_kat, bas), v_age, 0, 0);
        ut := jsonb_build_object('_v0', v_vecka - 1, '_anv', (g->>'anvant')::int, '_s', v_sasong,
                                 'kontrakt', public.personal_granska_kontrakt(v_kat, c->'contract', coalesce(bas->'kontrakt', bas->'contract'), public.personal_formaga(v_kat, g->'stats'), v_tier),
                                 'skadadTillRace', null, 'style', coalesce(bas->'style', c->'style'));
      else
        -- Nyrekryt eller junior: basnivå, juniorer +1 per vecka sedan starten.
        g := public.personal_granska_stats(v_kat, c->'stats', public.personal_basstats(v_kat, v_age), v_age,
                                           case when v_start then 5 * (v_junior + 2) else v_junior end,
                                           case when v_start then 5 * (v_junior + 2) else v_junior end);
        if not v_start and v_kat <> 'principal' and exists (
             select 1 from unnest(public.personal_nycklar(v_kat)) k
             where public.personal_tal(c->'stats', k, 0) > public.personal_tal(g->'stats', k, 0)) then
          v_avvisade := v_avvisade || jsonb_build_object('id', c->>'id', 'namn', c->>'namn', 'orsak', 'okänt ursprung');
          continue;
        end if;
        ut := jsonb_build_object('_v0', v_vecka - 1, '_anv', 0, '_s', v_sasong,
                                 'kontrakt', public.personal_granska_kontrakt(v_kat, c->'contract', null, public.personal_formaga(v_kat, g->'stats'), v_tier),
                                 'skadadTillRace', null, 'style', c->'style');
      end if;

      c := jsonb_build_object(
        'id', c->>'id', 'namn', c->'namn', 'nationalitet', c->'nationalitet', 'age', v_age,
        'stats', (case when jsonb_typeof(c->'stats') = 'object' then c->'stats' else '{}'::jsonb end) || (g->'stats'),
        'formaga', public.personal_formaga(v_kat, g->'stats'),
        'contract', ut->'kontrakt', '_v0', ut->'_v0', '_anv', ut->'_anv', '_s', ut->'_s', 'vantandeTraning', ut->'vantandeTraning');
      if v_kat = 'forare' then
        c := c || jsonb_build_object('roll', case when (p_personal->v_lista) is not null and (select x->>'roll' from jsonb_array_elements(p_personal->v_lista) x where x->>'id' = c->>'id' limit 1) in ('bil1', 'bil2') then (select x->>'roll' from jsonb_array_elements(p_personal->v_lista) x where x->>'id' = c->>'id' limit 1) else 'reserv' end,
                                     'style', ut->'style', 'skadadTillRace', ut->'skadadTillRace');
      elsif v_kat <> 'principal' then
        select c || jsonb_build_object('bil', case when x->'bil' in ('1'::jsonb, '2'::jsonb) then x->'bil' else '"reserv"'::jsonb end,
                                       'extra', to_jsonb(coalesce((x->>'extra')::boolean, false)))
        into c from jsonb_array_elements(p_personal->v_lista) x where x->>'id' = c->>'id' limit 1;
      end if;
      v_sedda := v_sedda || (c->>'id');
      if v_lista = 'teamPrincipal' then v_ny := jsonb_set(v_ny, '{teamPrincipal}', c);
      else v_ny := jsonb_set(v_ny, array[v_lista], (v_ny->v_lista) || jsonb_build_array(c)); end if;
    end loop;
  end loop;

  -- Chefer måste finnas i respektive lista.
  v_ny := v_ny || jsonb_build_object(
    'chefMekanikerId', (select to_jsonb(x->>'id') from jsonb_array_elements(v_ny->'mekanikerLista') x where x->>'id' = p_personal->>'chefMekanikerId' limit 1),
    'chefIngenjorId', (select to_jsonb(x->>'id') from jsonb_array_elements(v_ny->'ingenjorLista') x where x->>'id' = p_personal->>'chefIngenjorId' limit 1));
  v_ny := jsonb_strip_nulls(v_ny - 'teamPrincipal') || jsonb_build_object('teamPrincipal', v_ny->'teamPrincipal');

  -- Personer som lämnat laget sparas en tid (för marknaden).
  if not v_start then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_borttagna from (
      select x from (
        select x from jsonb_array_elements(coalesce(v_gammal->'forare', '[]'::jsonb)) x
        union all select x from jsonb_array_elements(coalesce(v_gammal->'mekanikerLista', '[]'::jsonb)) x
        union all select x from jsonb_array_elements(coalesce(v_gammal->'ingenjorLista', '[]'::jsonb)) x
        union all select v_gammal->'teamPrincipal' where jsonb_typeof(v_gammal->'teamPrincipal') = 'object'
      ) y where not (x->>'id' = any(v_sedda))
      union all select x from jsonb_array_elements(coalesce(v_gammal->'borttagna', '[]'::jsonb)) x
      limit 30) z;
  end if;
  v_ny := v_ny || jsonb_build_object('borttagna', v_borttagna);

  -- Veckans träningsorder (personernas traningsval): högst 3 förare och 3
  -- ordinarie mekaniker/ingenjörer. Gäller nästa träningsrace (måndag 20:00).
  foreach v_lista in array array['forare', 'mekanikerLista', 'ingenjorLista'] loop
    v_kat := case v_lista when 'forare' then 'forare' when 'mekanikerLista' then 'mekaniker' else 'ingenjor' end;
    for v_x in select y from jsonb_array_elements(case when jsonb_typeof(p_personal->v_lista) = 'array' then p_personal->v_lista else '[]'::jsonb end) y loop
      if not (v_x->>'id' = any(v_sedda)) or coalesce(v_x->>'traningsval', '') = 'erfarenhet'
         or not (coalesce(v_x->>'traningsval', '') = any(public.personal_nycklar(v_kat))) then continue; end if;
      if v_kat = 'forare' or not coalesce((v_x->>'extra')::boolean, false) then
        if coalesce((v_antal->>v_kat)::int, 0) >= 3 then continue; end if;
        v_antal := v_antal || jsonb_build_object(v_kat, coalesce((v_antal->>v_kat)::int, 0) + 1);
      end if;
      v_val := v_val || jsonb_build_object('id', v_x->>'id', 'kat', v_kat, 'attribut', v_x->>'traningsval');
    end loop;
  end loop;
  v_mal := case when (public.traning_klocka()->>'traning_dags')::boolean then v_vecka + 1 else v_vecka end;
  v_traning := coalesce(r.traning, '{}'::jsonb);
  v_traning := v_traning || jsonb_build_object(
    'order', coalesce((select jsonb_object_agg(k, v) from jsonb_each(coalesce(v_traning->'order', '{}'::jsonb)) o(k, v) where k::int >= v_vecka and k::int <> v_mal), '{}'::jsonb)
             || jsonb_build_object(v_mal::text, v_val),
    'aldradSasong', coalesce(v_traning->'aldradSasong', to_jsonb(v_sasong)));

  update public.lag_tillstand set personal = v_ny, traning = v_traning, version = version + 1, uppdaterad = now()
  where team_id = v_lag;
  return jsonb_build_object('personal', v_ny, 'avvisade', v_avvisade);
end; $$;
revoke execute on function public.personal_synka(jsonb) from public, anon;
grant execute on function public.personal_synka(jsonb) to authenticated;


-- kor-race sparar serverns ändringar (träning, uppdatering, åldrande), bara om
-- ingen annan hunnit ändra laget sedan det lästes (version).
create or replace function public.personal_server_spara(p_team uuid, p_version bigint, p_personal jsonb, p_traning jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.lag_tillstand set personal = p_personal, traning = p_traning, version = version + 1, uppdaterad = now()
  where team_id = p_team and version = p_version;
  return found;
end; $$;
revoke execute on function public.personal_server_spara(uuid, bigint, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.personal_server_spara(uuid, bigint, jsonb, jsonb) to service_role;

drop function if exists public.tillstand_alla();
create or replace function public.tillstand_alla()
returns table (team_id uuid, budget bigint, bil jsonb, personal jsonb, traning jsonb, version bigint)
language sql stable security definer set search_path = public as $$
  select team_id, budget, public.bil_tillampa_klara(bil), personal, traning, version from public.lag_tillstand;
$$;
revoke execute on function public.tillstand_alla() from public, anon, authenticated;
grant execute on function public.tillstand_alla() to service_role;

do $$ begin raise notice 'FAS 3B-3 klar'; end $$;
