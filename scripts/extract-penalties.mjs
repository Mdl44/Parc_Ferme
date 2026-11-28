import fs from 'node:fs/promises';
import path from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {DATA, GRID, MANIFEST, PENALTIES} from './lib/paths.mjs';

const run = promisify(execFile);

const TEAMS = [
    ['racing-bulls', /racing bulls|visa cash app/i],
    ['red-bull', /red bull/i],
    ['mclaren', /mclaren/i],
    ['mercedes', /mercedes/i],
    ['ferrari', /ferrari/i],
    ['williams', /williams/i],
    ['aston-martin', /aston martin/i],
    ['haas', /haas/i],
    ['audi', /audi/i],
    ['alpine', /alpine/i],
    ['cadillac', /cadillac/i]
];
const WORDS = {one: 1, two: 2, three: 3, four: 4, five: 5, six: 6};
const LABELS = ['No / Driver', 'Competitor', 'Time', 'Session', 'Fact', 'Infringement', 'Decision', 'Reason'];

const teamOf = (name) => {
    const hit = TEAMS.find(([, pattern]) => pattern.test(name));
    if (!hit) throw new Error(`unknown team: ${name}`);
    return hit[0];
};
const euros = (s) => Number(s.replace(/[,.]/g, ''));
const squash = (s) => s.replace(/\s+/g, ' ').trim();

async function pdfText(file) {
    const {stdout} = await run('pdftotext', ['-layout', path.join(DATA, file), '-'], {maxBuffer: 1 << 26});
    return stdout;
}

function labelAt(line) {
    const indent = line.length - line.trimStart().length;
    if (indent > 3) return null;
    const rest = line.trimStart();
    return LABELS.find((l) => rest.startsWith(l) && /^\s/.test(rest.slice(l.length))) ?? null;
}

function field(text, label) {
    const lines = text.split('\n');
    const start = lines.findIndex((line) => labelAt(line) === label);
    if (start === -1) return null;
    const parts = [lines[start].trimStart().slice(label.length)];
    for (const line of lines.slice(start + 1)) {
        if (!line.trim() || labelAt(line)) break;
        parts.push(line);
    }
    return squash(parts.join(' '));
}

function entryList(text) {
    const rows = [];
    let fp1 = false;
    for (const line of text.split('\n')) {
        if (/following drivers may also/i.test(line)) fp1 = true;
        const m = line.match(/^\s*(\d{1,3})\s+([A-Z]{3})\s+(.+?)\s{2,}([A-Z]{3})\s{2,}(.+?)\s{2,}(.+?)\s*$/);
        if (m)
            rows.push({fp1, raw: m[1], code: m[2], name: m[3], nationality: m[4], teamName: m[5], constructor: m[6]});
    }
    return rows;
}

function parsePoints(decision) {
    const m = decision.match(/\b(\d+|one|two|three|four|five|six)\s+penalty points?\b/i);
    if (!m) return {points: 0, printedTotal: null};
    const points = WORDS[m[1].toLowerCase()] ?? Number(m[1]);
    const total = decision.match(/total of (\d+)/i);
    return {points, printedTotal: total ? Number(total[1]) : null};
}

function parseFine(decision) {
    if (!/fined\s*€/i.test(decision)) return null;
    const amounts = [...decision.matchAll(/€\s?([\d][\d,.]*\d|\d)/g)].map((m) => euros(m[1]));
    const total = amounts[0];
    const suspended = /suspended/i.test(decision) ? (amounts[1] ?? 0) : 0;
    const party = /competitor[^.]*fined/i.test(decision) ? 'team' : 'driver';
    return {total, suspended, charged: total - suspended, party};
}

const manifest = JSON.parse(await fs.readFile(MANIFEST, 'utf8'));
const drivers = new Map();
const teams = new Map();
const weekends = [];
const warnings = [];

const lists = new Map();
for (const weekend of manifest.weekends) {
    const rows = [];
    for (const doc of weekend.documents.filter((d) => /entry list/i.test(d.title))) {
        rows.push(...entryList(await pdfText(doc.file)));
    }
    lists.set(weekend.order, rows);
}

let footnotes = 0;
const seenNumbers = new Map();
for (const row of [...lists.values()].flat()) {
    const counts = seenNumbers.get(row.name) ?? new Map();
    counts.set(row.raw, (counts.get(row.raw) ?? 0) + 1);
    seenNumbers.set(row.name, counts);
}
const numberOf = new Map(
    [...seenNumbers].map(([name, counts]) => [name, Number([...counts].sort((a, b) => b[1] - a[1])[0][0])])
);
for (const row of [...lists.values()].flat()) {
    const number = numberOf.get(row.name);
    if (row.raw !== String(number)) {
        if (!row.raw.startsWith(String(number)) && !row.raw.endsWith(String(number)))
            throw new Error(`${row.name} has numbers ${row.raw} and ${number}`);
        footnotes++;
    }
    row.number = number;
}

