
-- =====================================================================
-- FAS 3B-2: SERVERNS PERSONAL OCH KONTRAKT
-- Servern har en egen kopia av varje mänskligt lags personal (förare,
-- mekaniker, ingenjörer, Team Principal) i lag_tillstand.personal, och
-- racen körs med den. Klienten skickar sin trupp (personal_synka) och
-- servern godkänner bara det som kan ha hänt i spelet:
--  * nya personer: köpta (leverans), fria agenter, nyrekryter på basnivå
--    (10 i varje tränbar förmåga) eller juniorer;
--  * förmågor: sänkningar alltid, höjningar högst 5 poäng per vecka och
--    person (Team Principal 1 per förmåga och vecka), erfarenhet enligt ålder;
--  * kontrakt: nytt/förlängt kontrakt kräver minst lönegolvet, en förare
--    går aldrig ner i lön, och friköpsskyddet kan inte läggas till i efterhand.
-- Personalträning (+3 för alla) och skador görs direkt på servern.
-- =====================================================================
alter table public.lag_tillstand add column if not exists personal jsonb;

-- Personer som servern har lämnat över till ett lag utanför marknaden (friköp).
create table if not exists public.personal_ursprung (
  id bigserial primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  kategori text not null,
  person_id text not null,
  person jsonb not null,
  skapad timestamptz not null default now()
);
create index if not exists personal_ursprung_idx on public.personal_ursprung (team_id, person_id);
alter table public.personal_ursprung enable row level security;

create or replace function public.personal_vecka(p_tid timestamptz default now())
returns int language sql stable as $$
  select floor(extract(epoch from date_trunc('week', p_tid at time zone 'Europe/Stockholm')) / 604800)::int;
$$;

-- Veckor sedan onlinespelet startade (juniorer tränar +1 per vecka).
create or replace function public.personal_veckor_sedan_start()
returns int language sql stable as $$
  select greatest(0, public.personal_vecka() - public.personal_vecka('2026-09-21 12:00+02'::timestamptz));
$$;

create or replace function public.personal_nycklar(p_kat text)
returns text[] language sql immutable as $$
  select case p_kat
    when 'forare' then array['erfarenhet', 'snabbhet', 'dackhantering', 'forsvar', 'lagformaga']
    when 'mekaniker' then array['erfarenhet', 'motorkunskap', 'snabbhet', 'press', 'lagformaga']
    when 'ingenjor' then array['erfarenhet', 'taktik', 'snabbhet', 'press', 'lagformaga']
    when 'principal' then array['forhandling', 'sponsring', 'moral']
  end;
$$;

create or replace function public.personal_formaga(p_kat text, p_stats jsonb)
returns int language sql immutable as $$
  select round(avg(coalesce((p_stats->>k)::numeric, 0)))::int from unnest(public.personal_nycklar(p_kat)) k;
$$;

create or replace function public.personal_erfarenhet(p_age int)
returns int language sql immutable as $$
  select greatest(0, least(100, 10 + (coalesce(p_age, 20) - 20) * 5));
$$;

create or replace function public.personal_tal(p jsonb, k text, p_std numeric default 0)
returns numeric language sql immutable as $$
  select case when jsonb_typeof(p->k) = 'number' then (p->>k)::numeric else p_std end;
$$;

-- Basnivån för en nyrekryt (samma som spelet skapar): 10 i allt, erfarenhet efter ålder.
create or replace function public.personal_basstats(p_kat text, p_age int)
returns jsonb language sql immutable as $$
  select jsonb_object_agg(k, case when k = 'erfarenhet' then public.personal_erfarenhet(p_age) else 10 end)
  from unnest(public.personal_nycklar(p_kat)) k;
$$;

-- Förmågorna som klienten ger en köpt person / fri agent (se laggTillSpelarPerson).
create or replace function public.personal_stats_fran_marknad(p_kat text, p jsonb)
returns jsonb language sql immutable as $$
  select case when p_kat = 'principal' and jsonb_typeof(p->'stats') = 'object' then p->'stats'
    else (select jsonb_object_agg(k, case when k = 'erfarenhet' and p_kat <> 'principal'
                                            then public.personal_erfarenhet(public.personal_tal(p, 'age', 20)::int)
                                            else public.personal_tal(p, 'formaga', 10)::int end)
          from unnest(public.personal_nycklar(p_kat)) k)
  end;
