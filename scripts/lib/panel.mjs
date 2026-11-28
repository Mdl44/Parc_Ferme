import {TypedDataEncoder, concat, toBeHex, zeroPadValue} from 'ethers';

export const BATCH_TYPES = {
    Batch: [
        {name: 'calls', type: 'Call[]'},
        {name: 'nonce', type: 'uint256'}
    ],
    Call: [
        {name: 'target', type: 'address'},
        {name: 'value', type: 'uint256'},
        {name: 'data', type: 'bytes'}
    ]
};

export const USER_OP_TYPES = {
    PackedUserOperation: [
        {name: 'sender', type: 'address'},
        {name: 'nonce', type: 'uint256'},
        {name: 'initCode', type: 'bytes'},
        {name: 'callData', type: 'bytes'},
        {name: 'accountGasLimits', type: 'bytes32'},
        {name: 'preVerificationGas', type: 'uint256'},
        {name: 'gasFees', type: 'bytes32'},
        {name: 'paymasterAndData', type: 'bytes'}
    ]
};

export const panelDomain = (chainId, panel) => ({
    name: 'Parc Ferme Stewards Panel',
    version: '1',
    chainId,
    verifyingContract: panel
});

export const entryPointDomain = (chainId, entryPoint) => ({
    name: 'ERC4337',
    version: '1',
    chainId,
    verifyingContract: entryPoint
});

export const call = (contract, method, args = [], value = 0n) => ({
    target: contract.target,
    value,
    data: contract.interface.encodeFunctionData(method, args)
});

export const batchDigest = (domain, calls, nonce) => TypedDataEncoder.hash(domain, BATCH_TYPES, {calls, nonce});

export async function signBatch(signer, domain, calls, nonce) {
    return {
        signer: await signer.getAddress(),
        signature: await signer.signTypedData(domain, BATCH_TYPES, {calls, nonce})
    };
}

export function packSignatures(signed) {
    const sorted = [...signed].sort((a, b) => (BigInt(a.signer) < BigInt(b.signer) ? -1 : 1));
    return concat(sorted.map((s) => s.signature));
}

export const packUints = (high, low) => zeroPadValue(toBeHex((BigInt(high) << 128n) | BigInt(low)), 32);

export function buildUserOp({
    sender,
    nonce,
    callData,
    verificationGasLimit,
    callGasLimit,
    preVerificationGas,
    maxPriorityFeePerGas,
    maxFeePerGas
}) {
    return {
        sender,
        nonce,
        initCode: '0x',
        callData,
        accountGasLimits: packUints(verificationGasLimit, callGasLimit),
        preVerificationGas,
        gasFees: packUints(maxPriorityFeePerGas, maxFeePerGas),
        paymasterAndData: '0x',
        signature: '0x'
    };
}

const unsigned = ({signature, ...op}) => op;

export const userOpDigest = (domain, op) => TypedDataEncoder.hash(domain, USER_OP_TYPES, unsigned(op));

export async function signUserOp(signer, domain, op) {
    return {
        signer: await signer.getAddress(),
        signature: await signer.signTypedData(domain, USER_OP_TYPES, unsigned(op))
    };
}
