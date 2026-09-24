
-- =====================================================================
-- FAS 3B-5: JUNIORPROGRAM, MANAGERLICENS OCH SERVERNS LAGBILD
--  * scouta(): ett nytt juniorprospekt per vecka (söndag 20:00), max 5,
--    500 000 kr. Prospekten ligger i lag_tillstand.personal.juniorprogram,
--    tränar +1/vecka och åldras på servern; vid 20 år kan de skrivas.
--  * managerlicens_hamta(): 100 000 kr per uppdrag, en gång, kontrollerat
--    mot serverns data där det går.
--  * Klienten får inte längre rapportera några intäkter alls.
--  * publicera_lag(): personal och bil i lagbilden kommer från servern.
-- =====================================================================
create or replace function public.scouta(p_person jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  r public.lag_tillstand;
  v_vecka int := public.personal_vecka(now() + interval '4 hours'); -- nytt samtal från söndag 20:00
  v_r numeric := random() * 100;
  v_age int;
  j jsonb;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  r := public.lag_tillstand_las(v_lag);
  if r.personal is null then raise exception 'Laget är inte synkat med servern än – försök igen om en stund'; end if;
  if public.personal_tal(r.personal, 'scoutVecka', -1) >= v_vecka then raise exception 'Du kan bara ringa dina scouter en gång i veckan'; end if;
  if jsonb_array_length(coalesce(r.personal->'juniorprogram', '[]'::jsonb)) >= 5 then raise exception 'Juniorprogrammet är fullt'; end if;
  if r.budget < 500000 then raise exception 'Inte tillräckligt med pengar'; end if;
  v_age := case when v_r < 8 then 15 when v_r < 31 then 16 when v_r < 54 then 17 when v_r < 77 then 18 else 19 end;
  j := jsonb_build_object('id', 'j' || replace(gen_random_uuid()::text, '-', ''), 'age', v_age,
         'namn', left(coalesce(p_person->>'namn', 'Junior'), 60), 'nationalitet', left(coalesce(p_person->>'nationalitet', ''), 40),
         'style', case when p_person->>'style' in ('Aggressiv', 'Balanserad', 'Defensiv') then p_person->>'style' else 'Balanserad' end,
         'stats', public.personal_basstats('forare', v_age), 'formaga', public.personal_formaga('forare', public.personal_basstats('forare', v_age)),
         'scoutadDatum', now(), 'traningsval', null);
  update public.lag_tillstand
  set personal = personal || jsonb_build_object('juniorprogram', coalesce(personal->'juniorprogram', '[]'::jsonb) || jsonb_build_array(j), 'scoutVecka', v_vecka),
      budget = budget - 500000, version = version + 1, uppdaterad = now()
  where team_id = v_lag returning * into r;
  insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
  values (v_lag, 'scouting', -500000, 'Scouting: nytt juniorprospekt', 'scout:' || v_vecka);
  return jsonb_build_object('budget', r.budget, 'junior', j, 'juniorprogram', r.personal->'juniorprogram');
end; $$;
revoke execute on function public.scouta(jsonb) from public, anon;
grant execute on function public.scouta(jsonb) to authenticated;

create or replace function public.managerlicens_hamta(p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  r public.lag_tillstand;
  v_klar boolean;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  r := public.lag_tillstand_las(v_lag);
  v_klar := case p_id
    when 'lagnamn' then true
    when 'arenanamn' then true
    when 'mekaniker' then jsonb_array_length(coalesce(r.personal->'mekanikerLista', '[]'::jsonb)) >= 1
    when 'ingenjor' then jsonb_array_length(coalesce(r.personal->'ingenjorLista', '[]'::jsonb)) >= 1
    when 'taktik' then exists (select 1 from public.lag_order o where o.team_id = v_lag)
    when 'uppgradering' then exists (select 1 from public.lag_transaktioner t where t.team_id = v_lag and t.nyckel like 'upp:%')
    when 'forsta_race' then exists (select 1 from public.race_resultat rr where rr.lopp @> jsonb_build_array(jsonb_build_object('lagId', v_lag)))
    when 'forsta_vinst' then exists (select 1 from public.race_resultat rr where rr.lopp @> jsonb_build_array(jsonb_build_object('lagId', v_lag, 'placering', 1)))
    when 'sponsoravtal' then jsonb_typeof(r.ekonomi->'sponsoravtal') = 'object'
                             or exists (select 1 from public.ekonomi_vecka e where e.team_id = v_lag and e.rader->>'sponsorNamn' is not null)
    when 'transfer' then exists (select 1 from public.leveranser l where l.team_id = v_lag and l.typ in ('kopt', 'salt', 'frikopt'))
                         or exists (select 1 from public.personal_ursprung u where u.team_id = v_lag)
    when 'varvaanvandare' then exists (select 1 from public.referrals f where f.referrer_id = auth.uid() and f.inlost)
    else null end;
  if v_klar is null then raise exception 'Okänt uppdrag'; end if;
  if not v_klar then raise exception 'Uppdraget är inte löst än'; end if;
  insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
  values (v_lag, 'managerlicens', 100000, 'Managerlicens: ' || p_id, 'ml:' || p_id)
  on conflict (team_id, nyckel) do nothing;
  if found then
    update public.lag_tillstand set budget = budget + 100000, version = version + 1, uppdaterad = now() where team_id = v_lag returning * into r;
  end if;
  return jsonb_build_object('budget', r.budget, 'utbetald', found);
end; $$;
revoke execute on function public.managerlicens_hamta(text) from public, anon;
grant execute on function public.managerlicens_hamta(text) to authenticated;

-- Klientens ekonomihändelser: bara kostnader. Alla intäkter räknas av servern.
create or replace function public.ekonomi_handelser(p_handelser jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  h jsonb;
  v_belopp bigint;
  v_budget bigint;
  v_avvisade jsonb := '[]'::jsonb;
begin
  if v_lag is null then raise exception 'Du har ingen plats i pyramiden'; end if;
  if jsonb_array_length(p_handelser) > 100 then raise exception 'För många händelser'; end if;
  perform public.lag_tillstand_las(v_lag);
  for h in select * from jsonb_array_elements(p_handelser) loop
    v_belopp := (h->>'belopp')::bigint;
    if v_belopp is null or coalesce(h->>'nyckel', '') = '' then continue; end if;
    if v_belopp >= 0 then
      v_avvisade := v_avvisade || jsonb_build_array(h->>'nyckel');
      continue;
    end if;
    insert into public.lag_transaktioner (team_id, typ, belopp, text, nyckel)
    values (v_lag, left(coalesce(h->>'typ', 'kostnad'), 40), v_belopp, left(h->>'text', 200), 'k:' || (h->>'nyckel'))
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

-- Lagbilden som andra ser: personal och bil kommer från servern, övrigt
-- (namn, färger, karriär, avatarer m.m.) från klienten.
create or replace function public.personal_i_snapshot(p_snapshot jsonb, p_personal jsonb, p_bil jsonb)
returns jsonb language plpgsql stable as $$
declare
  s jsonb := coalesce(p_snapshot, '{}'::jsonb);
  k text;
begin
  if p_personal is not null then
    foreach k in array array['forare', 'mekanikerLista', 'ingenjorLista'] loop
      s := jsonb_set(s, array[k], coalesce((
        select jsonb_agg(coalesce((select x from jsonb_array_elements(coalesce(p_snapshot->k, '[]'::jsonb)) x where x->>'id' = sp->>'id' limit 1), '{}'::jsonb)
                         || (sp - '_v0' - '_anv' - '_s'))
        from jsonb_array_elements(coalesce(p_personal->k, '[]'::jsonb)) sp), '[]'::jsonb));
    end loop;
    s := s || jsonb_build_object(
      'teamPrincipal', case when jsonb_typeof(p_personal->'teamPrincipal') = 'object'
                            then coalesce(case when jsonb_typeof(p_snapshot->'teamPrincipal') = 'object' then p_snapshot->'teamPrincipal' end, '{}'::jsonb)
                                 || ((p_personal->'teamPrincipal') - '_v0' - '_anv' - '_s')
                            else 'null'::jsonb end,
      'chefMekanikerId', coalesce(p_personal->'chefMekanikerId', 'null'::jsonb),
      'chefIngenjorId', coalesce(p_personal->'chefIngenjorId', 'null'::jsonb));
  end if;
  if p_bil is not null then
    s := s || (select coalesce(jsonb_object_agg(k2, v), '{}'::jsonb) from jsonb_each(public.bil_tillampa_klara(p_bil)) e(k2, v));
  end if;
  return s;
end; $$;

create or replace function public.publicera_lag(p_snapshot jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_lag uuid := public.mitt_lag();
  lt public.lag_tillstand;
begin
  if auth.uid() is null then raise exception 'Inte inloggad'; end if;
  if pg_column_size(p_snapshot) > 2000000 then raise exception 'Lagdata för stor'; end if;
  select * into lt from public.lag_tillstand where team_id = v_lag;
  update public.teams
  set snapshot = case when lt.team_id is null then p_snapshot else public.personal_i_snapshot(p_snapshot, lt.personal, lt.bil) end,
      snapshot_at = now(),
      name = coalesce(nullif(left(p_snapshot->>'namn', 60), ''), name)
  where user_id = auth.uid();
end; $$;
revoke execute on function public.publicera_lag(jsonb) from public, anon;
grant execute on function public.publicera_lag(jsonb) to authenticated;

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
  v_jun jsonb;
  v_jkl jsonb := case when jsonb_typeof(p_personal->'juniorprogram') = 'array' then p_personal->'juniorprogram' else '[]'::jsonb end;
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
        -- Junior från serverns juniorprogram som fyllt 20 år.
        if bas is null and v_kat = 'forare' and not v_start then
          select j into bas from jsonb_array_elements(coalesce(v_gammal->'juniorprogram', '[]'::jsonb)) j
          where j->>'id' = c->>'id' and public.personal_tal(j, 'age', 0) >= 20;
          if bas is not null then v_ursprung := 'junior'; end if;
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
        g := public.personal_granska_stats(v_kat, c->'stats',
               case when v_ursprung = 'junior' then bas->'stats' else public.personal_stats_fran_marknad(v_kat, bas) end, v_age, 0, 0);
        ut := jsonb_build_object('_v0', v_vecka - 1, '_anv', (g->>'anvant')::int, '_s', v_sasong,
                                 'kontrakt', public.personal_granska_kontrakt(v_kat, c->'contract', coalesce(bas->'kontrakt', bas->'contract'), public.personal_formaga(v_kat, g->'stats'), v_tier),
                                 'skadadTillRace', null, 'style', coalesce(bas->'style', c->'style'));
      else
        -- Nyrekryt: basnivå (juniorer kommer numera från serverns juniorprogram).
        g := public.personal_granska_stats(v_kat, c->'stats', public.personal_basstats(v_kat, v_age), v_age,
                                           case when v_start then 5 * (v_junior + 2) else 0 end,
                                           case when v_start then 5 * (v_junior + 2) else 0 end);
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

  -- Juniorprogrammet ägs av servern: klienten kan släppa prospekt och välja
  -- träning, men inte lägga till några (det görs med scouta()). Första gången
  -- godtas klientens prospekt på basnivå.
  if not v_start and v_gammal ? 'juniorprogram' then
    select coalesce(jsonb_agg(
             coalesce((select jsonb_object_agg(k, v) from jsonb_each(m.cj) e(k, v)
                       where k in ('namn', 'nationalitet', 'style', 'scoutadDatum', 'avatarId', 'avatarSeed', 'avatarTraits', 'avatarSignature', 'avatarVersion')), '{}'::jsonb)
             || (sj - 'traningsval')
             || jsonb_build_object('traningsval', case when m.cj->>'traningsval' in ('snabbhet', 'dackhantering', 'forsvar', 'lagformaga') then to_jsonb(m.cj->>'traningsval') else 'null'::jsonb end)), '[]'::jsonb)
    into v_jun
    from jsonb_array_elements(v_gammal->'juniorprogram') sj
    join lateral (select x as cj from jsonb_array_elements(v_jkl) x where x->>'id' = sj->>'id' limit 1) m on true
    where not (sj->>'id' = any(v_sedda));
  else
    select coalesce(jsonb_agg(
             coalesce((select jsonb_object_agg(k, v) from jsonb_each(x) e(k, v)
                       where k in ('namn', 'nationalitet', 'style', 'scoutadDatum', 'avatarId', 'avatarSeed', 'avatarTraits', 'avatarSignature', 'avatarVersion')), '{}'::jsonb)
             || jsonb_build_object('id', x->>'id', 'age', a.age,
                                   'stats', public.personal_basstats('forare', a.age),
                                   'formaga', public.personal_formaga('forare', public.personal_basstats('forare', a.age)),
                                   'traningsval', case when x->>'traningsval' in ('snabbhet', 'dackhantering', 'forsvar', 'lagformaga') then to_jsonb(x->>'traningsval') else 'null'::jsonb end)), '[]'::jsonb)
    into v_jun
    from (select x from jsonb_array_elements(v_jkl) x where coalesce(x->>'id', '') <> '' and not (x->>'id' = any(v_sedda)) limit 5) y
    cross join lateral (select greatest(15, least(19, public.personal_tal(x, 'age', 17)::int)) as age) a;
  end if;
  v_ny := v_ny || jsonb_build_object('juniorprogram', v_jun, 'scoutVecka', coalesce(v_gammal->'scoutVecka', 'null'::jsonb));

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

do $$ begin raise notice 'FAS 3B-5 klar'; end $$;