$$;

-- Godkänner förmågor mot ett underlag. Sänkningar godtas. Höjningar godtas
-- upp till p_utrymme poäng totalt och p_per per förmåga; erfarenhet får
-- dessutom växa fritt upp till nivån för personens ålder.
create or replace function public.personal_granska_stats(p_kat text, p_klient jsonb, p_bas jsonb, p_age int, p_utrymme int, p_per int)
returns jsonb language plpgsql immutable as $$
declare
  k text;
  v_bas int; v_ny int; v_fri int; v_pool int;
  v_kvar int := greatest(0, p_utrymme);
  v_anv int := 0;
  r jsonb := '{}'::jsonb;
begin
  foreach k in array public.personal_nycklar(p_kat) loop
    v_bas := public.personal_tal(p_bas, k, 0)::int;
    v_ny := least(100, greatest(0, round(public.personal_tal(p_klient, k, v_bas))::int));
    if v_ny > v_bas then
      v_fri := case when k = 'erfarenhet' then least(v_ny - v_bas, greatest(0, public.personal_erfarenhet(p_age) - v_bas)) else 0 end;
      v_pool := least(v_ny - v_bas - v_fri, v_kvar, greatest(0, p_per));
      v_ny := v_bas + v_fri + v_pool;
      v_kvar := v_kvar - v_pool;
      v_anv := v_anv + v_pool;
    end if;
    r := r || jsonb_build_object(k, v_ny);
  end loop;
  return jsonb_build_object('stats', r, 'anvant', v_anv);
end; $$;

create or replace function public.personal_lonegolv(p_kat text, p_formaga int, p_tier int)
returns bigint language sql immutable as $$
  -- Lägsta lön som någon accepterar i spelets förhandling (med marginal för
  -- slumpen i baslönen och en division lägre).
  select case p_kat
    when 'forare' then greatest(160000, floor(greatest(1, p_formaga) * (case least(5, p_tier + 1) when 1 then 95000 when 2 then 60000 when 3 then 32000 when 4 then 16000 else 9000 end) * 0.69 / 10000) * 10000)
    when 'principal' then floor((case least(5, p_tier + 1) when 1 then 3200000 when 2 then 2200000 when 3 then 1400000 when 4 then 900000 else 600000 end) * 0.85 / 10000) * 10000
    else greatest(340000, floor(greatest(1, p_formaga) * (case least(5, p_tier + 1) when 1 then 42000 when 2 then 30000 when 3 then 20000 when 4 then 12000 else 8000 end) * 0.76 / 10000) * 10000)
  end::bigint;
$$;

-- Godkänner ett kontrakt mot underlaget (serverns senaste, eller säljarens).
create or replace function public.personal_granska_kontrakt(p_kat text, p_klient jsonb, p_bas jsonb, p_formaga int, p_tier int)
returns jsonb language plpgsql immutable as $$
declare
  c jsonb := case when jsonb_typeof(p_klient) = 'object' then p_klient else '{}'::jsonb end;
  b jsonb := case when jsonb_typeof(p_bas) = 'object' then p_bas else null end;
  v_lon bigint; v_langd int; v_kvar int;
  v_nytt boolean;
