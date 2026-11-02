// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";

/// @notice MUSD caps a trove's debt at its collateral value when it was opened or last refinanced,
///         over 110%, and adding collateral does not raise the cap. A vault opened small must still
///         take in deposits many times its size.
contract CapacityTest is BaseTest {
    function test_smallDeposit_noRefinance() public {
        _deposit(alice, 1e18);
        uint256 cap = troves.maxBorrowingCapacity(address(vault));
        _deposit(bob, 0.5e18);
        assertEq(troves.maxBorrowingCapacity(address(vault)), cap, "refinanced without need");
        _assertDeployed();
    }

    function test_bigDeposit_refinancesAndDeploysFully() public {
        _deposit(alice, 1e18);
        uint256 cap = troves.maxBorrowingCapacity(address(vault));
        (uint256 coll0,,) = troves.troves(address(vault));
        // At a 300% target the first trove can carry about 1/0.27 of its own size.
        assertLt(cap * 3e18 / PRICE, 3 * coll0, "cap is already loose");

        _deposit(bob, 20e18);
        assertGt(troves.maxBorrowingCapacity(address(vault)), cap * 10, "cap not reset");
        _assertDeployed();

        (uint256 b,) = _withdrawAll(bob);
        assertApproxEqRel(b, 20e18, 0.01e18);
        _withdrawAll(alice);
    }

    /// In Recovery Mode MUSD refuses the refinance and any debt increase that lowers the ratio, so
    /// the deposit waits idle (still withdrawable) and is deployed once Recovery Mode ends.
    function test_recoveryMode_depositWaitsIdle_thenDeploys() public {
        _deposit(alice, 1e18);
        (uint256 coll0, uint256 debt0,) = troves.troves(address(vault));
        troves.setRecoveryMode(true);

        uint256 shares = _deposit(bob, 20e18);
        assertGt(shares, 0);
        (uint256 coll, uint256 debt,) = troves.troves(address(vault));
        assertEq(coll, coll0, "trove changed");
        assertEq(debt, debt0, "trove changed");
        assertGe(address(vault).balance, 20e18, "deposit not idle");

        troves.setRecoveryMode(false);
        vault.rebalance();
        _assertDeployed();
    }

    function _assertDeployed() internal view {
        assertGe(_cr(), 2.5e18, "CR below band");
        assertLe(_cr(), 3.5e18, "CR above band");
        assertLt(address(vault).balance, 0.01e18, "BTC left idle");
        (, uint256 debt,) = troves.troves(address(vault));
        assertLe(debt, troves.maxBorrowingCapacity(address(vault)), "debt above cap");
    }
}
