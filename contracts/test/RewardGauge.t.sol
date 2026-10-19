// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {RewardGauge} from "../src/RewardGauge.sol";

/// @notice The testnet reward gauge on its own, and the vault harvesting from it end to end.
contract RewardGaugeTest is BaseTest {
    RewardGauge internal rg;
    address internal funder = makeAddr("funder");

    function setUp() public override {
        super.setUp();
        rg = new RewardGauge(address(pool), address(mezo), 7 days);
        BtcLpVault.Config memory c = _config();
        c.gauge = address(rg);
        vault = new BtcLpVault(c);
    }

    function _fund(uint256 amount) internal {
        mezo.mint(funder, amount);
        vm.startPrank(funder);
        mezo.approve(address(rg), amount);
        rg.notifyRewardAmount(amount);
        vm.stopPrank();
    }

    function test_vault_harvestsAndPaysHolders() public {
        _deposit(alice, 1e18);
        assertEq(rg.balanceOf(address(vault)), pool.balanceOf(address(rg)), "vault LP staked in the gauge");
        assertGt(rg.balanceOf(address(vault)), 0);

        _fund(7_000e18);
        skip(7 days);

        assertApproxEqRel(vault.claimable(alice), 6_300e18, 0.001e18);
        vm.prank(alice);
        uint256 got = vault.claimRewards();
        assertApproxEqRel(got, 6_300e18, 0.001e18, "90% to holders");
        assertEq(mezo.balanceOf(alice), got);
        assertApproxEqRel(mezo.balanceOf(feeRecipient), 700e18, 0.001e18, "10% fee");
    }

    function test_vault_rewardsSplitByTimeHeld() public {
        _deposit(alice, 1e18);
        _fund(7_000e18);
        skip(3.5 days);
        _deposit(bob, 1e18);
        skip(3.5 days);

        vm.prank(alice);
        uint256 a = vault.claimRewards();
        vm.prank(bob);
        uint256 b = vault.claimRewards();
        assertApproxEqRel(a, 6_300e18 * 3 / 4, 0.01e18);
        assertApproxEqRel(b, 6_300e18 / 4, 0.01e18);
    }

    function test_vault_exitKeepsEarnedRewards() public {
        _deposit(alice, 1e18);
        _deposit(bob, 1e18);
        _fund(7_000e18);
        skip(7 days);
        _withdrawAll(bob);

        vm.prank(bob);
        uint256 b = vault.claimRewards();
        assertApproxEqRel(b, 3_150e18, 0.01e18, "bob keeps rewards earned before exit");
    }

    function test_notify_isPermissionlessAndStreams() public {
        _fund(7_000e18);
        assertEq(rg.rewardRate(), uint256(7_000e18) / 7 days);
        assertEq(rg.periodFinish(), block.timestamp + 7 days);
        assertEq(mezo.balanceOf(address(rg)), 7_000e18);
    }

    function test_notify_topUpAddsToWhatIsLeft() public {
        _fund(7_000e18);
        skip(3.5 days);
        _fund(3_500e18);
        // 3,500 left + 3,500 new, spread over a fresh 7 days.
        assertApproxEqRel(rg.rewardRate(), uint256(7_000e18) / 7 days, 0.0001e18);
    }

    function test_notify_rejectsZero() public {
        vm.expectRevert(RewardGauge.ZeroAmount.selector);
        rg.notifyRewardAmount(0);
    }

    function test_getReward_onlyForSelf() public {
        vm.expectRevert(RewardGauge.NotAccount.selector);
        rg.getReward(alice);
    }

    function test_stakers_splitByStake() public {
        _fundLp(alice, 1e18);
        _fundLp(bob, 3e18);
        _fund(7_000e18);
        skip(7 days);

        vm.prank(alice);
        rg.getReward(alice);
        vm.prank(bob);
        rg.getReward(bob);
        assertApproxEqRel(mezo.balanceOf(alice), 1_750e18, 0.0001e18);
        assertApproxEqRel(mezo.balanceOf(bob), 5_250e18, 0.0001e18);
        assertLe(mezo.balanceOf(alice) + mezo.balanceOf(bob), 7_000e18, "never pays out more than funded");
    }

    function test_withdraw_returnsStake() public {
        _fundLp(alice, 2e18);
        vm.prank(alice);
        rg.withdraw(2e18);
        assertEq(pool.balanceOf(alice), 2e18);
        assertEq(rg.totalSupply(), 0);
    }

    /// @dev Give `user` pool LP (taken from this contract's seed position) and stake it.
    function _fundLp(address user, uint256 amount) internal {
        pool.transfer(user, amount);
        vm.startPrank(user);
        pool.approve(address(rg), amount);
        rg.deposit(amount);
        vm.stopPrank();
    }
}
