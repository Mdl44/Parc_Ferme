// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SuperLicence} from "../src/SuperLicence.sol";
import {TeamBond} from "../src/TeamBond.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";

contract BondHandler is Test {
    TeamBond public immutable bond;
    address public immutable panel;
    address[] public teams;

    uint256 public totalIn;
    uint256 public totalToPanel;
    uint256 public totalDebtPaid;
    uint256 public totalWithdrawn;

    constructor(TeamBond bond_, address panel_) {
        bond = bond_;
        panel = panel_;
        for (uint256 i = 0; i < 3; i++) {
            address team = makeAddr(string.concat("team", vm.toString(i)));
            teams.push(team);
            vm.prank(panel_);
            bond_.registerTeam(team);
        }
        vm.prank(panel_);
        bond_.openWeekend();
    }

    function teamCount() external view returns (uint256) {
        return teams.length;
    }

    function openWeekend() external {
        vm.prank(panel);
        try bond.openWeekend() {} catch {}
    }

    function closeWeekend() external {
        vm.prank(panel);
        try bond.closeWeekend() {} catch {}
    }

    function deposit(uint256 teamSeed, uint256 amount) external {
        address team = teams[teamSeed % teams.length];
        amount = bound(amount, 1, 5 ether);
        vm.deal(team, amount);
        vm.prank(team);
        try bond.depositBond{value: amount}() {
            totalIn += amount;
        } catch {}
    }

    function fine(uint256 teamSeed, uint256 eurAmount) external {
        address team = teams[teamSeed % teams.length];
        eurAmount = bound(eurAmount, 0, 3_000_000);
        vm.prank(panel);
        try bond.applyFine(team, eurAmount) returns (uint256, uint256 fromBond, uint256) {
            totalToPanel += fromBond;
        } catch {}
    }

    function payDebt(uint256 teamSeed, uint256 amount) external {
        address team = teams[teamSeed % teams.length];
        uint256 owed = bond.debtOf(team);
        if (owed == 0) return;
        amount = bound(amount, 1, owed);
        vm.deal(team, amount);
        vm.prank(team);
        bond.payDebt{value: amount}();
        totalDebtPaid += amount;
    }

    function withdraw(uint256 teamSeed, uint256 weekendSeed) external {
        address team = teams[teamSeed % teams.length];
        uint256 weekendId = bound(weekendSeed, 1, bond.currentWeekend());
        uint256 before = bond.bondOf(weekendId, team);
        vm.prank(team);
        try bond.withdraw(weekendId) {
            totalWithdrawn += before;
        } catch {}
    }
}

contract TeamBondInvariantTest is Test {
    TeamBond internal bond;
    BondHandler internal handler;
    address internal panel = makeAddr("panel");

    function setUp() public {
        MockAggregator ethUsd = new MockAggregator("ETH / USD", 8, 3000e8);
        MockAggregator eurUsd = new MockAggregator("EUR / USD", 8, 1.1e8);
        bond = new TeamBond(panel, ethUsd, eurUsd, 0, 1000, 1 days);
        handler = new BondHandler(bond, panel);

        targetContract(address(handler));
    }

    function invariant_BalanceIsDepositsMinusPayouts() public view {
        assertEq(address(bond).balance, handler.totalIn() - handler.totalToPanel() - handler.totalWithdrawn());
    }

    function invariant_BalanceEqualsTheSumOfAllBonds() public view {
        uint256 sum;
        for (uint256 w = 1; w <= bond.currentWeekend(); w++) {
            for (uint256 t = 0; t < handler.teamCount(); t++) {
                sum += bond.bondOf(w, handler.teams(t));
            }
        }
        assertEq(address(bond).balance, sum);
    }

    function invariant_PanelReceivesOnlyFinesAndDebtPayments() public view {
        assertEq(panel.balance, handler.totalToPanel() + handler.totalDebtPaid());
    }
}

contract LicenceHandler is Test {
    SuperLicence public immutable licence;
    address public immutable panel;
    address[] public drivers;

    mapping(address => uint256) public expectedPoints;

    constructor(SuperLicence licence_, address panel_) {
        licence = licence_;
        panel = panel_;
        for (uint256 i = 0; i < 4; i++) {
            address driver = makeAddr(string.concat("driver", vm.toString(i)));
            drivers.push(driver);
            vm.prank(panel_);
            licence_.mintLicence(driver);
        }
    }

    function driverCount() external view returns (uint256) {
        return drivers.length;
    }

    function addPoints(uint256 seed, uint256 amount) external {
        address driver = drivers[seed % drivers.length];
        amount = bound(amount, 0, 20);
        vm.prank(panel);
        licence.addPoints(driver, amount);
        expectedPoints[driver] += amount;
    }

    function serveBan(uint256 seed) external {
        address driver = drivers[seed % drivers.length];
        vm.prank(panel);
        try licence.serveBan(driver) {
            expectedPoints[driver] -= 12;
        } catch {}
    }

    function tryTransfer(uint256 seed, uint256 callerSeed, address to) external {
        address driver = drivers[seed % drivers.length];
        address caller = callerSeed % 2 == 0 ? driver : panel;
        uint256 id = licence.licenceId(driver);
        vm.prank(caller);
        try licence.transferFrom(driver, to, id) {} catch {}
    }
}

contract SuperLicenceInvariantTest is Test {
    SuperLicence internal licence;
    LicenceHandler internal handler;
    address internal panel = makeAddr("panel");

    function setUp() public {
        SuperLicence implementation = new SuperLicence();
        licence = SuperLicence(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(SuperLicence.initialize, (panel))))
        );
        handler = new LicenceHandler(licence, panel);

        targetContract(address(handler));
    }

    function invariant_LicencesNeverMove() public view {
        for (uint256 i = 0; i < handler.driverCount(); i++) {
            address driver = handler.drivers(i);
            assertEq(licence.ownerOf(licence.licenceId(driver)), driver);
            assertEq(licence.balanceOf(driver), 1);
        }
    }

    function invariant_PointsMatchTheActionsTaken() public view {
        for (uint256 i = 0; i < handler.driverCount(); i++) {
            address driver = handler.drivers(i);
            assertEq(licence.points(driver), handler.expectedPoints(driver));
            assertEq(licence.isBanned(driver), handler.expectedPoints(driver) >= 12);
        }
    }
}
