// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StewardsPanel} from "../../src/StewardsPanel.sol";

abstract contract PanelHelper is Test {
    bytes32 private constant CALL_TYPEHASH = keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 private constant BATCH_TYPEHASH =
        keccak256("Batch(Call[] calls,uint256 nonce)Call(address target,uint256 value,bytes data)");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function _digest(StewardsPanel panel, StewardsPanel.Call[] memory calls, uint256 nonce)
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
        returns (StewardsPanel.Call[] memory calls)
    {
        calls = new StewardsPanel.Call[](1);
        calls[0] = StewardsPanel.Call(target, value, data);
    }
}
