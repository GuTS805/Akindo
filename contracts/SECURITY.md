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
  `maxDeviationBps` from the oracle (testnet v5 and v6 10%, earlier testnet vaults 6%, mainnet 2%), and every swap has an oracle-based
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
| `Recovery.t.sol` (6) | Liquidation fallback and reopening, redemption surplus, transfer reward leaks, donation attacks, debt redistributed from a liquidation counted once |
| `Capacity.t.sol` (3) | MUSD's borrowing cap: a small deposit does not refinance, a 20x deposit refinances and deploys in full over keeper steps, a deposit in Recovery Mode waits idle and deploys after |
| `RecoveryMode.t.sol` (4) | Exits in Recovery Mode pay the NAV share in BTC and repay debt, wait once LP runs out, refuse a skewed pool, and a deposit made then stays withdrawable |
| `RewardGauge.t.sol` (9) | Reward streaming and the vault's harvest → claim path |
| `DepositV2.t.sol` (5) | v2 deposits: a newcomer pays its own deployment cost, the deposit cap, a reverted deployment leaves the deposit idle, `deployIdle` is vault-only |
| `IncentiveRouter.t.sol` (7) | Fee split between gauge incentives and treasury, permissionless push, config guards, refused incentives fall back to the treasury |
| `Sandwich.t.sol` (2) | Pushing the pool to the band edge around a rebalance, a deposit or a withdrawal never profits the attacker (2%, 6% and 10% bands, both directions); after a fall, an off-band delever is never worth more than the plain arbitrage |
| `WithdrawValue.t.sol` (5) | `withdrawMinValue` floors BTC plus MUSD at the oracle price: passes below the payout, reverts above it, holds when a pushed pool shifts the mix, needs the oracle |
| `Guards.t.sol` (9) | First deposit above the dead shares, a deposit that would round to zero shares after a donation, an emptied vault, a value floor without an oracle, a Recovery Mode exit that would take the debt under MUSD's minimum, a small vault held at the minimum debt after a fall, a pool too thin for the minimum debt, an empty pool |
| `MainnetOrder.t.sol` (37) | The unit, borrowing-cap, Recovery Mode and sandwich suites rerun with the mock tokens at the mainnet addresses, so BTC is the pool's token0 (on testnet MUSD sorts first) |
| `CrashExit.t.sol` (1) | Oracle -45% with the pool left behind: `rebalance()` cuts the debt and the trove is back above `minCR` |
| `Manipulation.t.sol` (7) | Deposit, push the pool off the oracle, withdraw, push it back, with the attacker's own capital: never profitable (512-run fuzz over 1–2,000 BTC and 2–80% skews), exits revert when the pool is pushed down |
| `EdgeCases.t.sol` (18) | Config guards, stale oracle, slippage limits, empty and idle vaults, approved transfers, surplus claims, last exit after a 15% fall |
| `Invariant.t.sol` | 1,024 runs × 64 random actions, including pool manipulation, oracle moves, liquidations and redemptions: shares and rewards add up, the trove obeys MUSD's rules, no LP left unstaked, every holder can exit |
| `InvariantRegression.t.sol` (1) | Replays the invariant suite's one CI failure (a test-harness artifact, below) and asserts the deployment step no longer reverts with `BelowMinCR` |
| `Fork.t.sol` (5) | Against the deployed testnet contracts: full cycle, MEZO earned from Mezo's live BTC/MUSD gauge, and fees booked as incentives on its incentive contract |
| `MainnetFork.t.sol` (3) | Full cycle against mainnet MUSD, the BTC/MUSD pool and the MEZO gauge: 0.2 BTC earned 3,309 MEZO in a day in October (1,595 at 12 Nov emissions) and returned 0.19995 BTC. The vault's fee, routed through `IncentiveRouter`, lands on the gauge's real `BribeVotingReward` (184 MEZO from one day) |

142 tests in 21 suites (the invariant suite counts as one), plus eight fork tests: five against the testnet contracts and three against Mezo mainnet.

Coverage of `src/` (`forge coverage --fuzz-seed 1 --no-match-contract Fork`, November 2026): 97% of lines, 95% of
statements, 100% of functions, 81% of branches (74% before the guard and mainnet-order suites). The
invariant suite's random seed moves these by a few points, so the seed is fixed for a comparable number.

