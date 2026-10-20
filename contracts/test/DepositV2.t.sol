// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {IRouter} from "../src/interfaces/IMezo.sol";

/// @notice Deposit behaviour added in v2: shares from the NAV change, a deposit cap, and an
///         isolated deployment step.
contract DepositV2Test is BaseTest {
    function _valueOfShares(address who) internal view returns (uint256) {
        return Math.mulDiv(vault.balanceOf(who), vault.pricePerShare(), 1e18);
    }

    /// A newcomer's MUSD borrowing fee is theirs: an existing holder's value does not move.
    function test_newDeposit_doesNotDiluteHolders() public {
        _deposit(bob, 10e18);
        uint256 before = _valueOfShares(bob);
        assertGt(vault.snapshot().netDebt, 0, "bob's deposit opened the trove");

        _deposit(alice, 50e18);
        uint256 after_ = _valueOfShares(bob);
        assertGe(after_ + 1e6, before, "bob paid part of alice's borrowing fee");
    }

    /// The newcomer receives slightly less than the BTC sent: exactly the cost of deploying it.
    function test_newDeposit_paysItsOwnDeploymentCost() public {
        _deposit(bob, 10e18);
        uint256 shares = _deposit(alice, 50e18);
        uint256 value = Math.mulDiv(shares, vault.pricePerShare(), 1e18);
        assertLt(value, 50e18, "deployment is not free");
        assertGt(value, 50e18 * 999 / 1000, "deployment costs more than 0.1%");
    }

    function test_depositCap_enforced() public {
        BtcLpVault.Config memory c = _config();
        c.depositCap = 5e18;
        vault = new BtcLpVault(c);

        _deposit(bob, 4e18);
        vm.prank(alice);
        vm.expectPartialRevert(BtcLpVault.DepositCapReached.selector);
        vault.deposit{value: 2e18}(0);

        _deposit(alice, 0.9e18); // still under the cap after deployment costs
        assertGt(vault.balanceOf(alice), 0);
    }

    /// If deployment reverts inside the deposit (here: the DEX refuses liquidity), the deposit
    /// still succeeds, the BTC waits idle and a later rebalance deploys it.
    function test_deploymentRevert_depositStillSucceeds() public {
        vm.mockCallRevert(address(router), abi.encodeWithSelector(IRouter.addLiquidity.selector), "router down");
        uint256 shares = _deposit(bob, 10e18);
        assertGt(shares, 0);
        assertEq(vault.snapshot().netDebt, 0, "nothing deployed");
        assertTrue(vault.needsRebalance());

        vm.clearMockedCalls();
        vault.rebalance();
        assertGt(vault.snapshot().netDebt, 0, "deployed later");
        assertApproxEqRel(_valueOfShares(bob), 10e18, 0.002e18);
    }

    function test_deployIdle_onlySelf() public {
        _deposit(bob, 10e18);
        vm.expectRevert(BtcLpVault.OnlySelf.selector);
        vault.deployIdle();
    }
}
