// =====================================================================
// UNDERCUT RACING MANAGER – SERVERNS RACELOGIK (delad kod)
// ---------------------------------------------------------------------
// Ren logik för Edge Function kor-race: förbereder AI-lag, bygger
// säsongsschema och kör kval/lopp för en division. Ingen databaskod här
// (den ligger i supabase/functions/kor-race/index.ts), så att allt kan
// testas utan server. Kräver att spelmotor/race.js, varld.js och sasong.js är laddade.
// =====================================================================
(function (root) {
    'use strict';
    const R = root.URMRace, V = root.URMVarld;

    // Seedad slump per händelse, t.ex. "T2_1|3|7|kval".
    function rngFor(...delar) { return R.skapaRng(delar.join('|')); }

    // Gör om en teams-rad (id, name, is_ai, snapshot) till ett lagobjekt som
    // racemotorn förstår. lagId/namn tas alltid från databasen, inte från
    // ögonblicksbilden, så att resultaten pekar på rätt rad i teams.
    function lagFranRad(rad) {
        const s = rad.snapshot || {};
        return Object.assign({}, s, { lagId: rad.id, namn: rad.name, arSpelare: !rad.is_ai });
    }

    // AI-lag som saknar ögonblicksbild får ett helt genererat lag.
    // rader: teams-rader i EN division. anvandaLagNamn/anvandaArenaNamn:
    // Set med namn som redan används i hela världen (delas mellan anropen).
    // Returnerar [{ id, name, snapshot }] att spara.
    function forberedAiLag(division, rader, anvandaLagNamn, anvandaArenaNamn, nyttId) {
        const saknas = rader.filter(r => r.is_ai && !r.snapshot);
        if (!saknas.length) return [];
        const signaturer = new Set();
        const rng = rngFor(division.id, 'aivarld', saknas.map(r => r.id).join(','));
        if (nyttId) V.sattIdFunktion(nyttId);
        try {
            return V.medSlump(rng, () => saknas.map(r => {
                const lag = V.skapaLag(false, division.tier, V.slumpaLagBasNamn(anvandaLagNamn), division.kort, signaturer, anvandaArenaNamn);
                lag.stallNr = r.slot + 1;
                lag.lagId = r.id;
                delete lag.taktikKval; delete lag.taktikLopp;
                return { id: r.id, name: lag.namn, snapshot: lag };
            }));
        } finally {
            if (nyttId) V.sattIdFunktion(null);
        }
    }

    // Säsongsschema för en division: 10 race, varje lag med en hemmabana
    // arrangerar ett race (fler varv om färre än 10 lag har bana).
    function byggSchema(division, sasong, lagLista) {
        const medBana = lagLista.filter(l => l.bana);
        if (!medBana.length) return [];
        const rng = rngFor(division.id, sasong, 'schema');
        const ordning = medBana.slice().sort((a, b) => String(a.lagId).localeCompare(String(b.lagId)));
        for (let i = ordning.length - 1; i > 0; i--) {
            const j = Math.floor(rng() * (i + 1));
            [ordning[i], ordning[j]] = [ordning[j], ordning[i]];
        }
        const schema = [];
        for (let i = 0; i < 10; i++) {
            const v = ordning[i % ordning.length];
            schema.push({ raceNr: i + 1, arrangorNamn: v.namn, arrangorLagId: v.lagId, banaNamn: v.bana, banaLangd: v.banaLangd, banaKurvor: v.banaKurvor });
        }
        return schema;
    }

    function banaFor(schema, raceNr) {
        const r = (schema || []).find(x => x.raceNr === raceNr);
        return r ? { banaNamn: r.banaNamn, banaLangd: r.banaLangd, banaKurvor: r.banaKurvor, arrangorNamn: r.arrangorNamn, arrangorLagId: r.arrangorLagId }
                 : { banaNamn: 'Okänd bana', banaLangd: 4.5, banaKurvor: 12 };
    }

    // order: Map teamId -> { kval, lopp } från lag_order.
    function sattTaktik(lagLista, order, bana, fas, rng) {
        lagLista.forEach(lag => {
            const o = order.get(lag.lagId);
            const egen = o && (fas === 'kval' ? o.kval : o.lopp);
            const taktik = lag.arSpelare ? (egen || R.standardTaktik(fas)) : R.slumpaTaktikVarden(bana, fas, rng);
            if (fas === 'kval') lag.taktikKval = taktik; else lag.taktikLopp = taktik;
        });
    }

    function korKval(division, sasong, raceNr, rader, order, schema) {
        const bana = banaFor(schema, raceNr);
        const lagLista = rader.map(lagFranRad);
        const rng = rngFor(division.id, sasong, raceNr, 'kval');
        sattTaktik(lagLista, order, bana, 'kval', rng);
        const kval = R.simuleraKval(lagLista, bana, rng, sasong + '-' + raceNr).map(e => ({
            lagId: e.lagId, lagNamn: e.lagNamn, arSpelare: e.arSpelare, stallNr: e.stallNr, bil: e.bil,
            forarId: e.forarId, forarNamn: e.forarNamn, startPos: e.startPos,
            kvalPoäng: Math.round(e.kvalPoäng * 10) / 10, procent: Math.round(e.procent * 100)
        }));
        return { bana, kval };
    }

    function korLopp(division, sasong, raceNr, rader, order, bana, kval) {
        const lagLista = rader.map(lagFranRad);
        const rng = rngFor(division.id, sasong, raceNr, 'lopp');
        sattTaktik(lagLista, order, bana, 'lopp', rng);
        const perId = new Map(lagLista.map(l => [l.lagId, l]));
        return R.simuleraLopp(kval, rad => perId.get(rad.lagId), bana, rng, sasong + '-' + raceNr).map(r => ({
            lagId: r.lagId, lagNamn: r.lagNamn, bil: r.bil, forarId: r.forarId, forarNamn: r.forarNamn,
            startPos: r.startPos, placering: r.placering, poäng: r.poäng, dnf: r.dnf, dnfOrsak: r.dnfOrsak,
            snabbasteVarv: !!r.snabbasteVarv, procent: r.procent, strategi: r.strategi, depaTid: r.depaTid,
            bransleVald: r.bransleVald, bransleRek: r.bransleRek, bransleProcent: r.bransleProcent, bransleStatus: r.bransleStatus
        }));
    }

    // Säsongsskifte. divisioner: [{ id, tier, parent_id }], lagRader: teams-rader
    // (id, division_id, slot, name, is_ai), tabell: serietabell-rader för
    // säsongen (team_id, poang, poang_bil1, poang_bil2). Returnerar nya platser
    // för ALLA lag + historik per division (sluttabell och flyttar).
    function sasongsskifte(divisioner, lagRader, tabell) {
        const defs = {};
        divisioner.forEach(d => { defs[d.id] = { tier: d.tier, parent: d.parent_id || null, children: [] }; });
        divisioner.forEach(d => { if (d.parent_id && defs[d.parent_id]) defs[d.parent_id].children.push(d.id); });
        Object.keys(defs).forEach(id => defs[id].children.sort());
        const poang = new Map(tabell.map(r => [r.team_id, r]));
        const tabeller = {};
        Object.keys(defs).forEach(id => {
            tabeller[id] = lagRader.filter(t => t.division_id === id).sort((a, b) => a.slot - b.slot).map(t => {
                const p = poang.get(t.id);
                return { lagId: t.id, namn: t.name, slot: t.slot, arManniska: !t.is_ai,
                    poäng: p ? p.poang : 0, poängBil1: p ? p.poang_bil1 : 0, poängBil2: p ? p.poang_bil2 : 0 };
            });
        });
        const { flyttar, sorted } = root.URMSasong.beraknaFlyttar(defs, tabeller, 3);
        const flyttadeUt = new Map(flyttar.map(f => [f.lag.lagId, f]));
        const placeringar = [];
        Object.keys(defs).forEach(id => {
            const kvar = tabeller[id].filter(l => !flyttadeUt.has(l.lagId));
            const upptagna = new Set(kvar.map(l => l.slot));
            kvar.forEach(l => placeringar.push({ id: l.lagId, division_id: id, slot: l.slot }));
            const in_ = flyttar.filter(f => f.till === id).map(f => f.lag);
            let slot = 0;
            in_.forEach(l => {
                while (upptagna.has(slot)) slot++;
                upptagna.add(slot);
                placeringar.push({ id: l.lagId, division_id: id, slot: slot });
            });
        });
        const historik = Object.keys(defs).map(id => ({
            division_id: id,
            tabell: sorted[id].map((l, i) => ({ placering: i + 1, team_id: l.lagId, namn: l.namn, manniska: l.arManniska, poang: l.poäng, poang_bil1: l.poängBil1, poang_bil2: l.poängBil2 })),
            flyttar: flyttar.filter(f => f.fran === id).map(f => ({ team_id: f.lag.lagId, namn: f.lag.namn, till: f.till, typ: f.typ }))
        }));
        return { placeringar, historik, antalFlyttar: flyttar.length };
    }

    // ---------------------------------------------------------------
    // Ekonomi och skador (Fas 3b). Samma formler som i b5_1-3.html.
    // ---------------------------------------------------------------
    const DIVISION_INTAKT_RANGES = { 1: [600000, 1000000], 2: [350000, 700000], 3: [150000, 400000], 4: [50000, 200000], 5: [25000, 120000] };
    const KOMPONENT_NYCKLAR = ['dack', 'motor', 'aero', 'vaxellada', 'chassi'];
    function prisPerPoang(tier) {
        const r = DIVISION_INTAKT_RANGES[tier] || DIVISION_INTAKT_RANGES[4];
        return Math.round(r[1] * 0.005 / 100) * 100;
    }
    function slutplaceringsBonus(tier, placering, antalLag) {
        const r = DIVISION_INTAKT_RANGES[tier] || DIVISION_INTAKT_RANGES[4];
        const topp = r[1] * 4, botten = r[1] * 0.6;
        const andel = antalLag > 1 ? (antalLag - placering) / (antalLag - 1) : 1;
        return Math.round((botten + (topp - botten) * andel) / 10000) * 10000;
    }
    function tavlingsregelAttribut(sasong) {
        const n = KOMPONENT_NYCKLAR.length;
        return KOMPONENT_NYCKLAR[((sasong - 1) % n + n) % n];
    }
    // 0–3 bilar skadas per race, aggressiva förare oftare (som tillampaSkador).
    function valjSkador(lagLista, rng) {
        const antal = Math.floor(rng() * 4);
        const pool = [];
        lagLista.forEach(lag => [1, 2].forEach(bilNr => { if (R.forarForBil(lag, bilNr)) pool.push({ lag, bilNr }); }));
        const valda = [];
        for (let n = 0; n < antal && pool.length > 0; n++) {
            const vikter = pool.map(k => { const f = R.forarForBil(k.lag, k.bilNr); return (f && R.SKADE_VIKT_STIL[f.style]) || 1; });
            let slump = rng() * vikter.reduce((s, v) => s + v, 0);
            let idx = 0;
            for (; idx < vikter.length; idx++) { slump -= vikter[idx]; if (slump <= 0) break; }
            if (idx >= pool.length) idx = pool.length - 1;
            valda.push(pool[idx]);
            pool.splice(idx, 1);
        }
        return valda.map(v => {
            const komponent = KOMPONENT_NYCKLAR[Math.floor(rng() * KOMPONENT_NYCKLAR.length)];
            const andelSkada = 0.10 + rng() * 0.60;
            const nuvarande = (R.bilParts(v.lag, v.bilNr) || {})[komponent] || 0;
            const f = R.forarForBil(v.lag, v.bilNr);
            return { lagId: v.lag.lagId, lagNamn: v.lag.namn, bilNr: v.bilNr, komponent, andelSkada,
                nyttVarde: Math.max(0, Math.round(nuvarande * (1 - andelSkada))), forareNamn: f ? f.namn : null, forarId: f ? f.id : null };
        });
    }

    // Mänskliga lags personal ägs av servern (lag_tillstand.personal, Fas 3b-2).
    // Ögonblicksbildens personer ersätts av serverns: bara godkända personer
    // kör, med serverns förmågor, roller, kontrakt och skador. Övriga fält
    // (avatar, karriär m.m.) behålls från ögonblicksbilden.
    function personalForRace(snapshot, personal) {
        const s = snapshot || {};
        if (!personal) return s;
        const ut = Object.assign({}, s);
        ['forare', 'mekanikerLista', 'ingenjorLista'].forEach(k => {
            const egna = new Map((s[k] || []).map(p => [p && p.id, p]));
            ut[k] = (personal[k] || []).map(p => {
                const kopia = Object.assign({}, egna.get(p.id) || {}, p);
                delete kopia._v0; delete kopia._anv; delete kopia._s;
                return kopia;
            });
        });
        ut.teamPrincipal = personal.teamPrincipal ? Object.assign({}, s.teamPrincipal || {}, personal.teamPrincipal) : null;
        ut.chefMekanikerId = personal.chefMekanikerId || null;
        ut.chefIngenjorId = personal.chefIngenjorId || null;
        return ut;
    }


    // ---------------------------------------------------------------------
    // Träning och utveckling (Fas 3b-3). Samma regler som spelet:
    // korTraningsrace(), tillampaVantandePersonalTraning() och aldrasAlla().
    // ---------------------------------------------------------------------
    const PERSONAL_LISTOR = [['forare', 'forare'], ['mekanikerLista', 'mekaniker'], ['ingenjorLista', 'ingenjor']];
    function statNycklar(kat) {
        return kat === 'forare' ? V.DRIVARE_STAT_KEYS : (kat === 'mekaniker' ? V.MEK_STAT_KEYS : V.ING_STAT_KEYS);
    }
    function kopiaPersonal(personal) { return JSON.parse(JSON.stringify(personal || {})); }

    // val: [{ id, kat, attribut }]. Förarna förbättras direkt, personalen
    // får en väntande förbättring som slår igenom vid veckouppdateringen.
    function traningsvecka(personal, val, rng) {
        const ny = kopiaPersonal(personal);
        const resultat = [];
        (val || []).forEach(v => {
            const nyckel = (PERSONAL_LISTOR.find(x => x[1] === v.kat) || [])[0];
            const p = nyckel && (ny[nyckel] || []).find(x => x.id === v.id);
            if (!p || !p.stats || v.attribut === 'erfarenhet' || statNycklar(v.kat).indexOf(v.attribut) < 0) return;
            const prest = R.simuleraForarPrestation(p, rng);
            const forbattring = Math.max(1, Math.min(5, Math.round(1 + prest.procent * 4)));
            if (v.kat === 'forare') {
                p.stats[v.attribut] = Math.min(100, (p.stats[v.attribut] || 0) + forbattring);
                p.formaga = V.beraknaFormaga(p.stats, statNycklar(v.kat));
            } else {
                p.vantandeTraning = { attribut: v.attribut, forbattring: forbattring, procent: prest.procent };
            }
            resultat.push({ id: p.id, namn: p.namn, typ: v.kat, attribut: v.attribut, procent: Math.round(prest.procent * 100),
                procentExakt: prest.procent, forbattring: forbattring, vantande: v.kat !== 'forare', nyttVarde: p.stats[v.attribut] });
        });
        resultat.sort((a, b) => b.procent - a.procent);
        resultat.forEach((r, i) => { r.placering = i + 1; });
        return { personal: ny, resultat };
    }

    // Söndagens uppdatering: personalens väntande träning slår igenom.
    function veckouppdateringPersonal(personal) {
        const ny = kopiaPersonal(personal);
        let antal = 0;
        [['mekanikerLista', 'mekaniker'], ['ingenjorLista', 'ingenjor']].forEach(([nyckel, kat]) => {
            (ny[nyckel] || []).forEach(p => {
                const vt = p.vantandeTraning;
                if (!vt) return;
                if (p.stats && vt.attribut) {
                    p.stats[vt.attribut] = Math.min(100, (p.stats[vt.attribut] || 0) + vt.forbattring);
                    p.formaga = V.beraknaFormaga(p.stats, statNycklar(kat));
                    antal++;
                }
                delete p.vantandeTraning;
            });
        });
        // Team Principal: +1 i varje förmåga per vecka (utvecklaTeamPrincipal()).
        const tp = ny.teamPrincipal;
        if (tp && tp.stats) {
            V.PRINCIPAL_STAT_KEYS.forEach(k => { tp.stats[k] = Math.min(100, (tp.stats[k] || 0) + 1); });
            tp.formaga = Math.round(V.PRINCIPAL_STAT_KEYS.reduce((sum, k) => sum + tp.stats[k], 0) / V.PRINCIPAL_STAT_KEYS.length);
        }
        return { personal: ny, antal };
    }

    // ---------------------------------------------------------------------
    // Veckoekonomin (Fas 3b-4), samma regler som korEkonomiUppdatering():
    // sponsor (avtal eller slump), merchandise (slump × förarnas popularitet),
    // biljetter (arenakapacitet × 700), löner, underhåll och ränta på minussaldo.
    // ---------------------------------------------------------------------
    const DIVISION_INTAKT = { 1: [600000, 1000000], 2: [350000, 700000], 3: [150000, 400000], 4: [50000, 200000], 5: [25000, 120000] };
    function slumpaIntakt(tier, rng) {
        const r = DIVISION_INTAKT[tier] || DIVISION_INTAKT[4];
        return Math.min(1000000, Math.round((r[0] + rng() * (r[1] - r[0])) / 1000) * 1000);
    }
    function veckoLon(p) {
        const c = p && p.contract;
        return Math.round(((c && typeof c.salaryPerSeason === 'number') ? c.salaryPerSeason : 1000000) / 10);
    }
    function veckoekonomi(personal, ekonomi, tier, budget, rng) {
        const ek = Object.assign({ arenaNiva: 1, arenaKapacitet: 5000, sponsoravtal: null }, JSON.parse(JSON.stringify(ekonomi || {})));
        const avtal = ek.sponsoravtal && ek.sponsoravtal.veckorKvar > 0 ? ek.sponsoravtal : null;
        const sponsor = avtal ? avtal.grundbelopp : Math.round(slumpaIntakt(tier, rng) * 1.3);
        let merch = slumpaIntakt(tier, rng);
        const p = personal || {};
        const bilForare = [1, 2].map(n => (p.forare || []).find(f => f.roll === 'bil' + n)).filter(Boolean);
        if (bilForare.length) {
            const snittPop = bilForare.reduce((sum, f) => sum + (typeof f.popularitet === 'number' ? f.popularitet : 50), 0) / bilForare.length;
            merch = Math.min(1000000, Math.round(merch * (0.4 + (snittPop / 100) * 0.8)));
        }
        const biljett = (ek.arenaKapacitet || 5000) * 700;
        const summa = lista => (lista || []).reduce((sum, x) => sum + veckoLon(x), 0);
        const forarLon = summa(p.forare), mekLon = summa(p.mekanikerLista), ingLon = summa(p.ingenjorLista);
        const principalLon = p.teamPrincipal ? veckoLon(p.teamPrincipal) : 0;
        const underhall = 30000;
        const minusRanta = budget < 0 ? Math.round(Math.abs(budget) * 0.05) : 0;
        const rader = [
            { typ: 'sponsor', belopp: sponsor, text: avtal ? 'Sponsorintäkt (' + avtal.sponsorNamn + ')' : 'Sponsorintäkt' },
            { typ: 'merch', belopp: merch, text: 'Merchandiseförsäljning' },
            { typ: 'biljett', belopp: biljett, text: 'Biljettintäkter' },
            { typ: 'underhall', belopp: -underhall, text: 'Fabriksunderhåll' },
            { typ: 'forarLon', belopp: -forarLon, text: 'Förarlöner' },
            { typ: 'mekLon', belopp: -mekLon, text: 'Mekanikerlöner' },
            { typ: 'ingLon', belopp: -ingLon, text: 'Ingenjörslöner' },
            { typ: 'principalLon', belopp: -principalLon, text: 'Team Principal-lön' },
            { typ: 'minusRanta', belopp: -minusRanta, text: 'Ränta på minussaldo' }
        ];
        let utgatt = null;
        if (avtal) {
            avtal.veckorKvar -= 1;
            if (avtal.veckorKvar <= 0) { utgatt = avtal.sponsorNamn; ek.sponsoravtal = null; }
        }
        return { ekonomi: ek, rader, netto: rader.reduce((sum, r) => sum + r.belopp, 0), sponsorNamn: avtal ? avtal.sponsorNamn : null, utgatt };
    }


    // Ny säsong: alla blir ett år äldre (+5 erfarenhet), förare över 30 tappar
    // lite i övriga förmågor, och den som nått pensionsåldern lämnar laget.
    const FORARE_PENSIONSALDER = 40, STAB_MAXALDER = 60, PRINCIPAL_PENSIONSALDER = 60, FORARE_NEDGANG_START = 30;
    const DRIVARE_NEDGANG_KEYS = ['snabbhet', 'dackhantering', 'forsvar', 'lagformaga'];
    function aldrasPersonal(personal, rng) {
        const ny = kopiaPersonal(personal);
        const pension = [];
        PERSONAL_LISTOR.forEach(([nyckel, kat]) => {
            ny[nyckel] = (ny[nyckel] || []).filter(p => {
                if (p.age !== undefined && p.age !== null) p.age += 1;
                if (p.stats) {
                    p.stats.erfarenhet = Math.min(100, (p.stats.erfarenhet || 0) + 5);
                    if (kat === 'forare' && p.age > FORARE_NEDGANG_START) {
                        const arOver = p.age - FORARE_NEDGANG_START;
                        DRIVARE_NEDGANG_KEYS.forEach(k => {
                            const maxNedgang = 1 + Math.min(5, Math.floor(arOver / 2));
                            const nedgang = 1 + Math.floor(rng() * maxNedgang);
                            p.stats[k] = Math.max(0, (p.stats[k] || 0) - nedgang);
                        });
                    }
                    p.formaga = V.beraknaFormaga(p.stats, statNycklar(kat));
                }
                const grans = kat === 'forare' ? FORARE_PENSIONSALDER : STAB_MAXALDER;
                if (p.age !== undefined && p.age >= grans) { pension.push({ id: p.id, namn: p.namn, kat }); return false; }
                return true;
            });
        });
        if (ny.chefMekanikerId && !(ny.mekanikerLista || []).some(p => p.id === ny.chefMekanikerId)) delete ny.chefMekanikerId;
        if (ny.chefIngenjorId && !(ny.ingenjorLista || []).some(p => p.id === ny.chefIngenjorId)) delete ny.chefIngenjorId;
        const tp = ny.teamPrincipal;
        if (tp) {
            if (tp.age !== undefined && tp.age !== null) tp.age += 1;
            if (tp.age >= PRINCIPAL_PENSIONSALDER) { pension.push({ id: tp.id, namn: tp.namn, kat: 'principal' }); ny.teamPrincipal = null; }
        }
        if (pension.length) {
            const borttagna = pension.map(x => Object.assign({ pension: true }, x));
            ny.borttagna = borttagna.concat(ny.borttagna || []).slice(0, 30);
        }
        return { personal: ny, pension };
    }

    root.URMServer = Object.freeze({ rngFor, lagFranRad, forberedAiLag, byggSchema, banaFor, korKval, korLopp, sasongsskifte,
        prisPerPoang, slutplaceringsBonus, tavlingsregelAttribut, valjSkador, personalForRace,
        traningsvecka, veckouppdateringPersonal, aldrasPersonal, veckoekonomi });
})(typeof globalThis !== 'undefined' ? globalThis : this);
