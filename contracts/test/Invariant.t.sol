// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {
    MockBTC,
    MockToken,
    MockPriceFeed,
    MockTroveSystem,
    MockPool,
    MockRouter,
    MockGauge
} from "./mocks/Mocks.sol";

/// @dev Random sequences of user, keeper, market and MUSD actions against the vault.
///      Every vault call and market move runs inside a state snapshot: MockBTC moves balances
///      with vm.deal, which a reverted call would not undo, unlike the real BTC precompile.
contract Handler is Test {
    BtcLpVault internal vault;
    MockBTC internal btc;
    MockToken internal musd;
    MockToken internal mezo;
    MockPriceFeed internal feed;
    MockTroveSystem internal troves;
    MockPool internal pool;
    MockRouter internal router;
    MockGauge internal gauge;

    address[] public actors;
    mapping(bytes32 => uint256) public calls;
    mapping(bytes32 => uint256) public reverts;
    mapping(bytes32 => uint256) public unmodelled;

    struct Deps {
        BtcLpVault vault;
        MockBTC btc;
        MockToken musd;
        MockToken mezo;
        MockPriceFeed feed;
        MockTroveSystem troves;
        MockPool pool;
        MockRouter router;
        MockGauge gauge;
    }

    constructor(Deps memory d) {
        vault = d.vault;
        btc = d.btc;
        musd = d.musd;
        mezo = d.mezo;
        feed = d.feed;
        troves = d.troves;
        pool = d.pool;
        router = d.router;
        gauge = d.gauge;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        btc.approve(address(router), type(uint256).max);
        musd.approve(address(router), type(uint256).max);
        mezo.approve(address(gauge), type(uint256).max);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------- users

    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 0.01e18, 3e18);
        vm.deal(a, a.balance + amount);
        _try(a, abi.encodeCall(BtcLpVault.deposit, (0)), amount, "deposit");
    }

    function withdraw(uint256 actorSeed, uint256 pct) external {
        address a = actors[actorSeed % actors.length];
        uint256 shares = vault.balanceOf(a) * bound(pct, 1, 100) / 100;
        if (shares == 0) return;
        _try(a, abi.encodeCall(BtcLpVault.withdraw, (shares, 0)), 0, "withdraw");
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 pct) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = vault.balanceOf(from) * bound(pct, 1, 100) / 100;
        if (amount == 0) return;
        _try(from, abi.encodeCall(vault.transfer, (to, amount)), 0, "transfer");
    }

    function claim(uint256 actorSeed) external {
        _try(actors[actorSeed % actors.length], abi.encodeCall(BtcLpVault.claimRewards, ()), 0, "claim");
    }

    // ---------------------------------------------------------------- keepers

    function rebalance() external {
        _try(address(this), abi.encodeCall(BtcLpVault.rebalance, ()), 0, "rebalance");
    }

    function harvest() external {
        _try(address(this), abi.encodeCall(BtcLpVault.harvest, ()), 0, "harvest");
    }

    // ---------------------------------------------------------------- market

    /// @dev Oracle and pool move together, kept within 45k..80k.
    function movePrice(int256 bps) external {
        bps = bound(bps, -500, 500);
        uint256 p = feed.price() * uint256(10_000 + bps) / 10_000;
        p = bound(p, 45_000e18, 80_000e18);
        uint256 snap = vm.snapshotState();
        feed.set(p);
        _tryPoolPrice(p, snap, "movePrice");
    }

    /// @dev Someone trades the pool away from the oracle (up to 8%).
    function pushPool(int256 bps) external {
        bps = bound(bps, -800, 800);
        _tryPoolPrice(feed.price() * uint256(10_000 + bps) / 10_000, vm.snapshotState(), "pushPool");
    }

    /// @dev Market moves run inside a snapshot too: a swap that reverts after MockBTC paid out
    ///      would otherwise leave the pool holding less BTC than its reserves say.
    function _tryPoolPrice(uint256 p, uint256 snap, bytes32 name) internal {
        try this.setPoolPrice(p) {
            vm.deleteStateSnapshot(snap);
            calls[name]++;
        } catch {
            vm.revertToStateAndDelete(snap);
            reverts[name]++;
        }
    }

    function streamRewards(uint256 amount) external {
        amount = bound(amount, 1e18, 10_000e18);
        mezo.mint(address(this), amount);
        gauge.notify(amount, 7 days);
        calls["streamRewards"]++;
    }

    function warp(uint256 secs) external {
        skip(bound(secs, 1 hours, 3 days));
    }

    // ---------------------------------------------------------------- MUSD events

    function liquidate(uint256 seed) external {
        if (seed % 20 != 0 || troves.getTroveStatus(address(vault)) != 1) return;
        troves.liquidate(address(vault));
        calls["liquidate"]++;
    }

    function redeem(uint256 seed) external {
        if (seed % 20 != 0 || troves.getTroveStatus(address(vault)) != 1) return;
        troves.redeemFully(address(vault));
        calls["redeem"]++;
    }

    // ---------------------------------------------------------------- helpers

    function setPoolPrice(uint256 p) public {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        (uint256 rBtc, uint256 rMusd) = pool.token0() == address(btc) ? (r0, r1) : (r1, r0);
        uint256 targetMusd = Math.sqrt(Math.mulDiv(rBtc * rMusd, p, 1e18));
        MockRouter.Route[] memory route = new MockRouter.Route[](1);
        uint256 amountIn;
        if (targetMusd > rMusd) {
            amountIn = targetMusd - rMusd;
            musd.setMinter(address(this));
            musd.mint(address(this), amountIn);
            musd.setMinter(address(troves));
            route[0] = MockRouter.Route(address(musd), address(btc), false, address(0));
        } else {
            amountIn = Math.mulDiv(rBtc * rMusd, 1, targetMusd) - rBtc;
            vm.deal(address(this), address(this).balance + amountIn);
            route[0] = MockRouter.Route(address(btc), address(musd), false, address(0));
        }
        if (amountIn > 0) router.swapExactTokensForTokens(amountIn, 0, route, address(this), 0);
    }

    /// @dev Another LP adds `btcAmount` of depth at the current pool price.
    function addDepth(uint256 btcAmount) external {
        uint256 musdAmount = Math.mulDiv(btcAmount, _poolPrice(), 1e18);
        musd.setMinter(address(this));
        musd.mint(address(this), musdAmount);
        musd.setMinter(address(troves));
        vm.deal(address(this), address(this).balance + btcAmount);
        router.addLiquidity(address(musd), address(btc), false, musdAmount, btcAmount, 0, 0, address(this), 0);
    }

    function _poolPrice() internal view returns (uint256) {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        (uint256 rBtc, uint256 rMusd) = pool.token0() == address(btc) ? (r0, r1) : (r1, r0);
        return Math.mulDiv(rMusd, 1e18, rBtc);
    }

    function _try(address caller, bytes memory data, uint256 value, bytes32 name) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(caller);
        (bool ok,) = address(vault).call{value: value}(data);
        if (ok && btc.movesLeaked()) {
            // A deposit's deployment step reverted inside the vault after MockBTC moved BTC.
            // On Mezo the revert undoes those moves; here it cannot, so the call is dropped.
            // DepositV2Test covers that path with a revert that comes before any BTC moves.
            vm.revertToStateAndDelete(snap);
            unmodelled[name]++;
        } else if (ok) {
            vm.deleteStateSnapshot(snap);
            calls[name]++;
        } else {
            vm.revertToStateAndDelete(snap);
            reverts[name]++;
        }
    }

    receive() external payable {}
}

