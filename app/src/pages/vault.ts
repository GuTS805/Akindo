import { formatUnits, parseEther } from "viem";
import { VAULT, mezoTestnet } from "../config";
import { vaultAbi } from "../vaultAbi";
import {
  WAD,
  claimableNow,
  collateralRatio,
  depositorApr,
  explain,
  navBtc,
  poolGap,
  readEvents,
  readMarket,
  readUser,
  readVault,
  rewardsPerSecond,
  shareValueBtc,
  testnet,
  type UserState,
  type VaultState,
} from "../lib/chain";
import { renderEvents } from "../lib/events";
import { $, btc, musd, num, pct, ratio, sats } from "../lib/format";
import { mountShell, showNotice } from "../lib/layout";
import { connect, initWallet, onWalletChange, sendTx, wallet, walletClient, watchAsset } from "../lib/wallet";

const GAS_RESERVE = parseEther("0.002");
const SLIPPAGE_BPS = 50n; // 0.5% on simulated outputs

let vault: VaultState | undefined;
let user: UserState | undefined;
let withdrawPct = 0;

// ---------------------------------------------------------------- rendering

function renderVault(v: VaultState) {
  const s = v.snap;
  $("alert").hidden = !!s;
  if (!s) {
    $("alert").textContent =
      "Mezo's price oracle is stale right now. MUSD pauses trove changes until it updates, so deposits and exits wait.";
    return;
  }

  const nav = navBtc(v);
  $("tvl").textContent = `${btc(nav, 4)} BTC`;
  $("tvl-usd").textContent = `≈ ${musd(s.navMusd)} MUSD`;
  $("pps").textContent = v.supply === 0n ? "1.0000" : btc((nav * WAD) / v.supply, 6);

  // Collateral ratio with its band
  const cr = collateralRatio(s);
  const lo = 1.5;
  const hi = 4.5;
  const pos = (x: number) => `${Math.min(100, Math.max(0, ((x - lo) / (hi - lo)) * 100))}%`;
  const minCR = ratio(v.minCR, WAD);
  const maxCR = ratio(v.maxCR, WAD);
  $("cr-band").style.left = pos(minCR);
  $("cr-band").style.width = `calc(${pos(maxCR)} - ${pos(minCR)})`;
  $("cr-mark").style.left = pos(cr || lo);
  $("cr").textContent = s.troveActive ? pct(cr, 0) : "No trove";
  $("cr").className = `value ${!s.troveActive ? "" : cr < minCR || cr > maxCR ? "warn" : "good"}`;
  $("cr-sub").textContent = `target ${pct(ratio(v.targetCR, WAD), 0)}, band ${pct(minCR, 0)}–${pct(maxCR, 0)}`;

  // Pool vs oracle
  const gap = poolGap(s);
  const band = Number(v.maxDeviationBps) / 10_000;
  $("gap").textContent = `${gap >= 0 ? "+" : ""}${pct(gap, 2)}`;
  $("gap").className = `value ${Math.abs(gap) <= band ? "good" : "bad"}`;
  $("gap-sub").textContent =
    Math.abs(gap) <= band ? `inside the ±${pct(band, 0)} band: pool actions allowed` : `outside ±${pct(band, 0)}: pool actions wait`;

  // Breakdown
  $("b-coll").textContent = `${btc(s.coll, 6)} BTC`;
  $("b-debt").textContent = `${musd(s.debt)} MUSD`;
  $("b-lp").textContent = `${btc(s.lpBtc, 6)} BTC + ${musd(s.lpMusd)} MUSD`;
  $("b-idle").textContent = `${btc(s.idleBtc, 6)} BTC / ${musd(s.idleMusd)} MUSD`;
  $("b-price").textContent = `${musd(s.price)} MUSD`;

  $("needs-rebalance").textContent = v.needsRebalance ? "Yes" : "No";
  $("needs-rebalance").className = v.needsRebalance ? "warn" : "";
}

