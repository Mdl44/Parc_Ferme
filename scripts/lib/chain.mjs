import fs from 'node:fs';
import path from 'node:path';
import {Contract, HDNodeWallet, JsonRpcProvider, NonceManager} from 'ethers';
import {ADDRESSES, ROOT} from './paths.mjs';

export const MNEMONIC = 'test test test test test test test test test test test junk';
export const RPC_URL = process.env.RPC_URL ?? 'http://127.0.0.1:8545';

export const ACCOUNTS = {
    deployer: 0,
    stewards: [1, 2, 3],
    firstTeam: 10,
    firstDriver: 30
};

const ABIS = path.join(ROOT, 'frontend', 'src', 'contracts', 'abis');

export function provider() {
    return new JsonRpcProvider(RPC_URL, undefined, {cacheTimeout: -1});
}

export function wallet(index, p) {
    return HDNodeWallet.fromPhrase(MNEMONIC, undefined, `m/44'/60'/0'/0/${index}`).connect(p);
}

export function abi(name) {
    const file = path.join(ABIS, `${name}.json`);
    if (!fs.existsSync(file)) throw new Error(`missing ${file}: run "bash script/export-abis.sh" in contracts/`);
    return JSON.parse(fs.readFileSync(file, 'utf8'));
}

export function addresses() {
    if (!fs.existsSync(ADDRESSES))
        throw new Error('no addresses.json: deploy first (forge script script/Deploy.s.sol --broadcast)');
    return JSON.parse(fs.readFileSync(ADDRESSES, 'utf8'));
}

export async function connect() {
    const p = provider();
    const network = await p.getNetwork();
    const a = addresses();
    if (BigInt(a.chainId) !== network.chainId)
        throw new Error(`addresses.json is for chain ${a.chainId}, the RPC is chain ${network.chainId}`);
    if ((await p.getCode(a.stewardsPanel)) === '0x')
        throw new Error('no contract at the panel address: Anvil was restarted, deploy again');

    const deployer = new NonceManager(wallet(ACCOUNTS.deployer, p));
    const c = (address, name, runner = p) => new Contract(address, abi(name), runner);
    return {
        provider: p,
        chainId: network.chainId,
        addresses: a,
        deployer,
        stewards: ACCOUNTS.stewards.map((i) => wallet(i, p)),
        panel: c(a.stewardsPanel, 'StewardsPanel'),
        licence: c(a.superLicence, 'SuperLicenceV2'),
        bond: c(a.teamBond, 'TeamBond'),
        registry: c(a.documentRegistry, 'DocumentRegistry'),
        entryPoint: c(a.entryPoint, 'EntryPoint'),
        ethUsd: c(a.ethUsdFeed, 'MockAggregator'),
        eurUsd: c(a.eurUsdFeed, 'MockAggregator'),
        at: c
    };
}

export function explain(err, contracts) {
    const data = err?.data ?? err?.info?.error?.data ?? err?.error?.data;
    if (typeof data === 'string' && data.length >= 10) {
        for (const contract of contracts) {
            try {
                const parsed = contract.interface.parseError(data);
                if (parsed) return `${parsed.name}(${parsed.args.join(', ')})`;
            } catch {}
        }
    }
    return err?.shortMessage ?? err?.message ?? String(err);
}
