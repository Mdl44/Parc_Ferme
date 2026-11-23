// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {StewardsPanel} from "../src/StewardsPanel.sol";
import {SuperLicence} from "../src/SuperLicence.sol";
import {TeamBond} from "../src/TeamBond.sol";
import {DocumentRegistry} from "../src/DocumentRegistry.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";

contract Deploy is Script {
    address internal constant SEPOLIA_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address internal constant SEPOLIA_EUR_USD = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;

    address internal constant ANVIL_STEWARD_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant ANVIL_STEWARD_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant ANVIL_STEWARD_3 = 0x90F79bf6eB2c4F870365E785982E1f101E9b4A67;

    uint256 internal constant THRESHOLD = 2;

    struct Deployment {
        StewardsPanel panel;
        SuperLicence licence;
        address licenceImplementation;
        TeamBond bond;
        DocumentRegistry registry;
        address ethUsdFeed;
        address eurUsdFeed;
        uint256 minBond;
        uint256 fineScale;
    }

    function run() external returns (Deployment memory d) {
        bool local = block.chainid == 31337;
        if (!local && block.chainid != 11155111) revert("Unsupported chain: use Anvil or Sepolia");

        uint256 fineScale = vm.envOr("FINE_SCALE", local ? uint256(40) : uint256(1000));
        uint256 minBond = vm.envOr("MIN_BOND", local ? uint256(1 ether) : uint256(0.02 ether));
        uint256 maxPriceAge = vm.envOr("MAX_PRICE_AGE", local ? uint256(1 days) : uint256(25 hours));

        address[] memory stewards = new address[](3);
        stewards[0] = vm.envOr("STEWARD_1", local ? ANVIL_STEWARD_1 : address(0));
        stewards[1] = vm.envOr("STEWARD_2", local ? ANVIL_STEWARD_2 : address(0));
        stewards[2] = vm.envOr("STEWARD_3", local ? ANVIL_STEWARD_3 : address(0));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        if (local) {
            d.ethUsdFeed = address(new MockAggregator("ETH / USD", 8, 3000e8));
            d.eurUsdFeed = address(new MockAggregator("EUR / USD", 8, 1.1e8));
        } else {
            d.ethUsdFeed = SEPOLIA_ETH_USD;
            d.eurUsdFeed = SEPOLIA_EUR_USD;
        }

        d.panel = new StewardsPanel(stewards, THRESHOLD);

        d.licenceImplementation = address(new SuperLicence());
        d.licence = SuperLicence(
            address(
                new ERC1967Proxy(d.licenceImplementation, abi.encodeCall(SuperLicence.initialize, (address(d.panel))))
            )
        );

        d.bond = new TeamBond(
            address(d.panel),
            AggregatorV3Interface(d.ethUsdFeed),
            AggregatorV3Interface(d.eurUsdFeed),
            minBond,
            fineScale,
            maxPriceAge
        );
        d.registry = new DocumentRegistry(address(d.panel));
        vm.stopBroadcast();

        d.minBond = minBond;
        d.fineScale = fineScale;

        console.log("Deployer:         ", deployer);
        console.log("StewardsPanel:    ", address(d.panel));
        console.log("SuperLicence:     ", address(d.licence), "(proxy)");
        console.log("  implementation: ", d.licenceImplementation);
        console.log("TeamBond:         ", address(d.bond));
        console.log("DocumentRegistry: ", address(d.registry));
        console.log("ETH/USD feed:     ", d.ethUsdFeed);
        console.log("EUR/USD feed:     ", d.eurUsdFeed);
        console.log("Fine scale:       ", fineScale);

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _exportToFrontend(d, deployer, stewards);
        } else {
            console.log("Dry run: front-end addresses not written (add --broadcast).");
        }
    }

    function _exportToFrontend(Deployment memory d, address deployer, address[] memory stewards) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeUint(obj, "fromBlock", block.number);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "stewards", stewards);
        vm.serializeAddress(obj, "stewardsPanel", address(d.panel));
        vm.serializeAddress(obj, "superLicence", address(d.licence));
        vm.serializeAddress(obj, "superLicenceImplementation", d.licenceImplementation);
        vm.serializeAddress(obj, "teamBond", address(d.bond));
        vm.serializeAddress(obj, "documentRegistry", address(d.registry));
        vm.serializeAddress(obj, "ethUsdFeed", d.ethUsdFeed);
        vm.serializeAddress(obj, "eurUsdFeed", d.eurUsdFeed);
        vm.serializeUint(obj, "minBond", d.minBond);
        string memory json = vm.serializeUint(obj, "fineScale", d.fineScale);

        vm.writeJson(json, "../frontend/src/contracts/addresses.json");
        console.log("Addresses written to frontend/src/contracts/addresses.json");
    }
}
