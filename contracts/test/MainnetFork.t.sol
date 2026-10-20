// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {ITroveManager, IGauge} from "../src/interfaces/IMezo.sol";
import {MockBTC, MockToken} from "./mocks/Mocks.sol";
import {MezoMainnet} from "../script/Addresses.sol";

interface IGaugeStream {
    function rewardRate() external view returns (uint256);
    function periodFinish() external view returns (uint256);
}

/// @notice Runs the vault against the real MUSD, Mezo Pools pool and MEZO-paying gauge on a
///         Mezo mainnet fork: the path to a mainnet deployment.
///         Set MEZO_MAINNET_RPC to enable, e.g. MEZO_MAINNET_RPC=https://mezo.drpc.org
/// @dev    BTC and MEZO are precompiles, absent from a local EVM, so their addresses get ERC-20
///         mocks (BTC keeps native-balance semantics; the gauge is given MEZO to pay out).
contract MainnetForkTest is Test {
    BtcLpVault internal vault;
    address internal alice = makeAddr("alice");
    address internal fee = makeAddr("fee");

    function setUp() public {
        string memory rpc = vm.envOr("MEZO_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        vm.etch(MezoMainnet.BTC, address(new MockBTC()).code);
        vm.allowCheatcodes(MezoMainnet.BTC);
        vm.etch(MezoMainnet.MEZO, address(new MockToken("Mezo", "MEZO")).code);
        deal(MezoMainnet.MEZO, MezoMainnet.GAUGE, 1e30);

        bytes memory live = vm.rpc(
            "eth_call",
            string.concat('[{"to":"', vm.toString(MezoMainnet.PRICE_FEED), '","data":"0x0fdb11cf"},"latest"]')
        );
        vm.mockCall(MezoMainnet.PRICE_FEED, abi.encodeWithSignature("fetchPrice()"), live);

        vault = new BtcLpVault(MezoMainnet.config(fee));
        vm.deal(alice, 10e18);

        // A live market: if the pool sits outside the oracle band at this block, the vault
        // correctly waits instead of deploying. That is market state, not a failure.
        BtcLpVault.Snapshot memory s = vault.snapshot();
        uint256 diff = s.poolPrice > s.price ? s.poolPrice - s.price : s.price - s.poolPrice;
        if (diff * 10_000 > s.price * vault.maxDeviationBps()) {
            emit log_named_uint("pool off the oracle by bps", diff * 10_000 / s.price);
            vm.skip(true);
        }
    }

    function test_mainnetFork_fullCycleWithRewards() public {
        vm.startPrank(alice);
        vault.deposit{value: 0.2e18}(0);

        ITroveManager tm = ITroveManager(MezoMainnet.TROVE_MANAGER);
        assertEq(tm.getTroveStatus(address(vault)), 1, "trove opened");
        assertApproxEqRel(vault.currentCR(), 3e18, 0.05e18);
        assertGt(IGauge(MezoMainnet.GAUGE).balanceOf(address(vault)), 0, "LP staked in the MEZO gauge");

        skip(1 days);
        IGaugeStream g = IGaugeStream(MezoMainnet.GAUGE);
        if (g.rewardRate() > 0 && g.periodFinish() > block.timestamp - 1 days) {
            uint256 got = vault.claimRewards();
            emit log_named_decimal_uint("MEZO claimed after 1 day", got, 18);
            assertGt(got, 0, "earned MEZO from the live gauge");
            assertGt(MockToken(MezoMainnet.MEZO).balanceOf(fee), 0, "fee taken");
        }

        uint256 half = vault.balanceOf(alice) / 2;
        (uint256 btc1, uint256 musd1) = vault.withdraw(half, 0);
        assertGt(btc1, 0.08e18);
        (uint256 btc2, uint256 musd2) = vault.withdraw(vault.balanceOf(alice), 0);
        vm.stopPrank();

        assertEq(tm.getTroveStatus(address(vault)), 2, "trove closed");
        uint256 price = vault.snapshot().price;
        uint256 value = btc1 + btc2 + (musd1 + musd2) * 1e18 / price;
        emit log_named_decimal_uint("value back (BTC) for 0.2 BTC", value, 18);
        assertGt(value, 0.194e18);
    }
}
