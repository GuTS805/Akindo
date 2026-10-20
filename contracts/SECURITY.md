# Security review

mbLP is unaudited hackathon code. This file records what was checked and how, so a reviewer can
reproduce it.

## Design properties

- **No privileged roles.** No owner, admin, pause or upgrade path. The fee recipient and every
  parameter are immutable; `rebalance()` and `harvest()` are permissionless. `IncentiveRouter`
  likewise has a fixed split and fixed destinations, and anyone can call `push()`.
- **Oracle-priced shares.** Deposits and exits are priced from Mezo's PriceFeed. LP is valued at
  the fair price `2·√(k·price)`, so moving the pool's spot price cannot inflate or dilute shares.
- **Oracle band.** Every pool action reverts when the pool is more than `maxDeviationBps` from the
  oracle (testnet 6%, mainnet 2%); every swap has an oracle-based minimum output.
- **Reentrancy.** Every external entry point is `nonReentrant`. External calls go only to the
  configured MUSD and Mezo Pools contracts, plus the final BTC/MUSD transfer to the caller.
- **First depositor.** 1,000 dead shares are minted to `0xdEaD` on the first deposit.
- **Rewards.** Rewards are harvested before any share transfer, mint or burn, so they cannot be
  moved between holders; the vault never sells them.
- **Exits never stuck behind MUSD rules.** An exit that would break the 1,800 MUSD minimum debt
  unwinds the whole position into idle assets that everyone can withdraw.

## Tests

| Suite | What it shows |
| --- | --- |
| `BtcLpVault.t.sol` (27) | Unit and fuzz tests of pricing, deposits, exits, rebalancing, slippage, donations, rewards |
| `Recovery.t.sol` (5) | Liquidation fallback and reopening, redemption surplus, transfer reward leaks, donation attacks |
| `RewardGauge.t.sol` (9) | Reward streaming and the vault's harvest → claim path |
| `IncentiveRouter.t.sol` (6) | Fee split between gauge incentives and treasury, permissionless push, config guards |
| `EdgeCases.t.sol` (18) | Config guards, stale oracle, slippage limits, empty and idle vaults, approved transfers, surplus claims, last exit after a 15% fall |
| `Invariant.t.sol` | 1,024 runs × 64 random actions, including pool manipulation, oracle moves, liquidations and redemptions: shares and rewards add up, the trove obeys MUSD's rules, no LP left unstaked, every holder can exit |
| `Fork.t.sol` | Full cycle against the deployed testnet MUSD and Mezo Pools |
| `MainnetFork.t.sol` | Full cycle against mainnet MUSD, the BTC/MUSD pool and the MEZO gauge: 0.2 BTC earned 3,309 MEZO in a day and returned 0.19995 BTC. The vault's fee, routed through `IncentiveRouter`, lands on the gauge's real `BribeVotingReward` (184 MEZO from one day) |

Coverage of `src/` (`forge coverage`): 97% of lines, 94% of statements, 100% of functions,
76% of branches.

## Static analysis (Slither 0.11.6)

```shell
pip install slither-analyzer
cd contracts && slither . --filter-paths "lib/|test/|script/"
```

32 results on `src/`, all reviewed. None needed a code change.

| Detector | Count | Finding | Assessment |
| --- | --- | --- | --- |
| `reentrancy-balance` (High) | 4 | `withdraw` compares `btcOut`, computed from a snapshot, after calls to the gauge, router and BorrowerOperations | False positive. `withdraw` is `nonReentrant` and the callees are the fixed Mezo contracts. `btcOut` is the caller's pro-rata entitlement by design; if the vault held less, the final `sendValue` would revert. |
| `reentrancy-no-eth` (Medium) | 1 | `claimRewards` writes `rewardReserve` after `gauge.getReward` | False positive. `nonReentrant`, trusted gauge; the reward is credited by balance difference before any state is used. |
| `incorrect-equality` (Medium) | 10 | `== 0` checks such as `shares == 0`, `got == 0`, `navMusd == 0`, and `balance == 0` in `IncentiveRouter.push` | Intended guards against empty values, not balance equalities an attacker can target. |
| `uninitialized-local` (Medium) | 2 | `addColl` / `withdrawColl` in `_lever` | Intended: exactly one of them is set, the other stays 0. |
| `unused-return` (Medium) | 5 | Ignored tuple members of `getReserves`, `getEntireDebtAndColl`, `getApproxHint` | Intended: only the needed members are used. |
| `timestamp` (Low) | 8 | Router deadlines and reward-period maths | Expected; deadlines are `block.timestamp` because outputs are bounded by the oracle, not by time. |
| `reentrancy-benign` (Low) | 2 | Events emitted after calls in `_harvest` / `claimRewards` | Benign. |

## Known limits

See [the root README](../README.md#known-limits): MEZO liquidity, impermanent loss on the pool
share, stale-oracle pauses, MUSD recovery mode, and the last exit on a thin pool.

## Reporting

Please open an issue on [GuTS805/Akindo](https://github.com/GuTS805/Akindo/issues).
