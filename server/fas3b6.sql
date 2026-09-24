-- =====================================================================
-- FAS 3B-6: TEAM PRINCIPAL-STARTLÖN OCH PÅMINNELSEMAIL
--  * En helt ny Team Principal börjar på 10 000 kr/vecka (100 000 kr per
--    säsong à 10 veckor). Förlängda/förhandlade avtal följer lönegolvet.
--  * Påminnelsemail: konton som inte varit aktiva på 30 dagar får ett
--    mail i veckan tills de loggar in igen (Edge Function
--    skicka-paminnelser, schemalagd i fas2/cron_paminnelser.sql).
--    Kan stängas av under Mitt konto → Inställningar (mail_installningar.paminnelse).
-- Går att köra om.
-- =====================================================================
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
  -- Helt ny Team Principal (inget underlag) får börja på startlönen
  -- 100 000 kr/säsong = 10 000 kr/vecka; förlängningar följer lönegolvet.
  v_lon := greatest(public.personal_tal(c, 'salaryPerSeason', 0)::bigint,
                    case when p_kat = 'principal' and b is null then 100000
                         else public.personal_lonegolv(p_kat, p_formaga, p_tier) end);
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

alter table public.profiles
  add column if not exists senast_paminnelse timestamptz;

-- Konton som ska få en påminnelse nu: inaktiva i minst 30 dagar och inte
-- påminda den senaste veckan (6,5 dygn, så att ett schemalagt jobb som
-- körs varje timme alltid hamnar på samma veckodag).
create or replace function public.inaktiva_for_paminnelse(p_max int default 50)
returns table(id uuid, email text, username text, inaktiv_sedan timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.email, p.username, coalesce(p.last_active, p.created_at)
  from public.profiles p
  where not coalesce(p.disabled, false)
    and p.email is not null
    and coalesce(p.last_active, p.created_at) < now() - interval '30 days'
    and (p.senast_paminnelse is null or p.senast_paminnelse < now() - interval '6 days 12 hours')
    and coalesce(p.mail_installningar->>'paminnelse', 'true') <> 'false'
  order by coalesce(p.last_active, p.created_at)
  limit greatest(1, least(coalesce(p_max, 50), 500));
$$;
revoke execute on function public.inaktiva_for_paminnelse(int) from public, anon, authenticated;
grant execute on function public.inaktiva_for_paminnelse(int) to service_role;

do $$ begin raise notice 'FAS 3B-6 klar'; end $$;
