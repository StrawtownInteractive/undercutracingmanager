// =====================================================================
// UNDERCUT RACING MANAGER – SÄSONGSSKIFTE (delad kod)
// ---------------------------------------------------------------------
// Räknar ut upp- och nedflyttningar när en säsong är slut. Samma regler i
// webbläsaren (avslutaSasongOchOmstrukturera) och på servern (kor-race):
//   - varje gruppvinnare (utom i Högstaligan) går upp till sin föräldragrupp,
//   - de bästa 2:orna i varje division går upp, lika många som det finns
//     grupper i divisionen ovanför (rankade på poäng, sedan bästa bilens poäng),
//   - de ANTAL_NEDFLYTTADE sista i varje grupp med undergrupper går ner.
// Flyttat oförändrat från b5_1-3.html.
// =====================================================================
(function (root) {
    'use strict';

    // groupDefs: { gid: { tier, parent, children } }, tabeller: { gid: [lag] }
    // där lag har poäng, poängBil1, poängBil2. Lagobjekten flyttas inte här –
    // funktionen returnerar bara vad som ska hända.
    function beraknaFlyttar(groupDefs, tabeller, antalNedflyttade) {
        const ALLA = Object.keys(groupDefs);
        const gruppSortering = (a, b) => b.poäng - a.poäng;
        const gruppIdForTier = tier => ALLA.filter(g => groupDefs[g].tier === tier);
        const antalBastaTvaorSomGarUpp = tier => tier > 1 ? gruppIdForTier(tier - 1).length : 0;
        function beraknaBastaTvaor(tier) {
            let lista = gruppIdForTier(tier).map(gid => {
                let s = [...(tabeller[gid] || [])].sort(gruppSortering);
                return s[1] ? { lag: s[1], gid: gid } : null;
            }).filter(Boolean);
            let bastaBil = l => Math.max(l.poängBil1 || 0, l.poängBil2 || 0);
            lista.sort((a, b) => gruppSortering(a.lag, b.lag) || (bastaBil(b.lag) - bastaBil(a.lag)));
            return lista;
        }

        let sorted = {}, uppIn = {}, nedIn = {}, utUppat = {};
        ALLA.forEach(gid => {
            sorted[gid] = [...(tabeller[gid] || [])].sort(gruppSortering);
            uppIn[gid] = []; nedIn[gid] = []; utUppat[gid] = 0;
        });
        let flyttar = [];
        let tiers = [...new Set(ALLA.map(g => groupDefs[g].tier))].sort((a, b) => a - b);
        tiers.forEach(tier => {
            if (tier === 1) return;
            gruppIdForTier(tier).forEach(gid => {
                let vinnare = sorted[gid][0];
                if (!vinnare) return;
                let till = groupDefs[gid].parent;
                uppIn[till].push(vinnare); utUppat[gid]++;
                flyttar.push({ lag: vinnare, fran: gid, till: till, typ: 'vinnare' });
            });
            let harPlats = g => uppIn[g].length < antalNedflyttade;
            beraknaBastaTvaor(tier).slice(0, antalBastaTvaorSomGarUpp(tier)).forEach(({ lag, gid }) => {
                let egen = groupDefs[gid].parent;
                let till = harPlats(egen) ? egen : gruppIdForTier(tier - 1).find(harPlats);
                if (!till) return;
                uppIn[till].push(lag); utUppat[gid]++;
                flyttar.push({ lag: lag, fran: gid, till: till, typ: 'tvaa' });
            });
        });
        ALLA.forEach(gid => {
            let def = groupDefs[gid];
            if (!def.children || def.children.length === 0) return;
            let s = sorted[gid];
            let underTier = groupDefs[def.children[0]].tier;
            let ledig = g => utUppat[g] - nedIn[g].length > 0;
            s.slice(Math.max(0, s.length - antalNedflyttade)).forEach(lag => {
                let till = def.children.find(ledig) || gruppIdForTier(underTier).find(ledig);
                if (!till) return;
                nedIn[till].push(lag);
                flyttar.push({ lag: lag, fran: gid, till: till, typ: 'ned' });
            });
        });
        return { flyttar, uppIn, nedIn, sorted };
    }

    root.URMSasong = Object.freeze({ beraknaFlyttar });
})(typeof globalThis !== 'undefined' ? globalThis : this);
