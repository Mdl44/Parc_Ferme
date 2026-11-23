// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC5192} from "./interfaces/IERC5192.sol";
import {ISuperLicence} from "./interfaces/ISuperLicence.sol";
import {PenaltyLib} from "./libraries/PenaltyLib.sol";

contract SuperLicence is ERC721Upgradeable, UUPSUpgradeable, IERC5192, ISuperLicence {
    error NotPanel(address caller);
    error ZeroAddress();
    error NoLicence(address driver);
    error LicenceAlreadyIssued(address driver);
    error NotBanned(address driver);
    error Soulbound();

    event PanelChanged(address indexed oldPanel, address indexed newPanel);
    event LicenceIssued(address indexed driver, uint256 indexed tokenId);
    event PointsAdded(address indexed driver, uint256 amount, uint256 total);
    event BanTriggered(address indexed driver, uint256 total);
    event BanServed(address indexed driver, uint256 remaining);

    uint256 public constant BAN_THRESHOLD = PenaltyLib.BAN_THRESHOLD;

    address public panel;

    mapping(address driver => uint256) public override points;

    modifier onlyPanel() {
        if (msg.sender != panel) revert NotPanel(msg.sender);
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address panel_) external initializer {
        if (panel_ == address(0)) revert ZeroAddress();
        __ERC721_init("FIA Super Licence", "LICENCE");
        panel = panel_;
        emit PanelChanged(address(0), panel_);
    }

    function setPanel(address newPanel) external onlyPanel {
        if (newPanel == address(0)) revert ZeroAddress();
        emit PanelChanged(panel, newPanel);
        panel = newPanel;
    }

    function mintLicence(address driver) external onlyPanel returns (uint256 tokenId) {
        tokenId = licenceId(driver);
        if (_ownerOf(tokenId) != address(0)) revert LicenceAlreadyIssued(driver);

        // forge-lint: disable-next-line(unsafe-oz-erc721-mint)
        _mint(driver, tokenId);
        emit LicenceIssued(driver, tokenId);
        emit Locked(tokenId);
    }

    function addPoints(address driver, uint256 amount) external onlyPanel {
        if (_ownerOf(licenceId(driver)) == address(0)) revert NoLicence(driver);

        bool wasBanned = isBanned(driver);
        points[driver] += amount;
        emit PointsAdded(driver, amount, points[driver]);

        if (!wasBanned && isBanned(driver)) {
            emit BanTriggered(driver, points[driver]);
        }
    }

    function serveBan(address driver) external onlyPanel {
        if (!isBanned(driver)) revert NotBanned(driver);
        points[driver] -= BAN_THRESHOLD;
        emit BanServed(driver, points[driver]);
    }

    function isBanned(address driver) public view returns (bool) {
        return PenaltyLib.isBanned(points[driver]);
    }

    function licenceId(address driver) public pure returns (uint256) {
        return uint256(uint160(driver));
    }

    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC5192).interfaceId || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function _authorizeUpgrade(address) internal override onlyPanel {}
}
