import fs from 'node:fs/promises';
import path from 'node:path';
import {StandardMerkleTree} from '@openzeppelin/merkle-tree';
import {MANIFEST, MERKLE} from './lib/paths.mjs';

const manifest = JSON.parse(await fs.readFile(MANIFEST, 'utf8'));
await fs.mkdir(MERKLE, {recursive: true});

const roots = [];
const samples = [];

for (const weekend of manifest.weekends) {
    const hashes = weekend.documents.map((d) => d.keccak256);
    if (hashes.some((h) => !/^0x[0-9a-f]{64}$/.test(h ?? '')))
        throw new Error(`${weekend.event}: run npm run hash first`);

    const tree = StandardMerkleTree.of(
        hashes.map((h) => [h]),
        ['bytes32']
    );
    const name = path.basename(weekend.folder);
    await fs.writeFile(
        path.join(MERKLE, `${name}.json`),
        JSON.stringify({
            order: weekend.order,
            event: weekend.event,
            root: tree.root,
            count: hashes.length,
            tree: tree.dump()
        }) + '\n'
    );
    roots.push({
        order: weekend.order,
        event: weekend.event,
        file: `merkle/${name}.json`,
        root: tree.root,
        count: hashes.length
    });

    for (const index of [0, Math.floor(hashes.length / 2), hashes.length - 1]) {
        samples.push({
            order: weekend.order,
            root: tree.root,
            documentHash: hashes[index],
            proof: tree.getProof([hashes[index]])
        });
    }
    console.log(`${weekend.event}: ${hashes.length} documents, root ${tree.root}`);
}

await fs.writeFile(
    path.join(MERKLE, 'roots.json'),
    JSON.stringify({season: manifest.season, weekends: roots}, null, 2) + '\n'
);
await fs.writeFile(path.join(MERKLE, 'samples.json'), JSON.stringify({samples}, null, 2) + '\n');
console.log(`wrote ${roots.length} trees, roots.json and samples.json (proofs for the Foundry test) to data/merkle/`);
