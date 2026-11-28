// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SuperLicence} from "./SuperLicence.sol";

contract SuperLicenceV2 is SuperLicence {
    using SafeCast for uint256;

    struct Award {
        uint128 amount;
        uint128 awardedAt;
    }

    event UpgradedToV2(uint256 legacyPointsExpireAt);

    uint256 public constant POINTS_VALIDITY = 365 days;

    uint256 public upgradedAt;

    mapping(address driver => Award[]) private _awards;

    mapping(address driver => uint256) private _firstLive;

    function initializeV2() external reinitializer(2) {
        upgradedAt = block.timestamp;
        emit UpgradedToV2(block.timestamp + POINTS_VALIDITY);
    }

    function points(address driver) public view override returns (uint256 total) {
        total = _legacyLive() ? _points[driver] : 0;
        Award[] storage list = _awards[driver];
        for (uint256 i = _firstLive[driver]; i < list.length; i++) {
            if (_live(list[i].awardedAt)) total += list[i].amount;
        }
    }

    function awardsOf(address driver) external view returns (Award[] memory) {
        return _awards[driver];
    }

    function nextExpiry(address driver) external view returns (uint256) {
        if (_legacyLive() && _points[driver] > 0) return upgradedAt + POINTS_VALIDITY;
        Award[] storage list = _awards[driver];
        for (uint256 i = _firstLive[driver]; i < list.length; i++) {
            if (_live(list[i].awardedAt) && list[i].amount > 0) return list[i].awardedAt + POINTS_VALIDITY;
        }
        return 0;
    }

    function version() external pure override returns (string memory) {
        return "2";
    }

    function _credit(address driver, uint256 amount) internal override {
        _awards[driver].push(Award({amount: amount.toUint128(), awardedAt: block.timestamp.toUint128()}));
    }

    function _debit(address driver, uint256 amount) internal override {
        uint256 left = amount;

        if (_legacyLive()) {
            uint256 fromLegacy = _min(left, _points[driver]);
            _points[driver] -= fromLegacy;
            left -= fromLegacy;
        }

        Award[] storage list = _awards[driver];
        uint256 i = _firstLive[driver];
        while (left > 0) {
            Award storage award = list[i];
            if (_live(award.awardedAt)) {
                uint256 taken = _min(left, award.amount);
                award.amount -= taken.toUint128();
                left -= taken;
            }
            if (award.amount == 0 || !_live(award.awardedAt)) i++;
        }
        _firstLive[driver] = i;
    }

    function _legacyLive() private view returns (bool) {
        return block.timestamp < upgradedAt + POINTS_VALIDITY;
    }

    function _live(uint256 awardedAt) private view returns (bool) {
        return block.timestamp < awardedAt + POINTS_VALIDITY;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
