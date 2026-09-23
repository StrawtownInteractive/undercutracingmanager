// =====================================================================
// UNDERCUT RACING MANAGER – SERVERNS RACELOGIK (delad kod)
// ---------------------------------------------------------------------
// Ren logik för Edge Function kor-race: förbereder AI-lag, bygger
// säsongsschema och kör kval/lopp för en division. Ingen databaskod här
// (den ligger i supabase/functions/kor-race/index.ts), så att allt kan
// testas utan server. Kräver att spelmotor/race.js och varld.js är laddade.
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
            bransleProcent: r.bransleProcent, bransleStatus: r.bransleStatus
        }));
    }

    root.URMServer = Object.freeze({ rngFor, lagFranRad, forberedAiLag, byggSchema, banaFor, korKval, korLopp });
})(typeof globalThis !== 'undefined' ? globalThis : this);
