// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Minimal interfaces for the Mezo contracts the vault calls.
// Signatures match mezo-org/musd and mezo-org/tigris.

interface IBorrowerOperations {
    function openTrove(uint256 debtAmount, address upperHint, address lowerHint) external payable;

    function adjustTrove(
        uint256 collWithdrawal,
        uint256 debtChange,
        bool isDebtIncrease,
        address upperHint,
        address lowerHint
    ) external payable;

    function closeTrove() external;

    /// @notice Claims collateral left over after a trove was fully redeemed.
    function claimCollateral() external;

    function minNetDebt() external view returns (uint256);
}

interface ITroveManager {
    function getEntireDebtAndColl(address borrower)
        external
        view
        returns (
            uint256 coll,
            uint256 principal,
            uint256 interest,
            uint256 pendingCollateral,
            uint256 pendingPrincipal,
            uint256 pendingInterest
        );

    // 0 nonExistent, 1 active, 2 closedByOwner, 3 closedByLiquidation, 4 closedByRedemption
    function getTroveStatus(address borrower) external view returns (uint8);
}

interface IPriceFeed {
    /// @notice BTC price in MUSD, 1e18 precision. Reverts when the oracle is stale.
    function fetchPrice() external view returns (uint256);
}

interface IHintHelpers {
    function getApproxHint(uint256 cr, uint256 numTrials, uint256 inputRandomSeed)
        external
        view
        returns (address hintAddress, uint256 diff, uint256 latestRandomSeed);

    function computeNominalCR(uint256 coll, uint256 debt) external pure returns (uint256);
}

interface ISortedTroves {
    function findInsertPosition(uint256 nicr, address prevId, address nextId)
        external
        view
        returns (address, address);
}

interface IPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function defaultFactory() external view returns (address);
}

interface IGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address account) external;
    function earned(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function rewardToken() external view returns (address);
    function stakingToken() external view returns (address);
}
