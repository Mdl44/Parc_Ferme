// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {StewardsPanel} from "../../src/StewardsPanel.sol";

abstract contract PanelHelper is Test {
    bytes32 private constant CALL_TYPEHASH = keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 private constant BATCH_TYPEHASH =
        keccak256("Batch(Call[] calls,uint256 nonce)Call(address target,uint256 value,bytes data)");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant USEROP_TYPEHASH = keccak256(
        "PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData)"
    );

    uint128 internal constant VERIFICATION_GAS = 300_000;
    uint128 internal constant CALL_GAS = 1_000_000;
    uint256 internal constant PRE_VERIFICATION_GAS = 60_000;
    uint128 internal constant GAS_PRICE = 2 gwei;

    IEntryPoint internal entryPoint = IEntryPoint(address(new EntryPoint()));

    function _userOp(StewardsPanel panel, BaseAccount.Call[] memory calls)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(panel);
        op.nonce = entryPoint.getNonce(address(panel), 0);
        op.callData = abi.encodeCall(BaseAccount.executeBatch, (calls));
        op.accountGasLimits = bytes32(uint256(VERIFICATION_GAS) << 128 | CALL_GAS);
        op.preVerificationGas = PRE_VERIFICATION_GAS;
        op.gasFees = bytes32(uint256(GAS_PRICE) << 128 | GAS_PRICE);
    }

    function _userOpDigest(PackedUserOperation memory op) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                USEROP_TYPEHASH,
                op.sender,
                op.nonce,
                keccak256(op.initCode),
                keccak256(op.callData),
                op.accountGasLimits,
                op.preVerificationGas,
                op.gasFees,
                keccak256(op.paymasterAndData)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("ERC4337"), keccak256("1"), block.chainid, address(entryPoint))
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _ops(PackedUserOperation memory op) internal pure returns (PackedUserOperation[] memory ops) {
        ops = new PackedUserOperation[](1);
        ops[0] = op;
    }

    function _digest(StewardsPanel panel, BaseAccount.Call[] memory calls, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        bytes32[] memory callHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            callHashes[i] =
                keccak256(abi.encode(CALL_TYPEHASH, calls[i].target, calls[i].value, keccak256(calls[i].data)));
        }
        bytes32 structHash = keccak256(abi.encode(BATCH_TYPEHASH, keccak256(abi.encodePacked(callHashes)), nonce));
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("Parc Ferme Stewards Panel"), keccak256("1"), block.chainid, address(panel)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256[] memory keys, bytes32 digest) internal pure returns (bytes memory signatures) {
        for (uint256 i = 0; i < keys.length; i++) {
            for (uint256 j = 0; j + 1 < keys.length - i; j++) {
                if (vm.addr(keys[j]) > vm.addr(keys[j + 1])) {
                    (keys[j], keys[j + 1]) = (keys[j + 1], keys[j]);
                }
            }
        }
        for (uint256 i = 0; i < keys.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            signatures = bytes.concat(signatures, abi.encodePacked(r, s, v));
        }
    }

    function _keys(uint256 a, uint256 b) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](2);
        keys[0] = a;
        keys[1] = b;
    }

    function _keys(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](3);
        keys[0] = a;
        keys[1] = b;
        keys[2] = c;
    }

    function _one(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (BaseAccount.Call[] memory calls)
    {
        calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call(target, value, data);
    }
}
