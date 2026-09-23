// =====================================================================
// UNDERCUT RACING MANAGER – RACEMOTOR (delad kod)
// ---------------------------------------------------------------------
// Samma fil körs i webbläsaren (<script src="spelmotor/race.js">) och på
// servern (Supabase Edge Function kor-race). Innehåller BARA ren
// beräkning: inga DOM-anrop, ingen spelarData, inga sidoeffekter.
// All slump går via en rng-funktion som skickas in:
//   - webbläsaren skickar Math.random
//   - servern skickar URMRace.skapaRng(seed), så att ett race kan
//     räknas om och kontrolleras i efterhand.
// Formlerna är flyttade oförändrade från b5_1-3.html.
// =====================================================================
(function (root) {
    'use strict';

    const VERSION = 1;

    // ---------------------------------------------------------------
    // Seedad slump (cyrb53-hash -> mulberry32)
    // ---------------------------------------------------------------
    function hashStrang(str) {
        let h1 = 0xdeadbeef, h2 = 0x41c6ce57;
        for (let i = 0; i < str.length; i++) {
            const ch = str.charCodeAt(i);
            h1 = Math.imul(h1 ^ ch, 2654435761);
            h2 = Math.imul(h2 ^ ch, 1597334677);
        }
        h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
        return h1 >>> 0;
    }
    function skapaRng(seed) {
        let a = hashStrang(String(seed));
        return function () {
            a = (a + 0x6D2B79F5) >>> 0;
            let t = a;
            t = Math.imul(t ^ (t >>> 15), t | 1);
            t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
    }

    // ---------------------------------------------------------------
    // Konstanter
    // ---------------------------------------------------------------
    const BRANSLE_LITER_PER_KM = 16;
    const BRANSLE_LITER_PER_KURVA = 1.5;
    const BRANSLE_MIN_REKOMMENDATION = 30;
    const BRANSLE_OVERVIKT_FAKTOR = 8;
    const BRANSLE_SPARKORNING_FAKTOR = 2.5;
    const BRANSLE_DNF_FAKTOR = 3.2;

    const DACK_ALTERNATIV = ['soft', 'medium', 'hard'];
    const DACK_EFFEKT = {
        soft: { kval: 1.6, loppBas: 0.9, loppSlitage: 1.8 },
        medium: { kval: 0, loppBas: 0, loppSlitage: 0 },
        hard: { kval: -1.3, loppBas: -0.4, loppSlitage: -1.1 }
    };
    const POANGSTABELL = [25, 18, 15, 12, 10, 8, 6, 4, 2, 1];
    const STRATEGIER = [
        { namn: '1-stopp Offensiv', riskFaktor: 1.3 },
        { namn: '2-stopp Balanserad', riskFaktor: 1.0 },
        { namn: '1-stopp Defensiv', riskFaktor: 0.8 }
    ];
    const SKADE_VIKT_STIL = { 'Aggressiv': 3, 'Balanserad': 1.5, 'Defensiv': 1 };
    const STANDARD_PARTS = { dack: 50, motor: 50, aero: 50, vaxellada: 50, chassi: 50 };

    // ---------------------------------------------------------------
    // Lagdata
    // ---------------------------------------------------------------
    function forarForBil(lag, bilNr) {
        return (lag.forare || []).find(f => f.roll === 'bil' + bilNr) || null;
    }
    function forarReserver(lag) {
        return (lag.forare || []).filter(f => f.roll === 'reserv');
    }
    // skadeNyckel = sasong + '-' + raceNr (samma format som f.skadadTillRace)
    function arForareSkadad(f, skadeNyckel) {
        return !!(f && f.skadadTillRace && f.skadadTillRace === skadeNyckel);
    }
    function forarForBilIRacet(lag, bilNr, skadeNyckel) {
        let f = forarForBil(lag, bilNr);
        if (f && arForareSkadad(f, skadeNyckel)) {
            let reserv = forarReserver(lag).find(r => !arForareSkadad(r, skadeNyckel));
            if (reserv) return reserv;
        }
        return f;
    }
    function bilParts(lag, bilNr) {
        return lag['parts' + bilNr] || STANDARD_PARTS;
    }
    function snittFormagaMedChef(lista, chefId) {
        if (!lista || lista.length === 0) return 10;
        let s = 0;
        lista.forEach(p => {
            let f = p.formaga || 0;
            if (chefId && p.id === chefId) f = Math.min(100, Math.round(f * 1.2));
            s += f;
        });
        return Math.round(s / lista.length);
    }
    function personalFormagaForBil(lag, bilNr) {
        let mek = (lag.mekanikerLista || []).filter(p => p.bil === bilNr && !p.extra);
        let ing = (lag.ingenjorLista || []).filter(p => p.bil === bilNr && !p.extra);
        return { mek: snittFormagaMedChef(mek, lag.chefMekanikerId), ing: snittFormagaMedChef(ing, lag.chefIngenjorId) };
    }

    // ---------------------------------------------------------------
    // Bränsle
    // ---------------------------------------------------------------
    function beraknaRekommenderatBransle(banaLangd, banaKurvor) {
        let langd = (banaLangd === undefined || banaLangd === null) ? 4.5 : banaLangd;
        let kurvor = (banaKurvor === undefined || banaKurvor === null) ? 12 : banaKurvor;
        let bas = langd * BRANSLE_LITER_PER_KM;
        let kurvTillagg = (kurvor - 12) * BRANSLE_LITER_PER_KURVA;
        return Math.max(BRANSLE_MIN_REKOMMENDATION, Math.round(bas + kurvTillagg));
    }
    function hamtaBransleForLag(lag, bransleRek) {
        let v = (lag && lag.taktikLopp) ? lag.taktikLopp.bransle : undefined;
        return (v === undefined || v === null || v <= 0) ? bransleRek : v;
    }
    function beraknaBransleEffekt(bransleVald, bransleRek) {
        let rek = bransleRek > 0 ? bransleRek : 1;
        let vald = (bransleVald === undefined || bransleVald === null || bransleVald <= 0) ? rek : bransleVald;
        let overskott = Math.max(0, vald - rek) / rek;
        let brist = Math.max(0, rek - vald) / rek;
        let overviktStraff = overskott * BRANSLE_OVERVIKT_FAKTOR;
        let sparStraff = brist * BRANSLE_SPARKORNING_FAKTOR;
        let dnfTillagg = Math.min(0.9, brist * brist * BRANSLE_DNF_FAKTOR);
        let status = overskott > 0.02 ? 'over' : (brist > 0.02 ? 'under' : 'optimal');
        return {
            vald: vald, rek: rek,
            prestandaBidrag: -(overviktStraff + sparStraff),
            dnfTillagg: dnfTillagg,
            procent: Math.round((vald / rek) * 100),
            status: status
        };
    }

    // ---------------------------------------------------------------
    // Bil, taktik och förare
    // ---------------------------------------------------------------
    function komponentBidrag(parts, bana, fas) {
        let p = parts || STANDARD_PARTS;
        let kurvor = (bana && bana.banaKurvor) ? bana.banaKurvor : 12;
        let langd = (bana && bana.banaLangd) ? bana.banaLangd : 4.5;
        let bidrag = 0;
        if (fas === 'kval') {
            bidrag += (p.motor / 100) * 2;
            bidrag += (p.aero / 100) * 4 * (kurvor / 12);
            bidrag += (p.chassi / 100) * 3;
            bidrag += (p.vaxellada / 100) * 1;
        } else {
            bidrag += (p.motor / 100) * 4 * (langd / 4.5);
            bidrag += (p.aero / 100) * 2;
            bidrag += (p.dack / 100) * 3 * (kurvor / 12);
            bidrag += (p.vaxellada / 100) * 2;
            bidrag += (p.chassi / 100) * 3;
        }
        return bidrag;
    }
    function standardTaktik(fas) {
        return fas === 'lopp'
            ? { dack: 'medium', downforce: 50, handling: 50, teamorder: 'ingen', bransle: null }
            : { dack: 'medium', downforce: 50, handling: 50 };
    }
    function beraknaTaktikBidrag(lag, bana, fas, ingFormaga) {
        let taktik = (fas === 'kval' ? lag.taktikKval : lag.taktikLopp) || standardTaktik(fas);
        let kurvor = (bana && bana.banaKurvor) ? bana.banaKurvor : 12;
        let langd = (bana && bana.banaLangd) ? bana.banaLangd : 4.5;
        let dackDef = DACK_EFFEKT[taktik.dack] || DACK_EFFEKT.medium;
        let downforceNorm = (((taktik.downforce !== undefined ? taktik.downforce : 50)) - 50) / 50;
        let handlingNorm = (((taktik.handling !== undefined ? taktik.handling : 50)) - 50) / 50;
        let bidrag = 0;
        if (fas === 'kval') {
            bidrag += dackDef.kval;
            bidrag += downforceNorm * 1.3 * (kurvor / 12);
            bidrag += handlingNorm * 0.6;
        } else {
            let depaForbattring = Math.max(0, Math.min(0.65, (ingFormaga || 0) / 100 * 0.65));
            bidrag += dackDef.loppBas;
            bidrag -= dackDef.loppSlitage * (kurvor / 12) * (1 - depaForbattring);
            bidrag += downforceNorm * 1.0 * (kurvor / 12);
            bidrag -= downforceNorm * 1.3 * (langd / 4.5);
            bidrag += handlingNorm * 1.1;
        }
        return bidrag;
    }
    function slumpaTaktikVarden(bana, fas, rng) {
        let kurvor = (bana && bana.banaKurvor) ? bana.banaKurvor : 12;
        let optimalDF = Math.max(10, Math.min(90, 20 + kurvor * 4));
        let t = {
            dack: DACK_ALTERNATIV[Math.floor(rng() * DACK_ALTERNATIV.length)],
            downforce: Math.max(0, Math.min(100, Math.round(optimalDF + (rng() * 30 - 15)))),
            handling: Math.max(0, Math.min(100, 40 + Math.floor(rng() * 40)))
        };
        if (fas === 'lopp') {
            t.teamorder = rng() < 0.25 ? (rng() < 0.5 ? 'bil1' : 'bil2') : 'ingen';
            let bransleRek = beraknaRekommenderatBransle(bana && bana.banaLangd, kurvor);
            t.bransle = Math.round(bransleRek * (0.9 + rng() * 0.2));
        }
        return t;
    }
    function simuleraForarPrestation(forare, rng) {
        let formaga = forare ? (forare.formaga || 10) : 10;
        let procent = 0.7 + rng() * 0.3;
        return { formaga: formaga, procent: procent, presterad: formaga * procent };
    }
    function beraknaBilPoang(lag, bilNr, forarePrestation, bana, fas) {
        let pf = personalFormagaForBil(lag, bilNr);
        let vagdSumma = (forarePrestation.presterad * 10) + pf.mek + pf.ing;
        let racingformaga = vagdSumma / 12;
        let komponent = komponentBidrag(bilParts(lag, bilNr), bana, fas);
        let taktikBidrag = beraknaTaktikBidrag(lag, bana, fas, pf.ing);
        let taktiskOrderBonus = 0;
        if (fas === 'lopp') {
            let f = forarForBil(lag, bilNr);
            if (f && f.contract && f.contract.firstDriverStatus) taktiskOrderBonus += 0.8;
            let order = lag.taktikLopp && lag.taktikLopp.teamorder;
            if (order && order !== 'ingen') {
                taktiskOrderBonus += (order === 'bil' + bilNr) ? 0.7 : -0.3;
            }
        }
        return racingformaga + komponent + taktikBidrag + taktiskOrderBonus;
    }
    function slumpBrus(spann, rng) {
        return (rng() - 0.5) * spann;
    }
    function slumpaStrategi(rng) {
        return STRATEGIER[Math.floor(rng() * STRATEGIER.length)];
    }
    function berakaDepaBonus(ingFormaga, strategi, dackVarde, rng) {
        let bas = (ingFormaga / 100) * 2.2;
        let dackEffekt = (dackVarde / 100) * 0.8 * strategi.riskFaktor;
        let brus = slumpBrus(1.2, rng);
        return bas + dackEffekt + brus;
    }

    // ---------------------------------------------------------------
    // KVAL. lagLista: lagobjekt med taktikKval redan satt (null = standard).
    // Returnerar raderna sorterade efter startposition. Rör inte lagen.
    // ---------------------------------------------------------------
    function simuleraKval(lagLista, bana, rng, skadeNyckel) {
        let entries = [];
        lagLista.forEach(lag => {
            let lagMedTaktik = lag.taktikKval ? lag : Object.assign({}, lag, { taktikKval: standardTaktik('kval') });
            [1, 2].forEach(bilNr => {
                let forare = forarForBilIRacet(lagMedTaktik, bilNr, skadeNyckel);
                if (!forare) return;
                let prest = simuleraForarPrestation(forare, rng);
                let poang = beraknaBilPoang(lagMedTaktik, bilNr, prest, bana, 'kval') + slumpBrus(3, rng);
                entries.push({
                    lagId: lag.lagId, lagNamn: lag.namn, arSpelare: !!lag.arSpelare, stallNr: lag.stallNr,
                    bil: bilNr, forarId: forare.id, forarNamn: forare.namn,
                    kvalPoäng: poang, procent: prest.procent
                });
            });
        });
        entries.sort((a, b) => b.kvalPoäng - a.kvalPoäng);
        entries.forEach((e, i) => { e.startPos = i + 1; });
        return entries;
    }

    // ---------------------------------------------------------------
    // LOPP. kvalResultat: rader med lagId/lagNamn, bil, startPos.
    // hittaLag(rad) returnerar lagobjektet (taktikLopp redan satt).
    // Returnerar raderna sorterade efter placering, med poäng, DNF och
    // snabbaste varv. Rör inte lagen (ingen poäng/moral/karriär).
    // ---------------------------------------------------------------
    function simuleraLopp(kvalResultat, hittaLag, bana, rng, skadeNyckel) {
        let antalEntries = kvalResultat.length;
        let bransleRek = beraknaRekommenderatBransle(bana.banaLangd, bana.banaKurvor);
        let loppResultat = kvalResultat.map(kvalRad => {
            let lag = hittaLag(kvalRad);
            if (!lag) return null;
            if (!lag.taktikLopp) lag = Object.assign({}, lag, { taktikLopp: standardTaktik('lopp') });
            let forare = forarForBilIRacet(lag, kvalRad.bil, skadeNyckel);
            let prest = simuleraForarPrestation(forare, rng);
            let startBonus = (antalEntries - kvalRad.startPos) * 0.3;
            let pf = personalFormagaForBil(lag, kvalRad.bil);
            let strategi = slumpaStrategi(rng);
            let depaBonus = berakaDepaBonus(pf.ing, strategi, bilParts(lag, kvalRad.bil).dack, rng);
            let moralBonus = ((lag.moral === undefined ? 50 : lag.moral) - 50) / 50 * 1.5;
            let bransleVald = hamtaBransleForLag(lag, bransleRek);
            let bransleEffekt = beraknaBransleEffekt(bransleVald, bransleRek);
            let loppPoang = beraknaBilPoang(lag, kvalRad.bil, prest, bana, 'lopp') + startBonus + depaBonus + moralBonus + bransleEffekt.prestandaBidrag + slumpBrus(3, rng);
            let depaTid = Math.max(1.6, Math.round((3.6 - (pf.ing / 100) * 1.3 - (strategi.riskFaktor || 0) * 0.15 + slumpBrus(0.4, rng)) * 100) / 100);
            let baseDnfChans = 0.02 * ((SKADE_VIKT_STIL[forare && forare.style] || 1.5) / 1.5);
            let dnfChans = Math.min(0.95, baseDnfChans + bransleEffekt.dnfTillagg);
            let dnfSlump = rng();
            let dnf = dnfSlump < dnfChans;
            let dnfOrsak = dnf ? (dnfSlump >= baseDnfChans ? 'bransle' : 'krasch') : null;
            return {
                lagId: kvalRad.lagId, lagNamn: kvalRad.lagNamn, bil: kvalRad.bil,
                forarId: forare ? forare.id : null, forarNamn: forare ? forare.namn : kvalRad.forarNamn,
                startPos: kvalRad.startPos, loppPoäng: loppPoang, procent: Math.round(prest.procent * 100),
                strategi: strategi.namn, depaTid: depaTid, dnf: dnf, dnfOrsak: dnfOrsak,
                bransleVald: bransleEffekt.vald, bransleRek: bransleEffekt.rek,
                bransleProcent: bransleEffekt.procent, bransleStatus: bransleEffekt.status
            };
        }).filter(r => r !== null);
        loppResultat.sort((a, b) => {
            if (a.dnf !== b.dnf) return a.dnf ? 1 : -1;
            return b.loppPoäng - a.loppPoäng;
        });
        loppResultat.forEach((res, idx) => {
            res.placering = idx + 1;
            res.poäng = (!res.dnf && idx < POANGSTABELL.length) ? POANGSTABELL[idx] : 0;
        });
        let snabbast = null;
        loppResultat.filter(r => !r.dnf).forEach(r => {
            if (!snabbast || r.procent > snabbast.procent) snabbast = r;
        });
        if (snabbast) snabbast.snabbasteVarv = true;
        return loppResultat;
    }

    root.URMRace = Object.freeze({
        VERSION, skapaRng, hashStrang,
        BRANSLE_LITER_PER_KM, BRANSLE_LITER_PER_KURVA, BRANSLE_MIN_REKOMMENDATION,
        BRANSLE_OVERVIKT_FAKTOR, BRANSLE_SPARKORNING_FAKTOR, BRANSLE_DNF_FAKTOR,
        DACK_ALTERNATIV, DACK_EFFEKT, POANGSTABELL, STRATEGIER, SKADE_VIKT_STIL,
        forarForBil, forarReserver, arForareSkadad, forarForBilIRacet, bilParts,
        snittFormagaMedChef, personalFormagaForBil,
        beraknaRekommenderatBransle, hamtaBransleForLag, beraknaBransleEffekt,
        komponentBidrag, standardTaktik, beraknaTaktikBidrag, slumpaTaktikVarden,
        simuleraForarPrestation, beraknaBilPoang, slumpBrus, slumpaStrategi, berakaDepaBonus,
        simuleraKval, simuleraLopp
    });
})(typeof globalThis !== 'undefined' ? globalThis : this);
