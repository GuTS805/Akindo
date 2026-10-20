// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {
    MockBTC,
    MockToken,
    MockPriceFeed,
    MockTroveSystem,
    MockPool,
    MockRouter,
    MockGauge
} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test {
    uint256 internal constant PRICE = 60_000e18;
    uint256 internal constant SEED_BTC = 10e18;

    MockBTC internal btc;
    MockToken internal musd;
    MockToken internal mezo;
    MockPriceFeed internal feed;
    MockTroveSystem internal troves;
    MockPool internal pool;
    MockRouter internal router;
    MockGauge internal gauge;
    BtcLpVault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public virtual {
        btc = new MockBTC();
        musd = new MockToken("Mezo USD", "MUSD");
        mezo = new MockToken("Mezo", "MEZO");
        feed = new MockPriceFeed(PRICE);
        troves = new MockTroveSystem(musd, feed);
        pool = new MockPool(address(btc), address(musd));
        router = new MockRouter(pool);
        gauge = new MockGauge(pool, mezo);

        btc.approve(address(router), type(uint256).max);
        musd.approve(address(router), type(uint256).max);
        mezo.approve(address(gauge), type(uint256).max);

        // Seed the pool at the oracle price.
        vm.deal(address(this), SEED_BTC);
        musd.mint(address(this), Math.mulDiv(SEED_BTC, PRICE, 1e18));
        router.addLiquidity(
            address(musd), address(btc), false, musd.balanceOf(address(this)), SEED_BTC, 0, 0, address(this), 0
        );
        musd.setMinter(address(troves));

        vault = new BtcLpVault(_config());

        vm.deal(alice, 100e18);
        vm.deal(bob, 100e18);
    }

    function _config() internal view returns (BtcLpVault.Config memory c) {
        c = BtcLpVault.Config({
            btc: address(btc),
            musd: address(musd),
            borrowerOperations: address(troves),
            troveManager: address(troves),
            priceFeed: address(feed),
            hintHelpers: address(troves),
            sortedTroves: address(troves),
            router: address(router),
            pool: address(pool),
            gauge: address(gauge),
            feeRecipient: feeRecipient,
            targetCR: 3e18,
            minCR: 2.5e18,
            maxCR: 3.5e18,
            maxDeviationBps: 200,
            feeBps: 1_000,
            minDeposit: 0.001e18
        });
    }

    // ---------------------------------------------------------------- helpers

    /// @dev try/catch rather than expectRevert: a reverting `new` would end the test early.
    function _expectBadConfig(BtcLpVault.Config memory c) internal {
        try new BtcLpVault(c) returns (BtcLpVault) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), BtcLpVault.BadConfig.selector);
        }
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.deposit{value: amount}(0);
    }

    function _withdrawAll(address user) internal returns (uint256 btcOut, uint256 musdOut) {
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        (btcOut, musdOut) = vault.withdraw(shares, 0);
    }

    function _poolPrice() internal view returns (uint256) {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        (uint256 rBtc, uint256 rMusd) = pool.token0() == address(btc) ? (r0, r1) : (r1, r0);
        return Math.mulDiv(rMusd, 1e18, rBtc);
    }

    /// @dev Trade against the pool until its spot price is about `p` (MUSD per BTC).
    function _setPoolPrice(uint256 p) internal {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        (uint256 rBtc, uint256 rMusd) = pool.token0() == address(btc) ? (r0, r1) : (r1, r0);
        uint256 targetMusd = Math.sqrt(Math.mulDiv(rBtc * rMusd, p, 1e18));
        MockRouter.Route[] memory route = new MockRouter.Route[](1);
        if (targetMusd > rMusd) {
            uint256 amountIn = targetMusd - rMusd;
            _mintMusd(address(this), amountIn);
            route[0] = MockRouter.Route(address(musd), address(btc), false, address(0));
            router.swapExactTokensForTokens(amountIn, 0, route, address(this), 0);
        } else {
            uint256 amountIn = Math.mulDiv(rBtc * rMusd, 1, targetMusd) - rBtc;
            vm.deal(address(this), address(this).balance + amountIn);
            route[0] = MockRouter.Route(address(btc), address(musd), false, address(0));
            router.swapExactTokensForTokens(amountIn, 0, route, address(this), 0);
        }
    }

    /// @dev Move oracle and pool together, like an arbitraged market.
    function _movePrice(uint256 p) internal {
        feed.set(p);
        _setPoolPrice(p);
    }

    function _mintMusd(address to, uint256 amount) internal {
        musd.setMinter(address(this));
        musd.mint(to, amount);
        musd.setMinter(address(troves));
    }

    function _streamRewards(uint256 amount, uint256 duration) internal {
        mezo.mint(address(this), amount);
        gauge.notify(amount, duration);
    }

    function _cr() internal view returns (uint256) {
        return vault.currentCR();
    }

    function _valueOf(uint256 btcAmount, uint256 musdAmount) internal view returns (uint256) {
        return btcAmount + Math.mulDiv(musdAmount, 1e18, feed.price());
    }

    receive() external payable {}
}
