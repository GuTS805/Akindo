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
        // The CI sequence stopped reaching the caught revert once deposits stopped deploying
        // work the vault already owed; this generated one (seed 2, 20 steps) reached it again.
        // Since the lever is capped by the collateral ratio (`_crRoom`) it no longer reverts.
        uint256 r = 2;
        for (uint256 i; i < 20; i++) {
            r = uint256(keccak256(abi.encode(r)));
            uint256 op = r % 6;
            uint256 a = (r >> 8) % 100_000;
            uint256 b = (r >> 40) % 1e22;
            if (op <= 1) h.deposit(a, b);
            else if (op == 2) h.withdraw(a, b);
            else if (op == 3) h.movePrice(int256(a % 1000) - 500);
            else if (op == 4) h.pushPool(int256(a % 1000) - 500);
            else h.liquidate(a * 20);
        }

        assertFalse(btc.movesLeaked());
        (uint256 r0, uint256 r1,) = pool.getReserves();
        assertEq(address(pool).balance, pool.token0() == address(btc) ? r0 : r1, "pool BTC != reserves");
        h.setPoolPrice(feed.price()); // reverted with "K" before the fix
        assertEq(h.unmodelled("deposit"), 0, "a deployment step reverted again (BelowMinCR)");
    }
}
