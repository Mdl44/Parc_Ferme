// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {StewardsPanel} from "../src/StewardsPanel.sol";
import {SuperLicence} from "../src/SuperLicence.sol";
import {SuperLicenceV2} from "../src/SuperLicenceV2.sol";
import {TeamBond} from "../src/TeamBond.sol";
import {DocumentRegistry} from "../src/DocumentRegistry.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {PanelHelper} from "./utils/PanelHelper.sol";

contract IntegrationTest is PanelHelper {
    StewardsPanel internal panel;
    SuperLicence internal licence;
    TeamBond internal bond;
    DocumentRegistry internal registry;

    uint256 internal constant KEY_1 = 0xA11CE;
    uint256 internal constant KEY_2 = 0xB0B;
    uint256 internal constant KEY_3 = 0xCA401;

    address internal ferrari = makeAddr("ferrari");
    address internal leclerc = makeAddr("leclerc");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        address[] memory stewards = new address[](3);
        stewards[0] = vm.addr(KEY_1);
        stewards[1] = vm.addr(KEY_2);
        stewards[2] = vm.addr(KEY_3);
        panel = new StewardsPanel(stewards, 2, entryPoint);

        SuperLicence implementation = new SuperLicence();
        licence = SuperLicence(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeCall(SuperLicence.initialize, (address(panel))))
            )
        );

        MockAggregator ethUsd = new MockAggregator("ETH / USD", 8, 3000e8);
        MockAggregator eurUsd = new MockAggregator("EUR / USD", 8, 1.1e8);
        bond = new TeamBond(address(panel), ethUsd, eurUsd, 0.1 ether, 1000, 1 days);
        registry = new DocumentRegistry(address(panel));

        vm.deal(ferrari, 100 ether);

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](3);
        calls[0] = _c(address(bond), abi.encodeCall(bond.registerTeam, (ferrari, "Team")));
        calls[1] = _c(address(bond), abi.encodeCall(bond.openWeekend, ()));
        calls[2] = _c(address(licence), abi.encodeCall(licence.mintLicence, (leclerc, "Driver", "DRV", 1)));
        _decide(calls);
    }

    function test_PenaltyDecision_PointsAndFineInOneBatch() public {
        vm.prank(ferrari);
        bond.depositBond{value: 1 ether}();
        uint256 fine = bond.quoteFineWei(10_000);

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);
        calls[0] = _c(address(licence), abi.encodeCall(licence.addPoints, (leclerc, 4, bytes32(0))));
        calls[1] = _c(address(bond), abi.encodeCall(bond.applyFine, (ferrari, 10_000, bytes32(0))));
        _decide(calls);

        assertEq(licence.points(leclerc), 4);
        assertEq(bond.bondOf(1, ferrari), 1 ether - fine);
        assertEq(address(panel).balance, fine);
    }

    function test_TwelvePointsMeansABanUntilItIsServed() public {
        _decide(_one(address(licence), 0, abi.encodeCall(licence.addPoints, (leclerc, 12, bytes32(0)))));
        assertTrue(licence.isBanned(leclerc));

        _decide(_one(address(licence), 0, abi.encodeCall(licence.serveBan, (leclerc))));
        assertFalse(licence.isBanned(leclerc));
        assertEq(licence.points(leclerc), 0);
    }

    function test_DecisionIsAllOrNothing() public {
        address unknownTeam = makeAddr("unknownTeam");

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);
        calls[0] = _c(address(licence), abi.encodeCall(licence.addPoints, (leclerc, 3, bytes32(0))));
        calls[1] = _c(address(bond), abi.encodeCall(bond.applyFine, (unknownTeam, 5_000, bytes32(0))));
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, panel.nonce()));

        vm.expectRevert(
            abi.encodeWithSelector(
                StewardsPanel.CallFailed.selector, 1, abi.encodeWithSelector(TeamBond.NotATeam.selector, unknownTeam)
            )
        );
        panel.executeDecision(calls, sigs);

        assertEq(licence.points(leclerc), 0);
    }

    function test_FineBiggerThanTheBondBecomesDebtThatTheTeamPays() public {
        vm.prank(ferrari);
        bond.depositBond{value: 0.1 ether}();

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);
        calls[0] = _c(address(bond), abi.encodeCall(bond.setFineScale, (1)));
        calls[1] = _c(address(bond), abi.encodeCall(bond.applyFine, (ferrari, 10_000, bytes32(0))));
        _decide(calls);

        uint256 owed = bond.debtOf(ferrari);
        assertGt(owed, 0);
        assertEq(address(panel).balance, 0.1 ether);

        vm.prank(ferrari);
        bond.payDebt{value: owed}();

        assertEq(bond.debtOf(ferrari), 0);
        assertEq(address(panel).balance, 0.1 ether + owed);
    }

    function test_NobodyButThePanelCanChangeTheContracts() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotPanel.selector, stranger));
        licence.addPoints(leclerc, 1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotPanel.selector, stranger));
        bond.applyFine(ferrari, 1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(DocumentRegistry.NotPanel.selector, stranger));
        registry.publishRoot(1, keccak256("root"), "cid");
        vm.stopPrank();

        address steward = vm.addr(KEY_1);
        vm.startPrank(steward);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotPanel.selector, steward));
        licence.addPoints(leclerc, 1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(TeamBond.NotPanel.selector, steward));
        bond.applyFine(ferrari, 1, bytes32(0));
        vm.stopPrank();
    }

    function test_EndOfWeekend_RefundAndPublishDocuments() public {
        vm.prank(ferrari);
        bond.depositBond{value: 1 ether}();

        bytes32 docA = keccak256("document-a.pdf");
        bytes32 docB = keccak256("document-b.pdf");
        bytes32 leafA = registry.leafOf(docA);
        bytes32 leafB = registry.leafOf(docB);
        bytes32 root =
            leafA < leafB ? keccak256(abi.encodePacked(leafA, leafB)) : keccak256(abi.encodePacked(leafB, leafA));

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);
        calls[0] = _c(address(bond), abi.encodeCall(bond.closeWeekend, ()));
        calls[1] = _c(address(registry), abi.encodeCall(registry.publishRoot, (1, root, "bafy-weekend-1")));
        _decide(calls);

        uint256 before = ferrari.balance;
        vm.prank(ferrari);
        bond.withdraw(1);
        assertEq(ferrari.balance, before + 1 ether);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        assertTrue(registry.verifyDocument(1, docA, proof));
        assertFalse(registry.verifyDocument(1, keccak256("forged.pdf"), proof));
    }

    function test_TreasuryCanBePaidOutByADecision() public {
        vm.deal(address(panel), 2 ether);
        address charity = makeAddr("charity");

        _decide(_one(charity, 1.5 ether, ""));

        assertEq(charity.balance, 1.5 ether);
        assertEq(address(panel).balance, 0.5 ether);
    }

    function test_LicenceUpgradeNeedsADecision() public {
        _decide(_one(address(licence), 0, abi.encodeCall(licence.addPoints, (leclerc, 5, bytes32(0)))));

        SuperLicenceV2 v2 = new SuperLicenceV2();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotPanel.selector, stranger));
        licence.upgradeToAndCall(address(v2), "");

        _decide(
            _one(
                address(licence),
                0,
                abi.encodeCall(licence.upgradeToAndCall, (address(v2), abi.encodeCall(SuperLicenceV2.initializeV2, ())))
            )
        );
        assertEq(licence.version(), "2");
        assertEq(licence.points(leclerc), 5);
    }

    function test_FinesPayForTheGasOfTheNextDecision() public {
        bytes32 doc = keccak256("Doc 68 - Infringement - Car 16");
        vm.prank(ferrari);
        bond.depositBond{value: 1 ether}();
        _decide(_one(address(bond), 0, abi.encodeCall(bond.applyFine, (ferrari, 30_000, doc))));
        uint256 treasury = address(panel).balance;
        assertGt(treasury, 0);

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);
        calls[0] = _c(address(licence), abi.encodeCall(licence.addPoints, (leclerc, 2, doc)));
        calls[1] = _c(address(bond), abi.encodeCall(bond.closeWeekend, ()));
        PackedUserOperation memory op = _userOp(panel, calls);
        op.signature = _sign(_keys(KEY_2, KEY_3), entryPoint.getUserOpHash(op));

        address payable bundler = payable(makeAddr("bundler"));
        vm.prank(bundler, bundler);
        entryPoint.handleOps(_ops(op), bundler);

        assertEq(licence.points(leclerc), 2);
        assertEq(uint256(bond.weekendStatus(1)), uint256(TeamBond.WeekendStatus.Closed));
        assertLt(address(panel).balance, treasury);
        assertEq(address(panel).balance + panel.entryPointDeposit() + bundler.balance, treasury);
    }

    function test_LicenceUpgradeThroughTheEntryPoint() public {
        _decide(_one(address(licence), 0, abi.encodeCall(licence.addPoints, (leclerc, 3, bytes32(0)))));
        vm.deal(address(panel), 1 ether);

        SuperLicenceV2 v2 = new SuperLicenceV2();
        PackedUserOperation memory op = _userOp(
            panel,
            _one(
                address(licence),
                0,
                abi.encodeCall(licence.upgradeToAndCall, (address(v2), abi.encodeCall(SuperLicenceV2.initializeV2, ())))
            )
        );
        op.signature = _sign(_keys(KEY_1, KEY_3), entryPoint.getUserOpHash(op));
        address payable bundler = payable(makeAddr("bundler"));
        vm.prank(bundler, bundler);
        entryPoint.handleOps(_ops(op), bundler);

        assertEq(licence.version(), "2");
        assertEq(licence.points(leclerc), 3);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(licence.points(leclerc), 0);
    }

    function _c(address target, bytes memory data) internal pure returns (BaseAccount.Call memory) {
        return BaseAccount.Call(target, 0, data);
    }

    function _decide(BaseAccount.Call[] memory calls) internal {
        bytes memory sigs = _sign(_keys(KEY_1, KEY_2), _digest(panel, calls, panel.nonce()));
        panel.executeDecision(calls, sigs);
    }
}
