// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DocumentRegistry} from "../src/DocumentRegistry.sol";

contract RealDocumentsTest is Test {
    struct Sample {
        bytes32 documentHash;
        uint256 order;
        bytes32[] proof;
        bytes32 root;
    }

    DocumentRegistry internal registry;
    Sample[] internal samples;
    address internal panel = makeAddr("panel");

    function setUp() public {
        registry = new DocumentRegistry(panel);
        string memory json = vm.readFile("../data/merkle/samples.json");
        Sample[] memory loaded = abi.decode(vm.parseJson(json, ".samples"), (Sample[]));

        vm.startPrank(panel);
        for (uint256 i = 0; i < loaded.length; i++) {
            samples.push(loaded[i]);
            if (registry.getRecord(loaded[i].order).root == bytes32(0)) {
                registry.publishRoot(loaded[i].order, loaded[i].root, "");
            }
        }
        vm.stopPrank();
    }

    function test_EveryWeekendHasARoot() public view {
        assertEq(samples.length, 30);
        for (uint256 order = 1; order <= 10; order++) {
            assertTrue(registry.getRecord(order).root != bytes32(0));
        }
    }

    function test_ProofsFromTheJavaScriptTreeVerifyOnChain() public view {
        for (uint256 i = 0; i < samples.length; i++) {
            Sample memory s = samples[i];
            assertTrue(registry.verifyDocument(s.order, s.documentHash, s.proof));
        }
    }

    function test_ADocumentDoesNotVerifyForAnotherWeekend() public view {
        for (uint256 i = 0; i < samples.length; i++) {
            Sample memory s = samples[i];
            uint256 other = s.order == 10 ? 1 : s.order + 1;
            assertFalse(registry.verifyDocument(other, s.documentHash, s.proof));
        }
    }

    function test_AChangedDocumentDoesNotVerify() public view {
        for (uint256 i = 0; i < samples.length; i++) {
            Sample memory s = samples[i];
            bytes32 changed = s.documentHash ^ bytes32(uint256(1));
            assertFalse(registry.verifyDocument(s.order, changed, s.proof));
        }
    }
}
