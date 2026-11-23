// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StewardsPanel is EIP712, ReentrancyGuard, IERC1271 {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    error NotThePanel(address caller);
    error InvalidSetup();
    error EmptyBatch();
    error InvalidSignatures();
    error CallFailed(uint256 index, bytes reason);
    error NotASteward(address account);
    error AlreadyASteward(address account);

    event Executed(uint256 indexed nonce, address indexed executor, uint256 calls);
    event Received(address indexed from, uint256 amount);
    event StewardReplaced(address indexed oldSteward, address indexed newSteward);

    bytes32 private constant CALL_TYPEHASH = keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 private constant BATCH_TYPEHASH =
        keccak256("Batch(Call[] calls,uint256 nonce)Call(address target,uint256 value,bytes data)");

    uint256 public immutable threshold;

    uint256 public nonce;

    mapping(address account => bool) public isSteward;
    address[] private _stewards;

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotThePanel(msg.sender);
        _;
    }

    constructor(address[] memory stewards_, uint256 threshold_) EIP712("Parc Ferme Stewards Panel", "1") {
        if (threshold_ == 0 || threshold_ > stewards_.length) revert InvalidSetup();

        for (uint256 i = 0; i < stewards_.length; i++) {
            address steward = stewards_[i];
            if (steward == address(0) || isSteward[steward]) revert InvalidSetup();
            isSteward[steward] = true;
            _stewards.push(steward);
        }
        threshold = threshold_;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function execute(Call[] calldata calls, bytes calldata signatures) external nonReentrant {
        if (calls.length == 0) revert EmptyBatch();

        uint256 current = nonce;
        if (!_signaturesValid(hashBatch(calls, current), signatures)) revert InvalidSignatures();

        nonce = current + 1;

        for (uint256 i = 0; i < calls.length; i++) {
            // forge-lint: disable-next-line(arbitrary-send-eth)
            (bool ok, bytes memory reason) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i, reason);
        }
        emit Executed(current, msg.sender, calls.length);
    }

    function replaceSteward(address oldSteward, address newSteward) external onlySelf {
        if (!isSteward[oldSteward]) revert NotASteward(oldSteward);
        if (newSteward == address(0) || isSteward[newSteward]) revert AlreadyASteward(newSteward);

        isSteward[oldSteward] = false;
        isSteward[newSteward] = true;
        for (uint256 i = 0; i < _stewards.length; i++) {
            if (_stewards[i] == oldSteward) {
                _stewards[i] = newSteward;
                break;
            }
        }
        emit StewardReplaced(oldSteward, newSteward);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue) {
        return _signaturesValid(hash, signature) ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    function stewards() external view returns (address[] memory) {
        return _stewards;
    }

    function hashBatch(Call[] calldata calls, uint256 nonce_) public view returns (bytes32) {
        bytes32[] memory callHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            callHashes[i] =
                keccak256(abi.encode(CALL_TYPEHASH, calls[i].target, calls[i].value, keccak256(calls[i].data)));
        }
        bytes32 structHash = keccak256(abi.encode(BATCH_TYPEHASH, keccak256(abi.encodePacked(callHashes)), nonce_));
        return _hashTypedDataV4(structHash);
    }

    function _signaturesValid(bytes32 digest, bytes calldata signatures) internal view returns (bool) {
        if (signatures.length % 65 != 0) return false;
        uint256 count = signatures.length / 65;
        if (count < threshold) return false;

        address previous = address(0);
        for (uint256 i = 0; i < count; i++) {
            (address signer, ECDSA.RecoverError recoverError,) =
                ECDSA.tryRecoverCalldata(digest, signatures[i * 65:(i + 1) * 65]);
            if (recoverError != ECDSA.RecoverError.NoError || signer <= previous || !isSteward[signer]) return false;
            previous = signer;
        }
        return true;
    }
}
