import { VAULT, mezoTestnet } from "../config";
import { vaultAbi } from "../vaultAbi";
import {
  WAD,
  claimableNow,
  readEvents,
  readUser,
  readVault,
  rewardsPerSecond,
  shareValueBtc,
  testnet,
  type UserState,
  type VaultEvent,
  type VaultState,
} from "../lib/chain";
import { renderEvents } from "../lib/events";
import { $, btc, musd, pct, ratio, sats } from "../lib/format";
import { clearNotice, mountShell, showNotice } from "../lib/layout";
import { connect, initWallet, onWalletChange, sendTx, wallet, walletClient, watchAsset } from "../lib/wallet";

let vault: VaultState | undefined;
let user: UserState | undefined;
let history: VaultEvent[] = [];

function slice(x: bigint): bigint {
  return vault && vault.supply > 0n && user ? (x * user.shares) / vault.supply : 0n;
}

function claimedTotal(): number {
  return history
    .filter((e) => e.name === "RewardClaimed")
    .reduce((sum, e) => sum + Number(e.args.amount as bigint) / 1e18, 0);
}

function tickRewards() {
  if (!vault || !user) return;
  $("p-rewards").textContent = `${claimableNow(vault, user).toFixed(6)} ${vault.rewardSymbol}`;
  const perDay = rewardsPerSecond(vault, user.shares) * 86_400;
  const claimed = claimedTotal();
  $("p-rewards-sub").textContent =
    perDay > 0
      ? `earning ${perDay.toFixed(perDay < 1 ? 4 : 2)} ${vault.rewardSymbol} a day${claimed > 0 ? ` · ${claimed.toFixed(4)} claimed` : ""}`
      : claimed > 0
        ? `${claimed.toFixed(4)} claimed so far`
        : "the gauge is not streaming rewards";
}

function render() {
  const connected = !!wallet.account;
  $("p-connect").hidden = connected;
  $("p-body").hidden = !connected;
  if (!connected || !vault || !user) return;

  const value = shareValueBtc(vault, user.shares);
  $("p-value").textContent = `${btc(value, 6)} BTC`;
  $("p-value-sub").textContent = vault.snap ? `${sats(value)} · ≈ ${musd((value * vault.snap.price) / WAD)} MUSD` : sats(value);
  $("p-shares").textContent = `${btc(user.shares, 6)} mbLP`;
  $("p-share-of").textContent = vault.supply > 0n ? `${pct(ratio(user.shares, vault.supply), 2)} of the vault` : "–";

  // Result vs deposits, all in BTC at today's oracle price: value now + taken out − put in.
  const price = vault.snap?.price ?? 0n;
  let inBtc = 0n;
  let outBtc = 0n;
  for (const e of history) {
    if (e.name === "Deposit") inBtc += e.args.btcIn as bigint;
    if (e.name === "Withdraw")
      outBtc += (e.args.btcOut as bigint) + (price > 0n ? ((e.args.musdOut as bigint) * WAD) / price : 0n);
  }
  if (inBtc > 0n) {
    const pnl = value + outBtc - inBtc;
    // Under half a micro-BTC rounds to zero at 6 decimals: show it as flat, not as "-0.000000".
    const flat = (pnl < 0n ? -pnl : pnl) < 500_000_000_000n;
    $("p-pnl").textContent = flat ? `0.000000 BTC` : `${pnl > 0n ? "+" : ""}${btc(pnl, 6)} BTC`;
    $("p-pnl").className = `value ${flat ? "" : pnl > 0n ? "good" : "warn"}`;
    // Rewards are paid in the reward token, not BTC, so they are shown next to the BTC result.
    const earned = claimedTotal() + claimableNow(vault, user);
    $("p-pnl-sub").textContent = `${flat ? `${pnl > 0n ? "+" : ""}${sats(pnl)}` : pct(ratio(pnl, inBtc), 2)} in BTC on ${btc(inBtc, 4)} deposited${
      earned > 0 ? `, plus ${earned.toFixed(4)} ${vault.rewardSymbol} earned` : ""
    }`;
  } else {
    $("p-pnl").textContent = "–";
    $("p-pnl-sub").textContent = "no deposits yet";
  }

  tickRewards();
  $("p-wallet-btc").textContent = `${btc(user.btc, 6)} BTC`;
  $("p-wallet-musd").textContent = `${musd(user.musd, 2)} MUSD`;
  $<HTMLButtonElement>("p-claim").disabled = wallet.busy || user.claimable === 0n;

  const s = vault.snap;
  if (s) {
    $("s-coll").textContent = `${btc(slice(s.coll), 6)} BTC`;
    $("s-debt").textContent = `${musd(slice(s.netDebt), 2)} MUSD`;
    $("s-lpbtc").textContent = `${btc(slice(s.lpBtc), 6)} BTC`;
    $("s-lpmusd").textContent = `${musd(slice(s.lpMusd), 2)} MUSD`;
    $("s-idle").textContent = `${btc(slice(s.idleBtc), 6)} BTC / ${musd(slice(s.idleMusd), 2)} MUSD`;
  }
  if (historyFailed) {
    $("p-history").innerHTML = `<li class="muted">History unavailable from the RPC right now, retrying.</li>`;
  } else {
    renderEvents($("p-history"), history, "No deposits or withdrawals from this address yet.");
  }
}

let refreshSeq = 0;
let historyFailed = false;
let readFailed = false;
let shownAccount: string | undefined;

async function refresh() {
  const seq = ++refreshSeq;
  const account = wallet.account;
  if (account !== shownAccount) {
    // Never show one address's position under another.
    user = undefined;
    history = [];
    shownAccount = account;
  }
  if (!account) {
    render();
    return;
  }
  const [v, u, h] = await Promise.allSettled([readVault(), readUser(account), readEvents(account)]);
  if (seq !== refreshSeq || wallet.account !== account) return;
  if (v.status === "fulfilled") vault = v.value;
  if (u.status === "fulfilled") user = u.value;
  if (h.status === "fulfilled") history = h.value;
  historyFailed = h.status === "rejected";
  const failed = [v, u].find((r) => r.status === "rejected") as PromiseRejectedResult | undefined;
  if (failed) {
    console.error("portfolio refresh", failed.reason);
    if (!readFailed) showNotice("Could not read your position from Mezo testnet. Retrying.");
  } else if (readFailed) {
    clearNotice();
  }
  readFailed = !!failed;
  render();
}

function setTx(html: string, isError = false) {
  const el = $("txstatus");
  el.hidden = false;
  el.innerHTML = html;
  el.className = `txstatus ${isError ? "bad" : ""}`;
}

async function claim() {
  const account = wallet.account;
  if (!account) return;
  await sendTx(
    "Claim rewards",
    async () => {
      await testnet.simulateContract({ address: VAULT, abi: vaultAbi, functionName: "claimRewards", account });
      return walletClient().writeContract({ address: VAULT, abi: vaultAbi, functionName: "claimRewards", account, chain: mezoTestnet });
    },
    setTx,
  );
  await refresh();
}

async function init() {
  mountShell("portfolio");
  $("p-connect-btn").addEventListener("click", connect);
  $("p-claim").addEventListener("click", claim);
  $("p-watch").addEventListener("click", watchAsset);
  onWalletChange(() => {
    refresh().catch(() => {});
  });
  initWallet().catch((e) => console.error("initWallet", e));
  setInterval(() => {
    if (document.visibilityState === "visible" && !wallet.busy) refresh().catch((e) => console.error(e));
  }, 30_000);
  setInterval(tickRewards, 1_000);
}

init();
