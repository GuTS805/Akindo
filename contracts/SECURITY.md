# Security review

mbLP is unaudited hackathon code. This file records what was checked and how, so a reviewer can
reproduce it.

## Design properties

- **No privileged roles.** No owner, admin, pause or upgrade path. The fee recipient and every
  parameter are immutable; `rebalance()` and `harvest()` are permissionless. `IncentiveRouter`
  likewise has a fixed split and fixed destinations, and anyone can call `push()`.
- **Oracle-priced shares.** Deposits and exits are priced from Mezo's PriceFeed. LP is valued at
  the fair price `2·√(k·price)`, so moving the pool's spot price cannot inflate or dilute shares.
- **Oracle band.** Adding liquidity and rebalancing revert when the pool is more than
  `maxDeviationBps` from the oracle (testnet 6%, mainnet 2%), and every swap has an oracle-based
  minimum output. Exits deliberately skip the band check so holders can always leave; what that
  allows is measured in `Manipulation.t.sol` (see the review findings below).
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
| `DepositV2.t.sol` (5) | v2 deposits: a newcomer pays its own deployment cost, the deposit cap, a reverted deployment leaves the deposit idle, `deployIdle` is vault-only |
| `IncentiveRouter.t.sol` (7) | Fee split between gauge incentives and treasury, permissionless push, config guards, refused incentives fall back to the treasury |
| `Manipulation.t.sol` (7) | Deposit, push the pool off the oracle, withdraw, push it back, with the attacker's own capital: never profitable (512-run fuzz over 1–2,000 BTC and 2–80% skews), exits revert when the pool is pushed down |
| `EdgeCases.t.sol` (18) | Config guards, stale oracle, slippage limits, empty and idle vaults, approved transfers, surplus claims, last exit after a 15% fall |
| `Invariant.t.sol` | 1,024 runs × 64 random actions, including pool manipulation, oracle moves, liquidations and redemptions: shares and rewards add up, the trove obeys MUSD's rules, no LP left unstaked, every holder can exit |
| `InvariantRegression.t.sol` (1) | Replays the invariant suite's one CI failure: a test-harness artifact (below), kept so it cannot return |
| `Fork.t.sol` | Full cycle against the deployed testnet MUSD and Mezo Pools |
| `MainnetFork.t.sol` | Full cycle against mainnet MUSD, the BTC/MUSD pool and the MEZO gauge: 0.2 BTC earned 3,309 MEZO in a day and returned 0.19995 BTC. The vault's fee, routed through `IncentiveRouter`, lands on the gauge's real `BribeVotingReward` (184 MEZO from one day) |

78 unit and fuzz tests, plus the invariant suite, its regression replay and two fork tests.

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

## Review findings (October 2026)

A second pass with automated security, TypeScript and failure-path reviewers. Each contract
finding was checked against a test before deciding.

| Finding | Verdict |
| --- | --- |
| Exits remove LP at the spot price without a band check, so an attacker could deposit, skew the pool, withdraw and skew it back | **Not profitable.** The pool fee is 0.3% on mainnet (factory `getFee`), the same as the mock. Pushing the pool and back costs more than the skewed exit gains: a 1,000 BTC attack at +50% loses 0.26 BTC, and the fuzz test never finds a profit. With the pool pushed down the exit's MUSD top-up fails its price check and reverts. |
| A deposit's MUSD borrowing fee (0.1% of the new debt) is carried by all holders, not only the depositor | **Fixed in v2.** Real but small (about 0.025% of the deposit, shared pro rata), never an attack. The v2 vault mints shares from the NAV change across the whole deposit, so the depositor pays it: another holder's 100 BTC round trip now moves Bob's 10 BTC by 2 sats instead of 0.0023 BTC (`test_newDeposit_doesNotDiluteHolders`, `test_control_noSkew`). |
| The exit's MUSD top-up swap allows up to `maxDeviationBps` of slippage | Bounded by the shortfall on a last-exit or unwind path; the pool must already be inside the band. Accepted, documented. |
| A best-effort rebalance inside `deposit` can still revert the deposit | **Fixed in v2.** Deployment runs in a self-call (`deployIdle`, callable only by the vault while its lock is held) inside `try`; if it reverts, the deposit still succeeds and the BTC waits idle (`test_deploymentRevert_depositStillSucceeds`). |
| No deposit cap for an unaudited vault | **Added in v2:** an immutable `depositCap` on vault value (2 BTC on testnet). |
| `IncentiveRouter.push` reverted entirely if the incentive contract refused the token | **Fixed.** A refused incentive now sends the whole balance to the treasury (`test_push_refusedIncentives_goToTreasury`). |
| `notifyRewardAmount` on `RewardGauge` is permissionless, so dust can stretch the stream | Accepted: it slows a stream but cannot take or lock rewards. |
| The invariant suite failed intermittently in CI with `K` (October 2026) | **Test harness, not the vault.** In the failing sequence a v2 deposit's deployment step reverted with `BelowMinCR` after MockBTC had moved BTC; the vault caught the revert as designed, but MockBTC moves balances with `vm.deal`, which a revert does not undo, so the mock pool held less BTC than its reserves. On Mezo the revert undoes the BTC moves. MockBTC now counts its moves in storage and in a sentinel balance, and the handler drops any call that leaves them out of step (`InvariantRegression.t.sol`). |
| In some states after a redemption, a liquidation or exits settled inside the vault, a deposit's deployment step reverts with `BelowMinCR` | **Open, safe.** `_lever` sizes new debt from total NAV; when the vault holds more LP than its trove supports, that debt would take the trove under `minCR`, so the final check reverts the deployment and the deposit waits as idle, withdrawable BTC while that state lasts. Funds are never at risk and every holder can still exit (checked by the invariant suite), but less of the vault earns. Planned fix for the next vault: cap the extra debt so the trove stays at the target ratio. |

App and keeper fixes from the same pass: event history now pages through the testnet RPC's
10,000-block log limit (history on the older vault had gone silently empty), read failures are
shown instead of rendered as zeros, refreshes never show one account's balances under another,
and the keeper fails its run when a transaction reverts.

## Known limits

See [the root README](../README.md#known-limits): MEZO liquidity, impermanent loss on the pool
share, stale-oracle pauses, MUSD recovery mode, and the last exit on a thin pool.

## Reporting

Please open an issue on [GuTS805/Akindo](https://github.com/GuTS805/Akindo/issues).
