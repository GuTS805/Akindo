// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BtcLpVault} from "../src/BtcLpVault.sol";

/// @notice Mezo testnet (chain 31611). Sources: mezo-org/musd deployments/matsnet,
///         mezo-org/tigris deployments/testnet; pool and gauge read from PoolFactory and Voter.
library MezoTestnet {
    uint256 internal constant CHAIN_ID = 31611;

    address internal constant BTC = 0x7b7C000000000000000000000000000000000000;
    address internal constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address internal constant BORROWER_OPERATIONS = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address internal constant TROVE_MANAGER = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address internal constant PRICE_FEED = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;
    address internal constant HINT_HELPERS = 0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6;
    address internal constant SORTED_TROVES = 0x722E4D24FD6Ff8b0AC679450F3D91294607268fA;
    address internal constant ROUTER = 0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9;
    address internal constant POOL = 0xd16A5Df82120ED8D626a1a15232bFcE2366d6AA9; // volatile BTC/MUSD
    address internal constant GAUGE = 0xeF07B6852f4F877fB3BBD90b8f358Fb3E07D0Cc3;

    function config(address feeRecipient) internal pure returns (BtcLpVault.Config memory) {
        return BtcLpVault.Config({
            btc: BTC,
            musd: MUSD,
            borrowerOperations: BORROWER_OPERATIONS,
            troveManager: TROVE_MANAGER,
            priceFeed: PRICE_FEED,
            hintHelpers: HINT_HELPERS,
            sortedTroves: SORTED_TROVES,
            router: ROUTER,
            pool: POOL,
            gauge: GAUGE,
            feeRecipient: feeRecipient,
            targetCR: 3e18,
            minCR: 2.5e18,
            maxCR: 3.5e18,
            // The testnet pool sits ~3.9% below the oracle; mainnet would use ~200.
            maxDeviationBps: 600,
            feeBps: 1_000,
            minDeposit: 0.001e18
        });
    }
}
