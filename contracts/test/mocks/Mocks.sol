// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @dev Mezo's BTC precompile: an ERC-20 whose balances ARE native balances.
contract MockBTC {
    string public constant name = "Bitcoin";
    string public constant symbol = "BTC";
    uint8 public constant decimals = 18;
    mapping(address => mapping(address => uint256)) public allowance;

    function balanceOf(address a) external view returns (uint256) {
        return a.balance;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "BTC: allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(from.balance >= amount, "BTC: balance");
        vm.deal(from, from.balance - amount);
        vm.deal(to, to.balance + amount);
    }
}

contract MockToken is ERC20 {
    address public minter;

    constructor(string memory n, string memory s) ERC20(n, s) {
        minter = msg.sender;
    }

    function setMinter(address m) external {
        minter = m;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "not minter");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == minter, "not minter");
        _burn(from, amount);
    }
}

contract MockPriceFeed {
    uint256 public price;
    bool public stale;

    constructor(uint256 p) {
        price = p;
    }

    function set(uint256 p) external {
        price = p;
    }

    function setStale(bool s) external {
        stale = s;
    }

    function fetchPrice() external view returns (uint256) {
        require(!stale, "PriceFeed: Oracle is stale.");
        return price;
    }
}

/// @dev One contract playing BorrowerOperations, TroveManager, HintHelpers and SortedTroves.
///      Mirrors MUSD rules that matter here: 110% MCR, 1800 min net debt, 200 gas compensation,
///      0.1% borrowing fee added to debt, native BTC collateral.
contract MockTroveSystem {
    struct Trove {
        uint256 coll;
        uint256 debt;
        uint8 status;
    }

    uint256 public constant MCR = 1.1e18;
    uint256 public constant GAS_COMP = 200e18;
    uint256 public minNetDebt = 1800e18;
    uint256 public feeBps = 10;

    MockToken public immutable musd;
    MockPriceFeed public immutable feed;
    mapping(address => Trove) public troves;
    mapping(address => uint256) public surplus;

    constructor(MockToken m, MockPriceFeed f) {
        musd = m;
        feed = f;
    }

    // ---- BorrowerOperations
    function openTrove(uint256 debtAmount, address, address) external payable {
        Trove storage t = troves[msg.sender];
        require(t.status != 1, "trove active");
        require(debtAmount >= minNetDebt, "below min debt");
        uint256 debt = debtAmount + (debtAmount * feeBps) / 10_000 + GAS_COMP;
        t.coll = msg.value;
        t.debt = debt;
        t.status = 1;
        _requireCR(t);
        musd.mint(msg.sender, debtAmount);
    }

    function adjustTrove(uint256 collWithdrawal, uint256 debtChange, bool isDebtIncrease, address, address)
        external
        payable
    {
        Trove storage t = troves[msg.sender];
        require(t.status == 1, "no trove");
        require(!(collWithdrawal > 0 && msg.value > 0), "both coll changes");
        require(collWithdrawal > 0 || msg.value > 0 || debtChange > 0, "no change");
        t.coll = t.coll + msg.value - collWithdrawal;
        if (isDebtIncrease) {
            t.debt += debtChange + (debtChange * feeBps) / 10_000;
            musd.mint(msg.sender, debtChange);
        } else if (debtChange > 0) {
            require(debtChange <= t.debt - GAS_COMP, "repay too much");
            t.debt -= debtChange;
            musd.burn(msg.sender, debtChange);
        }
        require(t.debt - GAS_COMP >= minNetDebt, "below min debt");
        _requireCR(t);
        if (collWithdrawal > 0) payable(msg.sender).transfer(collWithdrawal);
    }

    function closeTrove() external {
        Trove storage t = troves[msg.sender];
        require(t.status == 1, "no trove");
        musd.burn(msg.sender, t.debt - GAS_COMP);
        uint256 coll = t.coll;
        t.coll = 0;
        t.debt = 0;
        t.status = 2;
        payable(msg.sender).transfer(coll);
    }

    function claimCollateral() external {
        uint256 s = surplus[msg.sender];
        surplus[msg.sender] = 0;
        payable(msg.sender).transfer(s);
    }

    // ---- TroveManager
    function getEntireDebtAndColl(address b)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        Trove storage t = troves[b];
        return (t.coll, t.debt, 0, 0, 0, 0);
    }

    function getTroveStatus(address b) external view returns (uint8) {
        return troves[b].status;
    }

    // ---- HintHelpers / SortedTroves
    function computeNominalCR(uint256 coll, uint256 debt) external pure returns (uint256) {
        return debt == 0 ? type(uint256).max : (coll * 1e20) / debt;
    }

    function getApproxHint(uint256, uint256, uint256 seed) external pure returns (address, uint256, uint256) {
        return (address(0), 0, seed);
    }

    function findInsertPosition(uint256, address, address) external pure returns (address, address) {
        return (address(0), address(0));
    }

    // ---- test helpers
    function addInterest(address b, uint256 amount) external {
        troves[b].debt += amount;
    }

    function liquidate(address b) external {
        Trove storage t = troves[b];
        t.coll = 0;
        t.debt = 0;
        t.status = 3;
    }

    function redeemFully(address b) external {
        Trove storage t = troves[b];
        uint256 price = feed.fetchPrice();
        uint256 collTaken = Math.mulDiv(t.debt - GAS_COMP, 1e18, price);
        surplus[b] = t.coll - collTaken;
        t.coll = 0;
        t.debt = 0;
        t.status = 4;
        payable(address(0xBEEF)).transfer(collTaken);
    }

    function _requireCR(Trove storage t) internal view {
        require(Math.mulDiv(t.coll, feed.fetchPrice(), t.debt) >= MCR, "below MCR");
    }

    receive() external payable {}
}

