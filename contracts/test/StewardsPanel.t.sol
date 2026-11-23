// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {StewardsPanel} from "../src/StewardsPanel.sol";
import {PanelHelper} from "./utils/PanelHelper.sol";

contract Target {
    uint256 public value;
    uint256 public received;

    error Nope(uint256 code);

    function set(uint256 newValue) external payable {
        value = newValue;
        received += msg.value;
    }

    function fail() external pure {
        revert Nope(42);
    }
}

contract ReenteringTarget {
    StewardsPanel public panel;

    function setPanel(StewardsPanel panel_) external {
        panel = panel_;
    }

    function attack() external {
        panel.execute(new StewardsPanel.Call[](1), "");
    }
}

contract StewardsPanelTest is PanelHelper {
    StewardsPanel internal panel;
    Target internal target;

    uint256 internal constant KEY_1 = 0xA11CE;
    uint256 internal constant KEY_2 = 0xB0B;
    uint256 internal constant KEY_3 = 0xCA401;
    uint256 internal constant OUTSIDER_KEY = 0xBAD;

    address internal steward1 = vm.addr(KEY_1);
    address internal steward2 = vm.addr(KEY_2);
    address internal steward3 = vm.addr(KEY_3);
    address internal relayer = makeAddr("relayer");

    function setUp() public {
        address[] memory stewards = new address[](3);
        stewards[0] = steward1;
        stewards[1] = steward2;
        stewards[2] = steward3;
        panel = new StewardsPanel(stewards, 2);
        target = new Target();
    }

    function test_Constructor_SetsStewardsAndThreshold() public view {
        address[] memory list = panel.stewards();
        assertEq(list.length, 3);
        assertEq(list[0], steward1);
        assertEq(panel.threshold(), 2);
        assertTrue(panel.isSteward(steward2));
        assertFalse(panel.isSteward(relayer));
        assertEq(panel.nonce(), 0);
    }

    function test_RevertWhen_ConstructorIsInvalid() public {
        address[] memory three = new address[](3);
        three[0] = steward1;
        three[1] = steward2;
        three[2] = steward3;

        vm.expectRevert(StewardsPanel.InvalidSetup.selector);
        new StewardsPanel(three, 0);

        vm.expectRevert(StewardsPanel.InvalidSetup.selector);
        new StewardsPanel(three, 4);

        three[2] = steward1;
        vm.expectRevert(StewardsPanel.InvalidSetup.selector);
        new StewardsPanel(three, 2);

        three[2] = address(0);
        vm.expectRevert(StewardsPanel.InvalidSetup.selector);
        new StewardsPanel(three, 2);
    }

    function test_HashBatch_MatchesTheStandard() public view {
        StewardsPanel.Call[] memory calls = new StewardsPanel.Call[](2);
        calls[0] = StewardsPanel.Call(address(target), 1 ether, abi.encodeCall(Target.set, (7)));
        calls[1] = StewardsPanel.Call(address(0xdead), 0, "");

        assertEq(panel.hashBatch(calls, 5), _digest(panel, calls, 5));
    }

    function test_Execute_WithTwoOfThree() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, 0));

        vm.expectEmit(true, true, false, true, address(panel));
        emit StewardsPanel.Executed(0, relayer, 1);

        vm.prank(relayer);
        panel.execute(calls, sigs);

        assertEq(target.value(), 7);
        assertEq(panel.nonce(), 1);
    }

    function test_Execute_WithAllThree() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (8)));
        panel.execute(calls, _sign(_keys(KEY_1, KEY_2, KEY_3), _digest(panel, calls, 0)));
        assertEq(target.value(), 8);
    }

    function test_Execute_AnyTwoStewardsWork() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (1)));
        panel.execute(calls, _sign(_keys(KEY_2, KEY_3), _digest(panel, calls, 0)));

        calls = _one(address(target), 0, abi.encodeCall(Target.set, (2)));
        panel.execute(calls, _sign(_keys(KEY_1, KEY_3), _digest(panel, calls, 1)));

        assertEq(target.value(), 2);
        assertEq(panel.nonce(), 2);
    }

    function test_Execute_BatchRunsInOrderAndSendsEth() public {
        vm.deal(address(panel), 5 ether);
        address payable recipient = payable(makeAddr("recipient"));

        StewardsPanel.Call[] memory calls = new StewardsPanel.Call[](2);
        calls[0] = StewardsPanel.Call(address(target), 1 ether, abi.encodeCall(Target.set, (10)));
        calls[1] = StewardsPanel.Call(recipient, 2 ether, "");

        panel.execute(calls, _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, 0)));

        assertEq(target.value(), 10);
        assertEq(target.received(), 1 ether);
        assertEq(recipient.balance, 2 ether);
        assertEq(address(panel).balance, 2 ether);
    }

    function test_Execute_IfOneCallFailsEverythingIsUndone() public {
        StewardsPanel.Call[] memory calls = new StewardsPanel.Call[](2);
        calls[0] = StewardsPanel.Call(address(target), 0, abi.encodeCall(Target.set, (99)));
        calls[1] = StewardsPanel.Call(address(target), 0, abi.encodeCall(Target.fail, ()));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, 0));

        vm.expectRevert(
            abi.encodeWithSelector(
                StewardsPanel.CallFailed.selector, 1, abi.encodeWithSelector(Target.Nope.selector, 42)
            )
        );
        panel.execute(calls, sigs);

        assertEq(target.value(), 0);
        assertEq(panel.nonce(), 0);
    }

    function test_RevertWhen_BatchIsEmpty() public {
        vm.expectRevert(StewardsPanel.EmptyBatch.selector);
        panel.execute(new StewardsPanel.Call[](0), "");
    }

    function test_RevertWhen_OnlyOneSignature() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _signBy(KEY_1, _digest(panel, calls, 0));

        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, sigs);
    }

    function test_RevertWhen_NoSignatures() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, "");
    }

    function test_RevertWhen_SameStewardSignsTwice() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory one = _signBy(KEY_1, _digest(panel, calls, 0));

        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, bytes.concat(one, one));
    }

    function test_RevertWhen_SignaturesAreInTheWrongOrder() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes32 digest = _digest(panel, calls, 0);
        (uint256 low, uint256 high) = steward1 < steward2 ? (KEY_1, KEY_2) : (KEY_2, KEY_1);

        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, bytes.concat(_signBy(high, digest), _signBy(low, digest)));

        panel.execute(calls, bytes.concat(_signBy(low, digest), _signBy(high, digest)));
        assertEq(target.value(), 7);
    }

    function test_RevertWhen_OneSignerIsNotASteward() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _sign(_keys(KEY_1, OUTSIDER_KEY), _digest(panel, calls, 0));

        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, sigs);
    }

    function test_RevertWhen_SignatureLengthIsWrong() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, 0));
        bytes memory cut = new bytes(sigs.length - 1);
        for (uint256 i = 0; i < cut.length; i++) {
            cut[i] = sigs[i];
        }

        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, cut);
    }

    function test_RevertWhen_TheCallsAreChangedAfterSigning() public {
        StewardsPanel.Call[] memory signed = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(panel, signed, 0));

        StewardsPanel.Call[] memory tampered = _one(address(target), 0, abi.encodeCall(Target.set, (1000)));
        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(tampered, sigs);
    }

    function test_RevertWhen_ReplayingAnExecutedBatch() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 1 ether, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, 0));
        vm.deal(address(panel), 10 ether);

        panel.execute(calls, sigs);

        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, sigs);
        assertEq(target.received(), 1 ether);
    }

    function test_RevertWhen_SignedForAnotherNonce() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, 1));

        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, sigs);
    }

    function test_RevertWhen_SignedForAnotherChain() public {
        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, 0));

        vm.chainId(block.chainid + 1);
        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, sigs);
    }

    function test_RevertWhen_SignedForAnotherPanel() public {
        address[] memory stewards = panel.stewards();
        StewardsPanel other = new StewardsPanel(stewards, 2);

        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(other, calls, 0));

        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, sigs);
    }

    function test_RevertWhen_ExecuteIsReentered() public {
        ReenteringTarget evil = new ReenteringTarget();
        evil.setPanel(panel);

        StewardsPanel.Call[] memory calls = _one(address(evil), 0, abi.encodeCall(ReenteringTarget.attack, ()));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, 0));

        bytes memory inner = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.expectRevert(abi.encodeWithSelector(StewardsPanel.CallFailed.selector, 0, inner));
        panel.execute(calls, sigs);
    }

    function testFuzz_RevertWhen_SignedByNonStewards(uint256 keyA, uint256 keyB) public {
        uint256 n = 115792089237316195423570985008687907852837564279074904382605163141518161494337;
        keyA = bound(keyA, 1, n - 1);
        keyB = bound(keyB, 1, n - 1);
        vm.assume(keyA != keyB);
        vm.assume(!panel.isSteward(vm.addr(keyA)) && !panel.isSteward(vm.addr(keyB)));

        StewardsPanel.Call[] memory calls = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _sign(_keys(keyA, keyB), _digest(panel, calls, 0));

        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(calls, sigs);
    }

    function test_Receive_AcceptsEthAndEmits() public {
        vm.deal(relayer, 3 ether);

        vm.expectEmit(true, false, false, true, address(panel));
        emit StewardsPanel.Received(relayer, 3 ether);

        vm.prank(relayer);
        (bool ok,) = address(panel).call{value: 3 ether}("");

        assertTrue(ok);
        assertEq(address(panel).balance, 3 ether);
    }

    function test_ReplaceSteward_OnlyThroughASignedBatch() public {
        address newSteward = makeAddr("newSteward");

        vm.prank(steward1);
        vm.expectRevert(abi.encodeWithSelector(StewardsPanel.NotThePanel.selector, steward1));
        panel.replaceSteward(steward3, newSteward);

        StewardsPanel.Call[] memory calls =
            _one(address(panel), 0, abi.encodeCall(StewardsPanel.replaceSteward, (steward3, newSteward)));

        vm.expectEmit(true, true, false, false, address(panel));
        emit StewardsPanel.StewardReplaced(steward3, newSteward);
        panel.execute(calls, _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, 0)));

        assertTrue(panel.isSteward(newSteward));
        assertFalse(panel.isSteward(steward3));
        assertEq(panel.stewards()[2], newSteward);

        StewardsPanel.Call[] memory next = _one(address(target), 0, abi.encodeCall(Target.set, (7)));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_3), _digest(panel, next, 1));
        vm.expectRevert(StewardsPanel.InvalidSignatures.selector);
        panel.execute(next, sigs);
    }

    function test_RevertWhen_ReplacingWithBadAddresses() public {
        vm.startPrank(address(panel));
        vm.expectRevert(abi.encodeWithSelector(StewardsPanel.NotASteward.selector, relayer));
        panel.replaceSteward(relayer, makeAddr("x"));

        vm.expectRevert(abi.encodeWithSelector(StewardsPanel.AlreadyASteward.selector, steward2));
        panel.replaceSteward(steward1, steward2);

        vm.expectRevert(abi.encodeWithSelector(StewardsPanel.AlreadyASteward.selector, address(0)));
        panel.replaceSteward(steward1, address(0));
        vm.stopPrank();
    }

    function test_Erc1271_ValidWithEnoughSignatures() public view {
        bytes32 hash = keccak256("some message");
        bytes memory sigs = _sign(_keys(KEY_1, KEY_3), hash);

        assertEq(panel.isValidSignature(hash, sigs), IERC1271.isValidSignature.selector);
        assertTrue(SignatureChecker.isValidSignatureNow(address(panel), hash, sigs));
    }

    function test_Erc1271_InvalidWhenNotEnoughOrWrong() public view {
        bytes32 hash = keccak256("some message");

        assertEq(panel.isValidSignature(hash, _signBy(KEY_1, hash)), bytes4(0xffffffff));
        assertEq(panel.isValidSignature(hash, _sign(_keys(KEY_1, OUTSIDER_KEY), hash)), bytes4(0xffffffff));
        assertEq(panel.isValidSignature(hash, _sign(_keys(KEY_1, KEY_2), keccak256("other"))), bytes4(0xffffffff));
        assertFalse(SignatureChecker.isValidSignatureNow(address(panel), hash, ""));
    }

    function _signBy(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