## Static analysis (Slither 0.11.6)

```shell
pip install slither-analyzer
cd contracts && slither . --filter-paths "lib/|test/|script/"
```

48 results on `src/` (re-run on v5, November 2026; counts in the table below are from the v2 run, the detector classes are unchanged and nothing new is High), all reviewed. None needed a code change. The additions are in the Wave 2 code: `unused-return` for the ignored `getReserves` members in `_addRoom`, and the same `reentrancy-balance` pattern in `deposit` and `deployIdle`, which stays a false positive for the reason given below.

| Detector | Count | Finding | Assessment |
| --- | --- | --- | --- |
| `reentrancy-balance` (High) | 5 | `withdraw` compares `btcOut`, computed from a snapshot, after calls to the gauge, router and BorrowerOperations | False positive. `withdraw` is `nonReentrant` and the callees are the fixed Mezo contracts. `btcOut` is the caller's pro-rata entitlement by design; if the vault held less, the final `sendValue` would revert. |
| `reentrancy-balance` (High), v2 | (incl. above) | `deposit` reads `navBefore` before `this.deployIdle()` and mints `shares` after it | False positive. Reading NAV before deployment is the v2 design (shares come from the NAV change); `shares` is computed after the call from `navAfter`, not before it. The call goes to the vault itself; `deployIdle` reverts unless the caller is the vault with its lock held, and `deposit` is `nonReentrant`. |
| `reentrancy-no-eth` (Medium) | 1 | `claimRewards` writes `rewardReserve` after `gauge.getReward` | False positive. `nonReentrant`, trusted gauge; the reward is credited by balance difference before any state is used. |
| `incorrect-equality` (Medium) | 10 | `== 0` checks such as `shares == 0`, `got == 0`, `navMusd == 0`, and `balance == 0` in `IncentiveRouter.push` | Intended guards against empty values, not balance equalities an attacker can target. |
| `uninitialized-local` (Medium) | 2 | `addColl` / `withdrawColl` in `_lever` | Intended: exactly one of them is set, the other stays 0. |
| `unused-return` (Medium) | 5 | Ignored tuple members of `getReserves`, `getEntireDebtAndColl`, `getApproxHint` | Intended: only the needed members are used. |
| `timestamp` (Low) | 8 | Router deadlines and reward-period maths | Expected; deadlines are `block.timestamp` because outputs are bounded by the oracle, not by time. |
| `reentrancy-benign` (Low) | 2 | Events emitted after calls in `_harvest` / `claimRewards` | Benign. |
| `reentrancy-events` (Low) | 7 | `Deployed` and `Rebalance` emitted after calls to BorrowerOperations, the router and the gauge | Accepted. The callees are the fixed Mezo contracts and every entry point is `nonReentrant`; the events report what those calls did. |
| `cyclomatic-complexity` (Informational) | 1 | `deposit` has complexity 13 | Accepted: cap check, first-deposit path, best-effort deployment and the NAV-delta mint in one function, each covered by `DepositV2.t.sol`. |

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
| In some states after a redemption, a liquidation or exits settled inside the vault, a deposit's deployment step reverts with `BelowMinCR` | **Fixed in v6.** `_lever` sized new debt from total NAV; when the vault held more LP than its trove supported, that debt took the trove under `minCR` and the final check reverted the deployment, leaving the deposit idle. The debt is now also capped so the trove ends above the midpoint of `minCR` and `targetCR` (`_crRoom`), and spare BTC goes into the collateral. The sequence in `InvariantRegression.t.sol` hit the revert on v5 and no longer does |

App and keeper fixes from the same pass: event history now pages through the testnet RPC's
10,000-block log limit (history on the older vault had gone silently empty), read failures are
shown instead of rendered as zeros, refreshes never show one account's balances under another,
and the keeper fails its run when a transaction reverts.

## Review findings (November 2026, Wave 2)

Wave 1's judge review found the first item; the rest come from a pass over every public path,
with each suspected gap measured in a test before it was fixed or accepted.

