// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {MockRouter} from "./mocks/Mocks.sol";

/// @notice Deposit, push the pool off the oracle, withdraw, push it back: in one block, with the
///         attacker's own capital (nothing minted mid-attack). Measures the attacker's profit and
///         what an honest holder is left with.
contract ManipulationTest is BaseTest {
    uint256 internal constant BOB = 10e18;

    function setUp() public override {
        super.setUp();
        _deposit(bob, BOB);
        // Attacker capital: plenty of both sides, valued at the oracle before and after.
        vm.deal(address(this), 10_000e18);
        _mintMusd(address(this), 600_000_000e18);
    }

    function _wealth() internal view returns (uint256) {
        return _valueOf(address(this).balance, musd.balanceOf(address(this)));
    }

    /// @dev Like _setPoolPrice but spends the attacker's own balances.
    function _push(uint256 p) internal {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        (uint256 rBtc, uint256 rMusd) = pool.token0() == address(btc) ? (r0, r1) : (r1, r0);
        uint256 targetMusd = Math.sqrt(Math.mulDiv(rBtc * rMusd, p, 1e18));
        MockRouter.Route[] memory route = new MockRouter.Route[](1);
        if (targetMusd > rMusd) {
            route[0] = MockRouter.Route(address(musd), address(btc), false, address(0));
            router.swapExactTokensForTokens(targetMusd - rMusd, 0, route, address(this), 0);
        } else {
            route[0] = MockRouter.Route(address(btc), address(musd), false, address(0));
            router.swapExactTokensForTokens(Math.mulDiv(rBtc * rMusd, 1, targetMusd) - rBtc, 0, route, address(this), 0);
        }
    }

    /// @return profit attacker's gain in BTC at the oracle (negative = loss), bobLoss in BTC.
    function _attack(uint256 size, uint256 skewedPrice) internal returns (int256 profit, int256 bobLoss) {
        uint256 before = _wealth();
        vault.deposit{value: size}(0);
        _push(skewedPrice);
        vault.withdraw(vault.balanceOf(address(this)), 0);
        _push(PRICE);
        profit = int256(_wealth()) - int256(before);

        (uint256 b, uint256 m) = _withdrawAll(bob);
        bobLoss = int256(BOB) - int256(_valueOf(b, m));
    }

    function _run(string memory label, uint256 size, uint256 skewedPrice) internal returns (int256 profit, int256 bobLoss) {
        (profit, bobLoss) = _attack(size, skewedPrice);
        console2.log(label);
        console2.log("  attacker profit (sats)", profit / 1e10);
        console2.log("  bob loss (sats)       ", bobLoss / 1e10);
    }

    /// @dev Bob's own round trip, with no attacker: the borrowing fee and pool fees he pays himself.
    function test_baseline_bobAlone() public {
        (uint256 b, uint256 m) = _withdrawAll(bob);
        int256 bobLoss = int256(BOB) - int256(_valueOf(b, m));
        console2.log("bob alone, loss (sats)", bobLoss / 1e10);
        assertLt(bobLoss, int256(BOB / 1000), "round trip costs more than 0.1%");
    }

    /// @dev With the pool pushed down (BTC cheap), the exit's MUSD top-up fails its price check,
    ///      so the attack cannot complete; the attacker eats the swap fees of the push.
    function test_skewDown_exitReverts() public {
        vault.deposit{value: 100e18}(0);
        uint256 shares = vault.balanceOf(address(this));
        uint256 snap = vm.snapshotState();
        for (uint256 pctDown = 10; pctDown <= 50; pctDown += 20) {
            vm.revertToState(snap);
            _push(PRICE * (100 - pctDown) / 100);
            vm.expectRevert();
            vault.withdraw(shares, 0);
        }
    }

    function test_control_noSkew() public {
        (int256 profit, int256 bobLoss) = _run("no skew, 100 BTC", 100e18, PRICE);
        assertLe(profit, 0);
        // Bob pays only his own round trip (about 0.025%): someone else's borrowing fee is theirs.
        assertLt(bobLoss, int256(BOB) * 26 / 100_000, "a newcomer's deposit cost bob");
    }

    function test_skewUp20() public {
        (int256 profit,) = _run("pool +20%, 100 BTC", 100e18, PRICE * 120 / 100);
        assertLe(profit, 0, "attacker profits from a +20% skew");
    }

    function test_skewUp50() public {
        (int256 profit,) = _run("pool +50%, 100 BTC", 100e18, PRICE * 150 / 100);
        assertLe(profit, 0, "attacker profits from a +50% skew");
    }

    function test_skewUp50_large() public {
        (int256 profit,) = _run("pool +50%, 1000 BTC", 1000e18, PRICE * 150 / 100);
        assertLe(profit, 0, "attacker profits from a +50% skew");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_skewUp_neverProfits(uint256 size, uint256 skewBps) public {
        size = bound(size, 1e18, 2_000e18);
        skewBps = bound(skewBps, 200, 8_000);
        (int256 profit,) = _attack(size, PRICE * (10_000 + skewBps) / 10_000);
        assertLe(profit, 0, "deposit, skew up, withdraw is profitable");
    }
}