function renderUser() {
  const connected = !!wallet.account;
  $("watch-btn").hidden = !connected;
  $("faucet-hint").hidden = !(user && vault && user.btc < vault.minDeposit + GAS_RESERVE);
  $("musd-row").hidden = $("my-musd").hidden = !(user && user.musd > 0n);
  if (user) $("my-musd").textContent = `${musd(user.musd, 2)} MUSD`;

  if (!user || !vault) {
    for (const id of ["my-shares", "my-value", "my-rewards"]) $(id).textContent = connected ? "…" : "–";
    $("btc-balance").textContent = "";
    $("share-balance").textContent = "";
  } else {
    const value = shareValueBtc(vault, user.shares);
    $("my-shares").textContent = `${btc(user.shares, 6)} mbLP`;
    $("my-value").textContent = `${btc(value, 6)} BTC · ${sats(value)}`;
    tickRewards();
    $("btc-balance").textContent = `· wallet ${btc(user.btc, 6)} BTC`;
    $("share-balance").textContent = `· ${btc(user.shares, 6)} mbLP`;
  }
  renderButtons();
}

/** Claimable rewards keep counting up between chain reads while the gauge streams. */
function tickRewards() {
  if (!user || !vault) return;
  $("my-rewards").textContent = `${claimableNow(vault, user).toFixed(6)} ${vault.rewardSymbol}`;
  const perDay = rewardsPerSecond(vault, user.shares) * 86_400;
  $("rate-row").hidden = $("my-rate").hidden = perDay === 0;
  $("my-rate").textContent = `${num(perDay, perDay < 1 ? 4 : 2)} ${vault.rewardSymbol} a day`;
}

function renderButtons() {
  const account = wallet.account;
  const ready = !!account && !wallet.busy;
  const amount = parseAmount();
  const depositOk =
    ready && !!vault?.snap && amount !== undefined && amount >= (vault?.minDeposit ?? 0n) && amount <= (user?.btc ?? 0n);
  $<HTMLButtonElement>("deposit-btn").disabled = account ? !depositOk : wallet.busy;
  $("deposit-btn").textContent = account ? "Deposit" : "Connect wallet";
  $<HTMLButtonElement>("withdraw-btn").disabled = account
    ? !(ready && withdrawPct > 0 && (user?.shares ?? 0n) > 0n)
    : wallet.busy;
  $("withdraw-btn").textContent = account ? "Withdraw" : "Connect wallet";
  $<HTMLButtonElement>("claim-btn").disabled = !(ready && (user?.claimable ?? 0n) > 0n);
  $<HTMLButtonElement>("rebalance-btn").disabled = !(ready && vault?.needsRebalance);
  $<HTMLButtonElement>("harvest-btn").disabled = !ready;
}

function setTx(html: string, isError = false) {
  const el = $("txstatus");
  el.hidden = false;
  el.innerHTML = html;
  el.className = `txstatus ${isError ? "bad" : ""}`;
}

// ---------------------------------------------------------------- deposit / withdraw previews

function parseAmount(): bigint | undefined {
  const raw = $<HTMLInputElement>("deposit-amount").value.trim();
  if (!/^\d*\.?\d{0,18}$/.test(raw) || raw === "" || raw === ".") return undefined;
  try {
    return parseEther(raw);
  } catch {
    return undefined;
  }
}

function renderDepositPreview() {
  const amount = parseAmount();
  $("deposit-sats").textContent = amount ? sats(amount) : "";
  const el = $("deposit-preview");
  if (!amount || !vault?.snap) {
    el.textContent = vault ? `Minimum ${btc(vault.minDeposit, 3)} BTC.` : "";
  } else if (vault.minDeposit > amount) {
    el.innerHTML = `<span class="warn">Minimum deposit is ${btc(vault.minDeposit, 3)} BTC.</span>`;
  } else if (user && amount > user.btc) {
    el.innerHTML = `<span class="warn">More than your wallet balance.</span>`;
  } else {
    const nav = navBtc(vault);
    const shares = vault.supply === 0n || nav === 0n ? amount : (amount * vault.supply) / nav;
    const inBand = Math.abs(poolGap(vault.snap)) <= Number(vault.maxDeviationBps) / 10_000;
    el.innerHTML =
      `You get ≈ <strong>${btc(shares, 6)} mbLP</strong>.<br/>` +
      (inBand
        ? "Your BTC goes into the position in the same transaction."
        : "The pool is outside the oracle band, so your BTC waits idle until the next rebalance.");
  }
  renderButtons();
}

