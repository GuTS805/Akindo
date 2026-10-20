// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Handler} from "./Invariant.t.sol";

/// @dev The shrunk sequence from a CI invariant failure (seed 0xce36…51f6). A deposit's deployment
///      step reverted inside the vault (BelowMinCR) after MockBTC had moved BTC into and out of
///      the pool; the vault caught the revert, but vm.deal moves are not undone, so the pool
///      held less BTC than its reserves and the next swap failed its K check. On Mezo the
///      revert undoes the BTC moves. The handler now detects leaked moves and drops the call.
contract InvariantRegressionTest is BaseTest {
    Handler internal h;

    function setUp() public override {
        super.setUp();
        h = new Handler(Handler.Deps(vault, btc, musd, mezo, feed, troves, pool, router, gauge));
        mezo.setMinter(address(h));
    }

    function test_caughtDeploymentRevert_doesNotCorruptPool() public {
        h.deposit(4508, 12);
        h.deposit(15, 3423);
        h.redeem(8e22);
        h.deposit(4012, 6e22);
        h.withdraw(1059946039, 661694442);
        h.deposit(2268, 8);
        h.withdraw(9817, 20);
        h.movePrice(-488);
        h.liquidate(259200);
        h.deposit(6, 1e20);
        h.deposit(57005, 11295);
        h.redeem(1601264161297887046092300);
        h.deposit(12892, 1.1e18);

        assertFalse(btc.movesLeaked());
        (uint256 r0, uint256 r1,) = pool.getReserves();
        assertEq(address(pool).balance, pool.token0() == address(btc) ? r0 : r1, "pool BTC != reserves");
        h.setPoolPrice(feed.price()); // reverted with "K" before the fix
        assertGt(h.unmodelled("deposit"), 0, "sequence no longer hits the caught revert");
    }
}
