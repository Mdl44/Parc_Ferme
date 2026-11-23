// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISuperLicence {
    function mintLicence(address driver) external returns (uint256 tokenId);
    function addPoints(address driver, uint256 amount) external;
    function serveBan(address driver) external;
    function isBanned(address driver) external view returns (bool);
    function points(address driver) external view returns (uint256);
    function licenceId(address driver) external pure returns (uint256);
}