/// @dev Solidly volatile pool: x*y=k, 0.3% fee, LP is the pool token itself.
contract MockPool is ERC20 {
    address public immutable token0;
    address public immutable token1;
    uint256 internal r0;
    uint256 internal r1;
    uint256 public constant FEE_BPS = 30;

    constructor(address a, address b) ERC20("vAMM", "vAMM") {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint256, uint256, uint256) {
        return (r0, r1, block.timestamp);
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 a0 = b0 - r0;
        uint256 a1 = b1 - r1;
        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = Math.sqrt(a0 * a1) - 1000;
            _mint(address(0xdead), 1000);
        } else {
            liquidity = Math.min((a0 * supply) / r0, (a1 * supply) / r1);
        }
        require(liquidity > 0, "no liquidity");
        _mint(to, liquidity);
        (r0, r1) = (b0, b1);
    }

    function burn(address to) external returns (uint256 a0, uint256 a1) {
        uint256 liquidity = balanceOf(address(this));
        uint256 supply = totalSupply();
        a0 = (liquidity * r0) / supply;
        a1 = (liquidity * r1) / supply;
        _burn(address(this), liquidity);
        IERC20(token0).transfer(to, a0);
        IERC20(token1).transfer(to, a1);
        r0 = IERC20(token0).balanceOf(address(this));
        r1 = IERC20(token1).balanceOf(address(this));
    }

    function getAmountOut(uint256 amountIn, address tokenIn) public view returns (uint256) {
        (uint256 rIn, uint256 rOut) = tokenIn == token0 ? (r0, r1) : (r1, r0);
        uint256 inAfterFee = amountIn * (10_000 - FEE_BPS) / 10_000;
        return (inAfterFee * rOut) / (rIn + inAfterFee);
    }

    /// @dev Caller must have sent tokenIn first (router does this).
    function swap(uint256 out0, uint256 out1, address to) external {
        if (out0 > 0) IERC20(token0).transfer(to, out0);
        if (out1 > 0) IERC20(token1).transfer(to, out1);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > r0 - out0 ? b0 - (r0 - out0) : 0;
        uint256 in1 = b1 > r1 - out1 ? b1 - (r1 - out1) : 0;
        uint256 adj0 = b0 * 10_000 - in0 * FEE_BPS;
        uint256 adj1 = b1 * 10_000 - in1 * FEE_BPS;
        require(adj0 * adj1 >= r0 * r1 * 1e8, "K");
        (r0, r1) = (b0, b1);
    }
}