begin
  if b is not null then
    v_nytt := public.personal_tal(c, 'salaryPerSeason', -1) is distinct from public.personal_tal(b, 'salaryPerSeason', -1)
      or public.personal_tal(c, 'contractLength', -1) is distinct from public.personal_tal(b, 'contractLength', -1)
      or public.personal_tal(c, 'contractYearsRemaining', 0) > public.personal_tal(b, 'contractYearsRemaining', 0)
      or public.personal_tal(c, 'releaseClause', 0) is distinct from public.personal_tal(b, 'releaseClause', 0);
    if not v_nytt then
      -- Oförändrat avtal: bara åren kvar får räknas ner.
      return c || jsonb_build_object(
        'salaryPerSeason', b->'salaryPerSeason', 'contractLength', b->'contractLength',
        'contractYearsRemaining', to_jsonb(least(public.personal_tal(c, 'contractYearsRemaining', 0), public.personal_tal(b, 'contractYearsRemaining', 0))),
        'releaseClause', coalesce(b->'releaseClause', '0'::jsonb),
        'skyddadForFrikopJuniorForstaKontrakt', coalesce(b->'skyddadForFrikopJuniorForstaKontrakt', 'false'::jsonb));
    end if;
  end if;
  -- Nytt eller förlängt kontrakt.
  v_lon := greatest(public.personal_tal(c, 'salaryPerSeason', 0)::bigint, public.personal_lonegolv(p_kat, p_formaga, p_tier));
  if p_kat = 'forare' and b is not null and public.personal_tal(b, 'contractYearsRemaining', 0) > 0 then
    v_lon := greatest(v_lon, public.personal_tal(b, 'salaryPerSeason', 0)::bigint);
  end if;
  v_langd := least(5, greatest(1, public.personal_tal(c, 'contractLength', 1)::int));
  v_kvar := least(v_langd, greatest(0, public.personal_tal(c, 'contractYearsRemaining', v_langd)::int));
  return c || jsonb_build_object(
    'salaryPerSeason', v_lon, 'contractLength', v_langd, 'contractYearsRemaining', v_kvar,
    'releaseClause', least(100000000, greatest(0, public.personal_tal(c, 'releaseClause', 0)::bigint)),
    'skyddadForFrikopJuniorForstaKontrakt', case when b is null then coalesce(c->'skyddadForFrikopJuniorForstaKontrakt', 'false'::jsonb)
                                                 else coalesce(b->'skyddadForFrikopJuniorForstaKontrakt', 'false'::jsonb) end);
end; $$;

create or replace function public.personal_lista_nyckel(p_kat text)
returns text language sql immutable as $$
  select case p_kat when 'forare' then 'forare' when 'mekaniker' then 'mekanikerLista' when 'ingenjor' then 'ingenjorLista' else null end;
$$;

-- Tar bort en person ur serverns personal (såld, friköpt). Returnerar personen.
create or replace function public.personal_ta_bort(p_team uuid, p_person_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r public.lag_tillstand;
  v_pers jsonb;
  v_hittad jsonb;
  k text;
begin
  select * into r from public.lag_tillstand where team_id = p_team for update;
  if not found or r.personal is null then return null; end if;
  v_pers := r.personal;
  foreach k in array array['forare', 'mekanikerLista', 'ingenjorLista'] loop
    select x into v_hittad from jsonb_array_elements(coalesce(v_pers->k, '[]'::jsonb)) x where x->>'id' = p_person_id;
    if v_hittad is not null then
      v_pers := jsonb_set(v_pers, array[k], coalesce((select jsonb_agg(x) from jsonb_array_elements(v_pers->k) x where x->>'id' <> p_person_id), '[]'::jsonb));
      exit;
    end if;
  end loop;
  if v_hittad is null and v_pers->'teamPrincipal'->>'id' = p_person_id then
    v_hittad := v_pers->'teamPrincipal';
    v_pers := jsonb_set(v_pers, '{teamPrincipal}', 'null'::jsonb);
  end if;
  if v_hittad is null then return null; end if;
  v_pers := jsonb_set(v_pers, '{borttagna}', (
    select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select x from jsonb_array_elements(jsonb_build_array(v_hittad) || coalesce(v_pers->'borttagna', '[]'::jsonb)) x limit 30) y));
  update public.lag_tillstand set personal = v_pers, version = version + 1, uppdaterad = now() where team_id = p_team;
  return v_hittad;
end; $$;
revoke execute on function public.personal_ta_bort(uuid, text) from public, anon, authenticated;
grant execute on function public.personal_ta_bort(uuid, text) to service_role;

