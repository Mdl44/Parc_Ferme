import fs from 'node:fs/promises';
import path from 'node:path';
import {ContractFactory} from 'ethers';
import {abi, connect, explain} from './lib/chain.mjs';
import {call} from './lib/panel.mjs';
import {decideViaEntryPoint} from './lib/stewards.mjs';
import {ADDRESSES, CONTRACTS_OUT} from './lib/paths.mjs';

const ctx = await connect();
const {licence, deployer, stewards} = ctx;

if ((await licence.version()) === '2') {
    console.log('the licence is already on V2');
    process.exit(0);
}

const artifact = JSON.parse(
    await fs.readFile(path.join(CONTRACTS_OUT, 'SuperLicenceV2.sol', 'SuperLicenceV2.json'), 'utf8')
);
const factory = new ContractFactory(abi('SuperLicenceV2'), artifact.bytecode.object, deployer);
const implementation = await factory.deploy();
await implementation.waitForDeployment();
console.log(`V2 implementation deployed at ${implementation.target}`);

const initData = licence.interface.encodeFunctionData('initializeV2');
try {
    const result = await decideViaEntryPoint(
        ctx,
        [call(licence, 'upgradeToAndCall', [implementation.target, initData])],
        [stewards[0], stewards[2]],
        stewards[0]
    );
    console.log(`upgrade decided by stewards 1 and 3 through the EntryPoint (tx ${result.receipt.hash})`);
} catch (err) {
    throw new Error(`upgrade: ${explain(err, [ctx.panel, licence, ctx.entryPoint])}`);
}

const expiresAt = (await licence.upgradedAt()) + (await licence.POINTS_VALIDITY());
console.log(
    `licence version is now ${await licence.version()}; points from before the upgrade expire on ${new Date(Number(expiresAt) * 1000).toISOString().slice(0, 10)}`
);

const addresses = JSON.parse(await fs.readFile(ADDRESSES, 'utf8'));
addresses.superLicenceV1Implementation = addresses.superLicenceImplementation;
addresses.superLicenceImplementation = implementation.target;
await fs.writeFile(ADDRESSES, JSON.stringify(addresses, null, 2) + '\n');
console.log('addresses.json updated');
