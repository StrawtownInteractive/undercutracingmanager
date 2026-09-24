
-- =====================================================================
-- FAS 3B-4: VECKOEKONOMIN PÅ SERVERN
-- Servern räknar söndagens ekonomi (sponsor, merchandise, biljetter,
-- löner, underhåll, ränta på minussaldo), sponsoravtal, arenan,
-- kontrakts- och sponsorbonusar efter varje race, mästerskapsbonusar och
-- förarnas popularitet. Klienten får inte längre rapportera dessa intäkter.
-- =====================================================================
alter table public.lag_tillstand add column if not exists ekonomi jsonb;

create table if not exists public.ekonomi_vecka (
  team_id uuid not null references public.teams(id) on delete cascade,
  vecka int not null,
  sasong int,
  rader jsonb not null,
  netto bigint not null,
  budget_efter bigint,
  skapad timestamptz not null default now(),
  primary key (team_id, vecka)
);
alter table public.ekonomi_vecka enable row level security;
drop policy if exists "Managers läser sin veckoekonomi" on public.ekonomi_vecka;
create policy "Managers läser sin veckoekonomi" on public.ekonomi_vecka
  for select using (exists (select 1 from public.teams t where t.id = team_id and t.user_id = auth.uid()));

create or replace function public.lag_tier(p_team uuid)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select d.tier from public.teams t join public.divisions d on d.id = t.division_id where t.id = p_team), 4);
$$;
revoke execute on function public.lag_tier(uuid) from public, anon;

-- Samma formel som spelets skapaSponsorErbjudande()/genereraSponsorErbjudanden().
create or replace function public.sponsor_erbjudande(p_tier int, p_profil text, p_sponsring numeric)
returns jsonb language plpgsql immutable as $$
declare
  r0 numeric := case p_tier when 1 then 600000 when 2 then 350000 when 3 then 150000 when 4 then 50000 else 25000 end;
  r1 numeric := case p_tier when 1 then 1000000 when 2 then 700000 when 3 then 400000 when 4 then 200000 else 120000 end;
  v_mitt numeric := (r0 + r1) / 2 * 1.3;
  v_grund numeric := case p_profil when 'trygg' then 0.85 when 'risk' then 0.45 else 0.65 end;
  v_bonus numeric := case p_profil when 'trygg' then 0.4 when 'risk' then 4.0 else 0.8 end;
  v_g bigint;
begin
  v_g := round(v_mitt * v_grund / 10000) * 10000;
  v_g := round(v_g * (0.85 + coalesce(p_sponsring, 50) / 100 * 0.3) / 10000) * 10000;
  return jsonb_build_object(
    'profil', p_profil, 'grundbelopp', v_g,
    'pallBonus', (round(v_mitt * 0.06 * v_bonus / 5000) * 5000)::bigint,
    'vinstBonus', (round(v_mitt * 0.15 * v_bonus / 5000) * 5000)::bigint,
    'mastarskapsBonus', (round(v_mitt * 1.2 * v_bonus / 10000) * 10000)::bigint,
    'langd', 10);
end; $$;

create or replace function public.ekonomi_start()
returns jsonb language sql immutable as $$
  select jsonb_build_object('arenaNiva', 1, 'arenaKapacitet', 5000, 'sponsoravtal', null);
$$;

