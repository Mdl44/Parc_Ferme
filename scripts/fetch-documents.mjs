import fs from 'node:fs/promises';
import path from 'node:path';
import {DATA, MANIFEST} from './lib/paths.mjs';

const BASE = 'https://www.fia.com';
const SEASON = `${BASE}/documents/championships/fia-formula-one-world-championship-14/season/season-2026-2072/event/`;
const EVENTS = [
    'Dutch Grand Prix',
    'Italian Grand Prix',
    'Spanish Grand Prix',
    'Azerbaijan Grand Prix',
    'Bahrain Grand Prix',
    'Singapore Grand Prix',
    'United States Grand Prix',
    'Mexico City Grand Prix',
    'São Paulo Grand Prix',
    'Las Vegas Grand Prix'
];
const PAUSE_MS = 6000;
const HEADERS = {'User-Agent': 'Mozilla/5.0 (course project document fetcher)'};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function get(url) {
    let wait = 30;
    for (let attempt = 0; attempt < 20; attempt++) {
        let delay = wait;
        try {
            const res = await fetch(url, {headers: HEADERS, signal: AbortSignal.timeout(60_000)});
            if (res.ok) return Buffer.from(await res.arrayBuffer());
            if (res.status !== 429 && res.status < 500) throw new Error(`HTTP ${res.status} for ${url}`);
            delay = Number(res.headers.get('retry-after')) || wait;
            console.log(`  server busy (${res.status}), waiting ${delay}s`);
        } catch (err) {
            if (err.message.startsWith('HTTP ')) throw err;
            console.log(`  network error (${err.message}), waiting ${delay}s`);
        }
        await sleep(delay * 1000);
        wait = Math.min(wait * 2, 300);
    }
    throw new Error(`gave up after 20 attempts: ${url}`);
}

const decode = (s) =>
    s
        .replace(/&amp;/g, '&')
        .replace(/&quot;/g, '"')
        .replace(/&#0?39;/g, "'")
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&nbsp;/g, ' ');
const text = (fragment) =>
    decode(fragment.replace(/<[^>]+>/g, ' '))
        .replace(/\s+/g, ' ')
        .trim();
const slug = (name) =>
    name
        .normalize('NFD')
        .replace(/[\u0300-\u036f]/g, '')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-|-$/g, '');

async function exists(file) {
    try {
        await fs.access(file);
        return true;
    } catch {
        return false;
    }
}

const manifest = {season: 2026, source: `${BASE}/documents`, weekends: []};
let totalBytes = 0;

for (const [index, event] of EVENTS.entries()) {
    const order = index + 1;
    await sleep(PAUSE_MS);
    const page = (await get(SEASON + encodeURIComponent(event))).toString('utf8');
    const folder = `2026/${String(order).padStart(2, '0')}-${slug(event)}`;
    await fs.mkdir(path.join(DATA, folder), {recursive: true});

    const documents = [];
    for (const row of page.split('class="document-row').slice(1)) {
        const href = row.match(/href="([^"]+\.pdf)"/);
        if (!href) continue;
        const url = new URL(href[1], BASE).href;
        const title = row.match(/<div class="title">([\s\S]*?)<\/div>/);
        const published = text(row).match(/Published on\s*([0-9.]+\s+[0-9:]+)/);
        const file = `${folder}/${path.basename(new URL(url).pathname)}`;
        const full = path.join(DATA, file);

        if (!(await exists(full))) {
            const pdf = await get(url);
            if (pdf.subarray(0, 4).toString() !== '%PDF') {
                console.log(`  not a PDF, skipped: ${url}`);
                continue;
            }
            await fs.writeFile(full, pdf);
            await sleep(PAUSE_MS);
        }
        const {size} = await fs.stat(full);
        totalBytes += size;
        documents.push({
            title: title ? text(title[1]) : path.basename(file),
            published: published ? published[1] : null,
            file,
            bytes: size,
            url
        });
    }
    manifest.weekends.push({order, event: `2026 ${event}`, folder, documents});
    console.log(`${String(order).padStart(2, '0')} ${event}: ${documents.length} documents`);
}

await fs.writeFile(MANIFEST, JSON.stringify(manifest, null, 2) + '\n');
const count = manifest.weekends.reduce((n, w) => n + w.documents.length, 0);
console.log(`done: ${count} documents, ${(totalBytes / 1048576).toFixed(1)} MB`);
console.log('next: npm run data (adds the hashes, penalties and Merkle trees)');
