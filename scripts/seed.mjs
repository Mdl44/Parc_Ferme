import fs from 'node:fs/promises';
import path from 'node:path';
import {ZeroHash, formatEther, parseEther} from 'ethers';
import {ACCOUNTS, connect, explain, wallet} from './lib/chain.mjs';
import {call} from './lib/panel.mjs';
import {decide, decideViaEntryPoint} from './lib/stewards.mjs';
import {DATA, GRID, MERKLE, PENALTIES} from './lib/paths.mjs';

const ALL = process.argv.includes('--all');
const TEAM_FUNDS = parseEther('20');
const DRIVER_FUNDS = parseEther('1');
const PANEL_FUNDS = parseEther('2');
const ENTRY_POINT_DEPOSIT = parseEther('1');
const BOND = parseEther('2');

const read = async (file) => JSON.parse(await fs.readFile(file, 'utf8'));
const grid = await read(GRID);
const penalties = await read(PENALTIES);
const roots = await read(path.join(MERKLE, 'roots.json'));
const documents = await read(path.join(DATA, 'documents.json'));

const ctx = await connect();
const {panel, licence, bond, registry, entryPoint, ethUsd, eurUsd, deployer, stewards, provider} = ctx;
const contracts = [panel, licence, bond, registry, entryPoint];

const pairs = [
    [stewards[0], stewards[1]],
    [stewards[1], stewards[2]],
    [stewards[0], stewards[2]]
];
let turn = 0;
const nextPair = () => pairs[turn++ % pairs.length];

const teamWallets = new Map(grid.teams.map((t, i) => [t.id, wallet(ACCOUNTS.firstTeam + i, provider)]));
const driverWallets = new Map(grid.drivers.map((d, i) => [d.number, wallet(ACCOUNTS.firstDriver + i, provider)]));

const stats = {executeDecision: 0, EntryPoint: 0, txs: 0};

async function run(label, calls, {viaEntryPoint = false} = {}) {
    const signers = nextPair();
    try {
        const result = viaEntryPoint
            ? await decideViaEntryPoint(ctx, calls, signers, signers[0])
            : await decide(ctx, calls, signers, signers[0]);
        stats[result.path]++;
        const extra = result.gasCost ? `, gas paid by the panel: ${formatEther(result.gasCost)} ETH` : '';
        console.log(`  ${label} [${result.path}, ${calls.length} call${calls.length > 1 ? 's' : ''}${extra}]`);
    } catch (err) {
        throw new Error(`${label}: ${explain(err, contracts)}`);
    }
}

async function send(label, promise) {
    try {
        const receipt = await (await promise).wait();
        stats.txs++;
        return receipt;
    } catch (err) {
        throw new Error(`${label}: ${explain(err, contracts)}`);
    }
}

if ((await licence.balanceOf(driverWallets.get(grid.drivers[0].number).address)) > 0n) {
    throw new Error('already seeded: restart Anvil and deploy again for a fresh chain');
}

console.log(
    `seeding ${grid.teams.length} teams, ${grid.drivers.length} drivers and ${penalties.weekends.length} weekends`
);

for (const feed of [ethUsd, eurUsd]) {
    const [, answer] = await feed.latestRoundData();
    await send('refresh prices', feed.connect(deployer).setAnswer(answer));
}

for (const w of teamWallets.values())
    await send('fund team', deployer.sendTransaction({to: w.address, value: TEAM_FUNDS}));
for (const w of driverWallets.values())
    await send('fund driver', deployer.sendTransaction({to: w.address, value: DRIVER_FUNDS}));
await send('fund panel', deployer.sendTransaction({to: panel.target, value: PANEL_FUNDS}));
console.log(`funded ${teamWallets.size} teams, ${driverWallets.size} drivers and the panel`);

const setup = [
    ...grid.teams.map((t) => call(bond, 'registerTeam', [teamWallets.get(t.id).address, t.name])),
    ...grid.drivers.map((d) =>
        call(licence, 'mintLicence', [driverWallets.get(d.number).address, d.name, d.code, d.number])
    ),
    ...penalties.carriedOver.map((c) =>
        call(licence, 'addPoints', [driverWallets.get(c.car).address, c.points, ZeroHash])
    ),
    call(entryPoint, 'depositTo', [panel.target], ENTRY_POINT_DEPOSIT)
];
console.log('season setup');
await run(
    `register teams, issue licences, carry over ${penalties.carriedOver.length} drivers' points, fund the EntryPoint`,
    setup
);

