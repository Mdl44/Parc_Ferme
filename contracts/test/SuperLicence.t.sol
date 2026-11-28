// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SuperLicence} from "../src/SuperLicence.sol";
import {SuperLicenceV2} from "../src/SuperLicenceV2.sol";
import {IERC5192} from "../src/interfaces/IERC5192.sol";

contract SuperLicenceTest is Test {
    bytes32 internal constant DOC = keccak256("2026 Dutch Grand Prix - Doc 63");

    SuperLicence internal licence;
    SuperLicence internal implementation;

    address internal panel = makeAddr("panel");
    address internal verstappen = makeAddr("verstappen");
    address internal hamilton = makeAddr("hamilton");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        implementation = new SuperLicence();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(SuperLicence.initialize, (panel)));
        licence = SuperLicence(address(proxy));
    }

    function test_Initialize_SetsPanelAndName() public view {
        assertEq(licence.panel(), panel);
        assertEq(licence.name(), "FIA Super Licence");
        assertEq(licence.symbol(), "LICENCE");
    }

    function test_RevertWhen_InitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        licence.initialize(stranger);
    }

    function test_RevertWhen_InitializeImplementationDirectly() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(stranger);
    }

    function test_RevertWhen_InitializeWithZeroPanel() public {
        SuperLicence fresh = new SuperLicence();
        vm.expectRevert(SuperLicence.ZeroAddress.selector);
        new ERC1967Proxy(address(fresh), abi.encodeCall(SuperLicence.initialize, (address(0))));
    }

    function test_MintLicence() public {
        vm.prank(panel);
        uint256 id = licence.mintLicence(verstappen, "Driver", "DRV", 1);

        assertEq(id, licence.licenceId(verstappen));
        assertEq(licence.ownerOf(id), verstappen);
        assertEq(licence.balanceOf(verstappen), 1);
    }

    function test_MintLicence_EmitsEvents() public {
        uint256 id = licence.licenceId(verstappen);

        vm.expectEmit(true, true, false, true, address(licence));
        emit SuperLicence.LicenceIssued(verstappen, id, "Driver", 1);
        vm.expectEmit(false, false, false, true, address(licence));
        emit IERC5192.Locked(id);

        vm.prank(panel);
        licence.mintLicence(verstappen, "Driver", "DRV", 1);
    }

    function test_RevertWhen_MintTwiceForSameDriver() public {
        vm.startPrank(panel);
        licence.mintLicence(verstappen, "Driver", "DRV", 1);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.LicenceAlreadyIssued.selector, verstappen));
        licence.mintLicence(verstappen, "Driver", "DRV", 1);
        vm.stopPrank();
    }

    function test_RevertWhen_NonPanelMints() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotPanel.selector, stranger));
        licence.mintLicence(verstappen, "Driver", "DRV", 1);
    }

    function test_AddPoints_Accumulates() public {
        _issue(verstappen);

        vm.startPrank(panel);
        licence.addPoints(verstappen, 3, bytes32(0));
        licence.addPoints(verstappen, 2, bytes32(0));
        vm.stopPrank();

        assertEq(licence.points(verstappen), 5);
        assertFalse(licence.isBanned(verstappen));
    }

    function test_AddPoints_EmitsEvent() public {
        _issue(verstappen);

        vm.expectEmit(true, true, false, true, address(licence));
        emit SuperLicence.PointsAdded(verstappen, 4, 4, DOC);

        vm.prank(panel);
        licence.addPoints(verstappen, 4, DOC);
    }

    function test_RevertWhen_AddingZeroPoints() public {
        _issue(verstappen);

        vm.prank(panel);
        vm.expectRevert(SuperLicence.ZeroPoints.selector);
        licence.addPoints(verstappen, 0, DOC);
    }

    function test_MintLicence_StoresTheProfile() public {
        vm.prank(panel);
        licence.mintLicence(verstappen, "Max Verstappen", "VER", 3);

        SuperLicence.Profile memory p = licence.profileOf(verstappen);
        assertEq(p.name, "Max Verstappen");
        assertEq(p.code, "VER");
        assertEq(p.carNumber, 3);
        assertEq(licence.version(), "1");
    }

    function test_TokenUri_IsOnChainJsonThatFollowsThePoints() public {
        uint256 id = _issue(verstappen);

        string memory before = licence.tokenURI(id);
        assertTrue(_startsWith(before, "data:application/json;base64,"));

        vm.prank(panel);
        licence.addPoints(verstappen, 3, DOC);
        assertNotEq(licence.tokenURI(id), before);
    }

    function test_TokenUri_ChangesWhenTheDriverIsBanned() public {
        uint256 id = _issue(verstappen);
        vm.startPrank(panel);
        licence.addPoints(verstappen, 11, DOC);
        string memory active = licence.tokenURI(id);
        licence.addPoints(verstappen, 1, DOC);
        vm.stopPrank();

        assertTrue(licence.isBanned(verstappen));
        string memory banned = licence.tokenURI(id);
        assertTrue(_startsWith(banned, "data:application/json;base64,"));
        assertNotEq(banned, active);
    }

    function test_RevertWhen_TokenUriOfMissingLicence() public {
        uint256 id = licence.licenceId(hamilton);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        licence.tokenURI(id);
    }

    function test_AddPoints_BanTriggersAtTwelve() public {
        _issue(verstappen);

        vm.startPrank(panel);
        licence.addPoints(verstappen, 11, bytes32(0));
        assertFalse(licence.isBanned(verstappen));

        vm.expectEmit(true, false, false, true, address(licence));
        emit SuperLicence.BanTriggered(verstappen, 12);
        licence.addPoints(verstappen, 1, bytes32(0));
        vm.stopPrank();

        assertTrue(licence.isBanned(verstappen));
    }

    function test_AddPoints_BanEventOnlyOnce() public {
        _issue(verstappen);

        vm.startPrank(panel);
        licence.addPoints(verstappen, 12, bytes32(0));
        vm.recordLogs();
        licence.addPoints(verstappen, 2, bytes32(0));
        vm.stopPrank();

        assertEq(vm.getRecordedLogs().length, 1);
    }

    function test_RevertWhen_AddPointsWithoutLicence() public {
        vm.prank(panel);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NoLicence.selector, hamilton));
        licence.addPoints(hamilton, 1, bytes32(0));
    }

    function test_RevertWhen_NonPanelAddsPoints() public {
        _issue(verstappen);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotPanel.selector, stranger));
        licence.addPoints(verstappen, 1, bytes32(0));
    }

    function test_ServeBan_RemovesTwelvePointsAndKeepsTheRest() public {
        _issue(verstappen);

        vm.startPrank(panel);
        licence.addPoints(verstappen, 14, bytes32(0));

        vm.expectEmit(true, false, false, true, address(licence));
        emit SuperLicence.BanServed(verstappen, 2);
        licence.serveBan(verstappen);
        vm.stopPrank();

        assertEq(licence.points(verstappen), 2);
        assertFalse(licence.isBanned(verstappen));
    }

    function test_RevertWhen_ServeBanOfDriverWhoIsNotBanned() public {
        _issue(verstappen);

        vm.startPrank(panel);
        licence.addPoints(verstappen, 11, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotBanned.selector, verstappen));
        licence.serveBan(verstappen);
        vm.stopPrank();
    }

    function test_RevertWhen_NonPanelServesBan() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotPanel.selector, stranger));
        licence.serveBan(verstappen);
    }

    function test_Locked_IsTrue() public {
        uint256 id = _issue(verstappen);
        assertTrue(licence.locked(id));
    }

    function test_RevertWhen_LockedForMissingLicence() public {
        uint256 id = licence.licenceId(hamilton);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        licence.locked(id);
    }

    function test_RevertWhen_DriverTransfersLicence() public {
        uint256 id = _issue(verstappen);

        vm.prank(verstappen);
        vm.expectRevert(SuperLicence.Soulbound.selector);
        licence.transferFrom(verstappen, hamilton, id);
    }

    function test_RevertWhen_DriverSafeTransfersLicence() public {
        uint256 id = _issue(verstappen);

        vm.prank(verstappen);
        vm.expectRevert(SuperLicence.Soulbound.selector);
        licence.safeTransferFrom(verstappen, hamilton, id);
    }

    function test_RevertWhen_PanelTransfersLicence() public {
        uint256 id = _issue(verstappen);

        vm.prank(verstappen);
        licence.approve(panel, id);

        vm.prank(panel);
        vm.expectRevert(SuperLicence.Soulbound.selector);
        licence.transferFrom(verstappen, hamilton, id);
    }

    function test_SupportsInterfaces() public view {
        assertTrue(licence.supportsInterface(type(IERC5192).interfaceId));
        assertTrue(licence.supportsInterface(type(IERC721).interfaceId));
        assertEq(type(IERC5192).interfaceId, bytes4(0xb45a3c0e));
    }

    function test_SetPanel() public {
        vm.expectEmit(true, true, false, false, address(licence));
        emit SuperLicence.PanelChanged(panel, stranger);

        vm.prank(panel);
        licence.setPanel(stranger);

        assertEq(licence.panel(), stranger);

        vm.prank(panel);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotPanel.selector, panel));
        licence.mintLicence(verstappen, "Driver", "DRV", 1);
    }

    function test_RevertWhen_SetPanelToZero() public {
        vm.prank(panel);
        vm.expectRevert(SuperLicence.ZeroAddress.selector);
        licence.setPanel(address(0));
    }

    function test_RevertWhen_NonPanelSetsPanel() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotPanel.selector, stranger));
        licence.setPanel(stranger);
    }

    function test_Upgrade_ByPanelKeepsData() public {
        _issue(verstappen);
        vm.prank(panel);
        licence.addPoints(verstappen, 5, bytes32(0));

        SuperLicenceV2 v2 = new SuperLicenceV2();
        vm.prank(panel);
        licence.upgradeToAndCall(address(v2), abi.encodeCall(SuperLicenceV2.initializeV2, ()));

        assertEq(licence.version(), "2");
        assertEq(licence.points(verstappen), 5);
        assertEq(licence.ownerOf(licence.licenceId(verstappen)), verstappen);
    }

    function test_RevertWhen_NonPanelUpgrades() public {
        SuperLicenceV2 v2 = new SuperLicenceV2();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotPanel.selector, stranger));
        licence.upgradeToAndCall(address(v2), "");
    }

    function testFuzz_IsBannedMatchesThreshold(uint96 amount) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        _issue(verstappen);

        vm.prank(panel);
        licence.addPoints(verstappen, amount, bytes32(0));

        assertEq(licence.points(verstappen), amount);
        assertEq(licence.isBanned(verstappen), amount >= licence.BAN_THRESHOLD());
    }

    function testFuzz_PointsAddUpAndServeBan(uint48 first, uint48 second) public {
        first = uint48(bound(first, 1, type(uint48).max));
        second = uint48(bound(second, 1, type(uint48).max));
        _issue(verstappen);

        vm.startPrank(panel);
        licence.addPoints(verstappen, first, bytes32(0));
        licence.addPoints(verstappen, second, bytes32(0));
        uint256 total = uint256(first) + uint256(second);
        assertEq(licence.points(verstappen), total);

        if (total >= 12) {
            licence.serveBan(verstappen);
            assertEq(licence.points(verstappen), total - 12);
        } else {
            vm.expectRevert(abi.encodeWithSelector(SuperLicence.NotBanned.selector, verstappen));
            licence.serveBan(verstappen);
        }
        vm.stopPrank();
    }

    function _startsWith(string memory text, string memory prefix) internal pure returns (bool) {
        bytes memory t = bytes(text);
        bytes memory p = bytes(prefix);
        if (t.length < p.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (t[i] != p[i]) return false;
        }
        return true;
    }

    function _issue(address driver) internal returns (uint256 id) {
        vm.prank(panel);
        id = licence.mintLicence(driver, "Driver", "DRV", 1);
    }
}
