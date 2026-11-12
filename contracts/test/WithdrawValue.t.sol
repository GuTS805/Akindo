// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";

/// @notice `withdrawMinValue` floors the total value paid (BTC plus MUSD at the oracle price),
///         which `minBtcOut` alone cannot: an exit can be paid partly in MUSD.
contract WithdrawValueTest is BaseTest {
    function test_floorBelowPayout_succeeds() public {
        _deposit(alice, 10e18);
        _deposit(bob, 5e18);
        uint256 shares = vault.balanceOf(bob);
        uint256 fair = shares * vault.pricePerShare() / 1e18;
        vm.prank(bob);
        (uint256 b, uint256 m) = vault.withdrawMinValue(shares, 0, fair * 99 / 100);
        assertGe(_valueOf(b, m), fair * 99 / 100);
    }

    function test_floorAbovePayout_reverts() public {
        _deposit(alice, 10e18);
        _deposit(bob, 5e18);
        uint256 shares = vault.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(BtcLpVault.Slippage.selector);
        vault.withdrawMinValue(shares, 0, 5.1e18); // more than the 5 BTC deposited
    }

    /// A pool pushed down pays a leaver more MUSD and less BTC. minBtcOut = 0 lets that through;
    /// the value floor still holds the payout at its oracle value.
    function test_valueFloor_holdsWhenMixShifts() public {
        _deposit(alice, 10e18);
        _deposit(bob, 5e18);
        uint256 shares = vault.balanceOf(bob);
        uint256 fair = shares * vault.pricePerShare() / 1e18;
        _setPoolPrice(PRICE * 98 / 100);
        vm.prank(bob);
        (uint256 b, uint256 m) = vault.withdrawMinValue(shares, 0, fair * 98 / 100);
        assertGe(_valueOf(b, m), fair * 98 / 100);
    }

    function test_floor_needsOracle() public {
        _deposit(alice, 1e18);
        uint256 shares = vault.balanceOf(alice);
        feed.setStale(true);
        vm.prank(alice);
        vm.expectRevert(BtcLpVault.OracleUnavailable.selector);
        vault.withdrawMinValue(shares, 0, 1);
    }

    function test_plainWithdraw_unchanged() public {
        _deposit(alice, 2e18);
        (uint256 b, uint256 m) = _withdrawAll(alice);
        assertGt(_valueOf(b, m), 1.99e18);
    }
}
