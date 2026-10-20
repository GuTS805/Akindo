// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {IncentiveRouter} from "../src/IncentiveRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Mirrors Mezo Earn's BribeVotingReward.notifyRewardAmount: pulls the tokens and books
///      them to the current weekly epoch.
contract MockIncentives {
    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerEpoch;

    function notifyRewardAmount(address token, uint256 amount) external {
        require(amount > 0, "ZeroAmount");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        tokenRewardsPerEpoch[token][block.timestamp - (block.timestamp % 7 days)] += amount;
    }
}

contract IncentiveRouterTest is BaseTest {
    MockIncentives internal incentives;
    IncentiveRouter internal feeRouter;
    address internal treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();
        incentives = new MockIncentives();
        feeRouter = new IncentiveRouter(address(mezo), address(incentives), treasury, 5_000);
        BtcLpVault.Config memory c = _config();
        c.feeRecipient = address(feeRouter);
        vault = new BtcLpVault(c);
    }

    function _epoch() internal view returns (uint256) {
        return block.timestamp - (block.timestamp % 7 days);
    }

    function test_vaultFee_becomesGaugeIncentive() public {
        _deposit(alice, 1e18);
        _streamRewards(7_000e18, 7 days);
        skip(7 days);
        vault.harvest();

        assertApproxEqRel(mezo.balanceOf(address(feeRouter)), 700e18, 0.001e18, "10% fee lands in the router");
        (uint256 toIncentives, uint256 toTreasury) = feeRouter.push();

        assertApproxEqRel(toIncentives, 350e18, 0.001e18);
        assertEq(incentives.tokenRewardsPerEpoch(address(mezo), _epoch()), toIncentives, "booked to this epoch");
        assertEq(mezo.balanceOf(treasury), toTreasury);
        assertEq(mezo.balanceOf(address(feeRouter)), 0);
    }

    function test_push_isPermissionless() public {
        mezo.mint(address(feeRouter), 100e18);
        vm.prank(bob);
        feeRouter.push();
        assertEq(incentives.tokenRewardsPerEpoch(address(mezo), _epoch()), 50e18);
    }

    function test_push_allToIncentives() public {
        IncentiveRouter all = new IncentiveRouter(address(mezo), address(incentives), treasury, 10_000);
        mezo.mint(address(all), 100e18);
        (uint256 toIncentives, uint256 toTreasury) = all.push();
        assertEq(toIncentives, 100e18);
        assertEq(toTreasury, 0);
    }

    function test_push_allToTreasury() public {
        IncentiveRouter none = new IncentiveRouter(address(mezo), address(incentives), treasury, 0);
        mezo.mint(address(none), 100e18);
        none.push();
        assertEq(mezo.balanceOf(treasury), 100e18);
        assertEq(incentives.tokenRewardsPerEpoch(address(mezo), _epoch()), 0);
    }

    function test_push_revertsWhenEmpty() public {
        vm.expectRevert(IncentiveRouter.NothingToPush.selector);
        feeRouter.push();
    }

    function test_config_rejectsBadInputs() public {
        _expectRouterBadConfig(address(0), address(incentives), treasury, 5_000);
        _expectRouterBadConfig(address(mezo), address(0), treasury, 5_000);
        _expectRouterBadConfig(address(mezo), address(incentives), address(0), 5_000);
        _expectRouterBadConfig(address(mezo), address(incentives), treasury, 10_001);
    }

    function _expectRouterBadConfig(address t, address i, address tr, uint256 bps) internal {
        try new IncentiveRouter(t, i, tr, bps) returns (IncentiveRouter) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IncentiveRouter.BadConfig.selector);
        }
    }
}