contract InvariantTest is BaseTest {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(Handler.Deps(vault, btc, musd, mezo, feed, troves, pool, router, gauge));
        mezo.setMinter(address(handler));
        targetContract(address(handler));
        // setPoolPrice is a helper, not an action
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = Handler.deposit.selector;
        selectors[1] = Handler.withdraw.selector;
        selectors[2] = Handler.transfer.selector;
        selectors[3] = Handler.claim.selector;
        selectors[4] = Handler.rebalance.selector;
        selectors[5] = Handler.harvest.selector;
        selectors[6] = Handler.movePrice.selector;
        selectors[7] = Handler.pushPool.selector;
        selectors[8] = Handler.streamRewards.selector;
        selectors[9] = Handler.warp.selector;
        selectors[10] = Handler.liquidate.selector;
        selectors[11] = Handler.redeem.selector;
        selectors[12] = Handler.deposit.selector; // deposits twice as likely
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_sharesAddUp() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); i++) {
            sum += vault.balanceOf(handler.actors(i));
        }
        uint256 supply = vault.totalSupply();
        assertEq(supply, supply == 0 ? 0 : sum + vault.DEAD_SHARES());
    }

    function invariant_rewardsAreBacked() public view {
        assertLe(vault.rewardReserve(), mezo.balanceOf(address(vault)));
        uint256 owed;
        for (uint256 i; i < handler.actorCount(); i++) {
            owed += vault.claimable(handler.actors(i));
        }
        uint256 unharvested = gauge.earned(address(vault));
        uint256 available = vault.rewardReserve() + unharvested - Math.mulDiv(unharvested, vault.feeBps(), 10_000);
        assertLe(owed, available + 1e9, "claims exceed rewards");
    }

    function invariant_troveRespectsMusdRules() public view {
        if (troves.getTroveStatus(address(vault)) != 1) return;
        (uint256 coll, uint256 debt,,,,) = troves.getEntireDebtAndColl(address(vault));
        assertGe(debt - 200e18, troves.minNetDebt(), "below min debt");
        assertGe(Math.mulDiv(coll, feed.price(), debt), 1.5e18, "CR under 150%");
    }

    function invariant_noLooseLp() public view {
        assertEq(pool.balanceOf(address(vault)), 0);
    }

    /// @dev Whatever happened, with the market back at the oracle everyone can leave.
    ///      Exits settle the LP's MUSD gap inside the vault when the trove can carry it, else
    ///      buy it on the DEX, and the oracle guard refuses that swap if the pool is too thin;
    ///      then the exit must succeed once the pool has more depth. Funds never get stuck.
    function afterInvariant() public {
        handler.setPoolPrice(feed.price());
        for (uint256 i; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            uint256 shares = vault.balanceOf(a);
            if (shares == 0) continue;

            handler.setPoolPrice(feed.price()); // arbitrage between exits
            uint256 snap = vm.snapshotState();
            bool troveOpen = troves.getTroveStatus(address(vault)) == 1;
            vm.prank(a);
            try vault.withdraw(shares, 0) {
                vm.deleteStateSnapshot(snap);
            } catch {
                vm.revertToStateAndDelete(snap);
                assertTrue(troveOpen, "exit failed without a trove");
                handler.addDepth(100e18);
                handler.setPoolPrice(feed.price());
                vm.prank(a);
                vault.withdraw(shares, 0);
            }
        }
        assertEq(vault.totalSupply() == 0 ? 0 : vault.totalSupply() - vault.DEAD_SHARES(), 0);
        assertTrue(troves.getTroveStatus(address(vault)) != 1, "trove left open");
        assertLt(address(vault).balance, 0.0001e18, "BTC left behind");
    }
}
