// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC5192} from "./interfaces/IERC5192.sol";
import {ISuperLicence} from "./interfaces/ISuperLicence.sol";
import {PenaltyLib} from "./libraries/PenaltyLib.sol";

contract SuperLicence is ERC721Upgradeable, UUPSUpgradeable, IERC5192, ISuperLicence {
    using Strings for uint256;

    struct Profile {
        string name;
        string code;
        uint256 carNumber;
    }

    error NotPanel(address caller);
    error ZeroAddress();
    error ZeroPoints();
    error NoLicence(address driver);
    error LicenceAlreadyIssued(address driver);
    error NotBanned(address driver);
    error Soulbound();

    event PanelChanged(address indexed oldPanel, address indexed newPanel);
    event LicenceIssued(address indexed driver, uint256 indexed tokenId, string name, uint256 carNumber);
    event PointsAdded(address indexed driver, uint256 amount, uint256 total, bytes32 indexed decision);
    event BanTriggered(address indexed driver, uint256 total);
    event BanServed(address indexed driver, uint256 remaining);

    uint256 public constant BAN_THRESHOLD = PenaltyLib.BAN_THRESHOLD;

    address public panel;

    mapping(address driver => uint256) internal _points;

    mapping(address driver => Profile) private _profiles;

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

    function mintLicence(address driver, string calldata name, string calldata code, uint256 carNumber)
        external
        onlyPanel
        returns (uint256 tokenId)
    {
        tokenId = licenceId(driver);
        if (_ownerOf(tokenId) != address(0)) revert LicenceAlreadyIssued(driver);

        _profiles[driver] = Profile({name: name, code: code, carNumber: carNumber});
        // forge-lint: disable-next-line(unsafe-oz-erc721-mint)
        _mint(driver, tokenId);
        emit LicenceIssued(driver, tokenId, name, carNumber);
        emit Locked(tokenId);
    }

    function addPoints(address driver, uint256 amount, bytes32 decision) external onlyPanel {
        if (_ownerOf(licenceId(driver)) == address(0)) revert NoLicence(driver);
        if (amount == 0) revert ZeroPoints();

        bool wasBanned = isBanned(driver);
        _credit(driver, amount);
        uint256 total = points(driver);
        emit PointsAdded(driver, amount, total, decision);

        if (!wasBanned && PenaltyLib.isBanned(total)) {
            emit BanTriggered(driver, total);
        }
    }

    function serveBan(address driver) external onlyPanel {
        if (!isBanned(driver)) revert NotBanned(driver);
        _debit(driver, BAN_THRESHOLD);
        emit BanServed(driver, points(driver));
    }

    function points(address driver) public view virtual returns (uint256) {
        return _points[driver];
    }

    function isBanned(address driver) public view returns (bool) {
        return PenaltyLib.isBanned(points(driver));
    }

    function profileOf(address driver) external view returns (Profile memory) {
        return _profiles[driver];
    }

    function licenceId(address driver) public pure returns (uint256) {
        return uint256(uint160(driver));
    }

    function version() external pure virtual returns (string memory) {
        return "1";
    }

    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        address driver = _requireOwned(tokenId);
        Profile storage p = _profiles[driver];
        uint256 total = points(driver);
        string memory status = PenaltyLib.isBanned(total) ? "Banned" : "Active";

        string memory json = string.concat(
            '{"name":"Super Licence #',
            p.carNumber.toString(),
            " - ",
            p.name,
            '","description":"FIA Super Licence. Soulbound (ERC-5192): it can never be transferred.",',
            '"attributes":[{"trait_type":"Car number","value":',
            p.carNumber.toString(),
            '},{"trait_type":"Penalty points","value":',
            total.toString(),
            '},{"trait_type":"Status","value":"',
            status,
            '"}],"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_card(p, total, status))),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC5192).interfaceId || super.supportsInterface(interfaceId);
    }

    function _credit(address driver, uint256 amount) internal virtual {
        _points[driver] += amount;
    }

    function _debit(address driver, uint256 amount) internal virtual {
        _points[driver] -= amount;
    }

    function _card(Profile storage p, uint256 total, string memory status) private view returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="240" viewBox="0 0 400 240">',
            '<rect width="400" height="240" rx="16" fill="#15151e"/>',
            '<rect width="400" height="8" fill="#e10600"/>',
            '<text x="24" y="44" fill="#9a9aa6" font-family="sans-serif" font-size="14">FIA SUPER LICENCE</text>',
            '<text x="24" y="104" fill="#ffffff" font-family="sans-serif" font-size="30" font-weight="bold">',
            p.name,
            '</text><text x="24" y="136" fill="#9a9aa6" font-family="sans-serif" font-size="18">',
            p.code,
            "  #",
            p.carNumber.toString(),
            '</text><text x="24" y="200" fill="#ffffff" font-family="sans-serif" font-size="22">',
            total.toString(),
            " / 12 points  -  ",
            status,
            "</text></svg>"
        );
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function _authorizeUpgrade(address) internal override onlyPanel {}
}