-- Mitt lags ekonomitillstånd (arena, sponsoravtal). Första gången godtas
-- klientens arena (högst nivå 3) och ett pågående sponsoravtal inom
-- avtalsgränserna.
create or replace function public.mitt_ekonomi(p_start jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  r public.lag_tillstand;
  v_niva int;
  a jsonb;
  v_max jsonb;
  v_min jsonb;
  v_ek jsonb;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  r := public.lag_tillstand_las(v_lag);
  if r.ekonomi is null then
    v_niva := least(3, greatest(1, coalesce(public.personal_tal(p_start, 'arenaNiva', 1)::int, 1)));
    v_ek := public.ekonomi_start() || jsonb_build_object('arenaNiva', v_niva, 'arenaKapacitet', 5000 + 2500 * (v_niva - 1));
    a := p_start->'sponsoravtal';
    if jsonb_typeof(a) = 'object' and public.personal_tal(a, 'veckorKvar', 0) between 1 and 10 then
      v_max := public.sponsor_erbjudande(public.lag_tier(v_lag), 'trygg', 100);
      v_min := public.sponsor_erbjudande(public.lag_tier(v_lag), 'risk', 100);
      v_ek := v_ek || jsonb_build_object('sponsoravtal', jsonb_build_object(
        'sponsorNamn', left(coalesce(a->>'sponsorNamn', 'Sponsor'), 60),
        'grundbelopp', least(public.personal_tal(a, 'grundbelopp', 0), (v_max->>'grundbelopp')::numeric)::bigint,
        'pallBonus', least(public.personal_tal(a, 'pallBonus', 0), (v_min->>'pallBonus')::numeric)::bigint,
        'vinstBonus', least(public.personal_tal(a, 'vinstBonus', 0), (v_min->>'vinstBonus')::numeric)::bigint,
        'mastarskapsBonus', least(public.personal_tal(a, 'mastarskapsBonus', 0), (v_min->>'mastarskapsBonus')::numeric)::bigint,
        'veckorKvar', public.personal_tal(a, 'veckorKvar', 0)::int, 'langdTotalt', 10));
    end if;
    update public.lag_tillstand set ekonomi = v_ek, version = version + 1, uppdaterad = now()
    where team_id = v_lag and ekonomi is null;
  end if;
  select ekonomi into v_ek from public.lag_tillstand where team_id = v_lag;
  return v_ek;
end; $$;
revoke execute on function public.mitt_ekonomi(jsonb) from public, anon;
grant execute on function public.mitt_ekonomi(jsonb) to authenticated;

-- Arenauppgradering: 350 000, +2 500 platser.
create or replace function public.arena_uppgradera()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  r public.lag_tillstand;
  v_ek jsonb;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  r := public.lag_tillstand_las(v_lag);
  if r.budget < 350000 then raise exception 'Inte tillräckligt med pengar'; end if;
  v_ek := coalesce(r.ekonomi, public.ekonomi_start());
  v_ek := v_ek || jsonb_build_object('arenaNiva', public.personal_tal(v_ek, 'arenaNiva', 1)::int + 1,
                                     'arenaKapacitet', public.personal_tal(v_ek, 'arenaKapacitet', 5000)::int + 2500);
  update public.lag_tillstand set ekonomi = v_ek, budget = budget - 350000, version = version + 1, uppdaterad = now()
  where team_id = v_lag returning * into r;
  insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
  values (v_lag, 'arena', -350000, 'Arenauppgradering', 'arena:' || gen_random_uuid());
  return jsonb_build_object('budget', r.budget, 'ekonomi', r.ekonomi);
end; $$;
revoke execute on function public.arena_uppgradera() from public, anon;
grant execute on function public.arena_uppgradera() to authenticated;

-- Teckna sponsoravtal. Beloppen räknas av servern (division + Team
-- Principalens sponsring), klienten väljer bara profil och namn.
create or replace function public.sponsor_teckna(p_profil text, p_namn text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  r public.lag_tillstand;
  v_ek jsonb;
  e jsonb;
  v_namn text := case when p_namn = any(array['TechCorp AB', 'Nordic Energy', 'Velocity Bank', 'Fusion Oil', 'Starlight Försäkring', 'Quantum Däck', 'Borealis Telecom', 'Ironclad Logistik', 'Solaris Bränsle', 'Meridian Kapital']) then p_namn else 'TechCorp AB' end;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  if p_profil not in ('trygg', 'balanserad', 'risk') then raise exception 'Ogiltigt avtal'; end if;
  r := public.lag_tillstand_las(v_lag);
  v_ek := coalesce(r.ekonomi, public.ekonomi_start());
  if jsonb_typeof(v_ek->'sponsoravtal') = 'object' and public.personal_tal(v_ek->'sponsoravtal', 'veckorKvar', 0) > 0 then
    raise exception 'Du har redan ett aktivt sponsoravtal';
  end if;
  e := public.sponsor_erbjudande(public.lag_tier(v_lag), p_profil,
         coalesce(public.personal_tal(r.personal->'teamPrincipal'->'stats', 'sponsring', 50), 50));
  v_ek := v_ek || jsonb_build_object('sponsoravtal', jsonb_build_object(
    'sponsorNamn', v_namn, 'profil', p_profil, 'grundbelopp', e->'grundbelopp', 'pallBonus', e->'pallBonus',
    'vinstBonus', e->'vinstBonus', 'mastarskapsBonus', e->'mastarskapsBonus', 'veckorKvar', 10, 'langdTotalt', 10));
  update public.lag_tillstand set ekonomi = v_ek, version = version + 1, uppdaterad = now() where team_id = v_lag;
  return jsonb_build_object('ekonomi', v_ek);
end; $$;
revoke execute on function public.sponsor_teckna(text, text) from public, anon;
grant execute on function public.sponsor_teckna(text, text) to authenticated;

-- Efter varje race: kontraktsbonusar (kostnad), sponsorns pall-/vinstbonus
-- (intäkt) och förarnas popularitet. p_rader: [{ forarId, bil, placering, poang, dnf }].
create or replace function public.race_bonusar(p_team uuid, p_sasong int, p_race int, p_rader jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r public.lag_tillstand;
  v_nyckel text := p_sasong || '-' || p_race;
  rad jsonb;
  f jsonb;
  v_forare jsonb;
  a jsonb;
  v_plac int; v_poang numeric;
  v_kb bigint; v_sb bigint;
  v_pop numeric; v_delta int;
  v_summa bigint := 0;
begin
  select * into r from public.lag_tillstand where team_id = p_team for update;
  if not found or r.personal is null then return null; end if;
  if coalesce(r.ekonomi->>'senasteRace', '') = v_nyckel then return jsonb_build_object('redan', true); end if;
  v_forare := coalesce(r.personal->'forare', '[]'::jsonb);
  a := case when jsonb_typeof(r.ekonomi->'sponsoravtal') = 'object' and public.personal_tal(r.ekonomi->'sponsoravtal', 'veckorKvar', 0) > 0 then r.ekonomi->'sponsoravtal' else null end;
  for rad in select x from jsonb_array_elements(p_rader) x loop
    v_plac := public.personal_tal(rad, 'placering', 99)::int;
    v_poang := public.personal_tal(rad, 'poang', 0);
    select x into f from jsonb_array_elements(v_forare) x where x->>'id' = rad->>'forarId';
    if f is not null then
      v_kb := (case when v_plac <= 3 then public.personal_tal(f->'contract', 'podiumBonus', 0) else 0 end)
            + (case when v_plac = 1 then public.personal_tal(f->'contract', 'winBonus', 0) else 0 end)
            + (case when v_poang > 0 then round(public.personal_tal(f->'contract', 'pointsBonus', 0) * v_poang) else 0 end);
      if v_kb > 0 then
        insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
        values (p_team, 'kontraktsbonus', -v_kb, 'Kontraktsbonus: ' || coalesce(f->>'namn', ''), 'kbonus:' || v_nyckel || ':' || (rad->>'bil'))
        on conflict (team_id, nyckel) do nothing;
        if found then v_summa := v_summa - v_kb; end if;
      end if;
      v_delta := case when v_plac = 1 then 6 when v_plac <= 3 then 3 when v_plac <= 10 then 1 else -1 end;
      v_pop := public.personal_tal(f, 'popularitet', 45);
      v_pop := greatest(0, least(100, round(v_pop + v_delta + (45 - v_pop) * 0.04)));
      v_forare := (select jsonb_agg(case when x->>'id' = f->>'id' then x || jsonb_build_object('popularitet', v_pop::int) else x end)
                   from jsonb_array_elements(v_forare) x);
    end if;
    if a is not null and not coalesce((rad->>'dnf')::boolean, false) then
      v_sb := (case when v_plac <= 3 then public.personal_tal(a, 'pallBonus', 0) else 0 end)
            + (case when v_plac = 1 then public.personal_tal(a, 'vinstBonus', 0) else 0 end);
      if v_sb > 0 then
        insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
        values (p_team, 'sponsorbonus', v_sb, 'Sponsorbonus (' || coalesce(a->>'sponsorNamn', '') || ')', 'sbonus:' || v_nyckel || ':' || (rad->>'bil'))
        on conflict (team_id, nyckel) do nothing;
        if found then v_summa := v_summa + v_sb; end if;
      end if;
    end if;
  end loop;
  update public.lag_tillstand
  set personal = jsonb_set(personal, '{forare}', v_forare),
      ekonomi = coalesce(ekonomi, public.ekonomi_start()) || jsonb_build_object('senasteRace', v_nyckel),
      budget = budget + v_summa, version = version + 1, uppdaterad = now()
  where team_id = p_team;
  return jsonb_build_object('summa', v_summa);
end; $$;
revoke execute on function public.race_bonusar(uuid, int, int, jsonb) from public, anon, authenticated;
grant execute on function public.race_bonusar(uuid, int, int, jsonb) to service_role;

-- Säsongsslut: förarens mästerskapsbonus (bilen med flest poäng i
-- divisionen, kostnad) och sponsorns mästerskapsbonus (divisionsmästare).
create or replace function public.sasong_bonusar(p_team uuid, p_sasong int, p_bast_bil int, p_mastare boolean)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  r public.lag_tillstand;
  f jsonb;
  v_b bigint;
  v_summa bigint := 0;
begin
  select * into r from public.lag_tillstand where team_id = p_team for update;
  if not found or r.personal is null then return 0; end if;
  if p_bast_bil is not null then
    select x into f from jsonb_array_elements(coalesce(r.personal->'forare', '[]'::jsonb)) x where x->>'roll' = 'bil' || p_bast_bil;
    v_b := public.personal_tal(f->'contract', 'championshipBonus', 0)::bigint;
    if f is not null and v_b > 0 then
      insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
      values (p_team, 'kontraktsbonus', -v_b, 'Mästerskapsbonus: ' || coalesce(f->>'namn', ''), 'mbonus:' || p_sasong)
      on conflict (team_id, nyckel) do nothing;
      if found then v_summa := v_summa - v_b; end if;
    end if;
  end if;
  if p_mastare and jsonb_typeof(r.ekonomi->'sponsoravtal') = 'object' then
    v_b := public.personal_tal(r.ekonomi->'sponsoravtal', 'mastarskapsBonus', 0)::bigint;
    if v_b > 0 then
      insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
      values (p_team, 'sponsorbonus', v_b, 'Sponsorbonus – mästerskap', 'smbonus:' || p_sasong)
      on conflict (team_id, nyckel) do nothing;
      if found then v_summa := v_summa + v_b; end if;
    end if;
  end if;
  if v_summa <> 0 then
    update public.lag_tillstand set budget = budget + v_summa, version = version + 1, uppdaterad = now() where team_id = p_team;
  end if;
  return v_summa;
end; $$;
revoke execute on function public.sasong_bonusar(uuid, int, int, boolean) from public, anon, authenticated;
grant execute on function public.sasong_bonusar(uuid, int, int, boolean) to service_role;

-- kor-race sparar veckans ändringar i ett svep: personal, träning, ekonomi,
-- bokningar (idempotenta nycklar) och veckans ekonomirad – bara om laget
-- inte ändrats sedan det lästes.
create or replace function public.lag_server_spara(p_team uuid, p_version bigint, p_personal jsonb, p_traning jsonb,
                                                   p_ekonomi jsonb, p_bokningar jsonb, p_vecka jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  b jsonb;
  v_budget bigint;
begin
  update public.lag_tillstand set personal = p_personal, traning = p_traning, ekonomi = coalesce(p_ekonomi, ekonomi),
    version = version + 1, uppdaterad = now()
  where team_id = p_team and version = p_version;
  if not found then return false; end if;
  for b in select x from jsonb_array_elements(coalesce(p_bokningar, '[]'::jsonb)) x loop
    insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
    values (p_team, b->>'typ', (b->>'belopp')::bigint, left(b->>'text', 200), b->>'nyckel')
    on conflict (team_id, nyckel) do nothing;
    if found then update public.lag_tillstand set budget = budget + (b->>'belopp')::bigint where team_id = p_team; end if;
  end loop;
  if p_vecka is not null then
    select budget into v_budget from public.lag_tillstand where team_id = p_team;
    insert into public.ekonomi_vecka (team_id, vecka, sasong, rader, netto, budget_efter)
    values (p_team, (p_vecka->>'vecka')::int, (p_vecka->>'sasong')::int, p_vecka->'rader', (p_vecka->>'netto')::bigint, v_budget)
    on conflict (team_id, vecka) do nothing;
  end if;
  return true;
end; $$;
revoke execute on function public.lag_server_spara(uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.lag_server_spara(uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb) to service_role;

drop function if exists public.tillstand_alla();
create or replace function public.tillstand_alla()
returns table (team_id uuid, budget bigint, bil jsonb, personal jsonb, traning jsonb, version bigint, ekonomi jsonb, tier int)
language sql stable security definer set search_path = public as $$
  select lt.team_id, lt.budget, public.bil_tillampa_klara(lt.bil), lt.personal, lt.traning, lt.version, lt.ekonomi, public.lag_tier(lt.team_id)
  from public.lag_tillstand lt;
$$;
revoke execute on function public.tillstand_alla() from public, anon, authenticated;
grant execute on function public.tillstand_alla() to service_role;

create or replace function public.ekonomi_handelser(p_handelser jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  h jsonb;
  v_typ text;
  v_belopp bigint;
  v_tier int;
  v_tak bigint;
  v_budget bigint;
  v_avvisade jsonb := '[]'::jsonb;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  if jsonb_array_length(p_handelser) > 100 then raise exception 'För många händelser'; end if;
  select d.tier into v_tier from public.teams t join public.divisions d on d.id = t.division_id where t.id = v_lag;
  perform public.lag_tillstand_las(v_lag);
  for h in select * from jsonb_array_elements(p_handelser) loop
    v_typ := h->>'typ';
    v_belopp := (h->>'belopp')::bigint;
    if v_belopp is null or coalesce(h->>'nyckel', '') = '' then continue; end if;
    v_tak := case v_typ
      -- Veckans ekonomi: sponsor (max 1,3 × divisionens toppintäkt), merch, biljetter.
      -- Veckoekonomi och sponsorbonusar räknas av servern sedan Fas 3b-4.
      when 'managerlicens' then 100000
      when 'foregaende_klubb' then 5000000
      when 'konkurs' then 1000000
      else 0 end;
    if v_belopp > 0 and v_belopp > v_tak then
      v_avvisade := v_avvisade || jsonb_build_array(h->>'nyckel');
      continue;
    end if;
    if v_typ = 'konkurs' then
      select budget into v_budget from public.lag_tillstand where team_id = v_lag;
      if v_budget >= 0 then v_avvisade := v_avvisade || jsonb_build_array(h->>'nyckel'); continue; end if;
      v_belopp := least(1000000 - v_budget, 10000000);
    end if;
    insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
    values (v_lag, v_typ, v_belopp, left(h->>'text', 200), 'k:' || (h->>'nyckel'))
    on conflict (team_id, nyckel) do nothing;
    if found then
      update public.lag_tillstand set budget = budget + v_belopp, version = version + 1, uppdaterad = now() where team_id = v_lag;
    end if;
  end loop;
  select budget into v_budget from public.lag_tillstand where team_id = v_lag;
  return jsonb_build_object('budget', v_budget, 'avvisade', v_avvisade);
end; $$;
revoke execute on function public.ekonomi_handelser(jsonb) from public, anon;
grant execute on function public.ekonomi_handelser(jsonb) to authenticated;

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
        -- Popularitet (styr merchandise) ägs av servern; första gången högst 60.
        c := c || jsonb_build_object('popularitet', coalesce(
            case when jsonb_typeof(s->'popularitet') = 'number' then s->'popularitet' end,
            case when jsonb_typeof(bas->'popularitet') = 'number' then to_jsonb(least(100, greatest(0, (bas->>'popularitet')::numeric))::int) end,
            to_jsonb(least(60, greatest(0, public.personal_tal((select x from jsonb_array_elements(p_personal->v_lista) x where x->>'id' = c->>'id' limit 1), 'popularitet', 45)))::int)));
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



do $$ begin raise notice 'FAS 3B-4 klar'; end $$;
