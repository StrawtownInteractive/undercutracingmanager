// =====================================================================
// UNDERCUT RACING MANAGER – VÄRLDSGENERERING (delad kod)
// ---------------------------------------------------------------------
// Skapar lag, förare, personal, Team Principals, kontrakt, banor och
// raceschema. Samma fil körs i webbläsaren och på servern (Edge Functions).
// Koden är flyttad oförändrad från b5_1-3.html, med två skillnader:
//   - all slump går via slump(), som är Math.random om inget annat anges.
//     Servern kör med URMVarld.medSlump(rng, () => ...) för seedad slump.
//   - avatarer och id:n skapas via hooks (webbläsaren kopplar in
//     AvatarSystem.createAvatar, servern kan koppla in crypto.randomUUID).
// =====================================================================
(function (root) {
    'use strict';

    let slump = Math.random;
    const hooks = { skapaAvatar: function (p) { return p; }, nyttId: null };
    let personIdCounter = 0;

    function medSlump(rng, fn) {
        const forra = slump;
        slump = rng;
        try { return fn(); } finally { slump = forra; }
    }
    function sattAvatarFunktion(fn) { hooks.skapaAvatar = fn || function (p) { return p; }; }
    function sattIdFunktion(fn) { hooks.nyttId = fn || null; }

    // Skapar en hel AI-division (10 lag) + schema. Används av servern;
    // motsvarar första halvan av skapaGrupp() i b5_1-3.html.
    function skapaAiDivision(tier, kort, anvandaLagNamn, anvandaArenaNamn) {
        anvandaLagNamn = anvandaLagNamn || new Set();
        anvandaArenaNamn = anvandaArenaNamn || new Set();
        const signaturer = new Set();
        const lag = [];
        for (let i = 0; i < 10; i++) {
            lag.push(skapaLag(false, tier, slumpaLagBasNamn(anvandaLagNamn), kort, signaturer, anvandaArenaNamn));
        }
        const ordning = shuffle([...lag]);
        ordning.forEach((l, idx) => { l.stallNr = idx + 1; });
        return lag;
    }

        const NAMNPOOLER = {
            "Sverige":         { f: ["Erik","Lars","Anders","Karl","Johan","Nils","Gustav","Oskar","Viktor","Emil","Fredrik","Magnus","Daniel","Mattias","Per","Henrik","Björn","Sven","Anton","Axel","Elias","Hugo","Isak","Filip","William","Alexander","Simon","Jonas","Tobias","Rickard"],       e: ["Andersson","Johansson","Karlsson","Nilsson","Eriksson","Larsson","Olsson","Persson","Svensson","Gustafsson","Pettersson","Jonsson","Jansson","Hansson","Bengtsson","Jönsson","Lindberg","Jakobsson","Magnusson","Olofsson","Lindqvist","Lindgren","Berg","Berglund","Fredriksson","Sandberg","Forsberg","Lundberg","Åberg","Holm"] },
            "Italien":         { f: ["Marco","Giovanni","Matteo","Alessandro","Lorenzo","Federico","Leonardo","Francesco","Giuseppe","Antonio","Andrea","Luca","Davide","Simone","Riccardo","Emanuele","Stefano","Roberto","Paolo","Fabio","Gianluca","Salvatore","Vincenzo","Angelo","Domenico","Massimo","Claudio","Sergio","Enzo","Dario"], e: ["Rossi","Ferrari","Russo","Bianchi","Romano","Colombo","Ricci","Marino","Greco","Bruno","Gallo","Conti","De Luca","Costa","Giordano","Mancini","Rizzo","Lombardi","Moretti","Barbieri","Fontana","Santoro","Mariani","Rinaldi","Caruso","Ferrara","Galli","Martini","Leone","Longo"] },
            "Tyskland":        { f: ["Hans","Klaus","Wolfgang","Stefan","Michael","Andreas","Thomas","Sebastian","Florian","Matthias","Peter","Jürgen","Dieter","Werner","Frank","Uwe","Jan","Lukas","Tobias","Christian","Daniel","Markus","Benjamin","Philipp","Maximilian","Alexander","Julian","Felix","Niklas","Jonas"], e: ["Müller","Schmidt","Schneider","Fischer","Weber","Meyer","Wagner","Becker","Hoffmann","Schulz","Koch","Bauer","Richter","Klein","Wolf","Schröder","Neumann","Schwarz","Zimmermann","Braun","Krüger","Hofmann","Hartmann","Lange","Schmitt","Werner","Krause","Meier","Lehmann","Huber"] },
            "Frankrike":       { f: ["Pierre","Jean","Louis","Nicolas","Antoine","Julien","Mathieu","Olivier","Laurent","Étienne","François","Philippe","Michel","Alain","Bernard","Daniel","Christophe","Stéphane","Guillaume","Romain","Sébastien","Vincent","Thierry","Patrick","Xavier","Hugo","Maxime","Victor","Baptiste","Gabriel"], e: ["Martin","Bernard","Dubois","Robert","Petit","Durand","Leroy","Moreau","Simon","Laurent","Lefebvre","Michel","Garcia","David","Bertrand","Roux","Vincent","Fournier","Morel","Girard","André","Lefevre","Mercier","Dupont","Lambert","Bonnet","François","Rousseau","Blanc","Guerin"] },
            "Spanien":         { f: ["Carlos","Javier","Alejandro","Miguel","Pablo","Diego","Fernando","Sergio","Rafael","Manuel","Antonio","José","Francisco","Juan","Daniel","David","Jesús","Alberto","Adrián","Álvaro","Rubén","Iván","Óscar","Raúl","Marcos","Víctor","Hugo","Mario","Enrique","Joaquín"], e: ["García","Martínez","López","Sánchez","Pérez","Gómez","Fernández","Ruiz","Díaz","Morales","Jiménez","Álvarez","Romero","Alonso","Gutiérrez","Navarro","Torres","Domínguez","Vázquez","Ramos","Gil","Serrano","Blanco","Suárez","Molina","Ortega","Delgado","Castro","Ortiz","Rubio"] },
            "Storbritannien":  { f: ["James","Oliver","George","Harry","Thomas","William","Charlie","Jack","Henry","Edward","Daniel","Samuel","Joseph","Alexander","Benjamin","Lucas","Ethan","Michael","Callum","Ryan","Connor","Matthew","Andrew","Liam","Adam","Luke","Jacob","Nathan","Dylan","Owen"], e: ["Smith","Jones","Taylor","Brown","Wilson","Evans","Thomas","Roberts","Walker","Wright","Robinson","Green","Hall","Clark","Hughes","King","Baker","Harris","Edwards","Lewis","Phillips","Watson","Cooper","Ward","Turner","Morris","Cook","Bell","Murphy","Bailey"] },
            "Nederländerna":   { f: ["Jan","Willem","Pieter","Dirk","Bas","Sander","Thijs","Daan","Sven","Maarten","Tim","Lars","Wouter","Bart","Ruben","Niels","Rick","Erik","Tom","Koen","Joris","Stijn","Bram","Wesley","Kevin","Robin","Mark","Roy","Jasper","Vincent"], e: ["de Jong","Jansen","de Vries","van Dijk","Bakker","Visser","Smit","Meijer","Mulder","de Boer","Bos","Vos","Peters","Hendriks","van Leeuwen","Dekker","Brouwer","de Wit","Dijkstra","Smits","de Graaf","van der Berg","Kok","Jacobs","de Haan","Vermeulen","van den Berg","van der Meer","van der Linden","Hoekstra"] },
            "Finland":         { f: ["Mika","Antti","Juha","Timo","Ville","Sami","Jari","Petri","Heikki","Kalle","Matti","Pekka","Jukka","Markku","Tapio","Esa","Teemu","Jarmo","Ilkka","Risto","Tuomas","Markus","Aleksi","Joonas","Lauri","Niko","Miika","Aki","Toni","Janne"], e: ["Korhonen","Virtanen","Mäkinen","Nieminen","Mäkelä","Hämäläinen","Laine","Heikkinen","Koskinen","Järvinen","Lehtonen","Lehtinen","Saarinen","Salminen","Heinonen","Niemi","Heikkilä","Kinnunen","Salo","Turunen","Salonen","Rantanen","Ahonen","Manninen","Räsänen","Jokinen","Rinne","Aaltonen","Turpeinen","Nurmi"] },
            "Brasilien":       { f: ["Lucas","Gabriel","Rafael","Bruno","Felipe","André","Rodrigo","Thiago","Diego","Gustavo","João","Pedro","Matheus","Vitor","Caio","Eduardo","Leonardo","Marcelo","Fernando","Henrique","Vinícius","Fábio","Ricardo","Daniel","Alexandre","Renato","Anderson","Wesley","Marcos","Cauã"], e: ["Silva","Santos","Oliveira","Souza","Pereira","Costa","Almeida","Ferreira","Rodrigues","Carvalho","Gomes","Martins","Araújo","Melo","Barbosa","Ribeiro","Alves","Monteiro","Cardoso","Nascimento","Lima","Moreira","Teixeira","Correia","Machado","Dias","Nunes","Pinto","Barros","Freitas"] },
            "USA":             { f: ["John","Michael","David","James","Robert","William","Ryan","Kevin","Brian","Justin","Christopher","Matthew","Daniel","Andrew","Joshua","Tyler","Nicholas","Brandon","Jonathan","Eric","Jason","Adam","Zachary","Aaron","Jeremy","Sean","Austin","Cody","Dustin","Jordan"], e: ["Johnson","Williams","Miller","Davis","Anderson","Thompson","Moore","Jackson","Martin","White","Harris","Clark","Lewis","Robinson","Walker","Young","Allen","King","Wright","Scott","Torres","Hill","Green","Baker","Adams","Nelson","Carter","Mitchell","Perez","Roberts"] },
            "Japan":           { f: ["Hiroshi","Takeshi","Kenji","Satoshi","Yuki","Daiki","Ryo","Haruto","Takumi","Kazuki","Sota","Ren","Yuto","Riku","Sho","Hayato","Yuma","Sora","Kaito","Yusuke","Daisuke","Masahiro","Tatsuya","Noboru","Shinji","Kosuke","Tomoya","Naoki","Wataru","Isamu"], e: ["Sato","Suzuki","Takahashi","Tanaka","Watanabe","Ito","Yamamoto","Nakamura","Kobayashi","Saito","Kato","Yoshida","Yamada","Sasaki","Yamaguchi","Matsumoto","Inoue","Kimura","Shimizu","Hayashi","Yamazaki","Mori","Abe","Ikeda","Hashimoto","Yamashita","Ishikawa","Nakajima","Maeda","Ogawa"] },
            "Australien":      { f: ["Jack","Liam","Noah","Ethan","Lucas","Mason","Cooper","Riley","Hayden","Blake","Oliver","William","Jacob","Harrison","Thomas","James","Charlie","Lachlan","Xavier","Nathan","Connor","Flynn","Archer","Tyler","Zachary","Ryan","Dylan","Kai","Beau","Jayden"], e: ["Smith","Wilson","Taylor","Turner","Baker","King","Hall","Young","Mitchell","Clarke","Anderson","Thompson","White","Harris","Martin","Robinson","Walker","Campbell","Stewart","Morris","Roberts","Cook","Bell","Ward","Cox","Richardson","Watson","Brooks","Kelly","Hughes"] },
            "Belgien":         { f: ["Luc","Kevin","Thomas","Bart","Wouter","Jonas","Tom","Wim","Dries","Sander","Jan","Peter","Tim","Niels","Maxim","Stijn","Robbe","Milan","Arne","Matthias","Sam","Jens","Steven","Benjamin","Simon","Ruben","Nico","Bram","Gilles","Vincent"], e: ["Peeters","Janssens","Maes","Jacobs","Mertens","Willems","Claes","Goossens","Wouters","De Smet","Vermeulen","Michiels","Dubois","Lambert","Dupont","Hermans","Vandenberghe","Bogaert","Cools","De Clercq","Verhoeven","Coppens","Van Damme","De Backer","Segers","Vandenbroucke","Verstraete","Van den Bossche","Wauters","Smets"] },
            "Österrike":       { f: ["Franz","Josef","Andreas","Christian","Thomas","Markus","Stefan","Michael","Alexander","Bernhard","Johann","Herbert","Karl","Rudolf","Manfred","Werner","Gerhard","Anton","Wolfgang","Martin","Florian","Lukas","Julian","Simon","David","Fabian","Daniel","Patrick","Sebastian","Maximilian"], e: ["Gruber","Huber","Bauer","Wagner","Pichler","Steiner","Moser","Berger","Winkler","Egger","Fuchs","Mayer","Hofer","Leitner","Schmid","Wimmer","Wolf","Lang","Aigner","Schwarz","Auer","Baumgartner","Reiter","Schneider","Binder","Brunner","Wieser","Wallner","Weber","Wiesinger"] },
            "Monaco":          { f: ["Jean","Louis","Charles","Albert","Rainier","Marc","Alain","Frédéric","Hugo","Nicolas","Pierre","Antoine","Julien","Olivier","Laurent","Vincent","Philippe","Étienne","Gabriel","Maxime","Thomas","Guillaume","Bastien","Romain","Léo","Adrien","Grégoire","Victor","Rémi","Baptiste"], e: ["Roux","Blanc","Vidal","Riboni","Ferrand","Giraud","Novella","Barral","Cassini","Orengo","Martin","Bertrand","Fabron","Passeron","Médecin","Crovetto","Gastaud","Boisson","Notari","Léandri","Ricci","Spinelli","Ferraro","Bianchi","Rossi","Moretti","Colombo","Gallo","Santoro","Conti"] },
            "Mexiko":          { f: ["José","Luis","Juan","Carlos","Miguel","Alejandro","Fernando","Ricardo","Eduardo","Sergio","Antonio","Francisco","David","Jorge","Rafael","Roberto","Gerardo","Arturo","Ramón","Ignacio","Emilio","Diego","Iván","Óscar","Manuel","Andrés","Hugo","Víctor","Raúl","Marcos"], e: ["Hernández","García","Rodríguez","González","López","Martínez","Pérez","Sánchez","Ramírez","Torres","Flores","Cruz","Reyes","Morales","Ortiz","Gutiérrez","Chávez","Ramos","Vargas","Castillo","Jiménez","Romero","Mendoza","Aguilar","Medina","Guerrero","Rojas","Vega","Delgado","Contreras"] },
            "Kanada":          { f: ["Liam","Noah","Ethan","Logan","Jacob","William","Benjamin","Nathan","Alexandre","Samuel","Jack","Owen","James","Lucas","Thomas","Charlie","Henry","Mathieu","Olivier","Félix","Gabriel","Xavier","Antoine","Zachary","Ryan","Connor","Tyler","Cameron","Dylan","Carter"], e: ["Smith","Tremblay","Roy","Gagnon","Brown","Martin","Wilson","MacDonald","Campbell","Bouchard","Lee","Taylor","Anderson","Gauthier","Morin","Lavoie","Fortin","Gagné","Ouellet","Pelletier","Bélanger","Lévesque","Bergeron","Leblanc","Beaulieu","Côté","Thompson","White","Clark","Robinson"] },
            "Danmark":         { f: ["Lars","Anders","Mikkel","Jonas","Mads","Christian","Peter","Niels","Jesper","Rasmus","Søren","Henrik","Morten","Thomas","Jan","Michael","Martin","Kasper","Frederik","Emil","Oliver","William","Magnus","Victor","Alexander","Malte","August","Villads","Sebastian","Marcus"], e: ["Nielsen","Jensen","Hansen","Pedersen","Andersen","Christensen","Larsen","Sørensen","Rasmussen","Petersen","Møller","Poulsen","Thomsen","Johansen","Knudsen","Mortensen","Olsen","Madsen","Kristiansen","Jakobsen","Jørgensen","Lund","Schmidt","Holm","Vestergaard","Kristensen","Hermansen","Iversen","Frandsen","Bruun"] },
            "Norge":           { f: ["Ole","Lars","Erik","Magnus","Kristian","Bjørn","Anders","Jon","Håkon","Sindre","Odin","Henrik","Thomas","Martin","Jonas","Fredrik","Daniel","Sander","Emil","Markus","Aksel","Tobias","William","Oskar","Elias","Isak","Noah","Filip","Kasper","Sondre"], e: ["Hansen","Johansen","Olsen","Larsen","Andersen","Pedersen","Nilsen","Kristiansen","Jensen","Karlsen","Berg","Haugen","Hagen","Johnsen","Andreassen","Jacobsen","Dahl","Jørgensen","Halvorsen","Solberg","Iversen","Nygård","Strand","Sæther","Moen","Rasmussen","Amundsen","Sørensen","Knutsen","Skoglund"] },
            "Schweiz":         { f: ["Urs","Hans","Peter","Marco","Daniel","Christian","Andreas","Beat","Reto","Simon","Thomas","Michael","Martin","Stefan","Markus","Roger","Lukas","Philipp","David","Patrick","Adrian","Fabian","Dominik","Nicolas","Yannick","Samuel","Raphael","Jonas","Livio","Nino"], e: ["Müller","Meier","Keller","Weber","Schneider","Huber","Baumann","Frei","Zimmermann","Moser","Steiner","Fischer","Gerber","Brunner","Kaufmann","Bucher","Schmid","Widmer","Wyss","Graf","Roth","Suter","Bachmann","Marti","Berger","Egli","Vogel","Furrer","Ammann","Kunz"] }
        };

        const nationalitetPool = Object.keys(NAMNPOOLER);

        const forarStilar = ["Aggressiv", "Defensiv", "Balanserad"];

        function slumpaNationalitet() {
            return nationalitetPool[Math.floor(slump() * nationalitetPool.length)];
        }

        function slumpaPerson() {
            let nat = slumpaNationalitet();
            let pool = NAMNPOOLER[nat];
            let f = pool.f[Math.floor(slump() * pool.f.length)];
            let e = pool.e[Math.floor(slump() * pool.e.length)];
            return { namn: f + " " + e, nationalitet: nat };
        }

        function slumpaStil() {
            return forarStilar[Math.floor(slump() * forarStilar.length)];
        }

        function slumpaTidigareDatum(maxDagarSedan) {
            let dagarSedan = Math.floor(slump() * (maxDagarSedan || 300));
            let d = new Date(Date.now() - dagarSedan * 24 * 60 * 60 * 1000);
            return d.toISOString();
        }

        function shuffle(arr) {
            arr.sort(() => slump() - 0.5);
            return arr;
        }

        function nyttPersonId() {
            personIdCounter++;
            return hooks.nyttId ? hooks.nyttId() : 'p' + Date.now().toString(36) + '_' + personIdCounter;
        }

        const DRIVARE_STAT_KEYS = ['erfarenhet', 'snabbhet', 'dackhantering', 'forsvar', 'lagformaga'];

        const MEK_STAT_KEYS = ['erfarenhet', 'motorkunskap', 'snabbhet', 'press', 'lagformaga'];

        const ING_STAT_KEYS = ['erfarenhet', 'taktik', 'snabbhet', 'press', 'lagformaga'];

        function beraknaFormaga(stats, keys) {
            let s = 0;
            keys.forEach(k => { s += (stats[k] || 0); });
            return Math.round(s / keys.length);
        }

        function erfarenhetForAlder(age) {
            return Math.max(0, Math.min(100, 10 + (age - 20) * 5));
        }

        function tomKarriar() {
            return { lopp: 0, vinster: 0, pallplatser: 0, poang: 0, mastarskap: 0, poles: 0, snabbastaVarv: 0, dnf: 0 };
        }

        function tomPersonalKarriar() {
            return { sasonger: 0, bastaDepa: null };
        }

        function skapaPopularitet(formaga) {
            let bas = 25 + (formaga || 10) * 0.35;
            return Math.max(5, Math.min(100, Math.round(bas + slump() * 20)));
        }

        function skapaDriverStats(tier, age, arSpelare, roll) {
            // Alla nyrekryterade forare - spelarens egna (nya rookies, ersattare
            // vid utgatt kontrakt/pension) och datorstyrda lags - startar med
            // samma svaga basniva (10) i varje tranbar egenskap. Erfarenhet
            // undantas eftersom den bestams av alder, se erfarenhetForAlder().
            // (tier/arSpelare/roll behalls i signaturen for att inte paverka
            // anropsstallena, men styr inte langre nagon slumpning har.)
            let erf = erfarenhetForAlder(age);
            return { erfarenhet: erf, snabbhet: 10, dackhantering: 10, forsvar: 10, lagformaga: 10 };
        }

        const TIER_LON_SKALA_FORARE = { 1: 95000, 2: 60000, 3: 32000, 4: 16000, 5: 9000 };

        const TIER_LON_SKALA_STAB = { 1: 42000, 2: 30000, 3: 20000, 4: 12000, 5: 8000 };

        const PRINCIPAL_LON_TIER = { 1: 3200000, 2: 2200000, 3: 1400000, 4: 900000, 5: 600000 };

        function avrunda10k(v) { return Math.max(0, Math.round((v || 0) / 10000) * 10000); }

        function baseForarLon(formaga, tier) {
            let skala = TIER_LON_SKALA_FORARE[tier] || TIER_LON_SKALA_FORARE[4];
            return avrunda10k(Math.max(200000, (formaga || 10) * skala * (0.85 + slump() * 0.3)));
        }

        function baseStabLon(formaga, tier) {
            let skala = TIER_LON_SKALA_STAB[tier] || TIER_LON_SKALA_STAB[4];
            return avrunda10k(Math.max(400000, (formaga || 10) * skala * (0.9 + slump() * 0.2)));
        }

        function basePrincipalLon(tier) { return PRINCIPAL_LON_TIER[tier] || PRINCIPAL_LON_TIER[4]; }

        function nyttForarKontrakt(formaga, tier, arSpelare) {
            let lon = arSpelare ? avrunda10k(Math.max(200000, (formaga || 10) * (TIER_LON_SKALA_FORARE[tier] || TIER_LON_SKALA_FORARE[4]))) : baseForarLon(formaga, tier);
            let langd = arSpelare ? 3 : (2 + Math.floor(slump() * 3));
            return {
                typ: 'forare',
                salaryPerSeason: lon,
                contractLength: langd,
                contractYearsRemaining: langd,
                signingBonus: avrunda10k(lon * 0.12),
                podiumBonus: avrunda10k(lon * 0.035),
                winBonus: avrunda10k(lon * 0.09),
                pointsBonus: avrunda10k(lon * 0.0015),
                championshipBonus: avrunda10k(lon * 0.30),
                firstDriverStatus: false,
                releaseClause: avrunda10k(lon * (3 + slump() * 3)),
                performanceTarget: Math.max(5, Math.round((formaga || 10) * 0.6)),
                contractStatus: langd <= 1 ? 'Expiring' : 'Active',
                relation: 50 + Math.floor(slump() * 30),
                forhandlingsForsok: 0,
                aiInterest: null
            };
        }

        function nyttStabKontrakt(formaga, tier, roll) {
            let lon = roll === 'principal' ? basePrincipalLon(tier) : baseStabLon(formaga, tier); // ingångslön efter förmåga/division (samma nivå som lönekraven i förhandlingar)
            let langd = 2 + Math.floor(slump() * 3);
            return {
                typ: 'stab',
                roll: roll, // 'mekaniker' | 'ingenjor' | 'principal'
                salaryPerSeason: lon,
                contractLength: langd,
                contractYearsRemaining: langd,
                signingBonus: avrunda10k(lon * 0.08),
                performanceBonus: avrunda10k(lon * 0.03),
                releaseClause: avrunda10k(lon * 2),
                contractStatus: langd <= 1 ? 'Expiring' : 'Active',
                relation: 50 + Math.floor(slump() * 30),
                forhandlingsForsok: 0,
                aiInterest: null
            };
        }

        function teamInitialer(namn) {
            let ord = String(namn).replace(/\(.*?\)/g, '').trim().split(/\s+/);
            let a = ord[0] ? ord[0][0] : '?';
            let b = ord.length > 1 ? ord[1][0] : (ord[0] && ord[0][1] ? ord[0][1] : '');
            return (a + b).toUpperCase();
        }

        function genereraTeamFarger(namn) {
            let h = 0;
            let s = String(namn);
            for (let i = 0; i < s.length; i++) { h = (h * 31 + s.charCodeAt(i)) | 0; }
            h = Math.abs(h);
            let hue = h % 360;
            return {
                primary: `hsl(${hue}, 55%, 38%)`,
                secondary: `hsl(${(hue + 150) % 360}, 40%, 22%)`,
                accent: `hsl(${(hue + 35) % 360}, 85%, 55%)`,
                initial: teamInitialer(namn)
            };
        }

        const aiTeamBasNamn = [
            "Thunder Racing", "Apex Predators", "Veloce GP", "Nordic Speed", "Redline Motors",
            "Stellar Racing", "Omega GP", "Iron Horse", "Turbo Dynamics", "Eclipse Racing",
            "Pioneer Motorsport", "Titanium GP", "Zenith Racing", "Vortex Speed", "Falcon Motorsport",
            "Blaze Racing", "Quantum GP", "Apex Works", "Nova Motorsport", "Vanguard GP",
            "Sovereign Racing", "Horizon GP", "Alpha Motorsport", "Phantom Speed", "Crescent Racing",
            "Quantum Motors", "Voltage Velocity", "Chicane Squadron", "Titanium Motorsport", "Titan GP",
            "Nordic Autosport", "Granite GP", "Bronze Motors", "Catalyst Motors", "Storm Performance",
            "Pulse Squadron", "Chrome Squadron", "Desert Motorsport", "Neutron Engineering", "Carbon Performance",
            "Jaguar Dynamics", "Prime Racing", "Raven Speed", "Storm Engineering", "Quasar Autosport",
            "Ampere Dynamics", "Swift Racing", "Impulse Predators", "Lion Racing", "Diamond Motors",
            "Swift Team", "Steel Motorsport", "Piston GP", "Iron Velocity", "Crescent Squadron",
            "Quantum Dynamics", "Velocity Autosport", "Slipstream Motorsport", "Radiant Velocity", "Cobalt Dynamics",
            "Thunder Works", "Sapphire Team", "Impulse Team", "Nebula Predators", "Piston Motorsport",
            "Vanguard Engineering", "Obsidian Speed", "Ruby Engineering", "Condor Predators", "Eclipse Speed",
            "Vector Racing", "Onyx Motorsport", "Chicane Team", "Golden Engineering", "Mantis Squadron",
            "Meteor Team", "Iron Motors", "Solar Motorsport", "Platinum Racing", "Turbo Velocity",
            "Turbo Engineering", "Cheetah Performance", "Lunar Performance", "Torque Team", "Sector Racing",
            "Hawk Works", "Chrome GP", "Bison Autosport", "Vertex Performance", "Torque Speed",
            "Ignition Predators", "Horizon Racing", "Titan Motorsport", "Scorpion Predators", "Podium Motors",
            "Phoenix Predators", "Piston Team", "Hawk Motors", "Atlas Squadron", "Thunder Performance",
            "Turbo Predators", "Steel Dynamics", "Cobra Performance", "Orbit Predators", "Nordic Racing",
            "Catalyst Works", "Mantis Performance", "Shark Squadron", "Orion Motors", "Viper GP",
            "Voltage Engineering", "Cobalt Engineering", "Turbo Team", "Scorpion Engineering", "Tempest Motorsport",
            "Arctic Velocity", "Ember Team", "Nebula Speed", "Fusion Predators", "Bronze Racing",
            "Impulse Dynamics", "Lunar Velocity", "Omega Predators", "Mustang Motorsport", "Platinum Performance",
            "Turbo Autosport", "Tempest Dynamics", "Mirage Racing", "Comet Speed", "Velocity Squadron",
            "Copper Engineering", "Swift Dynamics", "Nitro Engineering", "Pioneer Racing", "Panther Works",
            "Bronze Engineering", "Galaxy Motors", "Emerald Works", "Kinetic Engineering", "Onyx GP",
            "Onyx Racing", "Aurora Velocity", "Obsidian Team", "Scorpion GP", "Ridge Dynamics",
            "Lion Autosport", "Kinetic Velocity", "Horizon Squadron", "Rapid Autosport", "Galaxy GP",
            // Utökad namnbas för Division 5 (totalt ~310 lag i spelvärlden).
            "Aero Racing", "Aero Dynamics", "Aero Engineering", "Aero Motors", "Aero GP",
            "Blitz Speed", "Blitz Performance", "Blitz Team", "Blitz Motorsport", "Blitz Works",
            "Boreal Autosport", "Boreal Squadron", "Boreal Racing", "Boreal Dynamics", "Boreal Engineering",
            "Canyon Velocity", "Canyon Predators", "Canyon Speed", "Canyon Performance", "Canyon Team",
            "Cyclone Motors", "Cyclone GP", "Cyclone Autosport", "Cyclone Squadron", "Cyclone Racing",
            "Dynamo Motorsport", "Dynamo Works", "Dynamo Velocity", "Dynamo Predators", "Dynamo Speed",
            "Everest Dynamics", "Everest Engineering", "Everest Motors", "Everest GP", "Everest Autosport",
            "Fjord Performance", "Fjord Team", "Fjord Motorsport", "Fjord Works", "Fjord Velocity",
            "Glacier Squadron", "Glacier Racing", "Glacier Dynamics", "Glacier Engineering", "Glacier Motors",
            "Harbor Predators", "Harbor Speed", "Harbor Performance", "Harbor Team", "Harbor Motorsport",
            "Helix GP", "Helix Autosport", "Helix Squadron", "Helix Racing", "Helix Dynamics",
            "Inferno Works", "Inferno Velocity", "Inferno Predators", "Inferno Speed", "Inferno Performance",
            "Jetstream Engineering", "Jetstream Motors", "Jetstream GP", "Jetstream Autosport", "Jetstream Squadron",
            "Kestrel Team", "Kestrel Motorsport", "Kestrel Works", "Kestrel Velocity", "Kestrel Predators",
            "Lightning Racing", "Lightning Dynamics", "Lightning Engineering", "Lightning Motors", "Lightning GP",
            "Magnum Speed", "Magnum Performance", "Magnum Team", "Magnum Motorsport", "Magnum Works",
            "Meridian Autosport", "Meridian Squadron", "Meridian Racing", "Meridian Dynamics", "Meridian Engineering",
            "Monsoon Velocity", "Monsoon Predators", "Monsoon Speed", "Monsoon Performance", "Monsoon Team",
            "Nimbus Motors", "Nimbus GP", "Nimbus Autosport", "Nimbus Squadron", "Nimbus Racing",
            "Nomad Motorsport", "Nomad Works", "Nomad Velocity", "Nomad Predators", "Nomad Speed",
            "Osprey Dynamics", "Osprey Engineering", "Osprey Motors", "Osprey GP", "Osprey Autosport",
            "Paragon Performance", "Paragon Team", "Paragon Motorsport", "Paragon Works", "Paragon Velocity",
            "Pegasus Squadron", "Pegasus Racing", "Pegasus Dynamics", "Pegasus Engineering", "Pegasus Motors",
            "Polar Predators", "Polar Speed", "Polar Performance", "Polar Team", "Polar Motorsport",
            "Pinnacle GP", "Pinnacle Autosport", "Pinnacle Squadron", "Pinnacle Racing", "Pinnacle Dynamics",
            "Rally Works", "Rally Velocity", "Rally Predators", "Rally Speed", "Rally Performance",
            "Rocket Engineering", "Rocket Motors", "Rocket GP", "Rocket Autosport", "Rocket Squadron",
            "Sabre Team", "Sabre Motorsport", "Sabre Works", "Sabre Velocity", "Sabre Predators",
            "Sierra Racing", "Sierra Dynamics", "Sierra Engineering", "Sierra Motors", "Sierra GP",
            "Sparrow Speed", "Sparrow Performance", "Sparrow Team", "Sparrow Motorsport", "Sparrow Works",
            "Summit Autosport", "Summit Squadron", "Summit Racing", "Summit Dynamics", "Summit Engineering",
            "Talon Velocity", "Talon Predators", "Talon Speed", "Talon Performance", "Talon Team",
            "Tornado Motors", "Tornado GP", "Tornado Autosport", "Tornado Squadron", "Tornado Racing",
            "Tundra Motorsport", "Tundra Works", "Tundra Velocity", "Tundra Predators", "Tundra Speed",
            "Typhoon Dynamics", "Typhoon Engineering", "Typhoon Motors", "Typhoon GP", "Typhoon Autosport",
            "Valkyrie Performance", "Valkyrie Team", "Valkyrie Motorsport", "Valkyrie Works", "Valkyrie Velocity",
            "Vulcan Squadron", "Vulcan Racing", "Vulcan Dynamics", "Vulcan Engineering", "Vulcan Motors",
            "Wildfire Predators", "Wildfire Speed", "Wildfire Performance", "Wildfire Team", "Wildfire Motorsport",
            "Wolf GP", "Wolf Autosport", "Wolf Squadron", "Wolf Racing", "Wolf Dynamics",
            "Zephyr Works", "Zephyr Velocity", "Zephyr Predators", "Zephyr Speed", "Zephyr Performance"
        ];

        function slumpaLagBasNamn(anvandaNamn) {
            anvandaNamn = anvandaNamn || new Set();
            let lediga = aiTeamBasNamn.filter(n => !anvandaNamn.has(n));
            let namn;
            if (lediga.length > 0) {
                namn = lediga[Math.floor(slump() * lediga.length)];
            } else {
                let bas = aiTeamBasNamn[Math.floor(slump() * aiTeamBasNamn.length)];
                let n = 2;
                namn = bas + ' ' + n;
                while (anvandaNamn.has(namn)) { n++; namn = bas + ' ' + n; }
            }
            anvandaNamn.add(namn);
            return namn;
        }

        const ARENA_BAS_NAMN = ["Autodromo", "Circuito", "Speedway", "Motordromo", "Raceway", "Arena", "Velodromo", "Ring", "Piste", "Baan", "Circuit", "Motorpark", "Rennbahn", "Autodrom", "Racepark", "Kartodromo", "Speedpark", "Motorring"];

        const ARENA_SUFFIX = ["Nazionale", "Metropolitano", "Grand Prix", "Speed", "Classic", "Internazionale", "Coastal", "Valley", "Heights", "Park", "Riviera", "Highlands", "Harbour", "Lakeside", "Summit", "Forest", "Canyon", "Bay"];

        function slumpaBana(anvandaNamn) {
            anvandaNamn = anvandaNamn || new Set();
            let namn;
            let forsok = 0;
            do {
                let bas = ARENA_BAS_NAMN[Math.floor(slump() * ARENA_BAS_NAMN.length)];
                let suff = ARENA_SUFFIX[Math.floor(slump() * ARENA_SUFFIX.length)];
                namn = bas + " " + suff;
                forsok++;
                if (forsok > 300) {
                    let grundNamn = namn;
                    let n = 2;
                    while (anvandaNamn.has(namn)) { namn = grundNamn + ' ' + n; n++; }
                    break;
                }
            } while (anvandaNamn.has(namn));
            anvandaNamn.add(namn);
            let langd = (3.5 + slump() * 2.5).toFixed(1);
            let kurvor = Math.floor(8 + slump() * 10);
            return { namn: namn, langd: parseFloat(langd), kurvor: kurvor };
        }

        function nyborjarParts() {
            return { dack: 10, motor: 10, aero: 10, vaxellada: 10, chassi: 10 };
        }

        function initMoral() {
            return 50 + Math.floor(slump() * 30);
        }

        const PRINCIPAL_STAT_KEYS = ['forhandling', 'sponsring', 'moral'];

        function skapaTeamPrincipal(tier, signaturSet, arSpelare) {
            let p = slumpaPerson();
            // Alla nya Team Principals (vid start och vid nyrekrytering) börjar
            // på basnivån 10 i samtliga förmågor och är 40-45 år. Spelarens egen
            // Principal ökar sedan +1 per förmåga och vecka (se
            // utvecklaTeamPrincipal()); datorstyrda lags stannar på 10.
            let stats = { forhandling: 10, sponsring: 10, moral: 10 };
            let principal = {
                id: nyttPersonId(), namn: p.namn, nationalitet: p.nationalitet, age: 40 + Math.floor(slump() * 6),
                stats: stats, formaga: Math.round((stats.forhandling + stats.sponsring + stats.moral) / 3),
                personalHistorik: []
            };
            hooks.skapaAvatar(principal, 'principal', { age: principal.age, forcedGender: 'maskulin' }, signaturSet);
            principal.contract = nyttStabKontrakt(principal.formaga, tier, 'principal');
            return principal;
        }

        function skapaAiPersonalLista(antal, tier, typ, signaturSet) {
            let lista = [];
            let statKeys = typ === 'ingenjor' ? ING_STAT_KEYS : MEK_STAT_KEYS;
            let andraNyckel = typ === 'ingenjor' ? 'taktik' : 'motorkunskap';
            for (let i = 0; i < antal; i++) {
                let p = slumpaPerson();
                let age = 20 + Math.floor(slump() * 11);
                // Datorstyrda lags personal ska ha 10 i sina respektive förmågor
                // (samma "svag basnivå"-konvention som redan används för
                // spelarens egen nya förare i skapaDriverStats() och för
                // nyanställd egen personal i anstallPersonal()). Till skillnad
                // från de anropen fryser vi här ÄVEN Erfarenhet på 10 (istället
                // för att räkna ut den från ålder) så att datorstyrda lags
                // förmåga aldrig kan överstiga 10/100 - se även aldrasAlla(),
                // som av samma skäl inte längre låter Erfarenhet växa för
                // AI-lag.
                let stats = { erfarenhet: 10, snabbhet: 10, press: 10, lagformaga: 10 };
                stats[andraNyckel] = 10;
                let ny = {
                    id: nyttPersonId(),
                    namn: p.namn,
                    age: age,
                    nationalitet: p.nationalitet,
                    stats: stats,
                    formaga: beraknaFormaga(stats, statKeys),
                    rekryDatum: slumpaTidigareDatum(300),
                    bil: (i % 2) + 1,
                    personalKarriar: tomPersonalKarriar(), personalHistorik: []
                };
                hooks.skapaAvatar(ny, typ, { age: age, forcedGender: 'maskulin' }, signaturSet);
                ny.contract = nyttStabKontrakt(ny.formaga, tier, typ);
                lista.push(ny);
            }
            return lista;
        }

        function skapaForarPerson(roll, tier, arSpelare, signaturSet) {
            let p = slumpaPerson();
            let age, stats;
            if (arSpelare) {
                age = 20;
            } else if (roll === 'reserv') {
                age = 20 + Math.floor(slump() * 5);
            } else {
                age = 20 + Math.floor(slump() * 15);
            }
            stats = skapaDriverStats(tier, age, arSpelare, roll);
            if (!arSpelare) {
                // Datorstyrda lags förare ska aldrig ha mer än basnivån (10) i
                // förmåga - till skillnad från Erfarenhet-beräkningen i
                // skapaDriverStats() (som normalt växer med ålder) fryser vi
                // den här på 10 för AI-lagens förare, se även aldrasAlla().
                stats.erfarenhet = 10;
            }
            let ny = {
                id: nyttPersonId(),
                namn: p.namn,
                age: age,
                nationalitet: p.nationalitet,
                style: slumpaStil(),
                stats: stats,
                formaga: beraknaFormaga(stats, DRIVARE_STAT_KEYS),
                popularitet: skapaPopularitet(beraknaFormaga(stats, DRIVARE_STAT_KEYS)),
                rekryDatum: arSpelare ? new Date().toISOString() : slumpaTidigareDatum(400),
                roll: roll,
                traningsval: null,
                // Karriärstatistik: byggs upp lopp för lopp och följer föraren för alltid,
                // oavsett stallbyten – nollställs ALDRIG av säsongsskiftet (till skillnad
                // från lag.poäng). Se korLoppet() och Historia-fliken/Legends.
                karriar: tomKarriar()
            };
            hooks.skapaAvatar(ny, 'forare', { age: age, forcedGender: 'maskulin' }, signaturSet);
            ny.contract = nyttForarKontrakt(ny.formaga, tier, arSpelare);
            return ny;
        }

        function skapaLag(arSpelare, tier, baseNamn, kort, signaturSet, anvandaArenaNamn) {
            let bData = arSpelare ? { namn: "Rookie Speedway", langd: 4.2, kurvor: 12 } : slumpaBana(anvandaArenaNamn);
            let mekAntal = arSpelare ? 0 : (Math.floor(slump() * 8) + 2);
            let ingAntal = arSpelare ? 0 : (Math.floor(slump() * 8) + 2);
            let namn = arSpelare ? "Scuderia Rookie" : (baseNamn + " (" + kort + ")");
            return {
                namn: namn,
                arSpelare: !!arSpelare,
                // Permanent, unikt lag-id – följer laget för alltid (till skillnad från
                // namnet, som spelaren kan byta) och används av Historik/Mästarlista/
                // Troféskåp för att peka ut exakt rätt lag över flera säsonger.
                lagId: nyttPersonId(),
                stallNr: 0,
                // Lagfärger: en gång per lag, deterministiskt utifrån lagnamnet.
                // Ägs av Team-systemet – AvatarSystem läser bara det här objektet.
                teamFarger: genereraTeamFarger(namn),
                land: slumpaNationalitet(),
                presentation: null,
                bana: bData.namn, banaLangd: bData.langd, banaKurvor: bData.kurvor,
                forare: [
                    skapaForarPerson('bil1', tier, arSpelare, signaturSet),
                    skapaForarPerson('bil2', tier, arSpelare, signaturSet),
                    skapaForarPerson('reserv', tier, arSpelare, signaturSet)
                ],
                mekanikerLista: skapaAiPersonalLista(mekAntal, tier, 'mekaniker', signaturSet),
                ingenjorLista: skapaAiPersonalLista(ingAntal, tier, 'ingenjor', signaturSet),
                chefMekanikerId: null,
                chefIngenjorId: null,
                taktikKval: { dack: 'medium', downforce: 50, handling: 50 },
                // bransle: null = "kör på rekommenderad mängd" (se hamtaBransleForLag).
                taktikLopp: { dack: 'medium', downforce: 50, handling: 50, teamorder: 'ingen', bransle: null },
                // Varje bil har sina EGNA fem komponenter (till skillnad från tidigare,
                // då Bil 1 och Bil 2 delade en gemensam komponentuppsättning) – se
                // bilParts()/renderFabrikTab()/uppgraderaDel()/reparateraDel().
                parts1: nyborjarParts(),
                parts2: nyborjarParts(),
                partsSkadad1: {},
                partsSkadad2: {},
                uppgraderingKo1: {},
                uppgraderingKo2: {},
                // Egen ko for pagaende reparationer (skild fran uppgraderingsko:n
                // sa att en skada som intraffar mitt i en pagaende uppgradering av
                // SAMMA komponent inte laser in sig - se reparateraDel()/
                // tillampaFardigaUppgraderingar()).
                reparationsKo1: {},
                reparationsKo2: {},
                moral: initMoral(),
                teamPrincipal: skapaTeamPrincipal(tier, signaturSet, arSpelare),
                poäng: 0, poängBil1: 0, poängBil2: 0,
                // Lagets egen karriärstatistik – till skillnad från poäng (som
                // nollställs varje säsong) byggs detta upp permanent och används
                // av fliken Statistik → Lagstatistik samt Lagsidans Troféskåp.
                karriar: tomKarriar()
            };
        }

        function genereraSchema(lagLista, forutbestamdOrdning) {
            // forutbestamdOrdning (valfri): en redan färdigsorterad lista med
            // exakt samma lag som lagLista, i den ordning de ska vara värdar
            // (se beraknaSchemaOrdning()/avslutaSasongOchOmstrukturera()).
            // Utan den (ny spelvärld, konkursåterstart) slumpas ordningen som
            // tidigare, eftersom det då inte finns någon förra säsong att
            // utgå ifrån.
            let kopia = forutbestamdOrdning || shuffle([...lagLista]);
            let schema = [];
            for (let i = 0; i < 10 && i < kopia.length; i++) {
                schema.push({
                    raceNr: i + 1,
                    arrangorNamn: kopia[i].namn,
                    // Stabilt lag-id för värdlaget – används av arenarekord/arkiv
                    // (se uppdateraArenaRekord() i korLoppet()) för att peka ut
                    // exakt rätt arena, oavsett om laget byter namn senare.
                    arrangorLagId: kopia[i].lagId,
                    banaNamn: kopia[i].bana,
                    banaLangd: kopia[i].banaLangd,
                    banaKurvor: kopia[i].banaKurvor
                });
            }
            return schema;
        }

    root.URMVarld = Object.freeze({
        medSlump, sattAvatarFunktion, sattIdFunktion, skapaAiDivision,
        slumpaNationalitet,
        slumpaPerson,
        slumpaStil,
        slumpaTidigareDatum,
        shuffle,
        nyttPersonId,
        beraknaFormaga,
        erfarenhetForAlder,
        tomKarriar,
        tomPersonalKarriar,
        skapaPopularitet,
        skapaDriverStats,
        teamInitialer,
        genereraTeamFarger,
        slumpaLagBasNamn,
        slumpaBana,
        nyborjarParts,
        initMoral,
        skapaTeamPrincipal,
        skapaAiPersonalLista,
        skapaForarPerson,
        skapaLag,
        genereraSchema,
        avrunda10k,
        baseForarLon,
        baseStabLon,
        basePrincipalLon,
        nyttForarKontrakt,
        nyttStabKontrakt,
        nationalitetPool,
        forarStilar,
        DRIVARE_STAT_KEYS,
        MEK_STAT_KEYS,
        ING_STAT_KEYS,
        ARENA_BAS_NAMN,
        ARENA_SUFFIX,
        PRINCIPAL_STAT_KEYS,
        NAMNPOOLER,
        aiTeamBasNamn,
        TIER_LON_SKALA_FORARE,
        TIER_LON_SKALA_STAB,
        PRINCIPAL_LON_TIER
    });
})(typeof globalThis !== 'undefined' ? globalThis : this);
