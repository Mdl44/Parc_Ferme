// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IDocumentRegistry} from "./interfaces/IDocumentRegistry.sol";

contract DocumentRegistry is IDocumentRegistry {
    struct WeekendRecord {
        bytes32 root;
        string cid;
        uint256 publishedAt;
    }

    error NotPanel(address caller);
    error ZeroAddress();
    error EmptyRoot();
    error RootAlreadyPublished(uint256 weekendId);
    error NoRoot(uint256 weekendId);

    event RootPublished(uint256 indexed weekendId, bytes32 root, string cid);

    address public immutable panel;

    mapping(uint256 weekendId => WeekendRecord) private _records;

    modifier onlyPanel() {
        if (msg.sender != panel) revert NotPanel(msg.sender);
        _;
    }

    constructor(address panel_) {
        if (panel_ == address(0)) revert ZeroAddress();
        panel = panel_;
    }

    function publishRoot(uint256 weekendId, bytes32 root, string calldata cid) external onlyPanel {
        if (root == bytes32(0)) revert EmptyRoot();
        if (_records[weekendId].root != bytes32(0)) revert RootAlreadyPublished(weekendId);

        _records[weekendId] = WeekendRecord({root: root, cid: cid, publishedAt: block.timestamp});
        emit RootPublished(weekendId, root, cid);
    }

    function verifyDocument(uint256 weekendId, bytes32 documentHash, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        bytes32 root = _records[weekendId].root;
        if (root == bytes32(0)) revert NoRoot(weekendId);
        return MerkleProof.verifyCalldata(proof, root, leafOf(documentHash));
    }

    function getRecord(uint256 weekendId) external view returns (WeekendRecord memory) {
        return _records[weekendId];
    }

    function leafOf(bytes32 documentHash) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(documentHash))));
    }
}
