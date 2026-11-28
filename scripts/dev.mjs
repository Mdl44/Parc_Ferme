import {connect} from './lib/chain.mjs';

const [command, arg] = process.argv.slice(2);
const ctx = await connect();
if (ctx.chainId !== 31337n) throw new Error('dev tools only run on Anvil');

async function refreshPrices() {
    for (const feed of [ctx.ethUsd, ctx.eurUsd]) {
        const [, answer] = await feed.latestRoundData();
        await (await feed.connect(ctx.deployer).setAnswer(answer)).wait();
    }
    console.log('mock price feeds refreshed (same prices, new timestamp)');
}

async function warp(days) {
    const seconds = Math.round(Number(days) * 86400);
    if (!Number.isFinite(seconds) || seconds <= 0) throw new Error('usage: npm run warp -- <days>');
    await ctx.provider.send('evm_increaseTime', [seconds]);
    await ctx.provider.send('evm_mine', []);
    const block = await ctx.provider.getBlock('latest');
    console.log(`moved ${days} days forward, chain time is now ${new Date(block.timestamp * 1000).toISOString()}`);
    await refreshPrices();
}

if (command === 'prices') await refreshPrices();
else if (command === 'warp') await warp(arg);
else throw new Error('usage: node dev.mjs prices | node dev.mjs warp <days>');