for (const weekend of manifest.weekends) {
    const carTeam = new Map();
    for (const row of lists.get(weekend.order)) {
        const team = teamOf(row.teamName);
        carTeam.set(row.number, team);
        teams.set(team, {id: team, name: row.teamName, constructor: row.constructor});
        const known = drivers.get(row.number);
        if (known?.lastWeekend === weekend.order) continue;
        drivers.set(row.number, {
            number: row.number,
            code: row.code,
            name: row.name,
            nationality: row.nationality,
            team,
            reserve: (known?.reserve ?? true) && row.fp1,
            weekends: (known?.weekends ?? 0) + 1,
            lastWeekend: weekend.order
        });
    }
    if (carTeam.size === 0) warnings.push(`${weekend.event}: no entry list found`);

    const penalties = [];
    for (const doc of weekend.documents) {
        if (!/infringe?ment|decision|offence/i.test(doc.title)) continue;
        const text = await pdfText(doc.file);
        const who = field(text, 'No / Driver');
        const decision = field(text, 'Decision');
        if (!who || !decision) continue;
        const car = who.match(/^(\d+)\s*-\s*(.+)$/);
        if (!car) continue;

        const {points, printedTotal} = parsePoints(decision);
        const fine = parseFine(decision);
        if (points === 0 && !fine) continue;

        const number = Number(car[1]);
        const competitor = field(text, 'Competitor') ?? '';
        const team = carTeam.get(number) ?? teamOf(competitor);
        if (!drivers.has(number)) {
            const name = squash(car[2]);
            drivers.set(number, {
                number,
                code: name.split(' ').at(-1).slice(0, 3).toUpperCase(),
                name,
                nationality: null,
                team,
                reserve: true,
                weekends: 0,
                lastWeekend: weekend.order
            });
        }
        if (fine && fine.party !== 'team') warnings.push(`${doc.file}: fine is not for the team, kept as data only`);

        penalties.push({
            document: Number(text.match(/Document\s+(\d+)/)?.[1] ?? 0),
            title: doc.title,
            file: doc.file,
            keccak256: doc.keccak256,
            car: number,
            driver: drivers.get(number).name,
            team,
            session: field(text, 'Session'),
            fact: field(text, 'Fact'),
            decision,
            points,
            printedTotal,
            fineEur: fine?.total ?? 0,
            fineSuspendedEur: fine?.suspended ?? 0,
            fineChargedEur: fine && fine.party === 'team' ? fine.charged : 0
        });
    }
    penalties.sort((a, b) => a.document - b.document);
    weekends.push({order: weekend.order, event: weekend.event, penalties});
}

const carriedOver = [];
const running = new Map();
for (const weekend of weekends) {
    for (const p of weekend.penalties.filter((x) => x.points > 0)) {
        if (!running.has(p.car)) {
            const before = p.printedTotal === null ? 0 : p.printedTotal - p.points;
            running.set(p.car, before);
            if (before > 0) carriedOver.push({car: p.car, driver: p.driver, points: before});
        }
        const total = running.get(p.car) + p.points;
        running.set(p.car, total);
        if (p.printedTotal !== null && p.printedTotal !== total) {
            warnings.push(`${p.file}: FIA says ${p.printedTotal} points, our running total is ${total}`);
        }
    }
}

const grid = {
    season: manifest.season,
    teams: [...teams.values()].map((t) => ({
        ...t,
        drivers: [...drivers.values()]
            .filter((d) => d.team === t.id)
            .map((d) => d.number)
            .sort((a, b) => a - b)
    })),
    drivers: [...drivers.values()].map(({lastWeekend, ...d}) => d).sort((a, b) => a.number - b.number)
};

await fs.writeFile(GRID, JSON.stringify(grid, null, 2) + '\n');
await fs.writeFile(PENALTIES, JSON.stringify({season: manifest.season, carriedOver, weekends}, null, 2) + '\n');

const all = weekends.flatMap((w) => w.penalties);
console.log(
    `grid: ${grid.teams.length} teams, ${grid.drivers.length} drivers (${grid.drivers.filter((d) => d.reserve).length} reserve)`
);
console.log(
    `penalties: ${all.length} decisions, ${all.reduce((n, p) => n + p.points, 0)} points, €${all.reduce((n, p) => n + p.fineChargedEur, 0).toLocaleString('en')} charged`
);
console.log(
    `carried over from before the summer break: ${carriedOver.map((c) => `#${c.car} ${c.points}`).join(', ') || 'none'}`
);
if (footnotes) console.log(`removed footnote markers glued to ${footnotes} car numbers in the entry lists`);
for (const w of warnings) console.log(`warning: ${w}`);
