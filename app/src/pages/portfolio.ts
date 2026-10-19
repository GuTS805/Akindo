import { VAULT, mezoTestnet } from "../config";
import { vaultAbi } from "../vaultAbi";
import {
  WAD,
  readEvents,
  readUser,
  readVault,
  shareValueBtc,
  testnet,
  type UserState,
  type VaultEvent,
  type VaultState,
} from "../lib/chain";
import { renderEvents } from "../lib/events";
import { $, btc, musd, pct, ratio, sats } from "../lib/format";
import { mountShell } from "../lib/layout";
import { connect, initWallet, onWalletChange, sendTx, wallet, walletClient, watchAsset } from "../lib/wallet";

let vault: VaultState | undefined;
let user: UserState | undefined;
let history: VaultEvent[] = [];

function slice(x: bigint): bigint {
  return vault && vault.supply > 0n && user ? (x * user.shares) / vault.supply : 0n;
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
    $("p-pnl").textContent = `${pnl >= 0n ? "+" : ""}${btc(pnl, 6)} BTC`;
    $("p-pnl").className = `value ${pnl >= 0n ? "good" : "warn"}`;
    $("p-pnl-sub").textContent = `${pct(ratio(pnl, inBtc), 2)} on ${btc(inBtc, 4)} BTC deposited`;
  } else {
    $("p-pnl").textContent = "–";
    $("p-pnl-sub").textContent = "no deposits yet";
  }

  $("p-rewards").textContent = `${btc(user.claimable, 6)} ${vault.rewardSymbol}`;
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
  renderEvents($("p-history"), history, "No deposits or withdrawals from this address yet.");
}

async function refresh() {
  if (!wallet.account) {
    render();
    return;
  }
  const account = wallet.account;
  [vault, user, history] = await Promise.all([readVault(), readUser(account), readEvents(account)]);
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
  await initWallet();
  setInterval(() => {
    if (document.visibilityState === "visible" && !wallet.busy) refresh().catch(() => {});
  }, 30_000);
}

init();
