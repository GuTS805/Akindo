// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";

/// @notice What happens to the vault when MUSD takes its trove away, and other edge paths.
contract RecoveryTest is BaseTest {
    function test_liquidation_vaultFallsBackToPlainLp() public {
        _deposit(alice, 1e18);
        _deposit(bob, 1e18);
        troves.liquidate(address(vault));

        // Only the LP is left (debt MUSD + matching BTC). There is not enough BTC to back a
        // new trove, so the vault must not try, and must not get stuck.
        assertFalse(vault.needsRebalance());
        vm.expectRevert(BtcLpVault.NothingToRebalance.selector);
        vault.rebalance();

        (uint256 btcOut, uint256 musdOut) = _withdrawAll(alice);
        assertGt(btcOut, 0.2e18);
        assertGt(musdOut, 10_000e18);
        _withdrawAll(bob);
    }

    function test_liquidation_newDepositsReopenTrove() public {
        _deposit(alice, 1e18);
        troves.liquidate(address(vault));

        _deposit(bob, 2e18);
        assertEq(troves.getTroveStatus(address(vault)), 1);
        assertGe(_cr(), 2.5e18);
        assertLe(_cr(), 3.5e18);
        assertLt(address(vault).balance, 0.01e18);
    }

    function test_redemption_surplusIsCountedAndTroveReopens() public {
        _deposit(alice, 1e18);
        _deposit(bob, 1e18);
        troves.redeemFully(address(vault));
        assertEq(troves.getTroveStatus(address(vault)), 4);

        // Redemption at the oracle price costs holders nothing, so bob's exit is whole
        // even though nobody called claimSurplusCollateral first.
        (uint256 btcOut, uint256 musdOut) = _withdrawAll(bob);
        assertApproxEqRel(_valueOf(btcOut, musdOut), 1e18, 0.005e18);

        assertTrue(vault.needsRebalance());
        vault.rebalance();
        assertEq(troves.getTroveStatus(address(vault)), 1);
        assertGe(_cr(), 2.5e18);
        assertLe(_cr(), 3.5e18);
    }

    function test_transfer_doesNotLeakEarlierRewards() public {
        _deposit(alice, 1e18);
        _streamRewards(7_000e18, 7 days);
        skip(7 days);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, shares);

        vm.prank(bob);
        uint256 b = vault.claimRewards();
        vm.prank(alice);
        uint256 a = vault.claimRewards();

        assertApproxEqRel(a, 6_300e18, 0.001e18);
        assertEq(b, 0);
    }

    /// @notice A liquidation redistributed to the vault's trove adds debt that MUSD reports
    ///         inside `interest` and again as `pendingInterest`. It must be counted once.
    function test_redistribution_pendingDebtCountedOnce() public {
        _deposit(alice, 1e18);
        BtcLpVault.Snapshot memory s0 = vault.snapshot();

        uint256 coll = 0.05e18;
        uint256 principal = 2_000e18;
        uint256 interest = 500e18;
        vm.deal(address(this), address(this).balance + coll);
        troves.redistribute{value: coll}(address(vault), principal, interest);

        BtcLpVault.Snapshot memory s1 = vault.snapshot();
        assertEq(s1.coll, s0.coll + coll);
        assertEq(s1.debt, s0.debt + principal + interest);
        assertApproxEqAbs(s1.navMusd + (principal + interest), s0.navMusd + coll * PRICE / 1e18, 1);
        assertEq(vault.currentCR(), s1.coll * PRICE / s1.debt);

        // Once a trove operation applies the redistribution, nothing changes in the vault's view.
        _deposit(bob, 1e18);
        (uint256 pc,,) = troves.pending(address(vault));
        assertEq(pc, 0);
        _withdrawAll(bob);
        _withdrawAll(alice);
    }

    function test_donation_cannotStealFromNextDepositor() public {
        _deposit(alice, 0.01e18);
        vm.deal(address(vault), address(vault).balance + 10e18);
        uint256 b = _deposit(bob, 1e18);
        assertGt(b, 0);
        (uint256 btcOut,) = _withdrawAll(bob);
        assertApproxEqRel(btcOut, 1e18, 0.01e18);
    }
}
