# mbLP: BTC-only LP vault on Mezo

[![CI](https://github.com/GuTS805/Akindo/actions/workflows/ci.yml/badge.svg)](https://github.com/GuTS805/Akindo/actions/workflows/ci.yml)

Deposit BTC. The vault turns it into staked BTC/MUSD liquidity on Mezo with one transaction:
about 75% becomes collateral in a MUSD trove, the vault borrows MUSD against it, pairs that MUSD
with the other 25% of the BTC in the BTC/MUSD pool and stakes the LP in the pool's gauge.
You hold one token, `mbLP`, and your exposure stays about 1x BTC.

- **App:** https://mblp.vercel.app (mirror: https://guts805.github.io/Akindo/)
- **Vault, MEZO rewards (Mezo testnet):** [`0xc41192A186C0ee2F593D611b0D0C00501B5Eea03`](https://explorer.test.mezo.org/address/0xc41192A186C0ee2F593D611b0D0C00501B5Eea03) ([verified source](https://explorer.test.mezo.org/address/0xc41192A186C0ee2F593D611b0D0C00501B5Eea03?tab=contract)), staked in a [`RewardGauge`](https://explorer.test.mezo.org/address/0x204ef88B33e5d35De7b52F8c1FFa58cf89d4f45b) streaming testnet MEZO
- **Vault, official gauge:** [`0x187958091532733eF2f8703F8029Cd72aA85B2d4`](https://explorer.test.mezo.org/address/0x187958091532733eF2f8703F8029Cd72aA85B2d4), same contract staked in Mezo's testnet gauge
- **Contracts, tests and deployment notes:** [`contracts/`](contracts/)

## Why

Mezo has 800+ BTC locked in veBTC but only about 1.2 BTC of BTC/MUSD liquidity across all its
pools (mainnet, October 2026). Buying BTC with MUSD costs 1–2% against the oracle at $1k–$10k
sizes. The gauges already pay for that liquidity: the volatile BTC/MUSD gauge streams about
42k MEZO a day. But providing it takes a trove, a borrow, a pool deposit and a stake, and then
watching the collateral ratio.

mbLP does all of that from a plain BTC deposit. Every deposit adds MUSD debt and BTC/MUSD depth
on Mezo, and nobody has to manage a position.

## Try it (testnet)

1. Get testnet BTC from the [Mezo faucet](https://faucet.test.mezo.org).
2. Open the [app](https://mblp.vercel.app) and connect an EVM wallet; it adds Mezo Testnet for you.
3. **Deposit** any amount from 0.001 BTC. It goes into the trove and pool in the same transaction.
4. **Withdraw** 25–100% of your shares. The app simulates exactly what you get back before you sign.
5. **Rebalance** and **Harvest** are open to anyone; the buttons light up when there is work to do.

## How it works

| Step | What the vault does |
| --- | --- |
| Deposit | Mints shares priced from the Mezo oracle (pool manipulation cannot dilute holders), then deploys the BTC if the pool is within the oracle band |
| Borrow | One MUSD trove at a 300% target collateral ratio (band 250–350%) |
| Provide | MUSD plus matching BTC into the volatile BTC/MUSD pool on Mezo Pools, LP staked in the gauge |
| Rebalance | Holds debt at `NAV / (targetCR + 1)` by borrowing, repaying and moving BTC between trove and pool. **Never swaps.** |
| Harvest | Pulls gauge rewards and credits them per share; claims are exact across share transfers |
| Exit | Pro-rata slice of every position. If the LP returned less MUSD than the debt slice, the gap stays in the trove with collateral worth gap + 0.5% at the oracle price, so exits do not move the pool. An exit that would break MUSD's 1,800 minimum debt unwinds the position instead of blocking anyone |

Mezo integration: MUSD (BorrowerOperations, TroveManager, hint helpers, PriceFeed), Mezo Pools
(Router, volatile BTC/MUSD pool, Gauge), the BTC precompile as native collateral, and redemption
and liquidation recovery.

No owner, no admin key, no upgrades. The fee (10% of rewards) and all parameters are fixed at
deployment.

## Security and testing

- 27 unit and fuzz tests, 5 recovery tests (liquidation, redemption, share transfers, donation)
- Invariant suite: random sequences of deposits, withdrawals, transfers, reward streams, oracle
  moves, pool manipulation, rebalances, liquidations and redemptions. Checks that shares and
  rewards add up, the trove keeps MUSD's rules, no LP is left unstaked, and every holder can exit
- Fork test of a full deposit → partial → full withdraw cycle against the deployed testnet MUSD
  and Mezo Pools contracts (returns 0.9997 BTC per BTC)
- Oracle-band guard on every pool action; LP valued at the manipulation-resistant fair price
  `2·sqrt(k·price)`; dead shares against first-depositor inflation; reentrancy guards
- The tests found real bugs (liquidation recovery, redemption surplus, reward leak on transfer, exits blocked by min debt, exits walking a thin pool); each fix is its own `fix:` commit

```shell
cd contracts
forge install foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-git
forge test
```

CI runs the full suite plus the testnet fork test on every push.

## Mainnet yield, today

The app reads the mainnet BTC/MUSD gauge live. On 2026-10-20: 42k MEZO/day on ~82k MUSD of
staked LP, about a **55% LP APR** in MEZO. About half of the vault's value is LP, so depositors
would earn **~24% before MUSD interest**, falling as more liquidity joins the gauge.

## Known limits

- Rewards are MEZO, which has little on-chain liquidity today; the vault pays them out and never sells them.
- Impermanent loss on the ~25% of value in the pool.
- While Mezo's oracle is stale, MUSD pauses all trove changes, so deposits and exits wait.
- In MUSD recovery mode (system collateral ratio under 150%) MUSD blocks closing troves and restricts collateral withdrawals, so exits that need either wait until the system recovers.
- The exit that closes the trove buys the LP's MUSD gap on the DEX and waits rather than sell BTC
  below the oracle band. Not binding on testnet (the pool holds ~1,300 BTC); it can be on mainnet.
- Mezo's official testnet BTC/MUSD gauge has no emissions and only the Voter can fund it, so the testnet demo runs a second vault on a `RewardGauge` (same interface, funded with testnet MEZO). On mainnet the vault uses the official gauge.
- Unaudited.

## Next (Wave 2)

- Concentrated-liquidity BTC/MUSD pool, which currently gets the larger gauge share
- Optional MEZO → veMEZO compounding
- Mezo Passport for Bitcoin-native wallets
- Mainnet deployment

## Repo

- `contracts/`: Foundry project (vault, interfaces, tests, deploy and keeper scripts)
- `app/`: static multi-page frontend (Vite + viem), deployed to Vercel and GitHub Pages: Home, Vault, Portfolio, Analytics (share-price history, live Mezo market), Simulator (mbLP vs holding BTC) and Docs
- `.github/workflows/`: Pages deploy and a keeper that calls `rebalance`/`harvest` every 30 minutes
