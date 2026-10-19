# BtcLpVault

Deposit BTC on Mezo, get one share token (`mbLP`). The vault:

1. keeps most of the BTC as collateral in a single MUSD trove,
2. borrows MUSD against it,
3. pairs that MUSD with the rest of the BTC as BTC/MUSD liquidity on Mezo Pools,
4. stakes the LP in the pool's gauge and passes the rewards to holders.

Rebalancing never swaps. Debt is steered to `NAV / (targetCR + 1)` by borrowing or repaying
and moving BTC between the trove and the pool. Pool actions revert when the pool price drifts
more than `maxDeviationBps` from the oracle. There is no owner and no upgrade path, and
`rebalance` and `harvest` can be called by anyone.

## Setup

```shell
forge install foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-git
forge build
```

## Test

```shell
forge test                                            # unit, fuzz and recovery tests on mocks
MEZO_TESTNET_RPC=https://rpc.test.mezo.org forge test --mc ForkTest   # real MUSD + Pools on a testnet fork
```

The fork test swaps in a mock for the BTC precompile and pins `PriceFeed.fetchPrice` to the live
value, since precompiles do not run in a local EVM. Everything else is the deployed testnet code.

## Deploy (Mezo testnet)

```shell
cp .env.example .env   # set PRIVATE_KEY
source .env
forge script script/Deploy.s.sol --rpc-url mezo_testnet --broadcast --skip-simulation
```

`--skip-simulation` is needed for the same reason: the constructor approves the router on the BTC
precompile, which forge cannot simulate locally. Addresses live in `script/Addresses.sol`.

| Contract | Testnet address |
| --- | --- |
| BTC | `0x7b7C000000000000000000000000000000000000` |
| MUSD | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` |
| BorrowerOperations | `0xCdF7028ceAB81fA0C6971208e83fa7872994beE5` |
| TroveManager | `0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0` |
| PriceFeed | `0x86bCF0841622a5dAC14A313a15f96A95421b9366` |
| Router | `0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9` |
| BTC/MUSD volatile pool | `0xd16A5Df82120ED8D626a1a15232bFcE2366d6AA9` |
| Gauge | `0xeF07B6852f4F877fB3BBD90b8f358Fb3E07D0Cc3` |

## Known limits

- While the oracle is stale, deposits and rebalances revert, and withdrawals that need a MUSD
  top-up swap revert too (the swap's minimum output comes from the oracle). Funds are not at
  risk; exits wait for the oracle.
- After a liquidation the vault holds the old LP and no trove. It keeps earning as plain LP
  and reopens a trove once deposits bring in enough BTC.
- The testnet gauge currently streams no rewards, so harvest is a no-op there.

## Layout

- `src/BtcLpVault.sol`: the vault
- `src/interfaces/IMezo.sol`: minimal interfaces for MUSD (mezo-org/musd) and Mezo Pools (mezo-org/tigris)
- `test/mocks/Mocks.sol`: local mocks of the BTC precompile, trove system, pool, router and gauge
