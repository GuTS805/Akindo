// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  RewardGauge
/// @notice Streams a reward token to stakers of a pool's LP, with the same interface the vault
///         uses on a Mezo Pools gauge (deposit / withdraw / getReward / earned).
/// @dev    Testnet only. The official testnet BTC/MUSD gauge has no emissions and only the
///         Voter can fund it, so a vault staked there never earns anything to harvest. Anyone
///         can fund this one with `notifyRewardAmount`, which makes harvest and claim testable
///         end to end with real testnet MEZO. On mainnet the vault uses the official gauge.
contract RewardGauge is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    uint256 public immutable duration;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Deposit(address indexed from, uint256 amount);
    event Withdraw(address indexed from, uint256 amount);
    event ClaimRewards(address indexed from, uint256 amount);
    event NotifyReward(address indexed from, uint256 amount, uint256 rewardRate, uint256 periodFinish);

    error ZeroAmount();
    error NotAccount();
    error RewardRateTooHigh();

    constructor(address stakingToken_, address rewardToken_, uint256 duration_) {
        if (stakingToken_ == address(0) || rewardToken_ == address(0) || duration_ == 0) revert ZeroAmount();
        stakingToken = IERC20(stakingToken_);
        rewardToken = IERC20(rewardToken_);
        duration = duration_;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + Math.mulDiv((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate, 1e18, totalSupply);
    }

    function earned(address account) public view returns (uint256) {
        return Math.mulDiv(balanceOf[account], rewardPerToken() - userRewardPerTokenPaid[account], 1e18)
            + rewards[account];
    }

    /// @notice Rewards still to be streamed in the current period.
    function left() public view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return (periodFinish - block.timestamp) * rewardRate;
    }

    function deposit(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    function getReward(address account) external nonReentrant updateReward(account) {
        if (msg.sender != account) revert NotAccount();
        uint256 reward = rewards[account];
        if (reward > 0) {
            rewards[account] = 0;
            rewardToken.safeTransfer(account, reward);
            emit ClaimRewards(account, reward);
        }
    }

    /// @notice Stream `amount` reward tokens over the next `duration` seconds, on top of what is
    ///         left of the current period. Permissionless: anyone can fund the gauge.
    function notifyRewardAmount(uint256 amount) external nonReentrant updateReward(address(0)) {
        if (amount == 0) revert ZeroAmount();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        rewardRate = (amount + left()) / duration;
        if (rewardRate == 0) revert ZeroAmount();
        // Never promise more than the gauge holds (reward token is never the staking token).
        if (rewardRate > rewardToken.balanceOf(address(this)) / duration) revert RewardRateTooHigh();

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
        emit NotifyReward(msg.sender, amount, rewardRate, periodFinish);
    }
}
