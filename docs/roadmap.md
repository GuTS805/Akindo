# Roadmap and plan beyond the hackathon

mbLP exists to deepen BTC/MUSD liquidity on Mezo. This page is the plan for getting it from a
tested testnet product to a mainnet vault Mezo can list, and an honest look at its economics.

## Where it stands (Wave 2, November 2026)

- Vault v6 live on Mezo testnet, source verified, staked in Mezo's live BTC/MUSD gauge; 142 tests, the
  invariant suite and eight fork tests (testnet and mainnet); every finding in [SECURITY.md](../contracts/SECURITY.md)
- Mainnet deploy script with address checks, a dry run and a required deposit cap; not run

## Where it stood (end of Wave 1)

- Vault, reward gauge and incentive router written, tested (78 tests, an invariant suite, testnet
  and mainnet fork tests, 97% line coverage) and reviewed with Slither
- Vaults live on Mezo testnet with real deposits, claims and withdrawals ([evidence](evidence.md));
  the default (v3) stakes in Mezo's live BTC/MUSD gauge, earns its MEZO emissions and runs the fee
  flywheel live; a keeper runs rebalance, harvest, reward top-ups and router pushes
- Mainnet configuration in place and exercised by a fork test against the real MUSD, pool, gauge
  and gauge incentive contracts
- Six-page app with EVM wallets and Bitcoin wallets through Mezo Passport; a real Unisat wallet
  has run deposit, claim and withdraw through it

## Wave 2 (2–15 Nov 2026): what was planned and what happened