const lastWeekend = ALL ? penalties.weekends.length : penalties.weekends.length - 1;

for (const weekend of penalties.weekends) {
    const root = roots.weekends.find((r) => r.order === weekend.order);
    console.log(`${weekend.event}`);

    await run('open the weekend', [call(bond, 'openWeekend')], {viaEntryPoint: true});
    const weekendId = await bond.currentWeekend();
    if (weekendId !== BigInt(weekend.order)) throw new Error(`weekend id ${weekendId} != ${weekend.order}`);

    for (const [id, w] of teamWallets) {
        const debt = await bond.debtOf(w.address);
        if (debt > 0n) await send(`${id} pays debt`, bond.connect(w).payDebt({value: debt}));
        await send(`${id} deposits`, bond.connect(w).depositBond({value: BOND}));
    }
    console.log(`  ${teamWallets.size} teams deposited ${formatEther(BOND)} ETH each`);

    if (weekend.order > lastWeekend) {
        console.log(`  left open: ${weekend.penalties.length} decision(s) to apply live from data/penalties.json`);
        break;
    }

    for (const p of weekend.penalties) {
        const calls = [];
        if (p.points > 0)
            calls.push(call(licence, 'addPoints', [driverWallets.get(p.car).address, p.points, p.keccak256]));
        if (p.fineChargedEur > 0)
            calls.push(call(bond, 'applyFine', [teamWallets.get(p.team).address, p.fineChargedEur, p.keccak256]));
        const what = [
            p.points ? `${p.points} pt` : null,
            p.fineChargedEur ? `€${p.fineChargedEur.toLocaleString('en')}` : null
        ];
        await run(`Doc ${p.document}, car ${p.car}: ${what.filter(Boolean).join(' + ')}`, calls);
    }

    await run(
        'close the weekend and publish its documents',
        [call(bond, 'closeWeekend'), call(registry, 'publishRoot', [weekend.order, root.root, ''])],
        {viaEntryPoint: true}
    );

    for (const [id, w] of teamWallets) {
        if ((await bond.bondOf(weekendId, w.address)) > 0n)
            await send(`${id} withdraws`, bond.connect(w).withdraw(weekendId));
    }
    console.log(`  teams withdrew what was left of their bonds`);
}

console.log('\nchecks');
const expected = new Map();
for (const c of penalties.carriedOver) expected.set(c.car, c.points);
for (const w of penalties.weekends.filter((x) => x.order <= lastWeekend)) {
    for (const p of w.penalties) expected.set(p.car, (expected.get(p.car) ?? 0) + p.points);
}
let mismatches = 0;
for (const [car, points] of expected) {
    const onChain = await licence.points(driverWallets.get(car).address);
    if (onChain !== BigInt(points)) {
        mismatches++;
        console.log(`  car ${car}: on-chain ${onChain}, expected ${points}`);
    }
}
console.log(
    `  penalty points on-chain match the FIA documents for ${expected.size - mismatches}/${expected.size} drivers`
);

const firstWeekend = documents.weekends[0];
const tree = await read(path.join(MERKLE, `${path.basename(firstWeekend.folder)}.json`));
const {StandardMerkleTree} = await import('@openzeppelin/merkle-tree');
const loaded = StandardMerkleTree.load(tree.tree);
const doc = firstWeekend.documents[0];
const ok = await registry.verifyDocument(1, doc.keccak256, loaded.getProof([doc.keccak256]));
console.log(`  "${doc.title}" verifies against the published root: ${ok}`);

const leclerc = grid.drivers.find((d) => d.code === 'LEC') ?? grid.drivers[0];
const uri = await licence.tokenURI(await licence.licenceId(driverWallets.get(leclerc.number).address));
const meta = JSON.parse(Buffer.from(uri.split(',')[1], 'base64').toString());
console.log(
    `  tokenURI is valid JSON: "${meta.name}", ${meta.attributes.map((a) => `${a.trait_type} ${a.value}`).join(', ')}`
);

const treasury = await provider.getBalance(panel.target);
console.log(
    `  panel treasury ${formatEther(treasury)} ETH, EntryPoint deposit ${formatEther(await panel.entryPointDeposit())} ETH`
);
console.log(
    `\ndone: ${stats.executeDecision} decisions with executeDecision, ${stats.EntryPoint} through the EntryPoint, ${stats.txs} team/funding transactions`
);
if (mismatches) process.exitCode = 1;
