// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IStakeManager} from "@account-abstraction/contracts/interfaces/IStakeManager.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {StewardsPanel} from "../src/StewardsPanel.sol";
import {PanelHelper} from "./utils/PanelHelper.sol";

contract Counter {
    uint256 public value;

    error Nope();

    function set(uint256 newValue) external {
        value = newValue;
    }

    function fail() external pure {
        revert Nope();
    }
}

contract StewardsPanelAccountTest is PanelHelper {
    StewardsPanel internal panel;
    Counter internal counter;

    uint256 internal constant KEY_1 = 0xA11CE;
    uint256 internal constant KEY_2 = 0xB0B;
    uint256 internal constant KEY_3 = 0xCA401;
    uint256 internal constant OUTSIDER_KEY = 0xBAD;

    address payable internal bundler = payable(makeAddr("bundler"));

    function setUp() public {
        address[] memory stewards = new address[](3);
        stewards[0] = vm.addr(KEY_1);
        stewards[1] = vm.addr(KEY_2);
        stewards[2] = vm.addr(KEY_3);
        panel = new StewardsPanel(stewards, 2, entryPoint);
        counter = new Counter();
        vm.deal(address(panel), 1 ether);
    }

    function test_EntryPointIsSet() public view {
        assertEq(address(panel.entryPoint()), address(entryPoint));
        assertEq(panel.getNonce(), 0);
    }

    function test_RevertWhen_EntryPointIsZero() public {
        address[] memory stewards = panel.stewards();
        vm.expectRevert(StewardsPanel.InvalidSetup.selector);
        new StewardsPanel(stewards, 2, IEntryPoint(address(0)));
    }

    function test_UserOpHash_MatchesTheStandard() public view {
        PackedUserOperation memory op = _userOp(panel, _one(address(counter), 0, abi.encodeCall(Counter.set, (7))));
        assertEq(entryPoint.getUserOpHash(op), _userOpDigest(op));
    }

    function test_HandleOps_RunsASignedDecisionAndThePanelPaysTheGas() public {
        PackedUserOperation memory op = _signedOp(_one(address(counter), 0, abi.encodeCall(Counter.set, (7))));
        uint256 panelBefore = address(panel).balance;

        vm.expectEmit(false, false, false, true, address(panel));
        emit StewardsPanel.ExecutedViaEntryPoint(1);

        vm.prank(bundler, bundler);
        entryPoint.handleOps(_ops(op), bundler);

        assertEq(counter.value(), 7);
        assertEq(panel.getNonce(), 1);
        assertEq(panel.nonce(), 0);
        assertGt(bundler.balance, 0);
        assertLt(address(panel).balance, panelBefore);
    }

    function test_HandleOps_UsesTheDepositFirst() public {
        BaseAccount.Call[] memory deposit =
            _one(address(entryPoint), 0.5 ether, abi.encodeCall(IStakeManager.depositTo, (address(panel))));
        panel.executeDecision(deposit, _sign(_keys(KEY_1, KEY_2), _digest(panel, deposit, 0)));
        assertEq(panel.entryPointDeposit(), 0.5 ether);

        uint256 balanceBefore = address(panel).balance;
        PackedUserOperation memory op = _signedOp(_one(address(counter), 0, abi.encodeCall(Counter.set, (9))));
        vm.prank(bundler, bundler);
        entryPoint.handleOps(_ops(op), bundler);

        assertEq(counter.value(), 9);
        assertEq(address(panel).balance, balanceBefore);
        assertLt(panel.entryPointDeposit(), 0.5 ether);
    }

    function test_HandleOps_CanCallThePanelItself() public {
        address newSteward = makeAddr("newSteward");
        address old = vm.addr(KEY_3);
        PackedUserOperation memory op =
            _signedOp(_one(address(panel), 0, abi.encodeCall(StewardsPanel.replaceSteward, (old, newSteward))));

        vm.prank(bundler, bundler);
        entryPoint.handleOps(_ops(op), bundler);

        assertTrue(panel.isSteward(newSteward));
        assertFalse(panel.isSteward(old));
    }

    function test_HandleOps_AFailingCallIsUndoneButGasIsPaid() public {
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call(address(counter), 0, abi.encodeCall(Counter.set, (5)));
        calls[1] = BaseAccount.Call(address(counter), 0, abi.encodeCall(Counter.fail, ()));
        PackedUserOperation memory op = _signedOp(calls);
        bytes32 opHash = entryPoint.getUserOpHash(op);

        bytes memory reason =
            abi.encodeWithSelector(StewardsPanel.CallFailed.selector, 1, abi.encodeWithSelector(Counter.Nope.selector));
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit IEntryPoint.UserOperationRevertReason(opHash, address(panel), 0, reason);

        vm.prank(bundler, bundler);
        entryPoint.handleOps(_ops(op), bundler);

        assertEq(counter.value(), 0);
        assertEq(panel.getNonce(), 1);
        assertGt(bundler.balance, 0);
    }

    function test_RevertWhen_UserOpHasOneSignature() public {
        PackedUserOperation memory op = _userOp(panel, _one(address(counter), 0, abi.encodeCall(Counter.set, (7))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_1, entryPoint.getUserOpHash(op));
        op.signature = abi.encodePacked(r, s, v);

        vm.prank(bundler, bundler);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        entryPoint.handleOps(_ops(op), bundler);
    }

    function test_RevertWhen_UserOpIsSignedByOutsiders() public {
        PackedUserOperation memory op = _userOp(panel, _one(address(counter), 0, abi.encodeCall(Counter.set, (7))));
        op.signature = _sign(_keys(KEY_1, OUTSIDER_KEY), entryPoint.getUserOpHash(op));

        vm.prank(bundler, bundler);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        entryPoint.handleOps(_ops(op), bundler);
    }

    function test_RevertWhen_UserOpIsChangedAfterSigning() public {
        PackedUserOperation memory op = _signedOp(_one(address(counter), 0, abi.encodeCall(Counter.set, (7))));
        op.callData =
            abi.encodeCall(BaseAccount.executeBatch, (_one(address(counter), 0, abi.encodeCall(Counter.set, (666)))));

        vm.prank(bundler, bundler);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        entryPoint.handleOps(_ops(op), bundler);
    }

    function test_RevertWhen_UserOpIsReplayed() public {
        PackedUserOperation memory op = _signedOp(_one(address(counter), 0, abi.encodeCall(Counter.set, (7))));
        vm.prank(bundler, bundler);
        entryPoint.handleOps(_ops(op), bundler);

        vm.prank(bundler, bundler);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA25 invalid account nonce"));
        entryPoint.handleOps(_ops(op), bundler);
    }

    function test_RevertWhen_PanelCannotPayForGas() public {
        vm.deal(address(panel), 0);
        PackedUserOperation memory op = _signedOp(_one(address(counter), 0, abi.encodeCall(Counter.set, (7))));

        vm.prank(bundler, bundler);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA21 didn't pay prefund"));
        entryPoint.handleOps(_ops(op), bundler);
    }

    function test_RevertWhen_ExecuteBatchIsCalledDirectly() public {
        BaseAccount.Call[] memory calls = _one(address(counter), 0, abi.encodeCall(Counter.set, (7)));

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, address(this), address(panel), address(entryPoint)
            )
        );
        panel.executeBatch(calls);
    }

    function test_RevertWhen_SingleExecuteIsCalledDirectly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, address(this), address(panel), address(entryPoint)
            )
        );
        panel.execute(address(counter), 0, abi.encodeCall(Counter.set, (7)));
    }

    function test_RevertWhen_ExecuteBatchIsEmpty() public {
        vm.prank(address(entryPoint));
        vm.expectRevert(StewardsPanel.EmptyBatch.selector);
        panel.executeBatch(new BaseAccount.Call[](0));
    }

    function test_ValidateUserOp_ReturnsFailureInsteadOfReverting() public {
        PackedUserOperation memory op = _userOp(panel, _one(address(counter), 0, abi.encodeCall(Counter.set, (7))));
        bytes32 opHash = entryPoint.getUserOpHash(op);
        op.signature = _sign(_keys(KEY_1, OUTSIDER_KEY), opHash);

        vm.prank(address(entryPoint));
        assertEq(panel.validateUserOp(op, opHash, 0), 1);

        op.signature = _sign(_keys(KEY_1, KEY_2), opHash);
        vm.prank(address(entryPoint));
        assertEq(panel.validateUserOp(op, opHash, 0), 0);
    }

    function test_BothPathsWorkSideBySide() public {
        PackedUserOperation memory op = _signedOp(_one(address(counter), 0, abi.encodeCall(Counter.set, (1))));
        vm.prank(bundler, bundler);
        entryPoint.handleOps(_ops(op), bundler);

        BaseAccount.Call[] memory calls = _one(address(counter), 0, abi.encodeCall(Counter.set, (2)));
        panel.executeDecision(calls, _sign(_keys(KEY_2, KEY_3), _digest(panel, calls, 0)));

        assertEq(counter.value(), 2);
        assertEq(panel.getNonce(), 1);
        assertEq(panel.nonce(), 1);
    }

    function _signedOp(BaseAccount.Call[] memory calls) internal view returns (PackedUserOperation memory op) {
        op = _userOp(panel, calls);
        op.signature = _sign(_keys(KEY_1, KEY_2), entryPoint.getUserOpHash(op));
    }
}