/** Mirrors the vault: an exit that leaves less than MUSD's minimum debt unwinds everything. */
function unwinds(shares: bigint): boolean {
  if (!vault?.snap?.troveActive || vault.supply === 0n) return false;
  const repay = (vault.snap.netDebt * shares) / vault.supply;
  const dead = 1000n;
  return vault.supply - shares === dead || vault.snap.netDebt - repay < vault.minNetDebt;
}

let previewSeq = 0;
async function renderWithdrawPreview() {
  const el = $("withdraw-preview");
  document.querySelectorAll<HTMLButtonElement>(".pct").forEach((b) =>
    b.classList.toggle("selected", Number(b.dataset.pct) === withdrawPct),
  );
  const account = wallet.account;
  if (!account || !user || !vault || withdrawPct === 0 || user.shares === 0n) {
    el.textContent = account && user?.shares === 0n ? "You have no shares yet." : "";
    renderButtons();
    return;
  }
  const v = vault;
  const shares = (user.shares * BigInt(withdrawPct)) / 100n;
  const seq = ++previewSeq;
  el.textContent = "Simulating…";
  try {
    const { result } = await testnet.simulateContract({
      address: VAULT,
      abi: vaultAbi,
      functionName: "withdraw",
      args: [shares, 0n],
      account,
    });
    if (seq !== previewSeq) return;
    const [btcOut, musdOut] = result;
    el.innerHTML =
      `You receive <strong>${btc(btcOut, 6)} BTC</strong> (${sats(btcOut)})` +
      (musdOut > 0n ? ` + <strong>${musd(musdOut, 2)} MUSD</strong>` : "") +
      "." +
      (unwinds(shares)
        ? `<br/><span class="warn">This exit would leave the trove under MUSD's ${musd(v.minNetDebt)} MUSD minimum debt, so the vault closes the trove and removes all LP. Everyone keeps their share as idle BTC/MUSD until deposits reopen it.</span>`
        : "");
  } catch (e) {
    if (seq !== previewSeq) return;
    el.innerHTML = `<span class="warn">${explain(e)}</span>`;
  }
  renderButtons();
}

// ---------------------------------------------------------------- transactions

function slip(x: bigint): bigint {
  return (x * (10_000n - SLIPPAGE_BPS)) / 10_000n;
}

async function deposit() {
  const account = wallet.account;
  if (!account) return connect();
  const amount = parseAmount();
  if (!amount) return;
  await sendTx(
    `Deposit ${btc(amount, 6)} BTC`,
    async () => {
      const { result: shares } = await testnet.simulateContract({
        address: VAULT,
        abi: vaultAbi,
        functionName: "deposit",
        args: [0n],
        value: amount,
        account,
      });
      return walletClient().writeContract({
        address: VAULT,
        abi: vaultAbi,
        functionName: "deposit",
        args: [slip(shares)],
        value: amount,
        account,
        chain: mezoTestnet,
      });
    },
    setTx,
  );
  $<HTMLInputElement>("deposit-amount").value = "";
  await refresh();
}

async function withdraw() {
  const account = wallet.account;
  if (!account) return connect();
  if (!user || withdrawPct === 0) return;
  const shares = (user.shares * BigInt(withdrawPct)) / 100n;
  await sendTx(
    `Withdraw ${withdrawPct}%`,
    async () => {
      const { result } = await testnet.simulateContract({
        address: VAULT,
        abi: vaultAbi,
        functionName: "withdraw",
        args: [shares, 0n],
        account,
      });
      return walletClient().writeContract({
        address: VAULT,
        abi: vaultAbi,
        functionName: "withdraw",
        args: [shares, slip(result[0])],
        account,
        chain: mezoTestnet,
      });
    },
    setTx,
  );
  withdrawPct = 0;
  await refresh();
  renderWithdrawPreview();
}

