// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract DeployTest is Test {
    function test_AnvilStewardsAreTheAnvilAccountsOneToThree() public {
        Deploy script = new Deploy();
        Deploy.Deployment memory d = script.run();

        address[] memory stewards = d.panel.stewards();
        assertEq(stewards[0], 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
        assertEq(stewards[1], 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC);
        assertEq(stewards[2], 0x90F79bf6EB2c4f870365E785982E1f101E93b906);
        assertEq(d.panel.threshold(), 2);
    }

    function test_EverythingIsOwnedByThePanel() public {
        Deploy.Deployment memory d = new Deploy().run();

        assertEq(d.licence.panel(), address(d.panel));
        assertEq(d.bond.panel(), address(d.panel));
        assertEq(d.registry.panel(), address(d.panel));
        assertEq(address(d.panel.entryPoint()), d.entryPoint);
        assertEq(d.licence.version(), "1");
        assertGt(d.bond.quoteFineWei(10_000), 0);
    }
}
