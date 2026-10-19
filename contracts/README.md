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

## Layout

- `src/BtcLpVault.sol`: the vault
- `src/interfaces/IMezo.sol`: minimal interfaces for MUSD (mezo-org/musd) and Mezo Pools (mezo-org/tigris)
- `test/mocks/Mocks.sol`: local mocks of the BTC precompile, trove system, pool, router and gauge
