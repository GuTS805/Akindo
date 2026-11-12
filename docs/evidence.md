# Evidence

Every claim in the README, backed by a transaction or a reproducible test. Testnet links go to
[explorer.test.mezo.org](https://explorer.test.mezo.org).

## Live checks anyone can run

- **Try to break it** ([mblp.surge.sh/break](https://mblp.surge.sh/break/)) sends twelve attacks to the deployed v6 vault
  as an `eth_call` from a stranger's address that holds 10 test BTC (set for the call only). On 12 Nov 2026
  eleven reverted with the contract's own error (`OnlySelf`, `DepositTooSmall`, `DepositCapReached`, `Slippage`,
  `ERC20InsufficientBalance`, `ZeroShares`, Mezo gauge's `NotAuthorized`, `NothingToRebalance`, and MUSD's
  `CollSurplusPool: No collateral available to claim`), one ran and returned 0 (a stranger's `claimRewards()`),
  and none got through. The page also tabulates the sandwich tests: the attacker loses 52,019 to 403,379 sats per
  attempt across the 2%, 6% and 10% bands (`forge test --match-contract SandwichTest -vv`).
- **Community** ([mblp.surge.sh/community](https://mblp.surge.sh/community/)) lists every Deposit event on v4, v5
  and v6 from an address other than the deployer's, read from the explorer's log index (RPC fallback), with a
  link to each transaction.
- **Round trip on v6 (our own keeper wallet, not a third-party user).** Deposit of 0.002 BTC in
  [`0xc1fa8fda…d973`](https://explorer.test.mezo.org/tx/0xc1fa8fda1cb9b8f3a89857ee71a43912a726d830f28819bddd896eccd2f5d973),
  full exit through `withdrawMinValue` with a 0.0019 BTC value floor in
  [`0xeecae225…b3f4`](https://explorer.test.mezo.org/tx/0xeecae2258027b80ffe50abcbf4c4d4dbd1bc0acb6cc92ffda03985c7f7c5b3f4):
  0.0020005 BTC back for 0.002 BTC in, and the vault stayed at about 306% CR.
- **Wave 2 deck:** [`docs/mbLP-wave2-deck.pdf`](mbLP-wave2-deck.pdf).

## Contracts (Mezo testnet, source verified)

| Contract | Address | Deploy tx |
| --- | --- | --- |
| **BtcLpVault v6** (app default) | [`0x1309FdcFB8394dC63b350409F44b311D7B0dE0C0`](https://explorer.test.mezo.org/address/0x1309FdcFB8394dC63b350409F44b311D7B0dE0C0?tab=contract) | [`0x06c195fc…ef52`](https://explorer.test.mezo.org/tx/0x06c195fc31f5df1ff9b701ef2e86f801979743f9d7afd33ac9683e53793cef52) |
| **BtcLpVault v5** | [`0xB1CF6f9F21bEE3421e0C99a435741dCdB1Ba914D`](https://explorer.test.mezo.org/address/0xB1CF6f9F21bEE3421e0C99a435741dCdB1Ba914D?tab=contract) | [`0x39d2be69…69a6`](https://explorer.test.mezo.org/tx/0x39d2be6920afd0a820cac62579bd9f01682f483421f47f544bf16b7939a369a6) |
| **BtcLpVault v4** | [`0x897F89aBf67dACC3634E169a3896bfCaFd388D9f`](https://explorer.test.mezo.org/address/0x897F89aBf67dACC3634E169a3896bfCaFd388D9f?tab=contract) | [`0x030aa50e…de46`](https://explorer.test.mezo.org/tx/0x030aa50e230e53f3edb71e59cbd6b2ae13e86ca3055bd0add016efd6aaf4de46) |
| **BtcLpVault v3** | [`0x75532765bfBa32E8DC796292937F9c571a2dBFEC`](https://explorer.test.mezo.org/address/0x75532765bfBa32E8DC796292937F9c571a2dBFEC) | [`0x734f475b…046e`](https://explorer.test.mezo.org/tx/0x734f475b06a20cd8a29c0e94884bd1a6c3157392d0cb586ba6825c4603f7046e) |
| IncentiveRouter (v3 to v6 fee recipient) | [`0x28bAf157D84aa72Bf7Ac3800c8243F1557cf2605`](https://explorer.test.mezo.org/address/0x28bAf157D84aa72Bf7Ac3800c8243F1557cf2605) | [`0xe3edf374…8beb`](https://explorer.test.mezo.org/tx/0xe3edf37469743381a1c46f090a53ce243cb79753a753021b6614442dafe38beb) |
| **BtcLpVault v2** | [`0x652e31Ba2658CC27ff0E36431cA008De7D439102`](https://explorer.test.mezo.org/address/0x652e31Ba2658CC27ff0E36431cA008De7D439102?tab=contract) | [`0x24e9ec15…f6409`](https://explorer.test.mezo.org/tx/0x24e9ec1599a462f6c614e71082279303267b8093ff4b4e7bf9eb363e84ff6409) |
| IncentiveRouter (v2 fee recipient) | [`0x924b8a4585B659D78041569fE0074719116126F2`](https://explorer.test.mezo.org/address/0x924b8a4585B659D78041569fE0074719116126F2?tab=contract) | [`0x275be767…56f41`](https://explorer.test.mezo.org/tx/0x275be76796e08a2e42e3b73f74ebdc25b058f2631de685f6cd65858184e56f41) |
| BtcLpVault v1, MEZO rewards | [`0xc41192A186C0ee2F593D611b0D0C00501B5Eea03`](https://explorer.test.mezo.org/address/0xc41192A186C0ee2F593D611b0D0C00501B5Eea03?tab=contract) | [`0xf6e25d64…5af1`](https://explorer.test.mezo.org/tx/0xf6e25d6458b4f2bcdd607c2fd3f3caa4c988b06124e7df4c95fc6071f1b45af1) |
| RewardGauge (testnet MEZO) | [`0x204ef88B33e5d35De7b52F8c1FFa58cf89d4f45b`](https://explorer.test.mezo.org/address/0x204ef88B33e5d35De7b52F8c1FFa58cf89d4f45b?tab=contract) | [`0x6f18affd…d14a`](https://explorer.test.mezo.org/tx/0x6f18affd16e0a207c9ab67d13f0a52ecacf9310088bcb059c447f2693e7bd14a) |
| BtcLpVault, legacy gauge | [`0x187958091532733eF2f8703F8029Cd72aA85B2d4`](https://explorer.test.mezo.org/address/0x187958091532733eF2f8703F8029Cd72aA85B2d4?tab=contract) | [`0x494f7cbd…45a5`](https://explorer.test.mezo.org/tx/0x494f7cbdb55db1cd30eae97bf74574949fe51fc5a91ca26bf513770c396e45a5) |

v6, v5, v4, v3 and the IncentiveRouter are source-verified through the explorer's Blockscout verifier
(`forge verify-contract --verifier blockscout`); v3 from the commit it was deployed from.

v4 was deployed on 3 Nov 2026 and seeded with 0.2 BTC in
[`0x72385121…ec20a7`](https://explorer.test.mezo.org/tx/0x72385121293b5c8b7a593ef776b13a5146c3d31315d1cf93971ee71b86ec20a7):
the trove opened at 301.8% CR with a borrowing cap of 10,698 MUSD, and 13.18 LP were staked in the
live gauge. The 0.2 BTC came from the deployer's own v2 and v1 positions, withdrawn in
[`0x8994b650…9def`](https://explorer.test.mezo.org/tx/0x8994b6509e850a1f5c93d7fc5a118d245d0bf46823f0a752d24dbedebbd29def)
and [`0x33f4267f…2885`](https://explorer.test.mezo.org/tx/0x33f4267f88e450705a0c706c9685a35f27e9454cc105691829215be95b4e2885).
v4 adds what Wave 1's review asked for:

- **Borrowing cap.** MUSD caps a trove's debt at its collateral when opened (or last refinanced) over
  110%, and adding collateral does not raise it, so v3 stops borrowing at about 2.7x its first
  deposit. v4 moves idle BTC into the trove and refinances when a deposit would pass the cap. Fork
  tests run a 13x deposit against the real troves: the cap rose from 8,049 to 113,465 MUSD on testnet
  and from 10,650 to 115,681 MUSD on mainnet, and the depositor got 1.99949 of 2 BTC back.
- **Recovery Mode.** MUSD then blocks collateral withdrawals and closing troves, so v3's exits revert.
  v4 pays the leaver's share of the NAV at the oracle price from idle assets and LP, repays debt with
  the LP's MUSD and leaves the collateral alone; those who stay keep 1x BTC exposure and a higher
  ratio. Against the real testnet troves (Recovery Mode forced), a 0.4 BTC holder got 0.39988 BTC of
  value back, the collateral did not move and the debt fell.
- **Redistributed debt.** MUSD's `getEntireDebtAndColl` already includes pending interest; v3 added
  it again, understating NAV after a liquidation was redistributed to its trove until the next trove
  operation.

v6 was deployed on 12 Nov 2026 and seeded with 0.2 BTC in
[`0x7c61486e…d6bd`](https://explorer.test.mezo.org/tx/0x7c61486e7c56622d9b7125ba3ffea2b1367e787aa154bb42ee06ed26a2d5d6bd):
the trove opened at 306.0% CR and 12.55 LP were staked in the live gauge. The 0.2 BTC came from v5's
seed, withdrawn in [`0x48163490…9c67`](https://explorer.test.mezo.org/tx/0x481634903a509c752c58535a452cc0c461a170d2225b6a0ae1811ebc48d89c67).
On the live contract, `withdrawMinValue` returns 0.0019995 BTC for 0.002 BTC of shares with a floor of
0.0019, and reverts with `Slippage` when the floor is 0.003. v6 changes two things:

- **Deployment revert.** v5 sized new debt from total NAV. When the vault holds more LP than its trove
  supports (after a redemption, a liquidation or an exit settled inside the vault) that debt would take
  the trove under `minCR` and the deployment reverted, leaving the deposit idle. The debt is now also
  capped so the trove ends above the midpoint of `minCR` and `targetCR`. The random sequence in
  `InvariantRegression.t.sol` reached the revert on v5 and no longer does.
- **Value floor.** `withdraw`'s `minBtcOut` covers only the BTC of a payout, but an exit can be paid
  partly in MUSD. `withdrawMinValue(shares, minBtcOut, minValueBtc)` also floors BTC plus MUSD at the
  oracle price, and the app uses it.

v5 was deployed on 12 Nov 2026 and seeded with 0.2 BTC in
[`0x49f5f746…1359`](https://explorer.test.mezo.org/tx/0x49f5f7461a95b9157383f64dad7a78bc51ac1cb48d17b478ee1a2fe565ec1359):
the trove opened at 305.8% CR and 12.57 LP were staked in the live gauge. The 0.2 BTC came from the
deployer's v4 position, withdrawn in
[`0xd42c2e60…a9da`](https://explorer.test.mezo.org/tx/0xd42c2e60f7ac2e2a87cdb8c8002a518a5f64669ef665fefa844c0e92a18da4a9).
A first v5, `0xEC3c…56D9` (steps of a fifth of the pool, 6% band), was withdrawn unused: the testnet pool
stood 6.7% above the oracle that day, outside its band, so its seed deposit waited idle (as designed). The
final v5 uses the widest band the contract allows, 10%, because the testnet pool drifts 4-7% from the
oracle with no arbitrage; mainnet uses 2%. v5 changes two things, both found by attacking v4:

- **Deployment sandwich.** An attacker can push the pool to the band edge, let a deposit or a keeper
  step add liquidity there, and push it back. With steps of a fifth of the pool the attacker still made
  0.0004 BTC (8% band) and 0.0014 BTC (10% band) per 20 BTC deployed; with steps of a tenth, every
  sandwich of a rebalance, a deposit or a withdrawal loses money at the 2%, 6% and 10% bands, in both
  directions (`Sandwich.t.sol`).
- **A fall with the pool left behind.** After BTC falls fast the pool trails the oracle, and v4's
  `rebalance()` reverted on the band while the trove sat under its minimum ratio. v5 lets it cut debt
  there (`CrashExit.t.sol`: oracle -45%, the trove returns above 250%). Pushing the pool further away
  first earns an attacker nothing beyond the plain arbitrage of the stale pool.

Fork suites after the change: 5/5 against the testnet contracts and 3/3 on a Mezo mainnet fork, with a
13x deposit still deployed in full over several keeper steps and withdrawn at (almost) its full value.

v2 was seeded with 0.1 BTC in [`0x00500517…aa75`](https://explorer.test.mezo.org/tx/0x00500517070cd3d072e34d88a2621850bc15ff062961767b3c459bdcdf7faa75):
one deposit opened its trove at 296% CR (1,890 MUSD debt) and staked the LP in the reward gauge. A
first v2 deployment, `0x50B7…0368`, was never used: `contracts/.env` overrode its fee recipient,
which is immutable, so the vault was redeployed with the router and the script fixed.

The router then ran live: a v2 [`harvest`](https://explorer.test.mezo.org/tx/0xccf02ad67979714564b3f51da47bbd13a54beea5b3e58c87c41ae0c29e5d4ec6)
sent the 10% fee (0.00519 MEZO) to the `IncentiveRouter`, and
[`push()`](https://explorer.test.mezo.org/tx/0x4c9c8c0bf5c1d1679a7b206db68abdb256dc30a4535882a1111b0bedf12741e9)
offered half to the BTC/MUSD gauge's incentive contract. Mezo's testnet Voter does not whitelist
MEZO there, so the contract refused it; the router emitted `IncentivesRefused` and sent the whole
fee to the treasury, leaving nothing stuck. On mainnet, where MEZO is whitelisted, the same call
posts the incentive (see the mainnet fork below).

A wallet outside the project's scripts then deposited through the app with MetaMask:
[`0x28b44f15…fb52`](https://explorer.test.mezo.org/tx/0x28b44f1569f1a764c8ce7ebc3c879ed341ea04b44a6caa215f9dd69c827cfb52),
0.001 BTC into v2 for 0.0010003 mbLP worth 0.00099999 BTC (a 2-sat cost), using 290,801 of the
581,603 gas the app set, so the headroom from the out-of-gas finding below is doing its job. Thirteen
minutes later the same wallet claimed 0.001229 MEZO through the Portfolio page:
[`0x6efa97b8…c5a2`](https://explorer.test.mezo.org/tx/0x6efa97b8bfd354c4231516b55f6fb845a0eaf4caba3f7f3bfc93800a5349c5a2).

Testers then used it on their own. `0x4820…5d07` deposited 0.001 BTC
([`0xbc5084b4…0067`](https://explorer.test.mezo.org/tx/0xbc5084b4b324bee5357dc0bc5399a949a35e3b882e3b74d1c68ea2cabf620067)),
which also triggered the vault's deployment step (1,282,180 gas, inside the app's headroom), and
claimed twice
([`0x1810944b…b971`](https://explorer.test.mezo.org/tx/0x1810944b7eb6e5c7ae2bb2b8776dd885c056c6f6735f83c74c43fe730f6fb971),
[`0x56b0b705…3794`](https://explorer.test.mezo.org/tx/0x56b0b705b83668eb10d4675c14b889cc3f4ba485dbfc9cd29e01943b5a593794)).
`0x0869…7A5c` deposited 0.001 BTC with MetaMask
([`0x052b6ba1…f520`](https://explorer.test.mezo.org/tx/0x052b6ba1d300e26d15e0be9eac000c3adfae8460222fd3519ccb496d709ef520))
and claimed 0.00368 MEZO
([`0x4897696b…011e`](https://explorer.test.mezo.org/tx/0x4897696b9a48863374d79ff7350c6d008487fc8b0081896b8303a5764d95011e)).

### A Bitcoin wallet through Mezo Passport

A Unisat wallet connected through Mezo Passport and ran the full cycle from its Mezo smart account,
[`0x58de…2Ded`](https://explorer.test.mezo.org/address/0x58de3E4e5cF5812866aaEE50cEF13672341a2Ded):
Unisat signed each step, Mezo's relayer submitted it, and the Safe emitted `ExecutionSuccess` every time.

| Step | Tx |
| --- | --- |
| Deposit 0.001 BTC (waits as idle BTC, 351,520 gas) | [`0xddfd9b6a…4eca`](https://explorer.test.mezo.org/tx/0xddfd9b6a4ef0f01a457f6071ca45be68983bccd469412cac9e86fdf1a2564eca) |
| Deposit 0.001 BTC, which also ran the deployment step (1,579,263 gas) | [`0x30219b76…c89f`](https://explorer.test.mezo.org/tx/0x30219b76d191c14d6b3198b894fdc39afda9aacd0bfdd8c536e413d5c4a2c89f) |
| Claim 0.001316 MEZO to the smart account (175,573 gas) | [`0xa92483bf…70a9`](https://explorer.test.mezo.org/tx/0xa92483bfc90985c2398775ba9aca1535acdcd2820a0cfcc5273af3a754a770a9) |
| Withdraw 50%: burn 0.00099996 mbLP, receive 0.00099974 BTC (1,492,118 gas) | [`0xecb58415…55d9`](https://explorer.test.mezo.org/tx/0xecb58415d91e232da3b67f0145762679a324e1798f65b7aeabdd4191cc6255d9) |

Getting there turned up two problems outside the vault. Passport's built-in testnet relayer host,
`test.mezo.org`, no longer resolves, so the app redirects Passport's relay calls to
`testnet.mezo.org`, which serves the same API. And Passport turns a relayer refusal into an
empty transaction hash, so the app now shows the relayer's own reason instead.

## The full user cycle, live

A fresh wallet, [`0x6ADe…82D6`](https://explorer.test.mezo.org/address/0x6ADe5c2CAdD3C7234e2B9F043eEc6caC790382D6),
used the MEZO rewards vault like any user would:

| Step | Result | Tx |
| --- | --- | --- |
| Deposit 0.005 BTC | One transaction: harvest, mint 0.005 mbLP, borrow MUSD against the new BTC, add it to the pool, stake the LP, emit `Rebalance` | [`0x2f8336f3…7172`](https://explorer.test.mezo.org/tx/0x2f8336f3691858722ea6ff9180becff76a31fdf3bb55860abbff6eb79f8d7172) |
| Claim rewards, 10 minutes later | 0.00916 testnet MEZO paid to the wallet | [`0xed48a841…ed92`](https://explorer.test.mezo.org/tx/0xed48a84191a12d8cd9ff3926ac8ed89eb8c5a89ed6e4dea9d27047130260ed92) |
| Withdraw half | 0.0025 BTC back | [`0x14f1bc3f…efb`](https://explorer.test.mezo.org/tx/0x14f1bc3f03e1099fabeb75ecc1bf689a9354f5b46aaed2ef438ce11ab0e1aefb) |

The first withdrawal attempt, sent with the gas limit the node estimated, ran out of gas
(1,291,830 of 1,298,688, [`0x2a96a038…2e9f`](https://explorer.test.mezo.org/tx/0x2a96a038e94e3091b42f432f9d8a882167e75a52e2ec983c4e1ccdb4ac032e9f)).
Nothing moved, but a user would have paid for a failed exit, so the app now sends every vault
transaction with 50% (at least 300k) gas headroom on top of the estimate.

## Vault operations

| Event | Tx |
| --- | --- |
| Seed the rewards vault with 0.115 BTC: trove opened at 296% CR, LP staked | [`0x2323e035…c644`](https://explorer.test.mezo.org/tx/0x2323e0357026a4ec0a17edcc43a3b083d0e0f3777adf933f039a8df8a6c4c644) |
| Fund the RewardGauge with 250 MEZO over 7 days (anyone can) | [`0x237e1ad9…8d53`](https://explorer.test.mezo.org/tx/0x237e1ad9c3981606b7f5fcd0ca234422c3fece0f41ba60b598076550059d8d53) |
| Keeper harvest | [`0x9a45ab02…ed9b`](https://explorer.test.mezo.org/tx/0x9a45ab02693f28234c994eb2155a09e5d39ec588d91f10f98a05b55a0422ed9b) |
| Keeper tops up the reward stream (approve, notify) | [`0x202e07fa…56ee`](https://explorer.test.mezo.org/tx/0x202e07fa2772874be5fdfd474be1112a937ac4e712f8b4ec134cdd52b9e456ee), [`0x70577b96…9521`](https://explorer.test.mezo.org/tx/0x70577b96d0aa1bc4b56ef5ebe7976c8a6c8baa3af43c852ecf4e68cf285a9521) |
| Seed the official-gauge vault with 0.12 BTC | [`0xa36213e3…435a`](https://explorer.test.mezo.org/tx/0xa36213e3f99118eb2a91839453d3ceb495661ae4db765ab45376ce9fbe60435a) |

The keeper is [`0x3e68…228F`](https://explorer.test.mezo.org/address/0x3e68A7eA5A9140dE973778402C7a14d24F75228F),
a throwaway key run by [`.github/workflows/keeper.yml`](../.github/workflows/keeper.yml). Every
call it makes is open to anyone.

## v3: Mezo's live gauge on testnet

The testnet BTC/MUSD pool has two gauges, on two Voters (both governed by the same Mezo address):

| Voter | BTC/MUSD gauge | State |
| --- | --- | --- |
| [`0x263F…5F0D`](https://explorer.test.mezo.org/address/0x263F1Fd5fB7F866881e1B6cD7d5d6c40Fd985F0D) | [`0x72D8…Cd2c`](https://explorer.test.mezo.org/address/0x72D88B0795373437E86792DEd8362D66dC43Cd2c) | Live. The Voter sent it 647,418 MEZO on 15 Oct 2026 and 760,811 MEZO on 22 Oct; MEZO is whitelisted on its incentive contract [`0x75b6…0ee1`](https://explorer.test.mezo.org/address/0x75b6B35Fc78826A0B7E1f9c08bb7d84bd70D0ee1) |
| [`0x72F8…5738`](https://explorer.test.mezo.org/address/0x72F8dd7F44fFa19E45955aa20A5486E8EB255738) | [`0xeF07…0Cc3`](https://explorer.test.mezo.org/address/0xeF07B6852f4F877fB3BBD90b8f358Fb3E07D0Cc3) | Stopped. Its Splitter's `activePeriod` is 13 Nov 2025 and `updatePeriod()` reverts, so `distribute()` reverts for every gauge; MEZO is not whitelisted there |

The earlier vaults used the second one (its addresses came from `mezo-org/tigris`), which is why
they needed the RewardGauge below. A builder in Mezo's Discord pointed to the live gauge. v3 is the
v2 contract staked there:

| Step | Result | Tx |
| --- | --- | --- |
| Seed 0.1 BTC | Trove opened at 296.8% CR; 6.72 LP staked in the live gauge | [`0x3c446a7e…dcaf`](https://explorer.test.mezo.org/tx/0x3c446a7ed8cc08a9f95e8ba592d37b083022bfcae03191fe642afd27325adcaf) |
| Harvest | ~1.92 MEZO from Mezo's gauge; the 10% fee (0.192 MEZO) to the router | [`0xb78d005d…0973`](https://explorer.test.mezo.org/tx/0xb78d005dbb2e18e6738b754dd33bef688d96951ab1e2e53ef5bf4bc58be40973) |
| Router `push()` | 0.0961 MEZO posted on the gauge's incentive contract, 0.0961 MEZO to the treasury: the fee flywheel, live | [`0xa7724a6c…cb26`](https://explorer.test.mezo.org/tx/0xa7724a6c5cda61f678b71d477412c39f16a59e210ba448544ed7f89ea48dcb26) |

### The demo video, from MetaMask

The [demo video](https://youtu.be/ICVxyTolYig) runs one cycle on v3 from MetaMask, with a fresh
wallet [`0x32e2…cCC4`](https://explorer.test.mezo.org/address/0x32e271dc4693dF1EdB59e0353dE7470B2E9acCC4)
on 22 Oct 2026:

| Step | Result | Tx |
| --- | --- | --- |
| Deposit 0.01 BTC | 0.0099997 mbLP minted; the BTC joins the trove, the pool and Mezo's live gauge | [`0x87428726…459d`](https://explorer.test.mezo.org/tx/0x874287262fadf7c3470ed3ae127c9dc7e826841f3e27901f3fe39252906d459d) |
| Claim | 0.0182 MEZO from Mezo's gauge to the wallet | [`0x08b84374…35cd1`](https://explorer.test.mezo.org/tx/0x08b84374d1914380bc21016c4535a2b76066cd8f2f3a439805365b0201235cd1) |
| Withdraw 50% | 0.005 mbLP burned for 0.0049987 BTC and no MUSD (the app had simulated 0.004998 BTC before signing) | [`0xdff587eb…2817`](https://explorer.test.mezo.org/tx/0xdff587ebe9c0cae4eaa484fccd9b804694d8f60a2df56fe3845515d160362817) |

The testnet fork tests run the same against the live gauge: 1 BTC earned 652 MEZO in a day, and
one day of its fees booked 36.25 MEZO as an incentive for the current epoch
([`Fork.t.sol`](../contracts/test/Fork.t.sol)).

### A lagging RPC backend

`rpc.test.mezo.org` spreads requests over several backends, and one ran about 99,000 blocks (some
5 days) behind on 22 Oct 2026. Requests that land on it see old state: a funded wallet at balance 0
and nonce 0, a new contract with no code, and empty logs past its head. Before the fix, the app
could show an empty history or zeros for the new vault, and transactions could fail with
"insufficient funds". The app now pins every read to the highest block it has seen (the lagging
backend then rejects the block and the read is retried) and asks again before believing an empty
log list; the keeper does the same, and CI retries the testnet fork tests.

## Why a reward gauge on testnet (v1, v2)

The gauge the earlier vaults stake in,
[`0xeF07…0Cc3`](https://explorer.test.mezo.org/address/0xeF07B6852f4F877fB3BBD90b8f358Fb3E07D0Cc3),
reports `rewardRate() = 0` and `periodFinish() = 0`, and `notifyRewardAmount` reverts with
`NotVoter()` for anyone but its Voter. The RewardGauge has the same interface the vault uses,
takes funding from anyone, and pays the real testnet MEZO token (`0x7b7C…0001`).

## Mainnet, on a fork

[`MainnetFork.t.sol`](../contracts/test/MainnetFork.t.sol) runs the vault against Mezo
**mainnet** MUSD, the volatile BTC/MUSD pool and its live MEZO gauge (addresses in
[`MezoMainnet`](../contracts/script/Addresses.sol), checked on chain):

```
MEZO claimed after 1 day: 3309.277852535972514077
value back (BTC) for 0.2 BTC: 0.199950959043366148
MEZO posted as a gauge incentive: 183.705393032249390098
```

The last line is the fee flywheel: the vault's fee, routed through `IncentiveRouter`, lands on the
gauge's real `BribeVotingReward` (`0x94A9…E305`, `PoolsVoter.gaugeToBribe`) for the current epoch,
where veBTC voters earn it by voting for the BTC/MUSD gauge.

That is about 0.06% of the deposit a day in MEZO at today's emissions. The test runs in
[CI](https://github.com/GuTS805/Akindo/actions/workflows/ci.yml) on every push:

```shell
cd contracts && MEZO_MAINNET_RPC=https://mezo.drpc.org forge test --mc MainnetForkTest -vv
```

## Tests and analysis

- 78 unit, fuzz, recovery, gauge, router, manipulation, v2 deposit and edge-case tests, an invariant suite and two fork tests;
  97% line and 100% function coverage of `src/`
- Slither: 41 results, each reviewed in [`contracts/SECURITY.md`](../contracts/SECURITY.md)
