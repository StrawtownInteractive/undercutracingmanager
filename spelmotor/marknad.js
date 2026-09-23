// =====================================================================
// UNDERCUT RACING MANAGER – GEMENSAM TRANSFERMARKNAD (serverlogik)
// ---------------------------------------------------------------------
// Ren logik för kor-race: AI-lagens försäljningar och bud, avslut av
// auktioner, fria agenter och ersättare i AI-lag. Ingen databaskod här.
// Kräver spelmotor/race.js och varld.js. Reglerna följer den tidigare
// lokala marknaden i b5_1-3.html (skapaAiListning, hojBudAI, losUtAuktion).
// =====================================================================
(function (root) {
    'use strict';
    const V = root.URMVarld;

    const AUKTION_DAGAR = 7;
    const ANTI_SNIPE_MS = 3 * 60 * 1000;
    const MAX_AI_LISTNINGAR = 30;
    const MIN_FRIA_AGENTER = 10;
    const AI_BUD_CHANS = 0.25; // per körning (var 5:e minut)

    const minHojning = bud => Math.max(10000, Math.round(bud * 0.02));
    const utropFor = p => Math.max(20000, Math.round((p.formaga || 10) * 8000));
    const listNyckel = { forare: 'forare', mekaniker: 'mekanikerLista', ingenjor: 'ingenjorLista' };

    // Personens ögonblicksbild på marknaden (samma fält som skapaMarknadsSnapshot).
    function marknadsPerson(p, kategori) {
        return {
            personId: p.id, kategori: kategori,
            namn: p.namn, age: p.age, nationalitet: p.nationalitet, style: p.style || null, formaga: p.formaga,
            popularitet: p.popularitet, rekryDatum: p.rekryDatum, stats: p.stats || null,
            bilLabel: kategori === 'forare' ? (p.roll === 'reserv' ? 'Reserv' : 'Bil ' + String(p.roll || '').replace('bil', '')) : (p.bil ? 'Bil ' + p.bil : 'Reserv'),
            foregaendeAgareLag: p.foregaendeAgareLag || null,
            lon: p.contract ? p.contract.salaryPerSeason : null,
            kontraktslangd: p.contract ? p.contract.contractYearsRemaining : null,
            kontrakt: p.contract ? Object.assign({}, p.contract) : null,
            karriar: kategori === 'forare' && p.karriar ? Object.assign({}, p.karriar) : null,
            karriarHistorik: kategori === 'forare' && Array.isArray(p.karriarHistorik) ? p.karriarHistorik.slice() : null,
            personalKarriar: kategori !== 'forare' && p.personalKarriar ? Object.assign({}, p.personalKarriar) : null,
            personalHistorik: kategori !== 'forare' && Array.isArray(p.personalHistorik) ? p.personalHistorik.slice() : null
        };
    }

    // Nya AI-försäljningar. aiLag: [{ id, snapshot }], upptagna: Set med
    // person-id:n som redan är ute. Returnerar rader att lägga in i marknad.
    function nyaAiListningar(aiLag, upptagna, antalAktiva, rng, nu) {
        const ut = [];
        const saljare = new Set();
        let forsok = 0;
        while (antalAktiva + ut.length < MAX_AI_LISTNINGAR && ut.length < 3 && forsok++ < 20 && aiLag.length) {
            const lag = aiLag[Math.floor(rng() * aiLag.length)];
            if (saljare.has(lag.id)) continue;
            const s = lag.snapshot || {};
            let kategori, p;
            if (rng() < 0.35) {
                kategori = 'forare';
                const k = (s.forare || []).filter(f => f.roll !== 'reserv');
                p = k[Math.floor(rng() * k.length)];
            } else {
                kategori = rng() < 0.5 ? 'mekaniker' : 'ingenjor';
                const l = s[listNyckel[kategori]] || [];
                p = l[Math.floor(rng() * l.length)];
            }
            if (!p || !p.namn || upptagna.has(p.id)) continue;
            upptagna.add(p.id); saljare.add(lag.id);
            const utrop = utropFor(p);
            ut.push({
                kategori, person_id: p.id, person: marknadsPerson(p, kategori), saljare_typ: 'lag',
                saljare_team_id: lag.id, utropspris: utrop, hogsta_bud: utrop,
                deadline: new Date(nu + AUKTION_DAGAR * 864e5).toISOString()
            });
        }
        return ut;
    }

    // Ett AI-lag höjer budet – bara på auktioner där ingen människa har budat
    // (samma regel som tidigare: AI:n tävlar aldrig mot en mänsklig budgivare).
    function aiBud(auktion, aiLagIds, rng, nu) {
        if (auktion.manskliga_bud > 0) return null;
        if (Date.parse(auktion.deadline) - nu < ANTI_SNIPE_MS) return null;
        if (rng() >= AI_BUD_CHANS) return null;
        const kandidater = aiLagIds.filter(id => id !== auktion.saljare_team_id && id !== auktion.hogsta_budare);
        if (!kandidater.length) return null;
        const hojning = Math.max(minHojning(auktion.hogsta_bud), Math.round(auktion.hogsta_bud * (0.05 + rng() * 0.15)));
        return { hogsta_bud: auktion.hogsta_bud + hojning, hogsta_budare: kandidater[Math.floor(rng() * kandidater.length)] };
    }

    // Tar bort en person ur en ögonblicksbild. ersatt=true (AI-lag) ger en ny
    // person på samma plats, precis som ersattAiPerson() gjorde lokalt.
    function taBortPerson(snapshot, kategori, personId, ersatt, tier) {
        const s = JSON.parse(JSON.stringify(snapshot || {}));
        const nyckel = listNyckel[kategori];
        if (!nyckel) {
            if (kategori === 'principal' && s.teamPrincipal && s.teamPrincipal.id === personId) s.teamPrincipal = null;
            return s;
        }
        const lista = Array.isArray(s[nyckel]) ? s[nyckel] : [];
        const idx = lista.findIndex(x => x.id === personId);
        if (idx < 0) return s;
        const gammal = lista[idx];
        lista.splice(idx, 1);
        if (ersatt) lista.push(ersattare(kategori, gammal.roll, gammal.bil, tier));
        s[nyckel] = lista;
        return s;
    }

    function ersattare(kategori, roll, bil, tier) {
        if (kategori === 'forare') return V.skapaForarPerson(roll || 'reserv', tier, false, new Set());
        const ny = V.skapaAiPersonalLista(1, tier, kategori, new Set())[0];
        ny.bil = bil || 1;
        return ny;
    }

    // Fyller vakanser (friköpta personer) i ett AI-lags ögonblicksbild.
    function fyllVakanser(snapshot, tier) {
        const s = JSON.parse(JSON.stringify(snapshot));
        (s.vakanser || []).forEach(v => {
            const nyckel = listNyckel[v.kategori];
            if (!nyckel) return;
            if (!Array.isArray(s[nyckel])) s[nyckel] = [];
            s[nyckel].push(ersattare(v.kategori, v.roll, v.bil, tier));
        });
        delete s.vakanser;
        return s;
    }

    function skapaFriAgent(kategori, sasong) {
        const p = V.slumpaPerson();
        const keys = kategori === 'forare' ? V.DRIVARE_STAT_KEYS : (kategori === 'ingenjor' ? V.ING_STAT_KEYS : V.MEK_STAT_KEYS);
        const stats = {};
        keys.forEach(k => { stats[k] = 10; });
        const formaga = V.beraknaFormaga(stats, keys);
        return {
            id: V.nyttPersonId(), kategori, namn: p.namn, age: 20, nationalitet: p.nationalitet,
            style: kategori === 'forare' ? V.slumpaStil() : null, stats, formaga,
            popularitet: kategori === 'forare' ? V.skapaPopularitet(formaga) : null,
            rekryDatum: new Date().toISOString(), friAgentSedanSasong: sasong
        };
    }

    root.URMMarknad = Object.freeze({
        AUKTION_DAGAR, MAX_AI_LISTNINGAR, MIN_FRIA_AGENTER,
        marknadsPerson, nyaAiListningar, aiBud, taBortPerson, fyllVakanser, skapaFriAgent
    });
})(typeof globalThis !== 'undefined' ? globalThis : this);
