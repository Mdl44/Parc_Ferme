// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ITeamBond} from "./interfaces/ITeamBond.sol";
import {PenaltyLib} from "./libraries/PenaltyLib.sol";

contract TeamBond is ITeamBond, ReentrancyGuard {
    enum WeekendStatus {
        None,
        Open,
        Closed
    }

    error NotPanel(address caller);
    error NotATeam(address caller);
    error ZeroAddress();
    error ZeroValue();
    error InvalidSetting();
    error AlreadyRegistered(address team);
    error PreviousWeekendNotClosed(uint256 weekendId);
    error WeekendNotOpen();
    error WeekendNotClosed(uint256 weekendId);
    error HasDebt(address team, uint256 debt);
    error BelowMinimumBond(uint256 bondAfterDeposit, uint256 minimum);
    error NothingToWithdraw(uint256 weekendId, address team);
    error Overpayment(uint256 sent, uint256 debt);
    error StalePrice(address feed, uint256 updatedAt);
    error BadPrice(address feed);
    error FeedDecimalsMismatch();
    error TransferFailed(address to, uint256 amount);

    event WeekendOpened(uint256 indexed weekendId);
    event WeekendClosed(uint256 indexed weekendId);
    event TeamRegistered(address indexed team, string name);
    event BondDeposited(uint256 indexed weekendId, address indexed team, uint256 amount, uint256 bondTotal);
    event FineApplied(
        uint256 indexed weekendId,
        address indexed team,
        uint256 eurAmount,
        uint256 fineWei,
        uint256 fromBond,
        uint256 newDebt,
        bytes32 indexed decision
    );
    event DebtPaid(address indexed team, uint256 amount, uint256 remainingDebt);
    event BondWithdrawn(uint256 indexed weekendId, address indexed team, uint256 amount);
    event MinBondChanged(uint256 oldValue, uint256 newValue);
    event FineScaleChanged(uint256 oldValue, uint256 newValue);
    event MaxPriceAgeChanged(uint256 oldValue, uint256 newValue);

    address public immutable panel;

    AggregatorV3Interface public immutable ethUsdFeed;
    AggregatorV3Interface public immutable eurUsdFeed;

    uint256 public maxPriceAge;

    uint256 public minBond;

    uint256 public fineScale;

    uint256 public currentWeekend;

    mapping(uint256 weekendId => WeekendStatus) public weekendStatus;
    mapping(address team => bool) public isTeam;

    mapping(address team => string) public teamName;

    mapping(address team => uint256) public override debtOf;

    mapping(uint256 weekendId => mapping(address team => uint256)) private _bond;

    modifier onlyPanel() {
        if (msg.sender != panel) revert NotPanel(msg.sender);
        _;
    }

    modifier onlyTeam() {
        if (!isTeam[msg.sender]) revert NotATeam(msg.sender);
        _;
    }

    constructor(
        address panel_,
        AggregatorV3Interface ethUsdFeed_,
        AggregatorV3Interface eurUsdFeed_,
        uint256 minBond_,
        uint256 fineScale_,
        uint256 maxPriceAge_
    ) {
        if (panel_ == address(0) || address(ethUsdFeed_) == address(0) || address(eurUsdFeed_) == address(0)) {
            revert ZeroAddress();
        }
        if (fineScale_ == 0 || maxPriceAge_ == 0) revert InvalidSetting();
        if (ethUsdFeed_.decimals() != eurUsdFeed_.decimals()) revert FeedDecimalsMismatch();

        panel = panel_;
        ethUsdFeed = ethUsdFeed_;
        eurUsdFeed = eurUsdFeed_;
        minBond = minBond_;
        fineScale = fineScale_;
        maxPriceAge = maxPriceAge_;
    }

    function openWeekend() external onlyPanel returns (uint256 weekendId) {
        uint256 last = currentWeekend;
        if (last != 0 && weekendStatus[last] != WeekendStatus.Closed) revert PreviousWeekendNotClosed(last);

        weekendId = last + 1;
        currentWeekend = weekendId;
        weekendStatus[weekendId] = WeekendStatus.Open;
        emit WeekendOpened(weekendId);
    }

    function closeWeekend() external onlyPanel {
        uint256 id = currentWeekend;
        if (weekendStatus[id] != WeekendStatus.Open) revert WeekendNotOpen();

        weekendStatus[id] = WeekendStatus.Closed;
        emit WeekendClosed(id);
    }

    function registerTeam(address team, string calldata name) external onlyPanel {
        if (team == address(0)) revert ZeroAddress();
        if (isTeam[team]) revert AlreadyRegistered(team);

        isTeam[team] = true;
        teamName[team] = name;
        emit TeamRegistered(team, name);
    }

    function setMinBond(uint256 newMinBond) external onlyPanel {
        emit MinBondChanged(minBond, newMinBond);
        minBond = newMinBond;
    }

    function setFineScale(uint256 newFineScale) external onlyPanel {
        if (newFineScale == 0) revert InvalidSetting();
        emit FineScaleChanged(fineScale, newFineScale);
        fineScale = newFineScale;
    }

    function setMaxPriceAge(uint256 newMaxPriceAge) external onlyPanel {
        if (newMaxPriceAge == 0) revert InvalidSetting();
        emit MaxPriceAgeChanged(maxPriceAge, newMaxPriceAge);
        maxPriceAge = newMaxPriceAge;
    }

    function applyFine(address team, uint256 eurAmount, bytes32 decision)
        external
        nonReentrant
        onlyPanel
        returns (uint256 fineWei, uint256 fromBond, uint256 newDebt)
    {
        if (!isTeam[team]) revert NotATeam(team);
        uint256 weekendId = currentWeekend;
        if (weekendStatus[weekendId] != WeekendStatus.Open) revert WeekendNotOpen();

        fineWei = quoteFineWei(eurAmount);
        (fromBond, newDebt) = PenaltyLib.splitFine(fineWei, _bond[weekendId][team]);

        _bond[weekendId][team] -= fromBond;
        debtOf[team] += newDebt;
        emit FineApplied(weekendId, team, eurAmount, fineWei, fromBond, newDebt, decision);

        if (fromBond > 0) _send(panel, fromBond);
    }

    function depositBond() external payable onlyTeam {
        uint256 weekendId = currentWeekend;
        if (weekendStatus[weekendId] != WeekendStatus.Open) revert WeekendNotOpen();
        if (debtOf[msg.sender] > 0) revert HasDebt(msg.sender, debtOf[msg.sender]);
        if (msg.value == 0) revert ZeroValue();

        uint256 total = _bond[weekendId][msg.sender] + msg.value;
        if (total < minBond) revert BelowMinimumBond(total, minBond);

        _bond[weekendId][msg.sender] = total;
        emit BondDeposited(weekendId, msg.sender, msg.value, total);
    }

    function payDebt() external payable nonReentrant {
        uint256 owed = debtOf[msg.sender];
        if (msg.value == 0) revert ZeroValue();
        if (msg.value > owed) revert Overpayment(msg.value, owed);

        debtOf[msg.sender] = owed - msg.value;
        emit DebtPaid(msg.sender, msg.value, owed - msg.value);

        _send(panel, msg.value);
    }

    function withdraw(uint256 weekendId) external nonReentrant {
        if (weekendStatus[weekendId] != WeekendStatus.Closed) revert WeekendNotClosed(weekendId);

        uint256 amount = _bond[weekendId][msg.sender];
        if (amount == 0) revert NothingToWithdraw(weekendId, msg.sender);

        _bond[weekendId][msg.sender] = 0;
        emit BondWithdrawn(weekendId, msg.sender, amount);

        _send(msg.sender, amount);
    }

    function bondOf(uint256 weekendId, address team) external view returns (uint256) {
        return _bond[weekendId][team];
    }

    function quoteFineWei(uint256 eurAmount) public view returns (uint256) {
        uint256 eurUsd = _latestPrice(eurUsdFeed);
        uint256 ethUsd = _latestPrice(ethUsdFeed);
        return PenaltyLib.eurToWei(eurAmount, eurUsd, ethUsd, fineScale);
    }

    function _latestPrice(AggregatorV3Interface feed) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadPrice(address(feed));
        if (updatedAt + maxPriceAge < block.timestamp) revert StalePrice(address(feed), updatedAt);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer);
    }

    function _send(address to, uint256 amount) private {
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed(to, amount);
    }
}
