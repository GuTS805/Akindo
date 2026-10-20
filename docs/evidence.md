# Evidence

Every claim in the README, backed by a transaction or a reproducible test. Testnet links go to
[explorer.test.mezo.org](https://explorer.test.mezo.org).

## Contracts (Mezo testnet, source verified)

| Contract | Address | Deploy tx |
| --- | --- | --- |
| BtcLpVault, MEZO rewards | [`0xc41192A186C0ee2F593D611b0D0C00501B5Eea03`](https://explorer.test.mezo.org/address/0xc41192A186C0ee2F593D611b0D0C00501B5Eea03?tab=contract) | [`0xf6e25d64…5af1`](https://explorer.test.mezo.org/tx/0xf6e25d6458b4f2bcdd607c2fd3f3caa4c988b06124e7df4c95fc6071f1b45af1) |
| RewardGauge (testnet MEZO) | [`0x204ef88B33e5d35De7b52F8c1FFa58cf89d4f45b`](https://explorer.test.mezo.org/address/0x204ef88B33e5d35De7b52F8c1FFa58cf89d4f45b?tab=contract) | [`0x6f18affd…d14a`](https://explorer.test.mezo.org/tx/0x6f18affd16e0a207c9ab67d13f0a52ecacf9310088bcb059c447f2693e7bd14a) |
| BtcLpVault, official gauge | [`0x187958091532733eF2f8703F8029Cd72aA85B2d4`](https://explorer.test.mezo.org/address/0x187958091532733eF2f8703F8029Cd72aA85B2d4?tab=contract) | [`0x494f7cbd…45a5`](https://explorer.test.mezo.org/tx/0x494f7cbdb55db1cd30eae97bf74574949fe51fc5a91ca26bf513770c396e45a5) |

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
```

That is about 0.06% of the deposit a day in MEZO at today's emissions. The test runs in
[CI](https://github.com/GuTS805/Akindo/actions/workflows/ci.yml) on every push:

```shell
cd contracts && MEZO_MAINNET_RPC=https://mezo.drpc.org forge test --mc MainnetForkTest -vv
```

## Tests and analysis

- 59 unit, fuzz, recovery, gauge and edge-case tests, an invariant suite and two fork tests;
  97% line and 100% function coverage of `src/`
- Slither: 31 results, each reviewed in [`contracts/SECURITY.md`](../contracts/SECURITY.md)
