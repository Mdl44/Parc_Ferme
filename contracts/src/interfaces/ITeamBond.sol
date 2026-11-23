// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ITeamBond {
    function openWeekend() external returns (uint256 weekendId);
    function closeWeekend() external;
    function registerTeam(address team) external;
    function applyFine(address team, uint256 eurAmount)
        external
        returns (uint256 fineWei, uint256 fromBond, uint256 newDebt);

    function depositBond() external payable;
    function payDebt() external payable;
    function withdraw(uint256 weekendId) external;

    function quoteFineWei(uint256 eurAmount) external view returns (uint256);
    function bondOf(uint256 weekendId, address team) external view returns (uint256);
    function debtOf(address team) external view returns (uint256);
}
