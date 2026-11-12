# Review request

mbLP is an unaudited BTC-only vault on Mezo. This page is for anyone willing to review it: what to
look at, what we believe holds, and how to check each claim yourself. Our own findings are in
[SECURITY.md](SECURITY.md).

## Scope

| File | Lines | What it does |
| --- | --- | --- |
| [`src/BtcLpVault.sol`](src/BtcLpVault.sol) | 888 | The vault: one shared MUSD trove, BTC/MUSD liquidity staked in Mezo's gauge, ERC-20 shares, MEZO rewards per share |
| [`src/IncentiveRouter.sol`](src/IncentiveRouter.sol) | 70 | Splits the vault's fee between a gauge incentive and a treasury |
| [`src/RewardGauge.sol`](src/RewardGauge.sol) | 119 | A test gauge with Mezo's gauge interface (used only by testnet v1 and v2) |

- Commit: [`2c16c3a`](https://github.com/GuTS805/Akindo/tree/2c16c3a47baf040391514a1256ae9afe5cd8ff63/contracts/src),
  the last change to `src/`. Later commits touch only tests, docs and the app.
- Deployed and source-verified on Mezo testnet as vault v6:
  [`0x1309FdcFB8394dC63b350409F44b311D7B0dE0C0`](https://explorer.test.mezo.org/address/0x1309FdcFB8394dC63b350409F44b311D7B0dE0C0?tab=contract)
  (fee recipient: IncentiveRouter [`0x28bAf157D84aa72Bf7Ac3800c8243F1557cf2605`](https://explorer.test.mezo.org/address/0x28bAf157D84aa72Bf7Ac3800c8243F1557cf2605)).
- Out of scope: Mezo's own contracts (MUSD, Pools, gauges, PriceFeed), the app, the keeper script.

## How it works, in one paragraph

A deposit mints shares from the change in the vault's net asset value (NAV) at Mezo's oracle price.
When the pool is within `maxDeviationBps` of the oracle, the vault keeps its trove at `targetCR`
(300%): about three quarters of its BTC is collateral, the borrowed MUSD is paired with the rest in
the volatile BTC/MUSD pool, and the LP is staked in the gauge. `rebalance()` (anyone) moves the trove
back inside `minCR`–`maxCR` without swapping. An exit takes its share of every position; the MUSD it
owes the trove comes from its LP slice, and a gap is settled inside the vault (the leaver leaves
collateral) or, if that would take the trove under `minCR`, bought on the pool with an oracle-based
minimum. There is no owner, no pause and no upgrade path.

## What we believe holds

Each line names the test that checks it. A counterexample to any of them is a finding.

1. **Shares cannot be inflated or diluted by moving the pool.** LP is valued at the fair price
   `2·√(k·price)`. `Manipulation.t.sol` (512-run fuzz, 1–2,000 BTC, 2–80% skews), `Sandwich.t.sol`.
2. **A deposit pays for its own deployment.** Shares come from the NAV change across the deposit,
   so MUSD's borrowing fee is not spread over existing holders. `DepositV2.t.sol`.
3. **Every holder can exit**, outside Recovery Mode and with a live oracle, once the pool is back at
   the oracle. `Invariant.t.sol` (`afterInvariant`, 1,024 runs × 64 random actions including
   liquidations, redemptions and pool manipulation).
4. **In Recovery Mode an exit pays its NAV share** from idle assets and LP, never more than about a
   quarter of the NAV beyond idle assets at once. `RecoveryMode.t.sol`.
5. **The trove never breaks MUSD's rules** (1,800 minimum net debt, over 150% CR). `invariant_troveRespectsMusdRules`,
   `Guards.t.sol`.
6. **Rewards are backed**: claims never exceed harvested plus unharvested rewards after the fee.
   `invariant_rewardsAreBacked`, `Recovery.t.sol` (transfers).
7. **No pool action at a bad price**: adding liquidity and rebalancing revert outside the band,
   except a delever when the trove is under `minCR`, which `Sandwich.t.sol` shows is never worth more
   than the plain arbitrage. Every swap has an oracle-based minimum output.
8. **Both pool token orders work** (MUSD first on testnet, BTC first on mainnet). `MainnetOrder.t.sol`.

## Where we would look first

- `_snapshot` and `lpFairValue`: everything is priced from it.
- `deposit`: the NAV-difference share formula and the `deployIdle` self-call wrapped in try/catch.
- `_proRataExit` and `_canSettleInside`: settling the MUSD gap inside the vault.
- `_recoveryExit` and `_recoveryLp`: exits while collateral cannot move.
- `_unwind` and `_topUpMusd`: the last exit, the only path that swaps BTC for MUSD.
- `_lever`, `_crRoom`, `_addRoom` and the refinance branch: sizing new debt.
- `rebalance` with `_mustDelever`: the one pool action allowed outside the band.

Accepted risks and their reasoning (stale oracle pauses, the last exit on a thin pool, MEZO
liquidity, a pool held off the oracle by someone paying to keep it there) are in
[SECURITY.md](SECURITY.md#review-findings-november-2026-wave-2).

## Reproduce

```shell
cd contracts
forge install foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-git
forge test                                   # 142 tests, plus fork tests if the RPC variables are set
MEZO_TESTNET_RPC=https://rpc.test.mezo.org forge test --mc '^ForkTest' -vv
MEZO_MAINNET_RPC=https://rpc-http.mezo.boar.network forge test --mc MainnetForkTest -vv
forge coverage --fuzz-seed 1 --no-match-contract Fork --no-match-coverage "(test|script)" --report summary
slither . --filter-paths "lib/|test/|script/"
```

The live vault can also be attacked without a wallet at [mblp.surge.sh/break](https://mblp.surge.sh/break/),
which sends twelve calls from a stranger's address and shows each revert reason.

## Reporting

Open an issue on [GuTS805/Akindo](https://github.com/GuTS805/Akindo/issues). For something you would
rather not post publicly, open an issue that only asks for a private channel. Confirmed findings go
into [SECURITY.md](SECURITY.md) with the test that reproduces them, the fix, and credit if you want it.