| Plan | Status |
| --- | --- |
| Address the Wave 1 feedback from the Mezo team | **Four of five done**: borrowing cap (refinance), Recovery Mode exits, the debt double-count, verified sources. The fifth, real third-party usage, has started: the first outside deposit is on v6 and the [Community page](https://mblp.surge.sh/community/) lists every one |
| Deployment sizing after a redemption | **Done in v6**: new debt is capped by the collateral ratio it leaves, so a deployment no longer reverts |
| Incentive router in the mainnet deployment | **Ready**: `script/deploy-mainnet.sh` deploys the router as the vault's fee recipient. Not run: mainnet waits for an audit |
| Concentrated BTC/MUSD pool | **Not started.** Moved after the audit: a range-managed strategy is a large change to audited code, and the review pass came first |

Added during the wave: an attack pass that found five more gaps (deployment sandwich, a fall with the pool
left behind, owed deployment work, the deployment revert above, and a value floor for exits), each fixed with a
test that failed first; a live [attack lab](https://mblp.surge.sh/break/); and vaults v4, v5 and v6.

## Path to mainnet and a Mezo Market listing

Mezo's [dApp requirements](https://mezo.org/docs/developers/getting-started/dapp-requirements/)
for featuring in the Mezo Market are MUSD integration, a third-party audit and full mainnet
functionality.

| Requirement | Status | Plan |
| --- | --- | --- |
| MUSD integration | Done | The vault's core is a MUSD trove |
| Mainnet functionality | Configured, fork-tested, deploy script ready | Deploy after the audit with a deposit cap (built in since v2; the mainnet script refuses to run without one); no team seed needed (below) |
| Third-party audit | Not started | Apply for an audit after Wave 2 with the frozen Wave 2 code; Slither triage and test suite ready for auditors |

Launch steps, in order: freeze code, audit, deploy with a small deposit cap, run the keeper, and
redeploy with a higher cap as the position proves itself (the cap is immutable, like every parameter).

**Why not mainnet in Wave 1.** The vault has no owner and no pause, by design. That is the right
property for a finished, audited vault and the wrong one for unaudited code holding real BTC, so it
stays on testnet until the audit. Mezo's rules welcome testnet entries; the mainnet configuration is
exercised on every push by the mainnet fork test instead.

**No team capital needed at launch.** MUSD's 1,800 MUSD minimum debt means the vault's first trove
needs about 0.11 BTC at its 300% target and a BTC price near $73,000, more than a typical first deposit. The vault handles this already: until the
pooled deposits can carry the minimum debt, they wait as idle BTC that every depositor can withdraw
in full, and once they can, anyone's `rebalance()` opens the trove. Deploying costs about $1 of gas
at October's mainnet gas price.

## Economics, honestly

- **Depositors** earn the gauge's MEZO on the LP half of their value. At October's mainnet rates
  that is about 24% a year before 1% MUSD interest, falling as liquidity grows.
- **The protocol** takes 10% of rewards. The whole volatile BTC/MUSD gauge emitted about 42k MEZO a
  day in October (about 15k on 12 Nov), roughly $45k a year at October's price, so fee revenue on this gauge alone is small. The fee
  is better used to pull more emissions to the pool than to be kept.
- **That is what the incentive router is for.** Posting part of the fee as gauge incentives buys
  veBTC votes for BTC/MUSD, raising the emissions the vault earns. Every deposit deepens the pool
  Mezo most needs, and the incentives keep that pool attractive to voters.
- **For Mezo**, each BTC deposited adds MUSD debt (interest revenue for Mezo) and BTC/MUSD depth,
  which makes buying BTC with MUSD cheaper for everyone.

### Revenue model and who pays the keeper

Measured on 12 Nov 2026 (MEZO $0.0041, BTC $72,895, Mezo mainnet gas price 0.0014625 gwei):

| Item | Value |
| --- | --- |
| Fee | 10% of the MEZO the vault earns (`feeBps` 1000), taken at harvest. No deposit or withdrawal fee |
| Where the fee goes | The IncentiveRouter posts 50% as a gauge incentive for veBTC voters (`incentiveBps` 5000) and sends 50% to the treasury |
| Ceiling on this gauge | The whole volatile BTC/MUSD gauge paid ~15,100 MEZO a day, so even owning all of it the fee is ~1,510 MEZO a day (~$6), half of it to the treasury |
| At 0.2 BTC (mainnet fork) | 1,595 MEZO a day earned, a 160 MEZO fee (~$0.65 a day) |
| Keeper cost | Each keeper call was charged 1.5M gas on testnet, about 0.0000022 BTC (~$0.16) at mainnet gas. A harvest and a push once a day is ~$10 a month |
| Who pays | The treasury half of the fee. The keeper is a convenience, not a dependency: deposits, withdrawals and claims harvest on their own, and anyone can call `rebalance()` and `harvest()` |

Fee revenue on the volatile gauge alone does not pay a team; the treasury half covers a daily keeper
from about 0.2 BTC of deposits. The business case is the next step below and the votes the incentives attract, not the fee.

### The next strategy: the concentrated BTC/MUSD pool

Mainnet, read on chain on 12 Nov 2026 (Voter `0x4823…1f03`):

| BTC/MUSD gauge | veBTC votes | MEZO a day | Pool liquidity | MEZO a day per $1k of liquidity |
| --- | --- | --- | --- | --- |
| Concentrated (`0x9CBc…5022`, tick spacing 200) | 240 | ~37,600 | ~$34.6k | ~1,090 |
| Volatile (`0x52e6…cefb`, mbLP's) | 96 | ~15,100 | ~$70.6k | ~214 |

The concentrated gauge pays about five times as much per dollar of liquidity, before counting that
only in-range liquidity earns. A range-managed strategy is a large change to the vault, so it comes
after the audit. On testnet the order is reversed (the concentrated gauge `0xFe31…5997` pays about a
sixteenth of the volatile one), so a testnet demo would not show the gain.

## Risks we track

MEZO's thin on-chain liquidity, impermanent loss on the pool share, oracle staleness and MUSD
recovery mode, the last exit on a thin pool, and the code being unaudited. Each is documented in
the [README](../README.md#known-limits) and, where it can be, covered by a test.
