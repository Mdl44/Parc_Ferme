import fs from 'node:fs/promises';
import path from 'node:path';
import {keccak256} from 'ethers';
import {DATA, MANIFEST} from './lib/paths.mjs';

const manifest = JSON.parse(await fs.readFile(MANIFEST, 'utf8'));
const seen = new Map();
let count = 0;

for (const weekend of manifest.weekends) {
    for (const doc of weekend.documents) {
        const bytes = await fs.readFile(path.join(DATA, doc.file));
        if (bytes.length !== doc.bytes) throw new Error(`size changed for ${doc.file}`);
        doc.keccak256 = keccak256(bytes);
        if (seen.has(doc.keccak256)) console.log(`  same content as ${seen.get(doc.keccak256)}: ${doc.file}`);
        seen.set(doc.keccak256, doc.file);
        count++;
    }
}

await fs.writeFile(MANIFEST, JSON.stringify(manifest, null, 2) + '\n');
console.log(`hashed ${count} documents (${seen.size} distinct) into data/documents.json`);