-- Hittar en person i serverns personal (även nyss borttagna).
create or replace function public.personal_hitta(p_personal jsonb, p_person_id text)
returns jsonb language sql immutable as $$
  select x from (
    select x from jsonb_array_elements(coalesce(p_personal->'forare', '[]'::jsonb)) x
    union all select x from jsonb_array_elements(coalesce(p_personal->'mekanikerLista', '[]'::jsonb)) x
    union all select x from jsonb_array_elements(coalesce(p_personal->'ingenjorLista', '[]'::jsonb)) x
    union all select p_personal->'teamPrincipal' where jsonb_typeof(p_personal->'teamPrincipal') = 'object'
    union all select x from jsonb_array_elements(coalesce(p_personal->'borttagna', '[]'::jsonb)) x
  ) y where x->>'id' = p_person_id limit 1;
$$;

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

      v_age := greatest(15, least(70, public.personal_tal(c, 'age', 20)::int));
      if s is not null then
        v_basage := public.personal_tal(s, 'age', v_age)::int;
        v_age := greatest(v_basage, least(v_age, v_basage + greatest(0, v_sasong - public.personal_tal(s, '_s', v_sasong)::int)));
        v_veckor := greatest(0, v_vecka - public.personal_tal(s, '_v0', v_vecka)::int);
        v_utrymme := v_veckor * (case when v_kat = 'principal' then 3 else 5 end) - public.personal_tal(s, '_anv', 0)::int;
        v_per := case when v_kat = 'principal' then v_veckor else 100 end;
        g := public.personal_granska_stats(v_kat, c->'stats', s->'stats', v_age, v_utrymme, v_per);
        ut := jsonb_build_object('_v0', s->'_v0', '_anv', public.personal_tal(s, '_anv', 0)::int + (g->>'anvant')::int, '_s', to_jsonb(case when v_age > v_basage then v_sasong else public.personal_tal(s, '_s', v_sasong)::int end),
                                 'kontrakt', public.personal_granska_kontrakt(v_kat, c->'contract', s->'contract', public.personal_formaga(v_kat, g->'stats'), v_tier),
                                 'skadadTillRace', s->'skadadTillRace', 'style', coalesce(s->'style', c->'style'));
      elsif bas is not null then
        v_basage := public.personal_tal(bas, 'age', v_age)::int;
        v_age := greatest(v_basage, least(v_age, v_basage + 1));
        g := public.personal_granska_stats(v_kat, c->'stats', public.personal_stats_fran_marknad(v_kat, bas), v_age, case when v_kat = 'principal' then 3 else 5 end, case when v_kat = 'principal' then 1 else 5 end);
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
        'contract', ut->'kontrakt', '_v0', ut->'_v0', '_anv', ut->'_anv', '_s', ut->'_s');
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

  update public.lag_tillstand set personal = v_ny, version = version + 1, uppdaterad = now()
  where team_id = v_lag;
  return jsonb_build_object('personal', v_ny, 'avvisade', v_avvisade);
end; $$;
revoke execute on function public.personal_synka(jsonb) from public, anon;
grant execute on function public.personal_synka(jsonb) to authenticated;

