// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";

/// @notice MUSD's Recovery Mode blocks collateral withdrawals and closing troves. Holders must
///         still be able to leave, at their fair share, without hurting those who stay.
contract RecoveryModeTest is BaseTest {
    address internal carol = makeAddr("carol");

    function test_exit_paysFairShareInBtc_repaysDebt() public {
        _deposit(alice, 4e18);
        _deposit(bob, 1e18);
        (uint256 coll0, uint256 debt0,) = troves.troves(address(vault));
        uint256 cr0 = _cr();
        uint256 ppsBefore = vault.pricePerShare();
        troves.setRecoveryMode(true);

        (uint256 b, uint256 m) = _withdrawAll(bob);
        assertApproxEqRel(_value(b, m), 1e18, 0.005e18, "bob's exit is not his share");
        assertLt(m * 1e18 / feed.price(), 0.001e18, "paid in BTC (MUSD only for the pool's mix)");

        (uint256 coll1, uint256 debt1,) = troves.troves(address(vault));
        assertEq(coll1, coll0, "collateral cannot move in Recovery Mode");
        assertLt(debt1, debt0, "LP MUSD repaid debt");
        assertGt(_cr(), cr0, "trove ratio improved");
        assertGe(vault.pricePerShare(), ppsBefore, "the exit cost alice");

        // Alice still holds about 1x BTC: LP MUSD still matches the debt.
        BtcLpVault.Snapshot memory s = vault.snapshot();
        assertApproxEqRel(s.lpMusd, s.netDebt, 0.02e18, "MUSD gap left for alice");
    }

    function test_exitsWaitOnceLpRunsOut_thenResume() public {
        _deposit(alice, 1e18);
        _deposit(bob, 4e18);
        troves.setRecoveryMode(true);

        // About a quarter of the NAV can leave: alice's fifth can, bob's four fifths cannot.
        (uint256 b, uint256 m) = _withdrawAll(alice);
        assertApproxEqRel(_value(b, m), 1e18, 0.005e18);

        uint256 shares = vault.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(BtcLpVault.RecoveryModeExitTooLarge.selector);
        vault.withdraw(shares, 0);

        troves.setRecoveryMode(false);
        (b, m) = _withdrawAll(bob);
        assertApproxEqRel(_value(b, m), 4e18, 0.01e18, "bob loses after waiting");
    }

    function test_exit_rejectsSkewedPool() public {
        _deposit(alice, 1e18);
        _deposit(bob, 1e18);
        troves.setRecoveryMode(true);
        _setPoolPrice(PRICE * 90 / 100);

        uint256 shares = vault.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert();
        vault.withdraw(shares, 0);
    }

    function test_deposit_staysWithdrawable() public {
        _deposit(alice, 1e18);
        troves.setRecoveryMode(true);
        vm.deal(carol, 1e18);
        _deposit(carol, 0.5e18);

        (uint256 b, uint256 m) = _withdrawAll(carol);
        assertApproxEqRel(_value(b, m), 0.5e18, 0.005e18);
    }

    function _value(uint256 b, uint256 m) internal view returns (uint256) {
        return b + m * 1e18 / feed.price();
    }
}
