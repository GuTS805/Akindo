# Evidence

Every claim in the README, backed by a transaction or a reproducible test. Testnet links go to
[explorer.test.mezo.org](https://explorer.test.mezo.org).

## Contracts (Mezo testnet, source verified)

| Contract | Address | Deploy tx |
| --- | --- | --- |
| **BtcLpVault v2** (app default) | [`0x652e31Ba2658CC27ff0E36431cA008De7D439102`](https://explorer.test.mezo.org/address/0x652e31Ba2658CC27ff0E36431cA008De7D439102?tab=contract) | [`0x24e9ec15…f6409`](https://explorer.test.mezo.org/tx/0x24e9ec1599a462f6c614e71082279303267b8093ff4b4e7bf9eb363e84ff6409) |
| IncentiveRouter (v2 fee recipient) | [`0x924b8a4585B659D78041569fE0074719116126F2`](https://explorer.test.mezo.org/address/0x924b8a4585B659D78041569fE0074719116126F2?tab=contract) | [`0x275be767…56f41`](https://explorer.test.mezo.org/tx/0x275be76796e08a2e42e3b73f74ebdc25b058f2631de685f6cd65858184e56f41) |
| BtcLpVault v1, MEZO rewards | [`0xc41192A186C0ee2F593D611b0D0C00501B5Eea03`](https://explorer.test.mezo.org/address/0xc41192A186C0ee2F593D611b0D0C00501B5Eea03?tab=contract) | [`0xf6e25d64…5af1`](https://explorer.test.mezo.org/tx/0xf6e25d6458b4f2bcdd607c2fd3f3caa4c988b06124e7df4c95fc6071f1b45af1) |
| RewardGauge (testnet MEZO) | [`0x204ef88B33e5d35De7b52F8c1FFa58cf89d4f45b`](https://explorer.test.mezo.org/address/0x204ef88B33e5d35De7b52F8c1FFa58cf89d4f45b?tab=contract) | [`0x6f18affd…d14a`](https://explorer.test.mezo.org/tx/0x6f18affd16e0a207c9ab67d13f0a52ecacf9310088bcb059c447f2693e7bd14a) |
| BtcLpVault, official gauge | [`0x187958091532733eF2f8703F8029Cd72aA85B2d4`](https://explorer.test.mezo.org/address/0x187958091532733eF2f8703F8029Cd72aA85B2d4?tab=contract) | [`0x494f7cbd…45a5`](https://explorer.test.mezo.org/tx/0x494f7cbdb55db1cd30eae97bf74574949fe51fc5a91ca26bf513770c396e45a5) |

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
([`0x052b6ba1…f520`](https://explorer.test.mezo.org/tx/0x052b6ba1d300e26d15e0be9eac000c3adfae8460222fd3519ccb496d709ef520)).

### A Bitcoin wallet through Mezo Passport

A Unisat wallet connected through Mezo Passport and deposited from its Mezo smart account,
[`0x58de…2Ded`](https://explorer.test.mezo.org/address/0x58de3E4e5cF5812866aaEE50cEF13672341a2Ded):
Unisat signed, Mezo's relayer submitted, and the Safe emitted `ExecutionSuccess` both times.

| Step | Tx |
| --- | --- |
| Deposit 0.001 BTC (waits as idle BTC, 351,520 gas) | [`0xddfd9b6a…4eca`](https://explorer.test.mezo.org/tx/0xddfd9b6a4ef0f01a457f6071ca45be68983bccd469412cac9e86fdf1a2564eca) |
| Deposit 0.001 BTC, which also ran the deployment step (1,579,263 gas) | [`0x30219b76…c89f`](https://explorer.test.mezo.org/tx/0x30219b76d191c14d6b3198b894fdc39afda9aacd0bfdd8c536e413d5c4a2c89f) |

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

## Why a reward gauge on testnet

Mezo's official testnet BTC/MUSD gauge
[`0xeF07…0Cc3`](https://explorer.test.mezo.org/address/0xeF07B6852f4F877fB3BBD90b8f358Fb3E07D0Cc3)
reports `rewardRate() = 0` and `periodFinish() = 0`. `notifyRewardAmount` reverts with
`NotVoter()` for anyone but Mezo's Voter, and `notifyRewardWithoutClaim` with `NotTeam()`. So a
vault staked there can never harvest anything on testnet. The RewardGauge has the same interface
the vault uses, takes funding from anyone, and pays the real testnet MEZO token
(`0x7b7C…0001`).

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
- Slither: 32 results, each reviewed in [`contracts/SECURITY.md`](../contracts/SECURITY.md)
