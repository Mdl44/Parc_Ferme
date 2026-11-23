// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TeamBond} from "../src/TeamBond.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";

contract ReentrantTeam {
    TeamBond public immutable bond;
    uint256 public weekendId;
    bool public reentryBlocked;

    constructor(TeamBond bond_) {
        bond = bond_;
    }

    function deposit() external payable {
        bond.depositBond{value: msg.value}();
    }

    function attack(uint256 weekendId_) external {
        weekendId = weekendId_;
        bond.withdraw(weekendId_);
    }

    receive() external payable {
        try bond.withdraw(weekendId) {}
        catch {
            reentryBlocked = true;
        }
    }
}

contract RejectsEth {}

contract TeamBondTest is Test {
    TeamBond internal bond;
    MockAggregator internal ethUsd;
    MockAggregator internal eurUsd;

    address internal panel = makeAddr("panel");
    address internal ferrari = makeAddr("ferrari");
    address internal mclaren = makeAddr("mclaren");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MIN_BOND = 0.1 ether;
    uint256 internal constant FINE_SCALE = 1000;
    uint256 internal constant MAX_AGE = 1 days;

    function setUp() public {
        ethUsd = new MockAggregator("ETH / USD", 8, 3000e8);
        eurUsd = new MockAggregator("EUR / USD", 8, 1.1e8);
        bond = new TeamBond(panel, ethUsd, eurUsd, MIN_BOND, FINE_SCALE, MAX_AGE);

        vm.deal(ferrari, 100 ether);
        vm.deal(mclaren, 100 ether);
    }

    function test_Constructor_SetsEverything() public view {
        assertEq(bond.panel(), panel);
        assertEq(address(bond.ethUsdFeed()), address(ethUsd));
        assertEq(address(bond.eurUsdFeed()), address(eurUsd));
        assertEq(bond.minBond(), MIN_BOND);
        assertEq(bond.fineScale(), FINE_SCALE);
        assertEq(bond.maxPriceAge(), MAX_AGE);
        assertEq(bond.currentWeekend(), 0);
    }

    function test_RevertWhen_ConstructorGetsZeroAddress() public {
        vm.expectRevert(TeamBond.ZeroAddress.selector);
        new TeamBond(address(0), ethUsd, eurUsd, MIN_BOND, FINE_SCALE, MAX_AGE);
    }

    function test_RevertWhen_ConstructorGetsZeroScale() public {
        vm.expectRevert(TeamBond.InvalidSetting.selector);
        new TeamBond(panel, ethUsd, eurUsd, MIN_BOND, 0, MAX_AGE);
    }

    function test_RevertWhen_FeedsHaveDifferentDecimals() public {
        MockAggregator odd = new MockAggregator("EUR / USD", 18, 1.1e18);
        vm.expectRevert(TeamBond.FeedDecimalsMismatch.selector);
        new TeamBond(panel, ethUsd, odd, MIN_BOND, FINE_SCALE, MAX_AGE);
    }

    function test_OpenWeekend() public {
        vm.expectEmit(true, false, false, false, address(bond));
        emit TeamBond.WeekendOpened(1);

        vm.prank(panel);
        uint256 id = bond.openWeekend();

        assertEq(id, 1);
        assertEq(bond.currentWeekend(), 1);
        assertEq(uint256(bond.weekendStatus(1)), uint256(TeamBond.WeekendStatus.Open));
    }

    function test_RevertWhen_OpeningWeekendWhileAnotherIsOpen() public {
        _open();
        vm.prank(panel);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.PreviousWeekendNotClosed.selector, 1));
        bond.openWeekend();
    }

    function test_OpenNextWeekendAfterClosing() public {
        _open();
        _close();
        vm.prank(panel);
        assertEq(bond.openWeekend(), 2);
    }

    function test_CloseWeekend() public {
        _open();

        vm.expectEmit(true, false, false, false, address(bond));
        emit TeamBond.WeekendClosed(1);
        _close();

        assertEq(uint256(bond.weekendStatus(1)), uint256(TeamBond.WeekendStatus.Closed));
    }

    function test_RevertWhen_ClosingWithoutOpenWeekend() public {
        vm.prank(panel);
        vm.expectRevert(TeamBond.WeekendNotOpen.selector);
        bond.closeWeekend();

        _open();
        _close();
        vm.prank(panel);
        vm.expectRevert(TeamBond.WeekendNotOpen.selector);
        bond.closeWeekend();
    }

    function test_RevertWhen_NonPanelManagesWeekends() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotPanel.selector, stranger));
        bond.openWeekend();
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotPanel.selector, stranger));
        bond.closeWeekend();
        vm.stopPrank();
    }

    function test_RegisterTeam() public {
        vm.expectEmit(true, false, false, false, address(bond));
        emit TeamBond.TeamRegistered(ferrari);

        vm.prank(panel);
        bond.registerTeam(ferrari);

        assertTrue(bond.isTeam(ferrari));
        assertFalse(bond.isTeam(mclaren));
    }

    function test_RevertWhen_RegisteringTwiceOrZeroOrNotPanel() public {
        vm.startPrank(panel);
        bond.registerTeam(ferrari);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.AlreadyRegistered.selector, ferrari));
        bond.registerTeam(ferrari);
        vm.expectRevert(TeamBond.ZeroAddress.selector);
        bond.registerTeam(address(0));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotPanel.selector, stranger));
        bond.registerTeam(mclaren);
    }

    function test_Settings() public {
        vm.startPrank(panel);

        vm.expectEmit(false, false, false, true, address(bond));
        emit TeamBond.MinBondChanged(MIN_BOND, 1 ether);
        bond.setMinBond(1 ether);

        vm.expectEmit(false, false, false, true, address(bond));
        emit TeamBond.FineScaleChanged(FINE_SCALE, 10);
        bond.setFineScale(10);

        vm.expectEmit(false, false, false, true, address(bond));
        emit TeamBond.MaxPriceAgeChanged(MAX_AGE, 2 days);
        bond.setMaxPriceAge(2 days);

        vm.stopPrank();

        assertEq(bond.minBond(), 1 ether);
        assertEq(bond.fineScale(), 10);
        assertEq(bond.maxPriceAge(), 2 days);
    }

    function test_RevertWhen_SettingsAreInvalidOrNotPanel() public {
        vm.startPrank(panel);
        vm.expectRevert(TeamBond.InvalidSetting.selector);
        bond.setFineScale(0);
        vm.expectRevert(TeamBond.InvalidSetting.selector);
        bond.setMaxPriceAge(0);
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotPanel.selector, stranger));
        bond.setMinBond(1);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotPanel.selector, stranger));
        bond.setFineScale(1);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotPanel.selector, stranger));
        bond.setMaxPriceAge(1);
        vm.stopPrank();
    }

    function test_DepositBond() public {
        _openWithTeams();

        vm.expectEmit(true, true, false, true, address(bond));
        emit TeamBond.BondDeposited(1, ferrari, 1 ether, 1 ether);

        vm.prank(ferrari);
        bond.depositBond{value: 1 ether}();

        assertEq(bond.bondOf(1, ferrari), 1 ether);
        assertEq(address(bond).balance, 1 ether);
    }

    function test_DepositBond_TopUpAddsToTheBond() public {
        _openWithTeams();
        _deposit(ferrari, 1 ether);
        _deposit(ferrari, 0.5 ether);
        assertEq(bond.bondOf(1, ferrari), 1.5 ether);
    }

    function test_RevertWhen_DepositByNonTeam() public {
        _openWithTeams();
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotATeam.selector, stranger));
        bond.depositBond{value: 1 ether}();
    }

    function test_RevertWhen_DepositWithoutOpenWeekend() public {
        vm.prank(panel);
        bond.registerTeam(ferrari);

        vm.prank(ferrari);
        vm.expectRevert(TeamBond.WeekendNotOpen.selector);
        bond.depositBond{value: 1 ether}();

        _open();
        _close();
        vm.prank(ferrari);
        vm.expectRevert(TeamBond.WeekendNotOpen.selector);
        bond.depositBond{value: 1 ether}();
    }

    function test_RevertWhen_DepositBelowMinimum() public {
        _openWithTeams();
        vm.prank(ferrari);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.BelowMinimumBond.selector, 0.05 ether, MIN_BOND));
        bond.depositBond{value: 0.05 ether}();
    }

    function test_RevertWhen_DepositZero() public {
        _openWithTeams();
        vm.prank(ferrari);
        vm.expectRevert(TeamBond.ZeroValue.selector);
        bond.depositBond{value: 0}();
    }

    function test_RevertWhen_PlainEthIsSentToTheContract() public {
        (bool ok,) = address(bond).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_QuoteFineWei_KnownValue() public view {
        assertEq(bond.quoteFineWei(10_000), 3_666_666_666_666_666);
    }

    function test_QuoteFineWei_FollowsThePrice() public {
        uint256 before = bond.quoteFineWei(10_000);
        ethUsd.setAnswer(1500e8);
        assertApproxEqAbs(bond.quoteFineWei(10_000), before * 2, 1);
    }

    function test_RevertWhen_EurFeedIsStale() public {
        vm.warp(block.timestamp + MAX_AGE + 1);
        ethUsd.setAnswer(3000e8);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.StalePrice.selector, address(eurUsd), 1));
        bond.quoteFineWei(1);
    }

    function test_RevertWhen_EthFeedIsStale() public {
        vm.warp(block.timestamp + MAX_AGE + 1);
        eurUsd.setAnswer(1.1e8);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.StalePrice.selector, address(ethUsd), 1));
        bond.quoteFineWei(1);
    }

    function test_PriceJustInsideTheAgeLimitIsAccepted() public {
        vm.warp(block.timestamp + MAX_AGE);
        bond.quoteFineWei(1);
    }

    function test_RevertWhen_PriceIsNotPositive() public {
        ethUsd.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.BadPrice.selector, address(ethUsd)));
        bond.quoteFineWei(1);

        ethUsd.setAnswer(3000e8);
        eurUsd.setAnswer(-5);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.BadPrice.selector, address(eurUsd)));
        bond.quoteFineWei(1);
    }

    function test_ApplyFine_TakesFromBondAndPaysThePanel() public {
        _openWithTeams();
        _deposit(ferrari, 1 ether);
        uint256 fine = bond.quoteFineWei(10_000);

        vm.expectEmit(true, true, false, true, address(bond));
        emit TeamBond.FineApplied(1, ferrari, 10_000, fine, fine, 0);

        vm.prank(panel);
        (uint256 fineWei, uint256 fromBond, uint256 newDebt) = bond.applyFine(ferrari, 10_000);

        assertEq(fineWei, fine);
        assertEq(fromBond, fine);
        assertEq(newDebt, 0);
        assertEq(bond.bondOf(1, ferrari), 1 ether - fine);
        assertEq(panel.balance, fine);
        assertEq(address(bond).balance, 1 ether - fine);
        assertEq(bond.debtOf(ferrari), 0);
    }

    function test_ApplyFine_BiggerThanBondBecomesDebt() public {
        _openWithTeams();
        _deposit(ferrari, 0.1 ether);
        vm.prank(panel);
        bond.setFineScale(1);

        uint256 fine = bond.quoteFineWei(10_000);
        vm.prank(panel);
        (, uint256 fromBond, uint256 newDebt) = bond.applyFine(ferrari, 10_000);

        assertEq(fromBond, 0.1 ether);
        assertEq(newDebt, fine - 0.1 ether);
        assertEq(bond.debtOf(ferrari), fine - 0.1 ether);
        assertEq(bond.bondOf(1, ferrari), 0);
        assertEq(panel.balance, 0.1 ether);
        assertEq(address(bond).balance, 0);
    }

    function test_ApplyFine_TeamThatNeverDepositedOwesTheWholeFine() public {
        _openWithTeams();
        uint256 fine = bond.quoteFineWei(5_000);

        vm.prank(panel);
        (, uint256 fromBond, uint256 newDebt) = bond.applyFine(mclaren, 5_000);

        assertEq(fromBond, 0);
        assertEq(newDebt, fine);
        assertEq(panel.balance, 0);
    }

    function test_ApplyFine_OnlyTouchesTheCurrentWeekendsBond() public {
        _openWithTeams();
        _deposit(ferrari, 1 ether);
        _close();

        vm.prank(panel);
        bond.openWeekend();
        _deposit(ferrari, 1 ether);

        vm.prank(panel);
        (, uint256 fromBond,) = bond.applyFine(ferrari, 10_000);

        assertEq(bond.bondOf(1, ferrari), 1 ether);
        assertEq(bond.bondOf(2, ferrari), 1 ether - fromBond);
    }

    function test_RevertWhen_FineByNonPanel() public {
        _openWithTeams();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotPanel.selector, stranger));
        bond.applyFine(ferrari, 100);
    }

    function test_RevertWhen_FiningAnUnregisteredTeam() public {
        _openWithTeams();
        vm.prank(panel);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotATeam.selector, stranger));
        bond.applyFine(stranger, 100);
    }

    function test_RevertWhen_FineWithoutOpenWeekend() public {
        vm.startPrank(panel);
        bond.registerTeam(ferrari);
        vm.expectRevert(TeamBond.WeekendNotOpen.selector);
        bond.applyFine(ferrari, 100);
        vm.stopPrank();
    }

    function test_RevertWhen_FineUsesAStalePrice() public {
        _openWithTeams();
        _deposit(ferrari, 1 ether);
        vm.warp(block.timestamp + MAX_AGE + 1);

        vm.prank(panel);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.StalePrice.selector, address(eurUsd), 1));
        bond.applyFine(ferrari, 10_000);

        assertEq(bond.bondOf(1, ferrari), 1 ether);
    }

    function test_RevertWhen_PanelCannotReceiveEth() public {
        RejectsEth rejecter = new RejectsEth();
        TeamBond b = new TeamBond(address(rejecter), ethUsd, eurUsd, MIN_BOND, FINE_SCALE, MAX_AGE);

        vm.startPrank(address(rejecter));
        b.registerTeam(ferrari);
        b.openWeekend();
        vm.stopPrank();

        vm.prank(ferrari);
        b.depositBond{value: 1 ether}();

        uint256 fine = b.quoteFineWei(10_000);
        vm.prank(address(rejecter));
        vm.expectRevert(abi.encodeWithSelector(TeamBond.TransferFailed.selector, address(rejecter), fine));
        b.applyFine(ferrari, 10_000);
    }

    function test_PayDebt_PartialThenFull() public {
        _createDebt(ferrari);
        uint256 owed = bond.debtOf(ferrari);

        vm.expectEmit(true, false, false, true, address(bond));
        emit TeamBond.DebtPaid(ferrari, owed / 2, owed - owed / 2);
        vm.prank(ferrari);
        bond.payDebt{value: owed / 2}();
        assertEq(bond.debtOf(ferrari), owed - owed / 2);

        uint256 panelBefore = panel.balance;
        vm.prank(ferrari);
        bond.payDebt{value: owed - owed / 2}();

        assertEq(bond.debtOf(ferrari), 0);
        assertEq(panel.balance, panelBefore + owed - owed / 2);
        assertEq(address(bond).balance, 0);
    }

    function test_RevertWhen_PayingMoreThanOwedOrZero() public {
        _createDebt(ferrari);
        uint256 owed = bond.debtOf(ferrari);

        vm.prank(ferrari);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.Overpayment.selector, owed + 1, owed));
        bond.payDebt{value: owed + 1}();

        vm.prank(ferrari);
        vm.expectRevert(TeamBond.ZeroValue.selector);
        bond.payDebt{value: 0}();
    }

    function test_RevertWhen_PayingDebtWithNoDebt() public {
        vm.prank(ferrari);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.Overpayment.selector, 1, 0));
        bond.payDebt{value: 1}();
    }

    function test_DebtBlocksTheNextDeposit_UntilPaid() public {
        _createDebt(ferrari);
        uint256 owed = bond.debtOf(ferrari);
        _close();
        vm.prank(panel);
        bond.openWeekend();

        vm.prank(ferrari);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.HasDebt.selector, ferrari, owed));
        bond.depositBond{value: 1 ether}();

        vm.prank(ferrari);
        bond.payDebt{value: owed}();

        _deposit(ferrari, 1 ether);
        assertEq(bond.bondOf(2, ferrari), 1 ether);
    }

    function test_Withdraw_ReturnsWhatIsLeft() public {
        _openWithTeams();
        _deposit(ferrari, 1 ether);
        vm.prank(panel);
        (, uint256 fromBond,) = bond.applyFine(ferrari, 10_000);
        _close();

        uint256 before = ferrari.balance;
        vm.expectEmit(true, true, false, true, address(bond));
        emit TeamBond.BondWithdrawn(1, ferrari, 1 ether - fromBond);

        vm.prank(ferrari);
        bond.withdraw(1);

        assertEq(ferrari.balance, before + 1 ether - fromBond);
        assertEq(bond.bondOf(1, ferrari), 0);
        assertEq(address(bond).balance, 0);
    }

    function test_Withdraw_WorksLaterEvenAfterANewWeekendStarted() public {
        _openWithTeams();
        _deposit(ferrari, 1 ether);
        _close();
        vm.prank(panel);
        bond.openWeekend();

        vm.prank(ferrari);
        bond.withdraw(1);
        assertEq(bond.bondOf(1, ferrari), 0);
    }

    function test_RevertWhen_WithdrawingBeforeTheWeekendIsClosed() public {
        _openWithTeams();
        _deposit(ferrari, 1 ether);

        vm.prank(ferrari);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.WeekendNotClosed.selector, 1));
        bond.withdraw(1);

        vm.prank(ferrari);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.WeekendNotClosed.selector, 99));
        bond.withdraw(99);
    }

    function test_RevertWhen_WithdrawingTwiceOrWithNothing() public {
        _openWithTeams();
        _deposit(ferrari, 1 ether);
        _close();

        vm.startPrank(ferrari);
        bond.withdraw(1);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NothingToWithdraw.selector, 1, ferrari));
        bond.withdraw(1);
        vm.stopPrank();

        vm.prank(mclaren);
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NothingToWithdraw.selector, 1, mclaren));
        bond.withdraw(1);
    }

    function test_Withdraw_ReentrancyAttackFails() public {
        ReentrantTeam attacker = new ReentrantTeam(bond);
        vm.startPrank(panel);
        bond.registerTeam(address(attacker));
        bond.registerTeam(mclaren);
        bond.openWeekend();
        vm.stopPrank();

        _deposit(mclaren, 5 ether);
        attacker.deposit{value: 1 ether}();
        _close();

        attacker.attack(1);

        assertTrue(attacker.reentryBlocked());
        assertEq(address(attacker).balance, 1 ether);
        assertEq(address(bond).balance, 5 ether);
    }

    function _open() internal {
        vm.prank(panel);
        bond.openWeekend();
    }

    function _close() internal {
        vm.prank(panel);
        bond.closeWeekend();
    }

    function _openWithTeams() internal {
        vm.startPrank(panel);
        bond.registerTeam(ferrari);
        bond.registerTeam(mclaren);
        bond.openWeekend();
        vm.stopPrank();
    }

    function _deposit(address team, uint256 amount) internal {
        vm.prank(team);
        bond.depositBond{value: amount}();
    }

    function _createDebt(address team) internal {
        vm.startPrank(panel);
        bond.registerTeam(team);
        bond.openWeekend();
        bond.setFineScale(1);
        vm.stopPrank();

        _deposit(team, MIN_BOND);
        vm.prank(panel);
        bond.applyFine(team, 10_000);
    }
}
