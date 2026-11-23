// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IDocumentRegistry {
    function publishRoot(uint256 weekendId, bytes32 root, string calldata cid) external;
    function verifyDocument(uint256 weekendId, bytes32 documentHash, bytes32[] calldata proof)
        external
        view
        returns (bool);
}
