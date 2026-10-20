// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {RewardGauge} from "../src/RewardGauge.sol";
import {MockPool, MockGauge, MockToken} from "./mocks/Mocks.sol";

/// @notice Guards and edge paths: bad configs, a stale oracle, slippage limits, empty-vault
///         views, approved transfers and the surplus claim.
contract EdgeCasesTest is BaseTest {
    // ---------------------------------------------------------------- constructor

    function _expectGaugeZero(address staking, uint256 duration) internal {
        try new RewardGauge(staking, address(mezo), duration) returns (RewardGauge) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), RewardGauge.ZeroAmount.selector);
        }
    }

    function test_config_rejectsBadRatios() public {
        BtcLpVault.Config memory c = _config();
        c.targetCR = c.minCR;
        _expectBadConfig(c);

        c = _config();
        c.maxCR = c.targetCR;
        _expectBadConfig(c);

        c = _config();
        c.minCR = 1.4e18;
        c.targetCR = 2e18;
        _expectBadConfig(c);
    }

    function test_config_rejectsFeeAndBand() public {
        BtcLpVault.Config memory c = _config();
        c.feeBps = 2_001;
        _expectBadConfig(c);

        c = _config();
        c.maxDeviationBps = 0;
        _expectBadConfig(c);

        c = _config();
        c.maxDeviationBps = 1_001;
        _expectBadConfig(c);
    }

    function test_config_rejectsWrongPool() public {
        MockToken other = new MockToken("Other", "OTH");
        MockPool wrong = new MockPool(address(btc), address(other));
        BtcLpVault.Config memory c = _config();
        c.pool = address(wrong);
        c.gauge = address(new MockGauge(wrong, mezo));
        _expectBadConfig(c);
    }

    function test_config_rejectsGaugeForAnotherPool() public {
        MockPool otherPool = new MockPool(address(btc), address(musd));
        BtcLpVault.Config memory c = _config();
        c.gauge = address(new MockGauge(otherPool, mezo));
        _expectBadConfig(c);
    }

    // ---------------------------------------------------------------- stale oracle

    function test_staleOracle_blocksDepositsAndPricedViews() public {
        _deposit(alice, 1e18);
        feed.setStale(true);

        vm.prank(bob);
        vm.expectRevert(BtcLpVault.OracleUnavailable.selector);
        vault.deposit{value: 1e18}(0);

        vm.expectRevert(BtcLpVault.OracleUnavailable.selector);
        vault.snapshot();
        vm.expectRevert(BtcLpVault.OracleUnavailable.selector);
        vault.pricePerShare();
        assertFalse(vault.needsRebalance(), "never asks for work it cannot price");
    }

    function test_staleOracle_blocksTroveExits() public {
        _deposit(alice, 1e18);
        feed.setStale(true);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.OracleUnavailable.selector);
        vault.withdraw(shares / 2, 0);

        feed.setStale(false);
        vm.prank(alice);
        vault.withdraw(shares / 2, 0);
    }

    // ---------------------------------------------------------------- slippage and input checks

    function test_deposit_respectsMinShares() public {
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.Slippage.selector);
        vault.deposit{value: 1e18}(2e18);
    }

    function test_deposit_rejectsDust() public {
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.DepositTooSmall.selector);
        vault.deposit{value: 0.0005e18}(0);
    }

    function test_withdraw_respectsMinBtcOut() public {
        _deposit(alice, 1e18);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.Slippage.selector);
        vault.withdraw(shares / 2, 1e18);
    }

    function test_withdraw_rejectsZero() public {
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.ZeroShares.selector);
        vault.withdraw(0, 0);
    }

    function test_rebalance_revertsWithNothingToDo() public {
        // A deposit below what a trove needs stays idle; there is nothing to rebalance.
        _deposit(alice, 0.01e18);
        assertFalse(vault.needsRebalance());
        vm.expectRevert(BtcLpVault.NothingToRebalance.selector);
        vault.rebalance();
    }

    // ---------------------------------------------------------------- views on an empty vault

    function test_views_onEmptyVault() public view {
        assertEq(vault.pricePerShare(), 1e18);
        assertEq(vault.currentCR(), 0);
        assertFalse(vault.needsRebalance());
        assertEq(vault.claimable(alice), 0);
    }

    function test_idleVault_exitsWithoutATrove() public {
        _deposit(alice, 0.01e18);
        assertEq(troves.getTroveStatus(address(vault)), 0, "too small for a trove");
        (uint256 btcOut, uint256 musdOut) = _withdrawAll(alice);
        assertApproxEqAbs(btcOut, 0.01e18 - 1e3, 1, "idle BTC back, minus dead shares");
        assertEq(musdOut, 0);
    }

    // ---------------------------------------------------------------- transfers and surplus

    function test_transferFrom_keepsEarnedRewardsWithSender() public {
        _deposit(alice, 1e18);
        _streamRewards(7_000e18, 7 days);
        skip(7 days);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.approve(bob, shares);
        vm.prank(bob);
        vault.transferFrom(alice, bob, shares);

        assertApproxEqRel(vault.claimable(alice), 6_300e18, 0.001e18, "rewards stay with alice");
        assertEq(vault.claimable(bob), 0, "bob starts from zero");
        assertEq(vault.balanceOf(bob), shares);
    }

    function test_claimSurplusCollateral_pullsRedemptionSurplus() public {
        _deposit(alice, 1e18);
        troves.redeemFully(address(vault));
        uint256 before = address(vault).balance;
        vault.claimSurplusCollateral();
        assertGt(address(vault).balance, before, "surplus BTC is back in the vault");
    }

    // ---------------------------------------------------------------- reward gauge guards

    function test_rewardGauge_guards() public {
        _expectGaugeZero(address(0), 7 days);
        _expectGaugeZero(address(pool), 0);

        RewardGauge rg = new RewardGauge(address(pool), address(mezo), 7 days);
        vm.expectRevert(RewardGauge.ZeroAmount.selector);
        rg.deposit(0);
        vm.expectRevert(RewardGauge.ZeroAmount.selector);
        rg.withdraw(0);

        // Less than one token unit per second rounds the rate to zero: refused, not lost.
        mezo.mint(address(this), 1_000);
        mezo.approve(address(rg), 1_000);
        vm.expectRevert(RewardGauge.ZeroAmount.selector);
        rg.notifyRewardAmount(1_000);
    }

    function test_rewardGauge_views() public {
        RewardGauge rg = new RewardGauge(address(pool), address(mezo), 7 days);
        assertEq(rg.left(), 0);
        assertEq(rg.rewardPerToken(), 0);
        assertEq(rg.lastTimeRewardApplicable(), 0);

        mezo.mint(address(this), 7_000e18);
        mezo.approve(address(rg), 7_000e18);
        rg.notifyRewardAmount(7_000e18);
        skip(1 days);
        assertApproxEqRel(rg.left(), 6_000e18, 0.0001e18);
        assertEq(rg.lastTimeRewardApplicable(), block.timestamp);
        assertEq(rg.rewardPerToken(), 0, "nothing staked, nothing accrues per token");
    }

    // ---------------------------------------------------------------- last exit after a fall

    /// After a fall, a large exit buys its MUSD gap on the DEX and pushes the pool below the
    /// oracle. The last exit then refuses to sell BTC beyond the band: it waits, losing nothing,
    /// and goes through once arbitrage brings the pool back.
    function test_lastExit_afterFall_waitsForArbThenPaysInFull() public {
        _deposit(alice, 1e18);
        _deposit(bob, 4e18);
        _movePrice(PRICE * 85 / 100);

        (uint256 b1, uint256 m1) = _withdrawAll(bob);
        assertApproxEqRel(_value(b1, m1), 4e18, 0.03e18, "bob's exit is close to his share");

        // MockBTC moves balances with vm.deal, which a revert does not undo: try the exit in
        // a snapshot and roll back, as a real chain would.
        uint256 shares = vault.balanceOf(alice);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vm.expectRevert(bytes("router: insufficient output"));
        vault.withdraw(shares, 0);
        vm.revertToState(snap);
        assertEq(vault.balanceOf(alice), shares, "nothing burned");

        _setPoolPrice(feed.price()); // arbitrage
        (uint256 b2, uint256 m2) = _withdrawAll(alice);
        assertEq(troves.getTroveStatus(address(vault)), 2, "trove closed");
        assertApproxEqRel(_value(b2, m2), 1e18, 0.03e18, "last holder is whole too");
    }

    function _value(uint256 b, uint256 m) internal view returns (uint256) {
        return b + m * 1e18 / feed.price();
    }
}
