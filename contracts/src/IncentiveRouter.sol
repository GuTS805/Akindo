// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The incentive ("bribe") contract Mezo Earn attaches to every pool gauge.
interface IVotingIncentives {
    function notifyRewardAmount(address token, uint256 amount) external;
}

/// @title  IncentiveRouter
/// @notice Turns the vault's reward fee into votes for its own pool. Set as the vault's fee
///         recipient: part of every fee is posted as an incentive on the BTC/MUSD gauge, where
///         veBTC voters earn it by voting for that gauge; the rest goes to the treasury.
/// @dev    Mezo Earn splits MEZO emissions between gauges by veBTC votes, and protocols attract
///         votes with incentives. More vault fees -> more incentives -> more votes -> more
///         emissions to the vault's LP -> higher depositor yield -> more deposits.
///         No owner; the split and both destinations are fixed. Anyone can call `push`.
contract IncentiveRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    IERC20 public immutable token;
    IVotingIncentives public immutable incentives;
    address public immutable treasury;
    uint256 public immutable incentiveBps;

    event Pushed(uint256 toIncentives, uint256 toTreasury);
    /// @notice The incentive contract refused the tokens (e.g. no longer whitelisted, gauge killed).
    event IncentivesRefused(uint256 amount);

    error BadConfig();
    error NothingToPush();

    constructor(address token_, address incentives_, address treasury_, uint256 incentiveBps_) {
        if (token_ == address(0) || incentives_ == address(0) || treasury_ == address(0) || incentiveBps_ > BPS) {
            revert BadConfig();
        }
        token = IERC20(token_);
        incentives = IVotingIncentives(incentives_);
        treasury = treasury_;
        incentiveBps = incentiveBps_;
    }

    /// @notice Post this contract's balance: `incentiveBps` as a gauge incentive for the current
    ///         epoch, the rest to the treasury. If the incentive contract refuses the tokens, the
    ///         whole balance goes to the treasury, so fees can never be stuck here.
    function push() external nonReentrant returns (uint256 toIncentives, uint256 toTreasury) {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NothingToPush();
        toIncentives = Math.mulDiv(balance, incentiveBps, BPS);

        if (toIncentives > 0) {
            token.forceApprove(address(incentives), toIncentives);
            try incentives.notifyRewardAmount(address(token), toIncentives) {}
            catch {
                token.forceApprove(address(incentives), 0);
                emit IncentivesRefused(toIncentives);
                toIncentives = 0;
            }
        }
        toTreasury = token.balanceOf(address(this));
        emit Pushed(toIncentives, toTreasury);
        if (toTreasury > 0) token.safeTransfer(treasury, toTreasury);
    }
}