contract MockRouter {
    MockPool public immutable pool;
    address public constant defaultFactory = address(0xFAC);
    uint256 public swapCount;

    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    constructor(MockPool p) {
        pool = p;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool,
        uint256 aDesired,
        uint256 bDesired,
        uint256 aMin,
        uint256 bMin,
        address to,
        uint256
    ) external returns (uint256 a, uint256 b, uint256 liquidity) {
        (a, b) = _quote(tokenA, aDesired, bDesired);
        require(a >= aMin && b >= bMin, "router: min");
        IERC20(tokenA).transferFrom(msg.sender, address(pool), a);
        IERC20(tokenB).transferFrom(msg.sender, address(pool), b);
        liquidity = pool.mint(to);
    }

    function _quote(address tokenA, uint256 aDesired, uint256 bDesired) internal view returns (uint256, uint256) {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        (uint256 rA, uint256 rB) = tokenA == pool.token0() ? (r0, r1) : (r1, r0);
        if (rA == 0 && rB == 0) return (aDesired, bDesired);
        uint256 bOptimal = (aDesired * rB) / rA;
        if (bOptimal <= bDesired) return (aDesired, bOptimal);
        return ((bDesired * rA) / rB, bDesired);
    }

    function removeLiquidity(
        address tokenA,
        address,
        bool,
        uint256 liquidity,
        uint256 aMin,
        uint256 bMin,
        address to,
        uint256
    ) external returns (uint256 a, uint256 b) {
        pool.transferFrom(msg.sender, address(pool), liquidity);
        (uint256 a0, uint256 a1) = pool.burn(to);
        (a, b) = tokenA == pool.token0() ? (a0, a1) : (a1, a0);
        require(a >= aMin && b >= bMin, "router: min");
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, Route[] calldata routes, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        swapCount++;
        address tokenIn = routes[0].from;
        uint256 out = pool.getAmountOut(amountIn, tokenIn);
        require(out >= amountOutMin, "router: insufficient output");
        IERC20(tokenIn).transferFrom(msg.sender, address(pool), amountIn);
        (uint256 o0, uint256 o1) = tokenIn == pool.token0() ? (uint256(0), out) : (out, uint256(0));
        pool.swap(o0, o1, to);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

/// @dev Synthetix-style gauge, like tigris Gauge (rewards streamed per second).
contract MockGauge {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    bool public alive = true;
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public rewardPerTokenStored;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public paid;
    mapping(address => uint256) public rewards;

    constructor(IERC20 s, IERC20 r) {
        stakingToken = s;
        rewardToken = r;
    }

    function setAlive(bool a) external {
        alive = a;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        uint256 t = Math.min(block.timestamp, periodFinish);
        uint256 dt = t > lastUpdate ? t - lastUpdate : 0;
        return rewardPerTokenStored + (dt * rewardRate * 1e18) / totalSupply;
    }

    function earned(address a) public view returns (uint256) {
        return (balanceOf[a] * (rewardPerToken() - paid[a])) / 1e18 + rewards[a];
    }

    function _upd(address a) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdate = Math.min(block.timestamp, periodFinish);
        rewards[a] = earned(a);
        paid[a] = rewardPerTokenStored;
    }

    /// @dev Caller must hold `amount` reward tokens and have approved this gauge.
    function notify(uint256 amount, uint256 duration) external {
        _upd(address(0));
        rewardToken.transferFrom(msg.sender, address(this), amount);
        rewardRate = amount / duration;
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + duration;
    }

    function deposit(uint256 amount) external {
        require(alive, "NotAlive");
        _upd(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        _upd(msg.sender);
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.transfer(msg.sender, amount);
    }

    function getReward(address a) external {
        require(msg.sender == a, "NotAuthorized");
        _upd(a);
        uint256 r = rewards[a];
        rewards[a] = 0;
        if (r > 0) rewardToken.transfer(a, r);
    }
}
