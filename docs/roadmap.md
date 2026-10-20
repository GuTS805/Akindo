# Roadmap and plan beyond the hackathon

mbLP exists to deepen BTC/MUSD liquidity on Mezo. This page is the plan for getting it from a
tested testnet product to a mainnet vault Mezo can list, and an honest look at its economics.

## Where it stands (end of Wave 1)

- Vault, reward gauge and incentive router written, tested (73 tests, an invariant suite, testnet
  and mainnet fork tests, 97% line coverage) and reviewed with Slither
- Two vaults live on Mezo testnet with real deposits, claims and withdrawals
  ([evidence](evidence.md)); a keeper runs rebalance, harvest and reward top-ups
- Mainnet configuration in place and exercised by a fork test against the real MUSD, pool, gauge
  and gauge incentive contracts
- Six-page app with EVM wallets and Bitcoin wallets through Mezo Passport

## Wave 2 (2–15 Nov 2026)

1. **Concentrated BTC/MUSD pool.** The CL gauge receives the larger share of emissions on mainnet
   (69k MEZO a day against 42k on the volatile gauge in October). A range-managed strategy for it
   is the biggest yield lever.
2. **Incentive router in the mainnet deployment.** The mainnet vault takes the `IncentiveRouter`
   as its fee recipient. On testnet the gauge incentive contract does not whitelist MEZO, so the
   flywheel is proven on the mainnet fork until it can run live.
3. **Real-wallet Passport flow.** Run deposit, claim and withdraw from a Bitcoin wallet through
   Mezo Passport, record the transactions, fix what that turns up.
4. **Address the Wave 1 feedback** from the Mezo team.

## Path to mainnet and a Mezo Market listing

Mezo's [dApp requirements](https://mezo.org/docs/developers/getting-started/dapp-requirements/)
for featuring in the Mezo Market are MUSD integration, a third-party audit and full mainnet
functionality.

| Requirement | Status | Plan |
| --- | --- | --- |
| MUSD integration | Done | The vault's core is a MUSD trove |
| Mainnet functionality | Configured, fork-tested | Deploy after the audit, with a deposit cap added to the Wave 2 vault; no team seed needed (below) |
| Third-party audit | Not started | Apply for an audit after Wave 2 with the frozen Wave 2 code; Slither triage and test suite ready for auditors |

Launch steps, in order: freeze code, add a deposit cap, audit, deploy, run the keeper, raise the cap
as the position proves itself.

**Why not mainnet in Wave 1.** The vault has no owner and no pause, by design. That is the right
property for a finished, audited vault and the wrong one for unaudited code holding real BTC, so it
stays on testnet until the audit. Mezo's rules welcome testnet entries; the mainnet configuration is
exercised on every push by the mainnet fork test instead.

**No team capital needed at launch.** MUSD's 1,800 MUSD minimum debt means a trove needs about
0.09 BTC behind it, more than a typical first deposit. The vault handles this already: until the
pooled deposits can carry the minimum debt, they wait as idle BTC that every depositor can withdraw
in full, and once they can, anyone's `rebalance()` opens the trove. Deploying costs about $1 of gas
at October's mainnet gas price.

## Economics, honestly

- **Depositors** earn the gauge's MEZO on the LP half of their value. At October's mainnet rates
  that is about 24% a year before 1% MUSD interest, falling as liquidity grows.
- **The protocol** takes 10% of rewards. The whole volatile BTC/MUSD gauge emits about 42k MEZO a
  day, roughly $45k a year at today's price, so fee revenue on this gauge alone is small. The fee
  is better used to pull more emissions to the pool than to be kept.
- **That is what the incentive router is for.** Posting part of the fee as gauge incentives buys
  veBTC votes for BTC/MUSD, raising the emissions the vault earns. Every deposit deepens the pool
  Mezo most needs, and the incentives keep that pool attractive to voters.
- **For Mezo**, each BTC deposited adds MUSD debt (interest revenue for Mezo) and BTC/MUSD depth,
  which makes buying BTC with MUSD cheaper for everyone.

## Risks we track

MEZO's thin on-chain liquidity, impermanent loss on the pool share, oracle staleness and MUSD
recovery mode, the last exit on a thin pool, and the code being unaudited. Each is documented in
the [README](../README.md#known-limits) and, where it can be, covered by a test.
