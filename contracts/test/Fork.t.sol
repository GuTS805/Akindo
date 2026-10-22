// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {ITroveManager, IGauge} from "../src/interfaces/IMezo.sol";
import {MockBTC, MockToken} from "./mocks/Mocks.sol";
import {IncentiveRouter} from "../src/IncentiveRouter.sol";
import {MezoTestnet} from "../script/Addresses.sol";

interface ITestnetBribe {
    function tokenRewardsPerEpoch(address token, uint256 epochStart) external view returns (uint256);
}

/// @notice Runs the vault against the real MUSD and Mezo Pools contracts on a testnet fork.
///         Set MEZO_TESTNET_RPC to enable, e.g. MEZO_TESTNET_RPC=https://rpc.test.mezo.org
/// @dev    The BTC precompile does not exist in a local EVM, so its address gets a mock
///         with the same behavior (ERC-20 balances are native balances).
contract ForkTest is Test {
    BtcLpVault internal vault;
    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory rpc = vm.envOr("MEZO_TESTNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        vm.etch(MezoTestnet.BTC, address(new MockBTC()).code);
        vm.allowCheatcodes(MezoTestnet.BTC);
        // MEZO is a precompile as well: a mock token, with the gauge funded to pay out.
        vm.etch(MezoTestnet.MEZO, address(new MockToken("Mezo", "MEZO")).code);
        deal(MezoTestnet.MEZO, MezoTestnet.GAUGE, 1e30);

        // The oracle behind PriceFeed is a precompile too: pin fetchPrice to the live value.
        bytes memory live = vm.rpc(
            "eth_call",
            string.concat('[{"to":"', vm.toString(MezoTestnet.PRICE_FEED), '","data":"0x0fdb11cf"},"latest"]')
        );
        vm.mockCall(MezoTestnet.PRICE_FEED, abi.encodeWithSignature("fetchPrice()"), live);

        vault = new BtcLpVault(MezoTestnet.config(makeAddr("fee")));
        vm.deal(alice, 10e18);
    }

    function test_fork_fullCycle() public {
        vm.startPrank(alice);
        vault.deposit{value: 1e18}(0);

        ITroveManager tm = ITroveManager(MezoTestnet.TROVE_MANAGER);
        assertEq(tm.getTroveStatus(address(vault)), 1, "trove opened");
        assertApproxEqRel(vault.currentCR(), 3e18, 0.05e18);
        assertGt(IGauge(MezoTestnet.GAUGE).balanceOf(address(vault)), 0, "LP staked");

        skip(1 days);
        uint256 half = vault.balanceOf(alice) / 2;
        (uint256 btc1, uint256 musd1) = vault.withdraw(half, 0);
        assertGt(btc1, 0.4e18);

        (uint256 btc2, uint256 musd2) = vault.withdraw(vault.balanceOf(alice), 0);
        vm.stopPrank();

        assertEq(tm.getTroveStatus(address(vault)), 2, "trove closed");
        uint256 price = vault.snapshot().price;
        uint256 value = btc1 + btc2 + (musd1 + musd2) * 1e18 / price;
        emit log_named_decimal_uint("value back (BTC)", value, 18);
        assertGt(value, 0.97e18);
    }

    /// The vault earns MEZO from Mezo's live BTC/MUSD gauge on testnet.
    function test_fork_earnsMezoFromLiveGauge() public {
        vm.prank(alice);
        vault.deposit{value: 1e18}(0);
        skip(1 days);
        vault.harvest();
        vm.prank(alice);
        vault.claimRewards();
        uint256 got = MockToken(MezoTestnet.MEZO).balanceOf(alice);
        emit log_named_decimal_uint("MEZO earned in a day on 1 BTC", got, 18);
        assertGt(got, 0, "earned MEZO");
    }

    /// The fee flywheel on testnet: half of the vault's fee is booked as a MEZO incentive on
    /// the live gauge's BribeVotingReward.
    function test_fork_feeBecomesGaugeIncentive() public {
        address treasury = makeAddr("treasury");
        IncentiveRouter feeRouter = new IncentiveRouter(MezoTestnet.MEZO, MezoTestnet.GAUGE_INCENTIVES, treasury, 5_000);
        BtcLpVault v = new BtcLpVault(MezoTestnet.config(address(feeRouter)));
        vm.prank(alice);
        v.deposit{value: 1e18}(0);
        skip(1 days);
        v.harvest();
        uint256 feeTaken = MockToken(MezoTestnet.MEZO).balanceOf(address(feeRouter));
        assertGt(feeTaken, 0, "fee reached the router");

        uint256 epoch = block.timestamp - (block.timestamp % 7 days);
        ITestnetBribe bribe = ITestnetBribe(MezoTestnet.GAUGE_INCENTIVES);
        uint256 before = bribe.tokenRewardsPerEpoch(MezoTestnet.MEZO, epoch);
        (uint256 toIncentives, uint256 toTreasury) = feeRouter.push();
        emit log_named_decimal_uint("MEZO posted as a gauge incentive", toIncentives, 18);
        assertEq(bribe.tokenRewardsPerEpoch(MezoTestnet.MEZO, epoch) - before, toIncentives, "booked this epoch");
        assertEq(MockToken(MezoTestnet.MEZO).balanceOf(treasury), toTreasury);
        assertApproxEqAbs(toIncentives, feeTaken / 2, 1);
    }
}
