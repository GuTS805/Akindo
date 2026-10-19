// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IBorrowerOperations,
    ITroveManager,
    IPriceFeed,
    IHintHelpers,
    ISortedTroves,
    IPool,
    IRouter,
    IGauge
} from "./interfaces/IMezo.sol";

/// @title BtcLpVault
/// @notice Deposit BTC only. The vault keeps most of it as collateral in one MUSD trove,
///         borrows MUSD, pairs it with the rest of the BTC as BTC/MUSD liquidity on Mezo Pools,
///         and stakes the LP in the pool's gauge to earn rewards (MEZO on mainnet).
/// @dev    Rebalancing never swaps: debt is steered to NAV / (targetCR + 1) by borrowing or
///         repaying and moving BTC between the trove and the pool. The only swap is a guarded
///         BTC->MUSD top-up when a withdrawal needs more MUSD than the LP returned.
///         No owner, no upgrades. Rebalance and harvest are permissionless.
contract BtcLpVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Config {
        address btc; // BTC ERC-20 precompile (mirrors the native balance on Mezo)
        address musd;
        address borrowerOperations;
        address troveManager;
        address priceFeed;
        address hintHelpers;
        address sortedTroves;
        address router;
        address pool; // volatile BTC/MUSD pool
        address gauge; // gauge staking that pool's LP
        address feeRecipient;
        uint256 targetCR; // 1e18 precision, e.g. 3e18 = 300%
        uint256 minCR; // rebalance below this
        uint256 maxCR; // rebalance above this
        uint256 maxDeviationBps; // max pool-vs-oracle price gap for pool actions
        uint256 feeBps; // share of rewards sent to feeRecipient
        uint256 minDeposit;
    }

    struct Snapshot {
        uint256 price; // MUSD per BTC, 1e18
        uint256 poolPrice; // MUSD per BTC implied by pool reserves
        uint256 coll; // BTC in trove
        uint256 debt; // total trove debt incl. gas compensation and interest
        uint256 netDebt; // debt minus gas compensation (what must be repaid)
        bool troveActive;
        uint256 lp; // LP tokens held (staked + unstaked)
        uint256 lpBtc; // BTC share of pool reserves
        uint256 lpMusd; // MUSD share of pool reserves
        uint256 lpFairValue; // LP value in MUSD at oracle price (manipulation resistant)
        uint256 idleBtc;
        uint256 idleMusd;
        uint256 navMusd;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MUSD_GAS_COMPENSATION = 200e18;
    uint256 public constant MAX_FEE_BPS = 2_000;
    uint256 public constant MAX_DEVIATION_BPS = 1_000;
    uint256 public constant DEAD_SHARES = 1e3;
    address public constant DEAD = address(0xdEaD);
    uint256 public constant HINT_TRIALS = 15;
    /// @notice Idle BTC worth more than this share of NAV makes the vault deployable.
    uint256 public constant IDLE_THRESHOLD_BPS = 100;
    uint8 internal constant TROVE_ACTIVE = 1;
    uint8 internal constant TROVE_CLOSED_BY_REDEMPTION = 4;

    IERC20 public immutable btc;
    IERC20 public immutable musd;
    IBorrowerOperations public immutable borrowerOperations;
    ITroveManager public immutable troveManager;
    IPriceFeed public immutable priceFeed;
    IHintHelpers public immutable hintHelpers;
    ISortedTroves public immutable sortedTroves;
    IRouter public immutable router;
    address public immutable poolFactory;
    IPool public immutable pool;
    IGauge public immutable gauge;
    IERC20 public immutable rewardToken;
    address public immutable feeRecipient;
    bool internal immutable btcIsToken0;

    uint256 public immutable targetCR;
    uint256 public immutable minCR;
    uint256 public immutable maxCR;
    uint256 public immutable maxDeviationBps;
    uint256 public immutable feeBps;
    uint256 public immutable minDeposit;

    /// @notice Rewards owed to holders but not yet claimed (kept apart from idle assets).
    uint256 public rewardReserve;
    uint256 public accRewardPerShare; // 1e18 precision
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public pendingRewards;

    event Deposit(address indexed user, uint256 btcIn, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 btcOut, uint256 musdOut);
    event Rebalance(uint256 netDebtBefore, uint256 netDebtAfter, uint256 crAfter);
    event Harvest(uint256 reward, uint256 fee);
    event RewardClaimed(address indexed user, uint256 amount);
    event Deployed(uint256 musdIntoPool, uint256 btcIntoPool, uint256 lpMinted);

    error BadConfig();
    error DepositTooSmall();
    error ZeroShares();
    error Slippage();
    error PoolPriceOffOracle(uint256 poolPrice, uint256 oraclePrice);
    error NothingToRebalance();
    error BelowMinCR(uint256 cr);
    error MinDebtWouldBreak();
    error OracleUnavailable();
    error InsolventVault();

    constructor(Config memory c) ERC20("Mezo BTC LP Vault", "mbLP") {
        if (
            c.targetCR <= c.minCR || c.maxCR <= c.targetCR || c.minCR < 1.5e18 || c.feeBps > MAX_FEE_BPS
                || c.maxDeviationBps == 0 || c.maxDeviationBps > MAX_DEVIATION_BPS
        ) revert BadConfig();

        btc = IERC20(c.btc);
        musd = IERC20(c.musd);
        borrowerOperations = IBorrowerOperations(c.borrowerOperations);
        troveManager = ITroveManager(c.troveManager);
        priceFeed = IPriceFeed(c.priceFeed);
        hintHelpers = IHintHelpers(c.hintHelpers);
        sortedTroves = ISortedTroves(c.sortedTroves);
        router = IRouter(c.router);
        poolFactory = IRouter(c.router).defaultFactory();
        pool = IPool(c.pool);
        gauge = IGauge(c.gauge);
        rewardToken = IERC20(IGauge(c.gauge).rewardToken());
        feeRecipient = c.feeRecipient;

        address t0 = IPool(c.pool).token0();
        address t1 = IPool(c.pool).token1();
        if (!((t0 == c.btc && t1 == c.musd) || (t0 == c.musd && t1 == c.btc))) revert BadConfig();
        if (IGauge(c.gauge).stakingToken() != c.pool) revert BadConfig();
        btcIsToken0 = t0 == c.btc;

        targetCR = c.targetCR;
        minCR = c.minCR;
        maxCR = c.maxCR;
        maxDeviationBps = c.maxDeviationBps;
        feeBps = c.feeBps;
        minDeposit = c.minDeposit;

        IERC20(c.btc).forceApprove(c.router, type(uint256).max);
        IERC20(c.musd).forceApprove(c.router, type(uint256).max);
        IERC20(c.pool).forceApprove(c.router, type(uint256).max);
        IERC20(c.pool).forceApprove(c.gauge, type(uint256).max);
    }

    /// @dev Receives BTC collateral released by BorrowerOperations. Donations raise NAV for holders.
    receive() external payable {}

    // ---------------------------------------------------------------- user actions

    /// @notice Deposit BTC and receive vault shares. Deploys idle BTC when the pool is near the oracle.
    function deposit(uint256 minShares) external payable nonReentrant returns (uint256 shares) {
        if (msg.value < minDeposit) revert DepositTooSmall();
        _harvest();
        _claimSurplus();

        uint256 price = _fetchPrice();
        if (price == 0) revert OracleUnavailable();

        uint256 supply = totalSupply();
        if (supply == 0) {
            if (msg.value <= DEAD_SHARES) revert DepositTooSmall();
            _mint(DEAD, DEAD_SHARES);
            shares = msg.value - DEAD_SHARES;
        } else {
            Snapshot memory s = _snapshot(price, msg.value);
            uint256 navBtc = Math.mulDiv(s.navMusd, 1e18, price);
            if (navBtc == 0) revert InsolventVault();
            shares = Math.mulDiv(msg.value, supply, navBtc);
        }
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert Slippage();

        _mint(msg.sender, shares);
        emit Deposit(msg.sender, msg.value, shares);

        // Best effort: if the pool is off the oracle or the vault is still below the
        // trove minimum, the BTC waits idle until a later rebalance.
        Snapshot memory after_ = _snapshot(price, 0);
        if (_withinBand(after_.poolPrice, price) && _needsRebalance(after_)) {
            _rebalance(after_, false);
        }
    }

    /// @notice Burn shares for a pro-rata slice of every position. Pays BTC, plus any MUSD left
    ///         after repaying this slice of the debt.
    function withdraw(uint256 shares, uint256 minBtcOut) external nonReentrant returns (uint256 btcOut, uint256 musdOut) {
        if (shares == 0) revert ZeroShares();
        _harvest();
        _claimSurplus();

        uint256 price = _fetchPrice(); // 0 when the oracle is stale: allowed unless a swap is needed
        Snapshot memory s = _snapshot(price, 0);
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);
        bool last = totalSupply() == DEAD_SHARES;

        // Idle slice
        btcOut = Math.mulDiv(s.idleBtc, shares, supply);
        uint256 musdHave = Math.mulDiv(s.idleMusd, shares, supply);

        // LP slice
        uint256 lpOut = last ? s.lp : Math.mulDiv(s.lp, shares, supply);
        if (lpOut > 0) {
            (uint256 b, uint256 m) = _removeLiquidity(lpOut);
            btcOut += b;
            musdHave += m;
        }

        // Trove slice
        if (s.troveActive) {
            uint256 repay = last ? s.netDebt : Math.mulDiv(s.netDebt, shares, supply);
            if (!last && s.netDebt - repay < borrowerOperations.minNetDebt()) revert MinDebtWouldBreak();

            if (musdHave < repay) {
                if (price == 0) revert OracleUnavailable();
                uint256 used;
                (used, musdHave) = _topUpMusd(repay - musdHave, btcOut, price, musdHave);
                btcOut -= used;
            }

            uint256 balBefore = address(this).balance;
            if (last) {
                borrowerOperations.closeTrove();
            } else {
                uint256 collOut = Math.mulDiv(s.coll, shares, supply);
                (address up, address low) = _hints(s.coll - collOut, s.debt - repay);
                borrowerOperations.adjustTrove(collOut, repay, false, up, low);
            }
            btcOut += address(this).balance - balBefore;
            musdHave -= repay;
        }

        if (btcOut < minBtcOut) revert Slippage();
        musdOut = musdHave;

        emit Withdraw(msg.sender, shares, btcOut, musdOut);
        if (musdOut > 0) musd.safeTransfer(msg.sender, musdOut);
        Address.sendValue(payable(msg.sender), btcOut);
    }

    /// @notice Claim accrued gauge rewards (MEZO on mainnet).
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _harvest();
        _settle(msg.sender);
        amount = pendingRewards[msg.sender];
        if (amount == 0) return 0;
        pendingRewards[msg.sender] = 0;
        rewardReserve -= amount;
        emit RewardClaimed(msg.sender, amount);
        rewardToken.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------- keepers (anyone)

    /// @notice Bring the trove back to the target CR and deploy idle BTC. Reverts if the pool
    ///         price is outside the oracle band, so it cannot be used to trade at a bad price.
    function rebalance() external nonReentrant {
        _harvest();
        _claimSurplus();
        uint256 price = _fetchPrice();
        if (price == 0) revert OracleUnavailable();
        Snapshot memory s = _snapshot(price, 0);
        if (!_needsRebalance(s)) revert NothingToRebalance();
        _checkBand(s.poolPrice, price);
        _rebalance(s, true);
    }

    /// @notice Pull gauge rewards into the vault and credit them to holders.
    function harvest() external nonReentrant {
        _harvest();
    }

    /// @notice After a full redemption of the vault's trove, pull the surplus collateral back.
    ///         Deposits, withdrawals and rebalances also do this on their own.
    function claimSurplusCollateral() external nonReentrant {
        borrowerOperations.claimCollateral();
    }

    // ---------------------------------------------------------------- views

    function snapshot() external view returns (Snapshot memory s) {
        uint256 price = _fetchPrice();
        if (price == 0) revert OracleUnavailable();
        s = _snapshot(price, 0);
    }

    /// @notice Collateral ratio of the vault's trove, 1e18 precision (0 when no trove).
    function currentCR() external view returns (uint256) {
        uint256 price = _fetchPrice();
        Snapshot memory s = _snapshot(price, 0);
        return s.troveActive && s.debt > 0 ? Math.mulDiv(s.coll, price, s.debt) : 0;
    }

    function needsRebalance() external view returns (bool) {
        uint256 price = _fetchPrice();
        if (price == 0) return false;
        return _needsRebalance(_snapshot(price, 0));
    }

    /// @notice Share price in BTC, 1e18 precision.
    function pricePerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        uint256 price = _fetchPrice();
        if (price == 0) revert OracleUnavailable();
        return Math.mulDiv(Math.mulDiv(_snapshot(price, 0).navMusd, 1e18, price), 1e18, supply);
    }

    /// @notice Rewards a user could claim now, including gauge rewards not yet harvested.
    function claimable(address user) external view returns (uint256) {
        uint256 acc = accRewardPerShare;
        uint256 supply = totalSupply();
        if (supply > 0) {
            uint256 earned = gauge.earned(address(this));
            acc += Math.mulDiv(earned - Math.mulDiv(earned, feeBps, BPS), 1e18, supply);
        }
        return pendingRewards[user] + Math.mulDiv(balanceOf(user), acc, 1e18) - rewardDebt[user];
    }

    // ---------------------------------------------------------------- strategy internals

    /// @dev Target state: collateral = targetCR * debt, LP = debt of MUSD + debt worth of BTC.
    ///      Then NAV = (targetCR + 1) * netDebt, so netDebt* = NAV / (targetCR + 1).
    function _targetNetDebt(uint256 navMusd) internal view returns (uint256) {
        return Math.mulDiv(navMusd, 1e18, targetCR + 1e18);
    }

    /// @dev Debt a new trove can take without swapping. With B = all BTC held (idle + LP),
    ///      M = all MUSD held, the pool needs (D + M) MUSD worth of BTC and the trove keeps the
    ///      rest at targetCR:  B*P - (D + M) = targetCR * (D + gasComp)
    ///      =>  D = (B*P - M - targetCR*gasComp) / (targetCR + 1).
    ///      After a liquidation M is large and D is usually 0: the vault then stays plain LP.
    function _openableDebt(Snapshot memory s) internal view returns (uint256) {
        uint256 btcValue = Math.mulDiv(s.idleBtc + s.lpBtc, s.price, 1e18);
        uint256 reserved = s.idleMusd + s.lpMusd + Math.mulDiv(MUSD_GAS_COMPENSATION, targetCR, 1e18);
        if (btcValue <= reserved) return 0;
        uint256 d = Math.mulDiv(btcValue - reserved, 1e18, targetCR + 1e18);
        return Math.min(d, _targetNetDebt(s.navMusd));
    }

    function _needsRebalance(Snapshot memory s) internal view returns (bool) {
        if (s.navMusd == 0) return false;
        uint256 idleValue = Math.mulDiv(s.idleBtc, s.price, 1e18) + s.idleMusd;
        bool idleHigh = idleValue * BPS > s.navMusd * IDLE_THRESHOLD_BPS;
        if (!s.troveActive) {
            return _openableDebt(s) >= borrowerOperations.minNetDebt();
        }
        uint256 cr = Math.mulDiv(s.coll, s.price, s.debt);
        return idleHigh || cr < minCR || cr > maxCR;
    }

    function _rebalance(Snapshot memory s, bool strict) internal {
        uint256 minNet = borrowerOperations.minNetDebt();
        uint256 before = s.netDebt;

        if (!s.troveActive) {
            uint256 debt = _openableDebt(s);
            if (debt < minNet) {
                if (strict) revert NothingToRebalance();
                return;
            }
            if (s.lp > 0) {
                // Trove was liquidated or redeemed while LP remained: unwind the LP and
                // rebuild both legs together.
                _removeLiquidity(s.lp);
                s = _snapshot(s.price, 0);
            }
            _open(s, debt);
            _finishRebalance(s.price, before);
            return;
        }

        uint256 target = _targetNetDebt(s.navMusd);
        if (target < minNet) target = minNet; // a small vault stays slightly above target leverage

        if (target > s.netDebt) {
            _lever(s, target - s.netDebt);
        } else if (target < s.netDebt) {
            _delever(s, s.netDebt - target, minNet);
        } else if (s.idleBtc > 0) {
            (address up, address low) = _hints(s.coll + s.idleBtc, s.debt);
            borrowerOperations.adjustTrove{value: s.idleBtc}(0, 0, false, up, low);
        }

        _finishRebalance(s.price, before);
    }

    function _finishRebalance(uint256 price, uint256 netDebtBefore) internal {
        _stakeAll();
        uint256 cr = _troveCR(price);
        if (cr != 0 && cr < minCR) revert BelowMinCR(cr);
        emit Rebalance(netDebtBefore, _netDebt(), cr);
    }

    /// @dev Open the trove and pair all MUSD held (new debt + idle) with BTC in the pool.
    function _open(Snapshot memory s, uint256 netDebt) internal {
        uint256 musdForPool = netDebt + s.idleMusd;
        uint256 btcForPool = Math.mulDiv(musdForPool, 1e18, s.poolPrice);
        if (btcForPool >= s.idleBtc) revert BelowMinCR(0);
        uint256 coll = s.idleBtc - btcForPool;
        uint256 debtWithComp = netDebt + MUSD_GAS_COMPENSATION;
        uint256 cr = Math.mulDiv(coll, s.price, debtWithComp);
        if (cr < minCR) revert BelowMinCR(cr);

        (address up, address low) = _hints(coll, debtWithComp);
        borrowerOperations.openTrove{value: coll}(netDebt, up, low);
        _addLiquidity(musdForPool, btcForPool);
    }

    /// @dev Borrow more and add it to the pool with matching BTC, taken from idle BTC first and
    ///      then from collateral. Leftover idle BTC goes to collateral.
    function _lever(Snapshot memory s, uint256 extraDebt) internal {
        uint256 musdForPool = extraDebt + s.idleMusd;
        uint256 btcForPool = Math.mulDiv(musdForPool, 1e18, s.poolPrice);

        uint256 addColl;
        uint256 withdrawColl;
        if (s.idleBtc >= btcForPool) addColl = s.idleBtc - btcForPool;
        else withdrawColl = btcForPool - s.idleBtc;

        uint256 newDebt = s.debt + extraDebt;
        (address up, address low) = _hints(s.coll + addColl - withdrawColl, newDebt);
        borrowerOperations.adjustTrove{value: addColl}(withdrawColl, extraDebt, true, up, low);
        _addLiquidity(musdForPool, btcForPool);
    }

    /// @dev Pull MUSD out of the pool (idle MUSD first) to repay debt; BTC from the pool
    ///      goes back into collateral. No swaps.
    function _delever(Snapshot memory s, uint256 repayWanted, uint256 minNet) internal {
        uint256 maxRepay = s.netDebt > minNet ? s.netDebt - minNet : 0;
        if (repayWanted > maxRepay) repayWanted = maxRepay;

        uint256 musdHave = s.idleMusd;
        uint256 btcBack = s.idleBtc;
        if (musdHave < repayWanted && s.lpMusd > 0) {
            uint256 lpOut = Math.min(s.lp, Math.mulDiv(s.lp, repayWanted - musdHave, s.lpMusd, Math.Rounding.Ceil));
            (uint256 b, uint256 m) = _removeLiquidity(lpOut);
            btcBack += b;
            musdHave += m;
        }
        uint256 repay = Math.min(musdHave, repayWanted);
        if (repay == 0 && btcBack == 0) return;

        (address up, address low) = _hints(s.coll + btcBack, s.debt - repay);
        borrowerOperations.adjustTrove{value: btcBack}(0, repay, false, up, low);
    }

    // ---------------------------------------------------------------- pool helpers

    function _addLiquidity(uint256 musdAmount, uint256 btcAmount) internal {
        if (musdAmount == 0 || btcAmount == 0) return;
        uint256 slip = BPS - maxDeviationBps;
        (uint256 m, uint256 b, uint256 lp) = router.addLiquidity(
            address(musd),
            address(btc),
            false,
            musdAmount,
            btcAmount,
            Math.mulDiv(musdAmount, slip, BPS),
            Math.mulDiv(btcAmount, slip, BPS),
            address(this),
            block.timestamp
        );
        emit Deployed(m, b, lp);
    }

    function _removeLiquidity(uint256 lpAmount) internal returns (uint256 btcOut, uint256 musdOut) {
        uint256 loose = pool.balanceOf(address(this));
        if (loose < lpAmount) gauge.withdraw(lpAmount - loose);
        (musdOut, btcOut) =
            router.removeLiquidity(address(musd), address(btc), false, lpAmount, 0, 0, address(this), block.timestamp);
    }

    /// @dev Guarded BTC->MUSD swap for a withdrawal shortfall. The minimum output comes from the
    ///      oracle, not the pool, so a sandwiched or drifted pool reverts instead of underpaying.
    function _topUpMusd(uint256 shortfall, uint256 btcAvailable, uint256 price, uint256 musdHave)
        internal
        returns (uint256 btcUsed, uint256 musdAfter)
    {
        btcUsed = Math.mulDiv(shortfall, 1e18 * (BPS + maxDeviationBps), price * BPS, Math.Rounding.Ceil);
        if (btcUsed > btcAvailable) revert Slippage();
        IRouter.Route[] memory route = new IRouter.Route[](1);
        route[0] = IRouter.Route({from: address(btc), to: address(musd), stable: false, factory: poolFactory});
        uint256 minOut = Math.mulDiv(Math.mulDiv(btcUsed, price, 1e18), BPS - maxDeviationBps, BPS);
        uint256[] memory amounts = router.swapExactTokensForTokens(btcUsed, minOut, route, address(this), block.timestamp);
        musdAfter = musdHave + amounts[amounts.length - 1];
        if (musdAfter < musdHave + shortfall) revert Slippage();
    }

    function _stakeAll() internal {
        uint256 loose = pool.balanceOf(address(this));
        if (loose > 0) {
            // A killed gauge must not block the strategy: LP then stays unstaked but counted.
            try gauge.deposit(loose) {} catch {}
        }
    }

    // ---------------------------------------------------------------- rewards

    function _harvest() internal {
        uint256 supply = totalSupply();
        if (supply == 0 || gauge.balanceOf(address(this)) == 0) return;
        uint256 before = rewardToken.balanceOf(address(this));
        gauge.getReward(address(this));
        uint256 got = rewardToken.balanceOf(address(this)) - before;
        if (got == 0) return;

        uint256 fee = Math.mulDiv(got, feeBps, BPS);
        uint256 toHolders = got - fee;
        rewardReserve += toHolders;
        accRewardPerShare += Math.mulDiv(toHolders, 1e18, supply);
        emit Harvest(got, fee);
        if (fee > 0) rewardToken.safeTransfer(feeRecipient, fee);
    }

    /// @dev A redeemed trove leaves surplus BTC in MUSD's surplus pool, outside NAV. Pull it in
    ///      before pricing shares so nobody exits or enters at a NAV missing that BTC.
    function _claimSurplus() internal {
        if (troveManager.getTroveStatus(address(this)) != TROVE_CLOSED_BY_REDEMPTION) return;
        try borrowerOperations.claimCollateral() {} catch {}
    }

    function _settle(address account) internal {
        uint256 accrued = Math.mulDiv(balanceOf(account), accRewardPerShare, 1e18);
        uint256 owed = accrued - rewardDebt[account];
        if (owed > 0) pendingRewards[account] += owed;
        rewardDebt[account] = accrued;
    }

    /// @dev Harvest before shares move, so rewards earned up to now stay with the sender.
    function transfer(address to, uint256 value) public override nonReentrant returns (bool) {
        _harvest();
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override nonReentrant returns (bool) {
        _harvest();
        return super.transferFrom(from, to, value);
    }

    /// @dev Settle rewards on every balance change so transfers keep reward accounting exact.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _settle(from);
        if (to != address(0)) _settle(to);
        super._update(from, to, value);
        if (from != address(0)) rewardDebt[from] = Math.mulDiv(balanceOf(from), accRewardPerShare, 1e18);
        if (to != address(0)) rewardDebt[to] = Math.mulDiv(balanceOf(to), accRewardPerShare, 1e18);
    }

    function rewardReserveIf(IERC20 token) internal view returns (uint256) {
        return address(token) == address(rewardToken) ? rewardReserve : 0;
    }

    // ---------------------------------------------------------------- accounting

    function _snapshot(uint256 price, uint256 excludeBtc) internal view returns (Snapshot memory s) {
        s.price = price;

        (uint256 r0, uint256 r1,) = pool.getReserves();
        (uint256 rBtc, uint256 rMusd) = btcIsToken0 ? (r0, r1) : (r1, r0);
        s.poolPrice = rBtc == 0 ? 0 : Math.mulDiv(rMusd, 1e18, rBtc);

        s.troveActive = troveManager.getTroveStatus(address(this)) == TROVE_ACTIVE;
        if (s.troveActive) {
            (uint256 coll, uint256 principal, uint256 interest,,, uint256 pendingInterest) =
                troveManager.getEntireDebtAndColl(address(this));
            s.coll = coll;
            s.debt = principal + interest + pendingInterest;
            s.netDebt = s.debt > MUSD_GAS_COMPENSATION ? s.debt - MUSD_GAS_COMPENSATION : 0;
        }

        s.lp = gauge.balanceOf(address(this)) + pool.balanceOf(address(this));
        uint256 lpSupply = pool.totalSupply();
        if (s.lp > 0 && lpSupply > 0) {
            s.lpBtc = Math.mulDiv(rBtc, s.lp, lpSupply);
            s.lpMusd = Math.mulDiv(rMusd, s.lp, lpSupply);
            // Fair reserves for x*y=k at the oracle price: value = 2 * sqrt(k * price).
            uint256 fairPoolValue = 2 * Math.sqrt(Math.mulDiv(rBtc * rMusd, price, 1e18));
            s.lpFairValue = Math.mulDiv(fairPoolValue, s.lp, lpSupply);
        }

        s.idleBtc = address(this).balance - excludeBtc - rewardReserveIf(btc);
        s.idleMusd = musd.balanceOf(address(this)) - rewardReserveIf(musd);

        uint256 assets = Math.mulDiv(s.coll + s.idleBtc, price, 1e18) + s.lpFairValue + s.idleMusd;
        s.navMusd = assets > s.netDebt ? assets - s.netDebt : 0;
    }

    function _troveCR(uint256 price) internal view returns (uint256) {
        if (troveManager.getTroveStatus(address(this)) != TROVE_ACTIVE) return 0;
        (uint256 coll, uint256 principal, uint256 interest,,, uint256 pendingInterest) =
            troveManager.getEntireDebtAndColl(address(this));
        uint256 debt = principal + interest + pendingInterest;
        return debt == 0 ? 0 : Math.mulDiv(coll, price, debt);
    }

    function _netDebt() internal view returns (uint256) {
        if (troveManager.getTroveStatus(address(this)) != TROVE_ACTIVE) return 0;
        (, uint256 principal, uint256 interest,,, uint256 pendingInterest) =
            troveManager.getEntireDebtAndColl(address(this));
        uint256 debt = principal + interest + pendingInterest;
        return debt > MUSD_GAS_COMPENSATION ? debt - MUSD_GAS_COMPENSATION : 0;
    }

    function _hints(uint256 coll, uint256 debt) internal view returns (address up, address low) {
        uint256 nicr = hintHelpers.computeNominalCR(coll, debt);
        (address approx,,) = hintHelpers.getApproxHint(nicr, HINT_TRIALS, uint256(blockhash(block.number - 1)));
        (up, low) = sortedTroves.findInsertPosition(nicr, approx, approx);
    }

    function _fetchPrice() internal view returns (uint256) {
        try priceFeed.fetchPrice() returns (uint256 p) {
            return p;
        } catch {
            return 0;
        }
    }

    function _withinBand(uint256 poolPrice, uint256 price) internal view returns (bool) {
        if (poolPrice == 0) return false;
        uint256 diff = poolPrice > price ? poolPrice - price : price - poolPrice;
        return diff * BPS <= price * maxDeviationBps;
    }

    function _checkBand(uint256 poolPrice, uint256 price) internal view {
        if (!_withinBand(poolPrice, price)) revert PoolPriceOffOracle(poolPrice, price);
    }
}
