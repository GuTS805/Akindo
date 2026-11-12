// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";

/// @notice A fast fall in BTC leaves the pool behind the oracle until arbitrageurs catch up (on
///         a thin pool that can take a long time). The vault must still be able to cut its debt
///         then, or it can be liquidated while `rebalance()` refuses to run.
contract CrashExitTest is BaseTest {
    function test_crash_poolLags_rebalanceStillDelevers() public {
        _deposit(alice, 10e18);
        _deployFully();
        uint256 cr0 = _cr();
        feed.set(PRICE * 55 / 100); // oracle -45%, pool stays
        uint256 crHit = _cr();
        assertLt(crHit, vault.minCR(), "crash did not breach minCR");
        assertLt(crHit, cr0);

        assertTrue(vault.needsRebalance());
        vault.rebalance(); // must not revert on the band
        assertGe(_cr(), vault.minCR(), "still under minCR");
    }
}
