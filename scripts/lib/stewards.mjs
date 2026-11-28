import {
    batchDigest,
    buildUserOp,
    entryPointDomain,
    packSignatures,
    panelDomain,
    signBatch,
    signUserOp,
    userOpDigest
} from './panel.mjs';

const GAS_MARGIN = (gas) => (gas * 12n) / 10n;
const VERIFICATION_GAS = 200_000n;
const PRE_VERIFICATION_GAS = 60_000n;

export async function decide(ctx, calls, signers, submitter) {
    const nonce = await ctx.panel.nonce();
    const domain = panelDomain(ctx.chainId, ctx.panel.target);
    const digest = batchDigest(domain, calls, nonce);
    if (digest !== (await ctx.panel.hashBatch(calls, nonce))) throw new Error('EIP-712 digest differs from the panel');

    const signed = await Promise.all(signers.map((s) => signBatch(s, domain, calls, nonce)));
    const panel = ctx.panel.connect(submitter);
    const signatures = packSignatures(signed);
    const gasLimit = GAS_MARGIN(await panel.executeDecision.estimateGas(calls, signatures));
    const receipt = await (await panel.executeDecision(calls, signatures, {gasLimit})).wait();
    return {receipt, path: 'executeDecision', nonce};
}

export async function decideViaEntryPoint(ctx, calls, signers, bundler) {
    const sender = ctx.panel.target;
    const callData = ctx.panel.interface.encodeFunctionData('executeBatch', [calls]);
    const callGas = await ctx.provider.estimateGas({from: ctx.entryPoint.target, to: sender, data: callData});
    const fees = await ctx.provider.getFeeData();

    const op = buildUserOp({
        sender,
        nonce: await ctx.entryPoint.getNonce(sender, 0),
        callData,
        verificationGasLimit: VERIFICATION_GAS,
        callGasLimit: GAS_MARGIN(callGas),
        preVerificationGas: PRE_VERIFICATION_GAS,
        maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
        maxFeePerGas: fees.maxFeePerGas
    });
    const domain = entryPointDomain(ctx.chainId, ctx.entryPoint.target);
    const opHash = userOpDigest(domain, op);
    if (opHash !== (await ctx.entryPoint.getUserOpHash(op)))
        throw new Error('UserOperation hash differs from the EntryPoint');

    op.signature = packSignatures(await Promise.all(signers.map((s) => signUserOp(s, domain, op))));
    const entryPoint = ctx.entryPoint.connect(bundler);
    const gasLimit = GAS_MARGIN(await entryPoint.handleOps.estimateGas([op], bundler.address));
    const receipt = await (await entryPoint.handleOps([op], bundler.address, {gasLimit})).wait();

    let outcome = null;
    let reason = null;
    for (const log of receipt.logs) {
        if (log.address.toLowerCase() !== ctx.entryPoint.target.toLowerCase()) continue;
        const parsed = ctx.entryPoint.interface.parseLog(log);
        if (parsed?.name === 'UserOperationEvent' && parsed.args.userOpHash === opHash) outcome = parsed.args;
        if (parsed?.name === 'UserOperationRevertReason' && parsed.args.userOpHash === opHash)
            reason = parsed.args.revertReason;
    }
    if (!outcome) throw new Error('the EntryPoint did not report the UserOperation');
    if (!outcome.success) {
        const decoded = reason ? ctx.panel.interface.parseError(reason) : null;
        throw new Error(`UserOperation reverted: ${decoded ? `${decoded.name}(${decoded.args.join(', ')})` : reason}`);
    }
    return {receipt, path: 'EntryPoint', gasCost: outcome.actualGasCost, opHash};
}
