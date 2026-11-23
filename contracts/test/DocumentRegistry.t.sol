// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DocumentRegistry} from "../src/DocumentRegistry.sol";

contract DocumentRegistryTest is Test {
    DocumentRegistry internal registry;

    address internal panel = makeAddr("panel");
    address internal stranger = makeAddr("stranger");

    bytes32 internal doc0 = keccak256("decision-01.pdf");
    bytes32 internal doc1 = keccak256("decision-02.pdf");
    bytes32 internal doc2 = keccak256("decision-03.pdf");
    bytes32 internal doc3 = keccak256("decision-04.pdf");

    bytes32 internal root;
    bytes32[] internal leaves;
    string internal constant CID = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

    function setUp() public {
        registry = new DocumentRegistry(panel);

        leaves.push(_leaf(doc0));
        leaves.push(_leaf(doc1));
        leaves.push(_leaf(doc2));
        leaves.push(_leaf(doc3));
        root = _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
    }

    function test_PublishRoot() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit DocumentRegistry.RootPublished(1, root, CID);

        vm.prank(panel);
        registry.publishRoot(1, root, CID);

        DocumentRegistry.WeekendRecord memory record = registry.getRecord(1);
        assertEq(record.root, root);
        assertEq(record.cid, CID);
        assertEq(record.publishedAt, block.timestamp);
    }

    function test_RevertWhen_NonPanelPublishes() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DocumentRegistry.NotPanel.selector, stranger));
        registry.publishRoot(1, root, CID);
    }

    function test_RevertWhen_PublishingTwiceForTheSameWeekend() public {
        vm.startPrank(panel);
        registry.publishRoot(1, root, CID);
        vm.expectRevert(abi.encodeWithSelector(DocumentRegistry.RootAlreadyPublished.selector, 1));
        registry.publishRoot(1, keccak256("another root"), CID);
        vm.stopPrank();

        assertEq(registry.getRecord(1).root, root);
    }

    function test_RevertWhen_RootIsEmpty() public {
        vm.prank(panel);
        vm.expectRevert(DocumentRegistry.EmptyRoot.selector);
        registry.publishRoot(1, bytes32(0), CID);
    }

    function test_RevertWhen_PanelIsZero() public {
        vm.expectRevert(DocumentRegistry.ZeroAddress.selector);
        new DocumentRegistry(address(0));
    }

    function test_DifferentWeekendsAreIndependent() public {
        bytes32 otherRoot = keccak256("other weekend");
        vm.startPrank(panel);
        registry.publishRoot(1, root, CID);
        registry.publishRoot(2, otherRoot, "cid-2");
        vm.stopPrank();

        assertEq(registry.getRecord(1).root, root);
        assertEq(registry.getRecord(2).root, otherRoot);
        assertEq(registry.getRecord(3).root, bytes32(0));
    }

    function test_Verify_EveryDocumentOfTheTree() public {
        vm.prank(panel);
        registry.publishRoot(1, root, CID);

        assertTrue(registry.verifyDocument(1, doc0, _proof(leaves[1], _pair(leaves[2], leaves[3]))));
        assertTrue(registry.verifyDocument(1, doc1, _proof(leaves[0], _pair(leaves[2], leaves[3]))));
        assertTrue(registry.verifyDocument(1, doc2, _proof(leaves[3], _pair(leaves[0], leaves[1]))));
        assertTrue(registry.verifyDocument(1, doc3, _proof(leaves[2], _pair(leaves[0], leaves[1]))));
    }

    function test_Verify_RejectsAFakeDocument() public {
        vm.prank(panel);
        registry.publishRoot(1, root, CID);

        bytes32 fake = keccak256("forged-decision.pdf");
        assertFalse(registry.verifyDocument(1, fake, _proof(leaves[1], _pair(leaves[2], leaves[3]))));
    }

    function test_Verify_RejectsAWrongProof() public {
        vm.prank(panel);
        registry.publishRoot(1, root, CID);

        assertFalse(registry.verifyDocument(1, doc0, _proof(leaves[3], _pair(leaves[0], leaves[1]))));
        assertFalse(registry.verifyDocument(1, doc0, new bytes32[](0)));
    }

    function test_Verify_DocumentFromAnotherWeekendFails() public {
        vm.startPrank(panel);
        registry.publishRoot(1, root, CID);
        registry.publishRoot(2, keccak256("other root"), "cid-2");
        vm.stopPrank();

        assertFalse(registry.verifyDocument(2, doc0, _proof(leaves[1], _pair(leaves[2], leaves[3]))));
    }

    function test_Verify_InnerNodeCannotPassAsADocument() public {
        vm.prank(panel);
        registry.publishRoot(1, root, CID);

        bytes32 n01 = _pair(leaves[0], leaves[1]);
        assertFalse(registry.verifyDocument(1, n01, _proof(_pair(leaves[2], leaves[3]))));
    }

    function test_RevertWhen_VerifyingAWeekendWithNoRoot() public {
        vm.expectRevert(abi.encodeWithSelector(DocumentRegistry.NoRoot.selector, 7));
        registry.verifyDocument(7, doc0, new bytes32[](0));
    }

    function test_LeafOf_MatchesTheOffChainFormula() public view {
        assertEq(registry.leafOf(doc0), keccak256(bytes.concat(keccak256(abi.encode(doc0)))));
    }

    function testFuzz_TwoDocumentTree(bytes32 a, bytes32 b, bytes32 c) public {
        vm.assume(a != b && c != a && c != b);
        bytes32 treeRoot = _pair(_leaf(a), _leaf(b));

        vm.prank(panel);
        registry.publishRoot(9, treeRoot, CID);

        assertTrue(registry.verifyDocument(9, a, _proof(_leaf(b))));
        assertTrue(registry.verifyDocument(9, b, _proof(_leaf(a))));
        assertFalse(registry.verifyDocument(9, c, _proof(_leaf(b))));
    }

    function _leaf(bytes32 documentHash) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(documentHash))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proof(bytes32 a) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = a;
    }

    function _proof(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        proof[0] = a;
        proof[1] = b;
    }
}
