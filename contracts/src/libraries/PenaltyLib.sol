// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library PenaltyLib {
    error InvalidPrice();
    error InvalidScale();

    uint256 internal constant BAN_THRESHOLD = 12;

    function isBanned(uint256 points) internal pure returns (bool) {
        return points >= BAN_THRESHOLD;
    }

    function eurToWei(uint256 eurAmount, uint256 eurUsd, uint256 ethUsd, uint256 fineScale)
        internal
        pure
        returns (uint256)
    {
        if (eurUsd == 0 || ethUsd == 0) revert InvalidPrice();
        if (fineScale == 0) revert InvalidScale();
        return Math.mulDiv(eurAmount * eurUsd, 1 ether, ethUsd * fineScale);
    }

    function splitFine(uint256 fine, uint256 available) internal pure returns (uint256 fromBond, uint256 debt) {
        fromBond = fine < available ? fine : available;
        debt = fine - fromBond;
    }
}
