// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {MockPool, MockRouter, MockGauge} from "./mocks/Mocks.sol";

/// @notice Guards that the other suites do not reach: dust and donation rounding, an emptied
///         vault, a value floor without an oracle, an empty pool, a Recovery Mode exit that would
///         take the debt under MUSD's minimum, and a small vault held at the minimum debt.
contract GuardsTest is BaseTest {
    function test_defaultOrder_musdIsToken0() public view {
        assertEq(pool.token0(), address(musd), "the default suites must run in testnet order");
    }

    // ---------------------------------------------------------------- deposits

    /// The first deposit mints DEAD_SHARES to a dead address; it must be larger than that.
    function test_firstDeposit_mustExceedDeadShares() public {
        BtcLpVault.Config memory c = _config();
        c.minDeposit = 0;
        vault = new BtcLpVault(c);
        uint256 dead = vault.DEAD_SHARES();

        vm.prank(alice);
        vm.expectRevert(BtcLpVault.DepositTooSmall.selector);
        vault.deposit{value: dead}(0);

        assertEq(_deposit(alice, dead + 1), 1);
    }

    /// BTC sent straight to the vault raises the share price. A deposit that would then round
    /// down to no shares reverts instead of handing its BTC to the existing holders.
    function test_donation_cannotMakeADepositMintNothing() public {
        _deposit(alice, 1e18);
        vm.deal(address(vault), address(vault).balance + 1e36);

        vm.prank(bob);
        vm.expectRevert(BtcLpVault.ZeroShares.selector);
        vault.deposit{value: 0.001e18}(0);
    }

    /// Shares outstanding but nothing behind them: deposits are refused rather than priced at zero.
    function test_deposit_intoEmptiedVault_reverts() public {
        _deposit(alice, 0.01e18); // too small for a trove: waits idle
        assertEq(troves.getTroveStatus(address(vault)), 0);
        vm.deal(address(vault), 0);

        vm.prank(bob);
        vm.expectRevert(BtcLpVault.InsolventVault.selector);
        vault.deposit{value: 0.01e18}(0);
    }

    // ---------------------------------------------------------------- exits

    /// Without a trove an exit needs no oracle, but a value floor does: it is priced at the oracle.
    function test_valueFloor_needsTheOracle_plainExitDoesNot() public {
        uint256 shares = _deposit(alice, 0.01e18);
        feed.setStale(true);

        vm.prank(alice);
        vm.expectRevert(BtcLpVault.OracleUnavailable.selector);
        vault.withdrawMinValue(shares, 0, 1);

        vm.prank(alice);
        (uint256 b, uint256 m) = vault.withdraw(shares, 0);
        assertApproxEqAbs(b, 0.01e18, 1e3, "idle BTC back in full");
        assertEq(m, 0);
    }

    /// In Recovery Mode the LP's MUSD repays debt. An exit whose repayment would take the trove
    /// under MUSD's minimum debt reverts instead of failing inside MUSD.
    function test_recoveryExit_belowMinDebt_reverts() public {
        _deposit(alice, 0.14e18); // net debt ~1,950 MUSD, just above the 1,800 minimum
        assertEq(troves.getTroveStatus(address(vault)), 1);
        troves.setRecoveryMode(true);

        uint256 shares = vault.balanceOf(alice) / 5;
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.RecoveryModeExitTooLarge.selector);
        vault.withdraw(shares, 0);

        troves.setRecoveryMode(false);
        vm.prank(alice);
        vault.withdraw(shares, 0);
    }

    // ---------------------------------------------------------------- rebalance

    /// After a fall, a small vault's target debt is under MUSD's minimum. Rebalance repays down
    /// to the minimum, not below it, and the trove ends above minCR.
    function test_smallVault_afterFall_delevers_toMinDebt() public {
        _deposit(alice, 0.14e18);
        uint256 minNet = troves.minNetDebt();
        assertGt(vault.snapshot().netDebt, minNet);

        _movePrice(49_200e18); // -18%: CR under 250%, target debt under 1,800
        assertLt(_cr(), vault.minCR());
        assertTrue(vault.needsRebalance());

        vault.rebalance();
        assertEq(vault.snapshot().netDebt, minNet, "repaid to the minimum debt");
        assertGe(_cr(), vault.minCR());
    }
}

/// @notice A pool so thin that one deployment step (a tenth of its MUSD) is under MUSD's
///         1,800 minimum debt: no trove can open, so BTC waits idle and nothing is forced.
contract ThinPoolTest is BaseTest {
    function setUp() public override {
        super.setUp();
        pool = new MockPool(address(btc), address(musd));
        router = new MockRouter(pool);
        gauge = new MockGauge(pool, mezo);
        btc.approve(address(router), type(uint256).max);
        musd.approve(address(router), type(uint256).max);
        vm.deal(address(this), 0.2e18);
        _mintMusd(address(this), 12_000e18); // 0.2 BTC at 60,000: a 1,200 MUSD step
        router.addLiquidity(address(musd), address(btc), false, 12_000e18, 0.2e18, 0, 0, address(this), 0);
        vault = new BtcLpVault(_config());
    }

    function test_thinPool_noTroveUnderMinDebt_btcWaitsIdle() public {
        uint256 shares = _deposit(alice, 1e18);
        assertEq(troves.getTroveStatus(address(vault)), 0, "a step cannot reach the minimum debt");
        assertEq(address(vault).balance, 1e18, "BTC waits idle");

        vm.expectRevert(BtcLpVault.NothingToRebalance.selector);
        vault.rebalance();

        vm.prank(alice);
        (uint256 b,) = vault.withdraw(shares, 0);
        assertEq(b, shares);
    }
}

/// @notice A vault on a pool nobody has funded yet: no price, so nothing is deployed.
contract EmptyPoolTest is BaseTest {
    function setUp() public override {
        super.setUp();
        pool = new MockPool(address(btc), address(musd));
        router = new MockRouter(pool);
        gauge = new MockGauge(pool, mezo);
        vault = new BtcLpVault(_config());
    }

    function test_emptyPool_depositsWaitIdle_andExitInFull() public {
        uint256 shares = _deposit(alice, 1e18);
        assertEq(troves.getTroveStatus(address(vault)), 0, "no trove without a pool price");
        assertEq(pool.totalSupply(), 0, "no liquidity added at a made-up price");
        assertTrue(vault.needsRebalance());

        vm.expectRevert(abi.encodeWithSelector(BtcLpVault.PoolPriceOffOracle.selector, 0, PRICE));
        vault.rebalance();

        vm.prank(alice);
        (uint256 b,) = vault.withdraw(shares, 0);
        assertEq(b, shares, "shares were minted 1:1 with idle BTC");
    }
}