-- Personalträning: +3 i en förmåga för hela mekaniker- eller ingenjörsteamet.
create or replace function public.trana_personal(p_typ text, p_attribut text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  r public.lag_tillstand;
  v_lista text := case p_typ when 'mekaniker' then 'mekanikerLista' when 'ingenjor' then 'ingenjorLista' else null end;
  v_kostnad bigint := case p_typ when 'mekaniker' then 80000 else 90000 end;
  v_ny jsonb;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  if v_lista is null or p_attribut = 'erfarenhet' or not (p_attribut = any(public.personal_nycklar(p_typ))) then raise exception 'Ogiltig förmåga att träna'; end if;
  r := public.lag_tillstand_las(v_lag);
  if r.personal is null then raise exception 'Laget är inte synkat med servern än – försök igen om en stund'; end if;
  if jsonb_array_length(coalesce(r.personal->v_lista, '[]'::jsonb)) = 0 then raise exception 'Du har ingen personal av den typen att träna'; end if;
  if r.budget < v_kostnad then raise exception 'Inte tillräckligt med pengar'; end if;
  select jsonb_agg(x || jsonb_build_object(
           'stats', (x->'stats') || jsonb_build_object(p_attribut, least(100, public.personal_tal(x->'stats', p_attribut, 0)::int + 3)),
           'formaga', public.personal_formaga(p_typ, (x->'stats') || jsonb_build_object(p_attribut, least(100, public.personal_tal(x->'stats', p_attribut, 0)::int + 3)))))
  into v_ny from jsonb_array_elements(r.personal->v_lista) x;
  update public.lag_tillstand
  set personal = jsonb_set(personal, array[v_lista], v_ny), budget = budget - v_kostnad, version = version + 1, uppdaterad = now()
  where team_id = v_lag returning * into r;
  insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
  values (v_lag, 'personal', -v_kostnad, 'Träning ' || p_typ || ' (' || p_attribut || ')', 'trana:' || gen_random_uuid());
  return jsonb_build_object('budget', r.budget, 'personal', r.personal, 'kostnad', v_kostnad);
end; $$;
revoke execute on function public.trana_personal(text, text) from public, anon;
grant execute on function public.trana_personal(text, text) to authenticated;

-- Skadad förare (efter ett race): missar nästa race, precis som i spelet.
create or replace function public.forare_skada(p_team uuid, p_bil int, p_skada text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  r public.lag_tillstand;
begin
  select * into r from public.lag_tillstand where team_id = p_team for update;
  if not found or r.personal is null then return false; end if;
  update public.lag_tillstand
  set personal = jsonb_set(personal, '{forare}', (
        select coalesce(jsonb_agg(case when x->>'roll' = 'bil' || p_bil then x || jsonb_build_object('skadadTillRace', p_skada) else x end), '[]'::jsonb)
        from jsonb_array_elements(coalesce(personal->'forare', '[]'::jsonb)) x)),
      version = version + 1, uppdaterad = now()
  where team_id = p_team;
  return true;
end; $$;
revoke execute on function public.forare_skada(uuid, int, text) from public, anon, authenticated;
grant execute on function public.forare_skada(uuid, int, text) to service_role;

-- Racemotorn läser nu även personalen.
drop function if exists public.tillstand_alla();
create or replace function public.tillstand_alla()
returns table (team_id uuid, budget bigint, bil jsonb, personal jsonb)
language sql stable security definer set search_path = public as $$
  select team_id, budget, public.bil_tillampa_klara(bil), personal from public.lag_tillstand;
$$;
revoke execute on function public.tillstand_alla() from public, anon, authenticated;
grant execute on function public.tillstand_alla() to service_role;

-- Marknaden: en egen person läggs ut med serverns förmågor och kontrakt.
create or replace function public.marknad_lagg_ut(p_kategori text, p_person jsonb, p_utropspris bigint, p_typ text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  v_id uuid;
  v_pid text := p_person->>'personId';
  v_personal jsonb;
  s jsonb;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  if p_typ not in ('lag', 'fri', 'sparkad') then raise exception 'Ogiltig typ'; end if;
  if v_pid is null or pg_column_size(p_person) > 200000 then raise exception 'Ogiltig person'; end if;
  if coalesce(p_utropspris, 0) < 1000 then raise exception 'Utgångspriset måste vara minst 1000'; end if;
  select personal into v_personal from public.lag_tillstand where team_id = v_lag;
  if v_personal is not null then
    s := public.personal_hitta(v_personal, v_pid);
    if s is null then raise exception 'Personen finns inte i ditt lag'; end if;
    p_person := p_person || jsonb_build_object('age', s->'age', 'stats', s->'stats', 'formaga', s->'formaga',
      'kontrakt', s->'contract', 'lon', s->'contract'->'salaryPerSeason', 'kontraktslangd', s->'contract'->'contractYearsRemaining');
  end if;
  insert into public.marknad (kategori, person_id, person, saljare_typ, saljare_team_id, utropspris, hogsta_bud, deadline)
  values (p_kategori, v_pid, p_person, p_typ, v_lag, p_utropspris, p_utropspris, now() + interval '7 days')
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'Personen är redan ute till försäljning';
end; $$;
revoke execute on function public.marknad_lagg_ut(text, jsonb, bigint, text) from public, anon;
grant execute on function public.marknad_lagg_ut(text, jsonb, bigint, text) to authenticated;

-- Friköp: för en människas lag gäller serverns person och kontrakt.
create or replace function public.marknad_frikop(p_team_id uuid, p_kategori text, p_person_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  t public.teams%rowtype;
  v_nyckel text := public.personal_lista_nyckel(p_kategori);
  v_person jsonb;
  v_server jsonb;
  v_rest jsonb;
  v_summa bigint;
  v_ref text := gen_random_uuid()::text;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  if v_nyckel is null then raise exception 'Ogiltig kategori'; end if;
  if p_team_id = v_lag then raise exception 'Du kan inte friköpa från ditt eget lag'; end if;
  select * into t from public.teams where id = p_team_id for update;
  if not found or t.snapshot is null then raise exception 'Hittade inte laget'; end if;
  select x into v_person from jsonb_array_elements(coalesce(t.snapshot->v_nyckel, '[]'::jsonb)) x where x->>'id' = p_person_id;
  if not t.is_ai and exists (select 1 from public.lag_tillstand where team_id = p_team_id and personal is not null) then
    select x into v_server from public.lag_tillstand lt, jsonb_array_elements(coalesce(lt.personal->v_nyckel, '[]'::jsonb)) x
    where lt.team_id = p_team_id and x->>'id' = p_person_id;
    if v_server is null then raise exception 'Personen finns inte längre i laget'; end if;
    v_person := coalesce(v_person, '{}'::jsonb) || (v_server - '_v0' - '_anv' - '_s');
  end if;
  if v_person is null then raise exception 'Personen finns inte längre i laget'; end if;
  v_summa := (v_person->'contract'->>'releaseClause')::bigint;
  if v_summa is null or v_summa <= 0 then raise exception 'Personen har ingen friköpsklausul'; end if;
  if coalesce((v_person->'contract'->>'skyddadForFrikopJuniorForstaKontrakt')::boolean, false) then raise exception 'Kontraktet är skyddat mot friköp'; end if;
  if exists (select 1 from public.marknad where person_id = p_person_id and status = 'aktiv') then raise exception 'Personen är ute på auktion – buda där i stället'; end if;
  if (public.lag_tillstand_las(v_lag)).budget < v_summa then raise exception 'Du har inte tillräcklig budget för friköpsklausulen'; end if;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rest
  from jsonb_array_elements(coalesce(t.snapshot->v_nyckel, '[]'::jsonb)) x where x->>'id' <> p_person_id;
  update public.teams
  set snapshot = jsonb_set(
        jsonb_set(snapshot, array[v_nyckel], v_rest),
        '{vakanser}', coalesce(snapshot->'vakanser', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('kategori', p_kategori, 'roll', v_person->>'roll', 'bil', v_person->'bil')))
  where id = p_team_id;

  perform public.ekonomi_bokfor(v_lag, 'marknad', -v_summa, 'Friköp av ' || (v_person->>'namn'), 'frikop-kop:' || v_ref);
  insert into public.personal_ursprung (team_id, kategori, person_id, person) values (v_lag, p_kategori, p_person_id, v_person);
  if not t.is_ai then
    perform public.personal_ta_bort(p_team_id, p_person_id);
    perform public.ekonomi_bokfor(p_team_id, 'marknad', v_summa, 'Friköp av ' || (v_person->>'namn'), 'frikop-salj:' || v_ref);
    insert into public.leveranser (team_id, typ, kategori, person_id, belopp, motpart)
    values (p_team_id, 'frikopt', p_kategori, p_person_id, v_summa, (select name from public.teams where id = v_lag));
  end if;
  return jsonb_build_object('person', v_person, 'summa', v_summa, 'lagNamn', t.name, 'arManniska', not t.is_ai);
end; $$;
revoke execute on function public.marknad_frikop(uuid, text, text) from public, anon;
grant execute on function public.marknad_frikop(uuid, text, text) to authenticated;

do $$ begin raise notice 'FAS 3B-2 klar'; end $$;