async function simpleCall(label: string, functionName: "claimRewards" | "rebalance" | "harvest") {
  const account = wallet.account;
  if (!account) return connect();
  await sendTx(
    label,
    async () => {
      await testnet.simulateContract({ address: VAULT, abi: vaultAbi, functionName, account });
      return walletClient().writeContract({ address: VAULT, abi: vaultAbi, functionName, account, chain: mezoTestnet });
    },
    setTx,
  );
  await refresh();
}

// ---------------------------------------------------------------- live panels

async function renderActivity() {
  const events = await readEvents();
  renderEvents($("activity"), events.slice(0, 8));
}

async function renderMainnetYield() {
  try {
    const m = await readMarket();
    $("m-emissions").textContent = `${num(m.vamm.perDay)} MEZO/day · MEZO ≈ $${m.mezoPrice.toFixed(4)}`;
    $("m-staked").textContent = `${num(m.vamm.staked)} MUSD`;
    $("m-lpapr").textContent = pct(m.vamm.apr);
    $("m-vaultapr").textContent = `≈ ${pct(depositorApr(m.vamm.apr, vault))} before MUSD interest`;
  } catch {
    $("m-emissions").textContent = "Mainnet RPC unavailable, retrying";
  }
}

// ---------------------------------------------------------------- refresh loop

async function refresh() {
  try {
    vault = await readVault();
    renderVault(vault);
  } catch (e) {
    showNotice(`Could not read the vault: ${explain(e)}`);
  }
  if (wallet.account) {
    try {
      user = await readUser(wallet.account);
    } catch {
      /* keep last */
    }
  } else {
    user = undefined;
  }
  renderUser();
  renderDepositPreview();
}

function bind() {
  $("deposit-btn").addEventListener("click", deposit);
  $("withdraw-btn").addEventListener("click", withdraw);
  $("claim-btn").addEventListener("click", () => simpleCall("Claim rewards", "claimRewards"));
  $("rebalance-btn").addEventListener("click", () => simpleCall("Rebalance", "rebalance"));
  $("harvest-btn").addEventListener("click", () => simpleCall("Harvest", "harvest"));
  $("watch-btn").addEventListener("click", watchAsset);
  $("deposit-amount").addEventListener("input", renderDepositPreview);
  $("deposit-max").addEventListener("click", () => {
    if (!user) return;
    const max = user.btc > GAS_RESERVE ? user.btc - GAS_RESERVE : 0n;
    $<HTMLInputElement>("deposit-amount").value = formatUnits(max, 18);
    renderDepositPreview();
  });
  document.querySelectorAll<HTMLButtonElement>(".pct").forEach((b) =>
    b.addEventListener("click", () => {
      withdrawPct = Number(b.dataset.pct);
      renderWithdrawPreview();
    }),
  );
  const tabs = document.querySelectorAll<HTMLButtonElement>(".tab");
  const showTab = (tab: string) => {
    tabs.forEach((x) => {
      const on = x.dataset.tab === tab;
      x.classList.toggle("active", on);
      x.setAttribute("aria-selected", String(on));
    });
    $("panel-deposit").hidden = tab !== "deposit";
    $("panel-withdraw").hidden = tab !== "withdraw";
  };
  tabs.forEach((t) => t.addEventListener("click", () => showTab(t.dataset.tab!)));
  if (location.hash === "#withdraw") showTab("withdraw"); // linked from the portfolio page
}

async function init() {
  mountShell("vault");
  bind();
  onWalletChange(() => {
    renderButtons();
    refresh();
  });
  await initWallet();
  renderActivity();
  renderMainnetYield();
  setInterval(() => {
    if (document.visibilityState === "visible" && !wallet.busy) refresh();
  }, 15_000);
  setInterval(tickRewards, 1_000);
  setInterval(() => {
    if (document.visibilityState === "visible") {
      renderActivity();
      renderMainnetYield();
    }
  }, 60_000);
}

init();