| Finding | Status |
| --- | --- |
| `_snapshot`, `_troveCR` and `_netDebt` added `pendingInterest` to MUSD's `interest`, which already includes it: NAV and share price read low after a liquidation was redistributed to the vault's trove | **Fixed.** The mock now models redistribution like MUSD; `test_redistribution_pendingDebtCountedOnce` failed before the fix. |
| MUSD caps a trove's debt at its opening collateral over 110%, so the vault stopped borrowing at about 2.7x its first deposit and later deposits sat idle | **Fixed** by refinancing when a lever would pass the cap (`Capacity.t.sol`, and a 13x deposit in both fork suites). |
| In Recovery Mode every exit that touched the trove reverted, so holders were stuck | **Fixed.** Exits pay the NAV share from idle assets and LP, repay debt with LP MUSD, leave collateral alone (`RecoveryMode.t.sol`, `test_fork_recoveryModeExit`). |
| A third party could push the pool to the edge of the oracle band, call `rebalance()` (or let a deposit deploy), and push it back: liquidity added at the edge loses value when the price returns, and that loss went to the attacker. At a 6% band, with a step half the pool's size, the attacker made about 0.002 BTC per 20 BTC deployed. Mainnet's pool is ~0.8 BTC, so any real deposit there would be that large | **Fixed.** One deployment step adds at most `MAX_ADD_BPS` of the pool's MUSD reserve; larger deposits deploy over several keeper steps. `Sandwich.t.sol` asserts that sandwiching a rebalance, a deposit or a withdrawal loses money at the 2%, 6% and 10% bands, pushing either way. The cap matters: with steps of a fifth of the pool the 6% band held, but at 8% and 10% the attacker still made 0.0004 and 0.0014 BTC per 20 BTC deployed, so the cap is a tenth of the pool, which holds up to the contract's widest allowed band |
| A small deposit could trigger deployment work the vault already owed (such as the rest of a large deposit) and pay its borrowing fee, minting it fewer shares or none (found by the fuzz test once deployment became step-limited) | **Fixed.** A deposit deploys only when it creates the need; owed work is the keeper's, paid by all holders. |
| After a fast fall in BTC the pool trails the oracle, and `rebalance()` reverted on the oracle band, so a trove under its minimum ratio could not cut its debt while the pool lagged (on a thin pool that can take long) | **Fixed.** Outside the band `rebalance()` may still run when the trove is under `minCR` and the step is a delever; adding liquidity still needs the band. `CrashExit.t.sol` reproduces the revert at an oracle -45% and passes after the fix; `test_offBandDelever_neverProfits` pushes the pool further away before the call: the attacker never earns more than the plain arbitrage of the stale pool, and what holders lose is within 5% of what it costs the attacker (griefing at parity, accepted) |
| Could anyone claim the vault's gauge rewards to it outside `_harvest`, leaving them uncredited? | **Not possible.** Mezo's gauges revert `getReward(vault)` from any other caller (`NotAuthorized`, checked on testnet and mainnet). |

Accepted, with their bounds:

- After a large deposit is deployed in steps, the borrowing fee of the later keeper steps is shared
  by all holders (0.1% of the step's new debt, about 0.025% of the value it deploys).
- A refinance moves the trove to MUSD's current interest rate. A large deposit can trigger one; it
  pays the refinancing fee itself, but the rate change is shared.
- `withdraw`'s `minBtcOut` bounds only the BTC of a withdrawal. A sandwich shifts a leaver's payout from MUSD to
  BTC, and the leaver comes out ahead in `Sandwich.t.sol`. v6 adds `withdrawMinValue`, which also
  floors the total value (BTC plus MUSD at the oracle price); the app uses it. The last exit's
  top-up swap is bounded by the oracle band.
- Holding the pool outside the oracle band blocks Recovery Mode exits and deployment while it
  lasts, at the cost of the trades that keep it there.
- The testnet pool drifts 4-8% from the oracle with no arbitrage (6.7% and later 8.1% on 12 Nov 2026; 6.7% left
  the 6% band's v4 and v5 deposits idle). Past 10% v6's deposits would wait idle and a rebalance
  could only cut debt under `minCR` until it came back; outside Recovery Mode exits do not
  check the band. The v5 and v6 vaults use the widest allowed band, 10%, which
  `Sandwich.t.sol` shows is safe with 10% steps; mainnet uses 2%.

## Known limits

See [the root README](../README.md#known-limits): MEZO liquidity, impermanent loss on the pool
share, stale-oracle pauses, MUSD recovery mode, and the last exit on a thin pool.

## Reporting

Please open an issue on [GuTS805/Akindo](https://github.com/GuTS805/Akindo/issues).
