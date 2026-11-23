// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PenaltyLib} from "../src/libraries/PenaltyLib.sol";

contract PenaltyLibHarness {
    function isBanned(uint256 points) external pure returns (bool) {
        return PenaltyLib.isBanned(points);
    }

    function eurToWei(uint256 eur, uint256 eurUsd, uint256 ethUsd, uint256 scale) external pure returns (uint256) {
        return PenaltyLib.eurToWei(eur, eurUsd, ethUsd, scale);
    }

    function splitFine(uint256 fine, uint256 available) external pure returns (uint256, uint256) {
        return PenaltyLib.splitFine(fine, available);
    }
}

contract PenaltyLibTest is Test {
    PenaltyLibHarness internal lib;

    uint256 internal constant EUR_USD = 1.1e8;
    uint256 internal constant ETH_USD = 3000e8;

    function setUp() public {
        lib = new PenaltyLibHarness();
    }

    function test_IsBanned_Boundary() public view {
        assertFalse(lib.isBanned(0));
        assertFalse(lib.isBanned(11));
        assertTrue(lib.isBanned(12));
        assertTrue(lib.isBanned(40));
    }

    function test_EurToWei_KnownValue() public view {
        assertEq(lib.eurToWei(10_000, EUR_USD, ETH_USD, 1), 3_666_666_666_666_666_666);
    }

    function test_EurToWei_FineScaleShrinksTheFine() public view {
        assertEq(lib.eurToWei(10_000, EUR_USD, ETH_USD, 1000), 3_666_666_666_666_666);
    }

    function test_EurToWei_ZeroEuroIsZero() public view {
        assertEq(lib.eurToWei(0, EUR_USD, ETH_USD, 1), 0);
    }

    function test_RevertWhen_EthPriceIsZero() public {
        vm.expectRevert(PenaltyLib.InvalidPrice.selector);
        lib.eurToWei(1, EUR_USD, 0, 1);
    }

    function test_RevertWhen_EurPriceIsZero() public {
        vm.expectRevert(PenaltyLib.InvalidPrice.selector);
        lib.eurToWei(1, 0, ETH_USD, 1);
    }

    function test_RevertWhen_ScaleIsZero() public {
        vm.expectRevert(PenaltyLib.InvalidScale.selector);
        lib.eurToWei(1, EUR_USD, ETH_USD, 0);
    }

    function test_SplitFine_BondCoversEverything() public view {
        (uint256 fromBond, uint256 debt) = lib.splitFine(5 ether, 8 ether);
        assertEq(fromBond, 5 ether);
        assertEq(debt, 0);
    }

    function test_SplitFine_BondIsTooSmall() public view {
        (uint256 fromBond, uint256 debt) = lib.splitFine(5 ether, 2 ether);
        assertEq(fromBond, 2 ether);
        assertEq(debt, 3 ether);
    }

    function test_SplitFine_NoBondMeansAllDebt() public view {
        (uint256 fromBond, uint256 debt) = lib.splitFine(5 ether, 0);
        assertEq(fromBond, 0);
        assertEq(debt, 5 ether);
    }

    function testFuzz_EurToWei_IsMonotonic(uint128 a, uint128 extra, uint64 eurUsd, uint64 ethUsd, uint32 scale)
        public
        view
    {
        eurUsd = uint64(bound(eurUsd, 1, 1e12));
        ethUsd = uint64(bound(ethUsd, 1, 1e14));
        scale = uint32(bound(scale, 1, 1e9));

        uint256 small = lib.eurToWei(a, eurUsd, ethUsd, scale);
        uint256 big = lib.eurToWei(uint256(a) + extra, eurUsd, ethUsd, scale);
        assertLe(small, big);
    }

    function testFuzz_EurToWei_DoublingScaleHalvesTheFine(uint128 eur, uint64 eurUsd, uint64 ethUsd, uint32 scale)
        public
        view
    {
        eurUsd = uint64(bound(eurUsd, 1, 1e12));
        ethUsd = uint64(bound(ethUsd, 1, 1e14));
        scale = uint32(bound(scale, 1, 1e9));

        uint256 single = lib.eurToWei(eur, eurUsd, ethUsd, scale);
        uint256 double_ = lib.eurToWei(eur, eurUsd, ethUsd, uint256(scale) * 2);
        assertEq(double_, single / 2);
    }

    function testFuzz_SplitFine_AddsUp(uint256 fine, uint256 available) public view {
        (uint256 fromBond, uint256 debt) = lib.splitFine(fine, available);

        assertEq(fromBond + debt, fine);
        assertLe(fromBond, available);
        if (fine <= available) assertEq(debt, 0);
    }
}
