// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {MockRouter} from "./mocks/Mocks.sol";

/// @notice A third party pushes the pool to the edge of the oracle band, lets someone else's
///         transaction (or the keeper step it calls itself) trade against the vault, then pushes
///         the pool back. Measures the attacker's profit and who pays for it.
contract SandwichTest is BaseTest {
    address internal eve = makeAddr("eve");

    function _setUpBand(uint256 bandBps) internal {
        BtcLpVault.Config memory c = _config();
        c.maxDeviationBps = bandBps;
        vault = new BtcLpVault(c);
        vm.deal(eve, 10_000e18);
        _mintMusd(eve, 600_000_000e18);
        vm.startPrank(eve);
        btc.approve(address(router), type(uint256).max);
        musd.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _wealth(address a) internal view returns (uint256) {
        return _valueOf(a.balance, musd.balanceOf(a));
    }

    /// @dev Move the pool to price p with eve's own funds.
    function _push(uint256 p) internal {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        (uint256 rBtc, uint256 rMusd) = pool.token0() == address(btc) ? (r0, r1) : (r1, r0);
        uint256 targetMusd = Math.sqrt(Math.mulDiv(rBtc * rMusd, p, 1e18));
        MockRouter.Route[] memory route = new MockRouter.Route[](1);
        vm.startPrank(eve);
        if (targetMusd > rMusd) {
            route[0] = MockRouter.Route(address(musd), address(btc), false, address(0));
            router.swapExactTokensForTokens(targetMusd - rMusd, 0, route, eve, 0);
        } else if (targetMusd < rMusd) {
            route[0] = MockRouter.Route(address(btc), address(musd), false, address(0));
            router.swapExactTokensForTokens(Math.mulDiv(rBtc * rMusd, 1, targetMusd) - rBtc, 0, route, eve, 0);
        }
        vm.stopPrank();
    }

    function _edge(uint256 bandBps, bool up) internal pure returns (uint256) {
        uint256 inside = bandBps * 98 / 100; // just inside the band
        return up ? PRICE * (10_000 + inside) / 10_000 : PRICE * (10_000 - inside) / 10_000;
    }

    function _log(string memory label, int256 eveProfit, int256 victimLoss) internal pure {
        console2.log(label);
        console2.log("  eve profit (sats)   ", eveProfit / 1e10);
        console2.log("  victim loss (sats)  ", victimLoss / 1e10);
    }

    /// A. Idle BTC waits for the keeper; eve skews the pool and calls rebalance herself.
    function _rebalanceAttack(uint256 bandBps, bool up, bool attack) internal returns (int256 profit, int256 holdersLoss) {
        _setUpBand(bandBps);
        _deposit(alice, 1e18);
        _setPoolPrice(PRICE * 80 / 100); // off the band: bob's deposit stays idle
        _deposit(bob, 20e18);
        _setPoolPrice(PRICE);
        uint256 navBefore = vault.snapshot().navMusd;

        uint256 w0 = _wealth(eve);
        if (attack) _push(_edge(bandBps, up));
        vm.prank(eve);
        vault.rebalance();
        if (attack) _push(PRICE);
        profit = int256(_wealth(eve)) - int256(w0);
        holdersLoss = int256(navBefore) - int256(vault.snapshot().navMusd);
        holdersLoss = holdersLoss * 1e18 / int256(PRICE);
    }

    /// B. Eve sandwiches bob's deposit.
    function _depositAttack(uint256 bandBps, bool up, bool attack) internal returns (int256 profit, int256 bobLoss) {
        _setUpBand(bandBps);
        _deposit(alice, 5e18);
        uint256 w0 = _wealth(eve);
        if (attack) _push(_edge(bandBps, up));
        uint256 shares = _deposit(bob, 10e18);
        if (attack) _push(PRICE);
        profit = int256(_wealth(eve)) - int256(w0);
        uint256 value = Math.mulDiv(shares, vault.pricePerShare(), 1e18);
        bobLoss = int256(10e18) - int256(value);
    }

    /// C. Eve sandwiches bob's withdrawal.
    function _withdrawAttack(uint256 bandBps, bool up) internal returns (int256 profit, int256 bobLoss) {
        _setUpBand(bandBps);
        _deposit(alice, 5e18);
        _deposit(bob, 5e18);
        uint256 fair = Math.mulDiv(vault.balanceOf(bob), vault.pricePerShare(), 1e18);
        uint256 w0 = _wealth(eve);
        _push(_edge(bandBps, up));
        (uint256 b, uint256 m) = _withdrawAll(bob);
        _push(PRICE);
        profit = int256(_wealth(eve)) - int256(w0);
        bobLoss = int256(fair) - int256(_valueOf(b, m));
    }

    /// Every sandwich costs the attacker more than it earns, at the mainnet band (2%), the old
    /// testnet band (6%) and the contract's widest (10%), pushing either way. The log shows who pays what.
    function test_sandwichesNeverProfit() public {
        uint256[3] memory bands = [uint256(200), 600, 1000];
        for (uint256 i; i < 3; i++) {
            for (uint256 j; j < 2; j++) {
                bool up = j == 0;
                string memory dir = up ? " up" : " down";
                uint256 snap = vm.snapshotState();
                (, int256 base) = _rebalanceAttack(bands[i], up, false);
                vm.revertToState(snap);
                console2.log("A/B baseline cost, no attack (sats)", base / 1e10);
                (int256 p, int256 l) = _rebalanceAttack(bands[i], up, true);
                _log(string.concat("A rebalance, band ", vm.toString(bands[i]), dir), p, l);
                assertLe(p, 0, "sandwich profits");
                vm.revertToState(snap);
                (, base) = _depositAttack(bands[i], up, false);
                vm.revertToState(snap);
                console2.log("B baseline cost, no attack (sats)", base / 1e10);
                (p, l) = _depositAttack(bands[i], up, true);
                _log(string.concat("B deposit,   band ", vm.toString(bands[i]), dir), p, l);
                assertLe(p, 0, "sandwich profits");
                vm.revertToState(snap);
                (p, l) = _withdrawAttack(bands[i], up);
                _log(string.concat("C withdraw,  band ", vm.toString(bands[i]), dir), p, l);
                assertLe(p, 0, "sandwich profits");
                vm.revertToState(snap);
            }
        }
    }

    /// D. After a fall the pool trails the oracle and `rebalance()` may cut debt outside the band.
    ///    Mode 0: eve only arbitrages the stale pool back to the oracle. Mode 1: an honest
    ///    rebalance, then the arbitrage. Mode 2/3: eve pushes the pool further away (up/down),
    ///    makes the rebalance happen there, then arbitrages. NAV is read once the pool is back at
    ///    the oracle, so the stale pool's own mispricing is in every mode.
    function _crashRun(uint256 mode) internal returns (int256 profit, int256 navBtc) {
        _setUpBand(200);
        _deposit(alice, 10e18);
        _deployFully();
        feed.set(PRICE * 55 / 100); // oracle falls 45%, the pool does not follow
        uint256 w0 = _wealth(eve);
        if (mode == 2) _push(PRICE * 130 / 100);
        if (mode == 3) _push(PRICE * 40 / 100);
        if (mode >= 1) vault.rebalance();
        _push(feed.price());
        profit = int256(_wealth(eve)) - int256(w0);
        navBtc = int256(vault.snapshot().navMusd * 1e18 / feed.price());
    }

    function test_offBandDelever_neverProfits() public {
        uint256 snap = vm.snapshotState();
        (int256 arbOnly,) = _crashRun(0);
        vm.revertToState(snap);
        (int256 honest, int256 navHonest) = _crashRun(1);
        vm.revertToState(snap);
        console2.log("eve arbitrage only (sats)    ", arbOnly / 1e10);
        console2.log("eve after honest rebalance   ", honest / 1e10);
        for (uint256 mode = 2; mode <= 3; mode++) {
            (int256 p, int256 nav) = _crashRun(mode);
            vm.revertToState(snap);
            console2.log(mode == 2 ? "pushed up   : eve profit" : "pushed down : eve profit", p / 1e10);
            console2.log("  holders NAV vs honest (sats)", (nav - navHonest) / 1e10);
            int256 best = arbOnly > honest ? arbOnly : honest;
            assertLe(p, best + int256(0.001e18), "attack earns more than the plain arbitrage");
            // Griefing costs eve about what it costs holders (within 5%): nobody profits from it.
            assertLe((navHonest - nav) * 100, (best - p) * 105 + int256(0.001e18) * 100, "holders pay more than the attacker");
        }
    }
}
