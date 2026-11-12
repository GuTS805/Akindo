// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPool, IRouter} from "../src/interfaces/IMezo.sol";

/// @notice Fork tests check the vault, not the market. A live pool can sit outside the oracle band
///         (the testnet pool drifts several percent with no arbitrage), which would leave every
///         deposit idle. This trades on the fork, with the real router, until the pool is at the
///         oracle price.
abstract contract PoolAligner is Test {
    function _alignPool(address btc, address musd, address pool, address router, address factory, uint256 price)
        internal
    {
        (uint256 r0, uint256 r1,) = IPool(pool).getReserves();
        (uint256 rBtc, uint256 rMusd) = IPool(pool).token0() == btc ? (r0, r1) : (r1, r0);
        uint256 targetMusd = Math.sqrt(Math.mulDiv(rBtc * rMusd, price, 1e18));
        IRouter.Route[] memory route = new IRouter.Route[](1);
        if (targetMusd > rMusd) {
            uint256 amountIn = targetMusd - rMusd;
            deal(musd, address(this), amountIn);
            IERC20(musd).approve(router, amountIn);
            route[0] = IRouter.Route(musd, btc, false, factory);
            IRouter(router).swapExactTokensForTokens(amountIn, 0, route, address(this), block.timestamp);
        } else if (targetMusd < rMusd) {
            uint256 amountIn = Math.mulDiv(rBtc * rMusd, 1, targetMusd) - rBtc;
            vm.deal(address(this), address(this).balance + amountIn);
            IERC20(btc).approve(router, amountIn);
            route[0] = IRouter.Route(btc, musd, false, factory);
            IRouter(router).swapExactTokensForTokens(amountIn, 0, route, address(this), block.timestamp);
        }
    }
}
