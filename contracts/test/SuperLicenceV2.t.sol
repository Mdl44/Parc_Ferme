// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SuperLicence} from "../src/SuperLicence.sol";
import {SuperLicenceV2} from "../src/SuperLicenceV2.sol";

contract SuperLicenceV2Test is Test {
    bytes32 internal constant DOC = keccak256("decision");
    uint256 internal constant YEAR = 365 days;

    SuperLicenceV2 internal licence;

    address internal panel = makeAddr("panel");
    address internal norris = makeAddr("norris");
    address internal piastri = makeAddr("piastri");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_800_000_000);
        SuperLicence v1 = new SuperLicence();
        ERC1967Proxy proxy = new ERC1967Proxy(address(v1), abi.encodeCall(SuperLicence.initialize, (panel)));
        licence = SuperLicenceV2(address(proxy));

        vm.startPrank(panel);
        licence.mintLicence(norris, "Lando Norris", "NOR", 1);
        licence.mintLicence(piastri, "Oscar Piastri", "PIA", 81);
        licence.addPoints(norris, 4, DOC);
        vm.stopPrank();
    }

    function test_Upgrade_KeepsEverythingFromV1() public {
        _upgrade();

        assertEq(licence.version(), "2");
        assertEq(licence.upgradedAt(), vm.getBlockTimestamp());
        assertEq(licence.panel(), panel);
        assertEq(licence.name(), "FIA Super Licence");
        assertEq(licence.ownerOf(licence.licenceId(norris)), norris);
        assertEq(licence.profileOf(piastri).carNumber, 81);
        assertEq(licence.points(norris), 4);
    }

    function test_Upgrade_EmitsWhenLegacyPointsExpire() public {
        SuperLicenceV2 v2 = new SuperLicenceV2();

        vm.expectEmit(false, false, false, true, address(licence));
        emit SuperLicenceV2.UpgradedToV2(vm.getBlockTimestamp() + YEAR);

        vm.prank(panel);
        licence.upgradeToAndCall(address(v2), abi.encodeCall(SuperLicenceV2.initializeV2, ()));
    }

    function test_RevertWhen_InitializeV2Twice() public {
        _upgrade();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        licence.initializeV2();
    }

    function test_RevertWhen_StrangerUpgrades() public {
        SuperLicenceV2 v2 = new SuperLicenceV2();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotPanel.selector, stranger));
        licence.upgradeToAndCall(address(v2), abi.encodeCall(SuperLicenceV2.initializeV2, ()));
    }

    function test_PointsExpireAfterTwelveMonths() public {
        _upgrade();
        vm.prank(panel);
        licence.addPoints(piastri, 3, DOC);

        vm.warp(vm.getBlockTimestamp() + YEAR - 1);
        assertEq(licence.points(piastri), 3);

        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(licence.points(piastri), 0);
    }

    function test_LegacyPointsExpireTwelveMonthsAfterTheUpgrade() public {
        _upgrade();
        uint256 upgradedAt = vm.getBlockTimestamp();

        vm.warp(upgradedAt + 100 days);
        vm.prank(panel);
        licence.addPoints(norris, 3, DOC);
        assertEq(licence.points(norris), 7);
        assertEq(licence.nextExpiry(norris), upgradedAt + YEAR);

        vm.warp(upgradedAt + YEAR);
        assertEq(licence.points(norris), 3);
        assertEq(licence.nextExpiry(norris), upgradedAt + 100 days + YEAR);

        vm.warp(upgradedAt + 100 days + YEAR);
        assertEq(licence.points(norris), 0);
        assertEq(licence.nextExpiry(norris), 0);
    }

    function test_ExpiredPointsDoNotCountTowardsABan() public {
        _upgrade();
        vm.prank(panel);
        licence.addPoints(piastri, 8, DOC);

        vm.warp(vm.getBlockTimestamp() + YEAR);
        vm.prank(panel);
        licence.addPoints(piastri, 8, DOC);

        assertEq(licence.points(piastri), 8);
        assertFalse(licence.isBanned(piastri));
    }

    function test_BanIsTriggeredByLivePoints() public {
        _upgrade();
        vm.startPrank(panel);
        licence.addPoints(norris, 5, DOC);

        vm.expectEmit(true, false, false, true, address(licence));
        emit SuperLicence.BanTriggered(norris, 12);
        licence.addPoints(norris, 3, DOC);
        vm.stopPrank();

        assertTrue(licence.isBanned(norris));
    }

    function test_ServeBan_TakesTheOldestPointsFirst() public {
        _upgrade();
        uint256 start = vm.getBlockTimestamp();
        vm.startPrank(panel);
        vm.warp(start + 10 days);
        licence.addPoints(norris, 4, DOC);
        vm.warp(start + 20 days);
        licence.addPoints(norris, 6, DOC);
        assertEq(licence.points(norris), 14);

        licence.serveBan(norris);
        vm.stopPrank();

        assertEq(licence.points(norris), 2);
        SuperLicenceV2.Award[] memory awards = licence.awardsOf(norris);
        assertEq(awards[0].amount, 0);
        assertEq(awards[1].amount, 2);
        assertEq(licence.nextExpiry(norris), start + 20 days + YEAR);
    }

    function test_ServeBan_SkipsExpiredPoints() public {
        _upgrade();
        vm.startPrank(panel);
        licence.addPoints(piastri, 6, DOC);
        vm.warp(vm.getBlockTimestamp() + YEAR + 1);
        licence.addPoints(piastri, 12, DOC);
        licence.addPoints(piastri, 1, DOC);
        assertEq(licence.points(piastri), 13);

        licence.serveBan(piastri);
        vm.stopPrank();

        assertEq(licence.points(piastri), 1);
    }

    function test_ServeBan_WorksAfterLegacyExpired() public {
        _upgrade();
        vm.warp(vm.getBlockTimestamp() + YEAR);
        vm.startPrank(panel);
        licence.addPoints(norris, 12, DOC);
        assertEq(licence.points(norris), 12);
        licence.serveBan(norris);
        vm.stopPrank();
        assertEq(licence.points(norris), 0);
    }

    function test_TokenUriFollowsExpiry() public {
        _upgrade();
        uint256 id = licence.licenceId(norris);
        string memory withPoints = licence.tokenURI(id);

        vm.warp(vm.getBlockTimestamp() + YEAR);
        assertNotEq(licence.tokenURI(id), withPoints);
    }

    function testFuzz_PointsMatchASimpleModel(uint8[6] memory amounts, uint32[6] memory gaps) public {
        _upgrade();
        uint256 start = vm.getBlockTimestamp();
        uint256[6] memory times;
        uint256 t = start;

        vm.startPrank(panel);
        for (uint256 i = 0; i < 6; i++) {
            t += bound(gaps[i], 0, 200 days);
            times[i] = t;
            vm.warp(t);
            uint256 amount = bound(amounts[i], 1, 3);
            amounts[i] = uint8(amount);
            licence.addPoints(piastri, amount, DOC);
        }
        vm.stopPrank();

        for (uint256 step = 0; step < 4; step++) {
            uint256 expected = 0;
            for (uint256 i = 0; i < 6; i++) {
                if (vm.getBlockTimestamp() < times[i] + YEAR) expected += amounts[i];
            }
            assertEq(licence.points(piastri), expected);
            vm.warp(vm.getBlockTimestamp() + 150 days);
        }
    }

    function _upgrade() internal {
        SuperLicenceV2 v2 = new SuperLicenceV2();
        vm.prank(panel);
        licence.upgradeToAndCall(address(v2), abi.encodeCall(SuperLicenceV2.initializeV2, ()));
    }
}
