// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";

contract BtcLpVaultTest is BaseTest {
    // ---------------------------------------------------------------- config

    function test_constructor_rejectsBadConfig() public {
        BtcLpVault.Config memory c = _config();
        c.minCR = 1.2e18;
        _expectBadConfig(c);

        c = _config();
        c.maxCR = c.targetCR;
        _expectBadConfig(c);

        c = _config();
        c.feeBps = 2_001;
        _expectBadConfig(c);

        c = _config();
        c.gauge = address(new BadGauge(address(btc)));
        _expectBadConfig(c);
    }

    // ---------------------------------------------------------------- deposit

    function test_firstDeposit_opensTroveAndStakesLp() public {
        uint256 shares = _deposit(alice, 1e18);

        assertEq(shares, 1e18 - vault.DEAD_SHARES());
        assertEq(troves.getTroveStatus(address(vault)), 1);
        assertApproxEqRel(_cr(), 3e18, 0.02e18);
        assertGt(gauge.balanceOf(address(vault)), 0);
        assertEq(pool.balanceOf(address(vault)), 0, "LP left unstaked");
        assertLt(address(vault).balance, 0.001e18, "BTC left idle");
        assertApproxEqRel(vault.pricePerShare(), 1e18, 0.002e18);
    }

    function test_deposit_belowMinimumReverts() public {
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.DepositTooSmall.selector);
        vault.deposit{value: 0.0001e18}(0);
    }

    function test_deposit_minSharesSlippage() public {
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.Slippage.selector);
        vault.deposit{value: 1e18}(1e18);
    }

    function test_smallFirstDeposit_waitsIdle() public {
        // 0.1 BTC = 6k MUSD of NAV, too small for the 1800 MUSD minimum debt at 300% CR.
        _deposit(alice, 0.1e18);
        assertEq(troves.getTroveStatus(address(vault)), 0);
        assertEq(address(vault).balance, 0.1e18);
        assertFalse(vault.needsRebalance());
    }

    function test_secondDeposit_getsFairShares() public {
        uint256 a = _deposit(alice, 1e18);
        uint256 b = _deposit(bob, 1e18);
        assertApproxEqRel(b, a, 0.002e18);
        assertApproxEqRel(_cr(), 3e18, 0.05e18);
        assertLt(address(vault).balance, 0.001e18);
    }

    function test_deposit_poolOffOracle_btcStaysIdle() public {
        _deposit(alice, 1e18);
        _setPoolPrice(PRICE * 110 / 100);

        uint256 netDebtBefore = vault.snapshot().netDebt;
        uint256 b = _deposit(bob, 1e18);

        assertEq(vault.snapshot().netDebt, netDebtBefore, "no borrowing against a moved pool");
        assertApproxEqAbs(address(vault).balance, 1e18, 0.001e18);
        // Shares are priced from the oracle, so the pushed pool does not dilute or inflate bob.
        assertApproxEqRel(b, vault.balanceOf(alice), 0.01e18);
    }

    // ---------------------------------------------------------------- withdraw

    function test_withdrawAll_closesTroveAndReturnsValue() public {
        _deposit(alice, 1e18);
        uint256 before = alice.balance;
        (uint256 btcOut, uint256 musdOut) = _withdrawAll(alice);

        assertEq(alice.balance - before, btcOut);
        assertEq(musd.balanceOf(alice), musdOut);
        assertEq(troves.getTroveStatus(address(vault)), 2);
        // Round trip costs only the 0.1% borrow fee on a quarter of NAV plus a tiny top-up swap.
        assertGe(_valueOf(btcOut, musdOut), 0.997e18);
    }

    function test_partialWithdraw_keepsOthersWhole() public {
        _deposit(alice, 1e18);
        _deposit(bob, 1e18);
        uint256 ppsBefore = vault.pricePerShare();

        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        (uint256 btcOut, uint256 musdOut) = vault.withdraw(half, 0);

        assertApproxEqRel(_valueOf(btcOut, musdOut), 0.5e18, 0.003e18);
        assertGe(vault.pricePerShare(), ppsBefore * 999 / 1000);
        assertApproxEqRel(_cr(), 3e18, 0.05e18);
    }

    function test_withdraw_minBtcOutSlippage() public {
        _deposit(alice, 1e18);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.Slippage.selector);
        vault.withdraw(shares, 1e18);
    }

    function test_withdraw_belowMinDebt_unwinds() public {
        _deposit(alice, 0.2e18); // 12k NAV -> ~2.9k net debt
        assertEq(troves.getTroveStatus(address(vault)), 1);
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        (uint256 btcOut, uint256 musdOut) = vault.withdraw(half, 0);

        // Half of 2.9k would leave less than 1800 debt, so the whole position unwinds.
        assertEq(troves.getTroveStatus(address(vault)), 2);
        assertEq(gauge.balanceOf(address(vault)), 0);
        assertApproxEqRel(_valueOf(btcOut, musdOut), 0.1e18, 0.005e18);

        (btcOut, musdOut) = _withdrawAll(alice);
        assertApproxEqRel(_valueOf(btcOut, musdOut), 0.1e18, 0.005e18);
    }

    function test_whaleExit_doesNotStrandSmallHolder() public {
        _deposit(alice, 1e18);
        _deposit(bob, 0.05e18);
        uint256 ppsBefore = vault.pricePerShare();

        // Alice leaving would put debt under the minimum; she must still get out.
        (uint256 aBtc, uint256 aMusd) = _withdrawAll(alice);
        assertApproxEqRel(_valueOf(aBtc, aMusd), 1e18, 0.005e18);
        assertEq(troves.getTroveStatus(address(vault)), 2);
        assertGe(vault.pricePerShare(), ppsBefore * 995 / 1000, "bob not diluted");

        (uint256 bBtc, uint256 bMusd) = _withdrawAll(bob);
        assertApproxEqRel(_valueOf(bBtc, bMusd), 0.05e18, 0.005e18);
    }

    function test_staleOracle_blocksExitsWhileTroveOpen() public {
        _deposit(alice, 1e18);
        feed.setStale(true);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.OracleUnavailable.selector);
        vault.withdraw(shares / 2, 0);

        feed.setStale(false);
        _withdrawAll(alice);
    }

    function test_partialExit_settlesGapWithoutSwapping() public {
        _deposit(alice, 1e18);
        _deposit(bob, 1e18);
        // LP now holds less MUSD than the debt it backs, and the pool is pushed as well.
        _movePrice(55_000e18);
        _setPoolPrice(55_000e18 * 95 / 100);
        uint256 ppsBefore = vault.pricePerShare();
        uint256 swaps = router.swapCount();

        (uint256 btcOut, uint256 musdOut) = _withdrawAll(alice);

        assertEq(router.swapCount(), swaps, "partial exit must not swap");
        assertGt(_valueOf(btcOut, musdOut), 0.95e18);
        assertGe(vault.pricePerShare(), ppsBefore, "bob gains the settle premium");
        assertEq(troves.getTroveStatus(address(vault)), 1);
    }

    function test_finalExitSwap_revertsWhenPoolIsPushed() public {
        _deposit(alice, 1e18);
        _movePrice(55_000e18);
        // Attacker dumps BTC so the closing top-up swap would sell BTC cheap.
        _setPoolPrice(55_000e18 * 95 / 100);

        uint256 shares = vault.balanceOf(alice);
        // MockBTC moves balances with vm.deal, which a reverted call does not undo; the snapshot
        // restores state the way the real precompile would.
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        try vault.withdraw(shares, 0) {
            fail();
        } catch (bytes memory reason) {
            assertEq(keccak256(reason), keccak256(abi.encodeWithSignature("Error(string)", "router: insufficient output")));
        }
        vm.revertToState(snap);

        // Once the pool is back near the oracle the same exit goes through.
        _setPoolPrice(55_000e18);
        (uint256 btcOut, uint256 musdOut) = _withdrawAll(alice);
        assertGt(_valueOf(btcOut, musdOut), 0.95e18);
        assertEq(troves.getTroveStatus(address(vault)), 2);
    }

    function test_withdraw_zeroSharesReverts() public {
        vm.expectRevert(BtcLpVault.ZeroShares.selector);
        vault.withdraw(0, 0);
    }

    // ---------------------------------------------------------------- rebalance

    function test_rebalance_afterPriceRise_borrowsMore() public {
        _deposit(alice, 1e18);
        uint256 debtBefore = vault.snapshot().netDebt;
        _movePrice(75_000e18);
        assertGt(_cr(), 3.5e18);
        assertTrue(vault.needsRebalance());

        uint256 swaps = router.swapCount();
        vault.rebalance();

        assertEq(router.swapCount(), swaps, "rebalance must not swap");
        assertGt(vault.snapshot().netDebt, debtBefore);
        assertGe(_cr(), 2.5e18);
        assertLe(_cr(), 3.5e18);
        assertFalse(vault.needsRebalance());
    }

    function test_rebalance_afterPriceDrop_repays() public {
        _deposit(alice, 1e18);
        uint256 debtBefore = vault.snapshot().netDebt;
        _movePrice(50_000e18);
        assertLt(_cr(), 2.5e18);

        uint256 swaps = router.swapCount();
        vault.rebalance();

        assertEq(router.swapCount(), swaps, "rebalance must not swap");
        assertLt(vault.snapshot().netDebt, debtBefore);
        assertGe(_cr(), 2.5e18);
        assertLe(_cr(), 3.5e18);
    }

    function test_rebalance_poolOffOracleReverts() public {
        _deposit(alice, 1e18);
        feed.set(75_000e18); // oracle moves, pool does not
        vm.expectRevert(abi.encodeWithSelector(BtcLpVault.PoolPriceOffOracle.selector, _poolPrice(), 75_000e18));
        vault.rebalance();
    }

    function test_rebalance_nothingToDoReverts() public {
        _deposit(alice, 1e18);
        vm.expectRevert(BtcLpVault.NothingToRebalance.selector);
        vault.rebalance();
    }

    function test_rebalance_deploysIdleBtcLater() public {
        _deposit(alice, 1e18);
        _setPoolPrice(PRICE * 110 / 100);
        _deposit(bob, 1e18); // stays idle
        _setPoolPrice(PRICE);

        assertTrue(vault.needsRebalance());
        vault.rebalance();
        assertLt(address(vault).balance, 0.01e18);
        assertApproxEqRel(_cr(), 3e18, 0.05e18);
    }

    // ---------------------------------------------------------------- oracle

    function test_staleOracle_blocksDepositsAndRebalance() public {
        _deposit(alice, 1e18);
        feed.setStale(true);

        vm.prank(bob);
        vm.expectRevert(BtcLpVault.OracleUnavailable.selector);
        vault.deposit{value: 1e18}(0);

        vm.expectRevert(BtcLpVault.OracleUnavailable.selector);
        vault.rebalance();

        assertFalse(vault.needsRebalance());
    }

    // ---------------------------------------------------------------- rewards

    function test_harvest_paysHoldersAndFee() public {
        _deposit(alice, 1e18);
        _streamRewards(7_000e18, 7 days);
        skip(7 days);

        assertApproxEqRel(vault.claimable(alice), 6_300e18, 0.001e18);
        vm.prank(alice);
        uint256 got = vault.claimRewards();

        assertApproxEqRel(got, 6_300e18, 0.001e18);
        assertEq(mezo.balanceOf(alice), got);
        assertApproxEqRel(mezo.balanceOf(feeRecipient), 700e18, 0.001e18);
        assertEq(vault.claimable(alice), 0);
    }

    function test_rewards_splitByTimeHeld() public {
        _deposit(alice, 1e18);
        _streamRewards(7_000e18, 7 days);
        skip(3.5 days);
        _deposit(bob, 1e18);
        skip(3.5 days);

        vm.prank(alice);
        uint256 a = vault.claimRewards();
        vm.prank(bob);
        uint256 b = vault.claimRewards();

        // alice: all of the first half + half of the second; bob: half of the second.
        assertApproxEqRel(a, 6_300e18 * 3 / 4, 0.01e18);
        assertApproxEqRel(b, 6_300e18 / 4, 0.01e18);
    }

    function test_killedGauge_doesNotBlockDeposits() public {
        _deposit(alice, 1e18);
        gauge.setAlive(false);

        uint256 b = _deposit(bob, 1e18);
        assertApproxEqRel(b, vault.balanceOf(alice), 0.002e18);
        assertGt(pool.balanceOf(address(vault)), 0, "new LP held unstaked");

        _withdrawAll(bob);
        _withdrawAll(alice);
        assertEq(troves.getTroveStatus(address(vault)), 2);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_roundTrip(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 0.2e18, 20e18);
        _deposit(alice, amount);
        (uint256 btcOut, uint256 musdOut) = _withdrawAll(alice);
        assertGe(_valueOf(btcOut, musdOut), amount * 99 / 100);
    }

    function testFuzz_depositsNeverDiluteExistingHolders(uint96 rawA, uint96 rawB) public {
        uint256 a = bound(rawA, 0.2e18, 20e18);
        uint256 b = bound(rawB, 0.001e18, 20e18);
        _deposit(alice, a);
        uint256 pps = vault.pricePerShare();
        _deposit(bob, b);
        assertGe(vault.pricePerShare(), pps * 9_990 / 10_000);
    }
}

contract BadGauge {
    address public stakingToken;
    address public rewardToken = address(1);

    constructor(address s) {
        stakingToken = s;
    }
}
