import {
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  createPublicClient,
  createWalletClient,
  custom,
  formatUnits,
  http,
  parseEther,
  type Address,
  type EIP1193Provider,
  type Hash,
} from "viem";
import {
  GITHUB,
  MAINNET,
  MUSD,
  VAULT,
  VAULT_DEPLOY_BLOCK,
  borrowerOpsAbi,
  clPoolAbi,
  erc20Abi,
  gaugeAbi,
  mezoMainnet,
  mezoTestnet,
  poolAbi,
  priceFeedAbi,
} from "./config";
import { vaultAbi } from "./vaultAbi";

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

const testnet = createPublicClient({ chain: mezoTestnet, transport: http(), batch: { multicall: true } });
const mainnet = createPublicClient({ chain: mezoMainnet, transport: http(), batch: { multicall: true } });

const WAD = 10n ** 18n;
const GAS_RESERVE = parseEther("0.002");
const SLIPPAGE_BPS = 50n; // 0.5% on simulated outputs
const EXPLORER = mezoTestnet.blockExplorers.default.url;

type Snapshot = {
  price: bigint;
  poolPrice: bigint;
  coll: bigint;
  debt: bigint;
  netDebt: bigint;
  troveActive: boolean;
  lp: bigint;
  lpBtc: bigint;
  lpMusd: bigint;
  lpFairValue: bigint;
  idleBtc: bigint;
  idleMusd: bigint;
  navMusd: bigint;
};

type VaultState = {
  snap?: Snapshot; // undefined while the oracle is stale
  supply: bigint;
  needsRebalance: boolean;
  minCR: bigint;
  targetCR: bigint;
  maxCR: bigint;
  maxDeviationBps: bigint;
  feeBps: bigint;
  minDeposit: bigint;
  rewardSymbol: string;
  minNetDebt: bigint;
};

type UserState = { btc: bigint; shares: bigint; claimable: bigint; musd: bigint };

let account: Address | undefined;
let vault: VaultState | undefined;
let user: UserState | undefined;
let withdrawPct = 0;
let busy = false;

// ---------------------------------------------------------------- wallet discovery (EIP-6963)

type Announced = { info: { uuid: string; name: string; icon: string; rdns: string }; provider: EIP1193Provider };
const announced = new Map<string, Announced>();
let provider: EIP1193Provider | undefined = window.ethereum;
const WALLET_KEY = "mblp.wallet";

window.addEventListener("eip6963:announceProvider", (e) => {
  const d = (e as CustomEvent<Announced>).detail;
  if (d?.info?.uuid && d.provider) announced.set(d.info.uuid, d);
});
window.dispatchEvent(new Event("eip6963:requestProvider"));

function remember(rdns: string | undefined) {
  try {
    if (rdns) localStorage.setItem(WALLET_KEY, rdns);
  } catch {
    /* storage may be blocked */
  }
}

function remembered(): Announced | undefined {
  try {
    const rdns = localStorage.getItem(WALLET_KEY);
    return [...announced.values()].find((a) => a.info.rdns === rdns);
  } catch {
    return undefined;
  }
}

function pickWallet(): Promise<Announced> {
  const list = [...announced.values()];
  const dialog = $<HTMLDialogElement>("wallet-picker");
  const ul = $("wallet-list");
  ul.innerHTML = "";
  return new Promise((resolve, reject) => {
    for (const a of list) {
      const li = document.createElement("li");
      const btn = document.createElement("button");
      btn.className = "btn wide wallet-option";
      const img = document.createElement("img");
      img.src = a.info.icon;
      img.alt = "";
      btn.append(img, document.createTextNode(a.info.name));
      btn.addEventListener("click", () => {
        dialog.close();
        resolve(a);
      });
      li.append(btn);
      ul.append(li);
    }
    dialog.addEventListener("close", () => reject(new Error("No wallet chosen.")), { once: true });
    dialog.showModal();
  });
}

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;

// ---------------------------------------------------------------- formatting

function btc(wei: bigint, dp = 8): string {
  const neg = wei < 0n;
  const [i, f = ""] = formatUnits(neg ? -wei : wei, 18).split(".");
  return `${neg ? "-" : ""}${BigInt(i).toLocaleString("en-US")}.${(f + "0".repeat(dp)).slice(0, dp)}`;
}

function sats(wei: bigint): string {
  return `${(wei / 10n ** 10n).toLocaleString("en-US")} sats`;
}

function musd(wei: bigint, dp = 0): string {
  return Number(formatUnits(wei, 18)).toLocaleString("en-US", { maximumFractionDigits: dp, minimumFractionDigits: dp });
}

function pct(x: number, dp = 1): string {
  return `${(x * 100).toFixed(dp)}%`;
}

function ratio(a: bigint, b: bigint): number {
  return b === 0n ? 0 : Number((a * 1_000_000n) / b) / 1_000_000;
}

function short(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

function ago(ts: bigint): string {
  if (ts === 0n) return "";
  const s = Math.max(0, Math.floor(Date.now() / 1000) - Number(ts));
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86_400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86_400)}d ago`;
}

function txLink(hash: string): string {
  return `<a href="${EXPLORER}/tx/${hash}" target="_blank" rel="noopener">${short(hash)}</a>`;
}

// ---------------------------------------------------------------- reads

async function readVault(): Promise<VaultState> {
  const read = <T>(functionName: string) =>
    testnet.readContract({ address: VAULT, abi: vaultAbi, functionName } as never) as Promise<T>;
  const [snap, supply, needsRebalance, minCR, targetCR, maxCR, maxDeviationBps, feeBps, minDeposit, rewardToken] = await Promise.all([
    read<Snapshot>("snapshot").catch(() => undefined),
    read<bigint>("totalSupply"),
    read<boolean>("needsRebalance"),
    read<bigint>("minCR"),
    read<bigint>("targetCR"),
    read<bigint>("maxCR"),
    read<bigint>("maxDeviationBps"),
    read<bigint>("feeBps"),
    read<bigint>("minDeposit"),
    read<Address>("rewardToken"),
  ]);
  // The testnet gauge pays in BTC (the precompile); mainnet gauges pay MEZO.
  const rewardSymbol = rewardToken.toLowerCase() === "0x7b7c000000000000000000000000000000000000" ? "BTC" : "MEZO";
  const borrowerOps = await read<Address>("borrowerOperations");
  const minNetDebt = await testnet.readContract({ address: borrowerOps, abi: borrowerOpsAbi, functionName: "minNetDebt" });
  return {
    snap,
    supply,
    needsRebalance,
    minCR,
    targetCR,
    maxCR,
    maxDeviationBps,
    feeBps,
    minDeposit,
    rewardSymbol,
    minNetDebt,
  };
}

async function readUser(a: Address): Promise<UserState> {
  const [bal, shares, claimable, musd] = await Promise.all([
    testnet.getBalance({ address: a }),
    testnet.readContract({ address: VAULT, abi: vaultAbi, functionName: "balanceOf", args: [a] }),
    testnet.readContract({ address: VAULT, abi: vaultAbi, functionName: "claimable", args: [a] }),
    testnet.readContract({ address: MUSD, abi: erc20Abi, functionName: "balanceOf", args: [a] }),
  ]);
  return { btc: bal, shares, claimable, musd };
}

function navBtc(v: VaultState): bigint {
  return v.snap && v.snap.price > 0n ? (v.snap.navMusd * WAD) / v.snap.price : 0n;
}

function shareValueBtc(v: VaultState, shares: bigint): bigint {
  return v.supply === 0n ? 0n : (navBtc(v) * shares) / v.supply;
}

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
  const cr = s.troveActive && s.debt > 0n ? ratio(s.coll * s.price, s.debt * WAD) : 0;
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
  const gap = s.poolPrice === 0n ? 0 : ratio(s.poolPrice, s.price) - 1;
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
  const connected = !!account;
  $("connect").textContent = connected ? short(account!) : "Connect wallet";

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
    $("my-rewards").textContent = `${btc(user.claimable, 6)} ${vault.rewardSymbol}`;
    $("btc-balance").textContent = `· wallet ${btc(user.btc, 6)} BTC`;
    $("share-balance").textContent = `· ${btc(user.shares, 6)} mbLP`;
  }
  renderButtons();
}

function renderButtons() {
  const ready = !!account && !busy;
  const amount = parseAmount();
  const depositOk =
    ready && !!vault?.snap && amount !== undefined && amount >= (vault?.minDeposit ?? 0n) && amount <= (user?.btc ?? 0n);
  $<HTMLButtonElement>("deposit-btn").disabled = account ? !depositOk : busy;
  $("deposit-btn").textContent = account ? "Deposit" : "Connect wallet";
  $<HTMLButtonElement>("withdraw-btn").disabled = account ? !(ready && withdrawPct > 0 && (user?.shares ?? 0n) > 0n) : busy;
  $("withdraw-btn").textContent = account ? "Withdraw" : "Connect wallet";
  $<HTMLButtonElement>("claim-btn").disabled = !(ready && (user?.claimable ?? 0n) > 0n);
  $<HTMLButtonElement>("rebalance-btn").disabled = !(ready && vault?.needsRebalance);
  $<HTMLButtonElement>("harvest-btn").disabled = !ready;
}

function showAlert(msg: string) {
  $("alert").textContent = msg;
  $("alert").hidden = false;
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
    const gap = ratio(vault.snap.poolPrice, vault.snap.price) - 1;
    const inBand = Math.abs(gap) <= Number(vault.maxDeviationBps) / 10_000;
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
  if (!account || !user || !vault || withdrawPct === 0 || user.shares === 0n) {
    el.textContent = account && user?.shares === 0n ? "You have no shares yet." : "";
    renderButtons();
    return;
  }
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
        ? `<br/><span class="warn">This exit would leave the trove under MUSD's ${musd(vault.minNetDebt)} MUSD minimum debt, so the vault closes the trove and removes all LP. Everyone keeps their share as idle BTC/MUSD until deposits reopen it.</span>`
        : "");
  } catch (e) {
    if (seq !== previewSeq) return;
    el.innerHTML = `<span class="warn">${explain(e)}</span>`;
  }
  renderButtons();
}

// ---------------------------------------------------------------- wallet

function wallet() {
  const eth = provider;
  if (!eth) throw new Error("No browser wallet found. Install MetaMask or another EVM wallet.");
  return { eth, client: createWalletClient({ chain: mezoTestnet, transport: custom(eth), account: account! }) };
}

async function ensureChain() {
  const { eth } = wallet();
  const chainId = "0x" + mezoTestnet.id.toString(16);
  if ((await eth.request({ method: "eth_chainId" })) === chainId) return;
  try {
    await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] });
  } catch (e) {
    const code = (e as { code?: number; data?: { originalError?: { code?: number } } }).code;
    const inner = (e as { data?: { originalError?: { code?: number } } }).data?.originalError?.code;
    if (code !== 4902 && inner !== 4902) throw e;
    await eth.request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId,
          chainName: mezoTestnet.name,
          nativeCurrency: mezoTestnet.nativeCurrency,
          rpcUrls: [...mezoTestnet.rpcUrls.default.http],
          blockExplorerUrls: [EXPLORER],
        },
      ],
    });
  }
}

async function connect() {
  try {
    // Several wallets installed: let the user choose; one: use it; none announced: window.ethereum.
    if (announced.size > 1) {
      const chosen = await pickWallet();
      provider = chosen.provider;
      remember(chosen.info.rdns);
    } else if (announced.size === 1) {
      const only = [...announced.values()][0];
      provider = only.provider;
      remember(only.info.rdns);
    }
    const { eth } = wallet();
    attachListeners(eth);
    const accounts = (await eth.request({ method: "eth_requestAccounts" })) as Address[];
    account = accounts[0];
    await ensureChain();
    await refresh();
  } catch (e) {
    if (e instanceof Error && e.message === "No wallet chosen.") return;
    showAlert(explain(e));
  }
}

const listening = new WeakSet<EIP1193Provider>();
function attachListeners(eth: EIP1193Provider) {
  if (listening.has(eth)) return;
  listening.add(eth);
  eth.on?.("accountsChanged", (accs: Address[]) => {
    if (eth !== provider) return;
    account = accs[0];
    refresh();
  });
  eth.on?.("chainChanged", () => {
    if (eth === provider) updateNetworkBadge();
  });
}

async function watchAsset() {
  try {
    await wallet().eth.request({
      method: "wallet_watchAsset",
      params: { type: "ERC20", options: { address: VAULT, symbol: "mbLP", decimals: 18 } },
    });
  } catch (e) {
    showAlert(explain(e));
  }
}

async function updateNetworkBadge() {
  const badge = $("network-badge");
  const eth = provider;
  if (!eth || !account) {
    badge.textContent = "Mezo Testnet";
    badge.classList.remove("wrong");
    return;
  }
  const id = parseInt((await eth.request({ method: "eth_chainId" })) as string, 16);
  const right = id === mezoTestnet.id;
  badge.textContent = right ? "Mezo Testnet" : "Wrong network";
  badge.classList.toggle("wrong", !right);
}

// ---------------------------------------------------------------- transactions

async function send(label: string, write: () => Promise<Hash>) {
  if (busy) return;
  busy = true;
  renderButtons();
  setTx(`${label}: confirm in your wallet…`);
  try {
    await ensureChain();
    const hash = await write();
    setTx(`${label}: sent ${txLink(hash)}, waiting for the block…`);
    const receipt = await testnet.waitForTransactionReceipt({ hash, pollingInterval: 2_000, timeout: 180_000 });
    setTx(
      receipt.status === "success" ? `${label} confirmed ${txLink(hash)}` : `${label} reverted ${txLink(hash)}`,
      receipt.status !== "success",
    );
  } catch (e) {
    setTx(explain(e), true);
  } finally {
    busy = false;
    await refresh();
  }
}

function slip(x: bigint): bigint {
  return (x * (10_000n - SLIPPAGE_BPS)) / 10_000n;
}

async function deposit() {
  if (!account) return connect();
  const amount = parseAmount();
  if (!amount) return;
  await send(`Deposit ${btc(amount, 6)} BTC`, async () => {
    const { result: shares } = await testnet.simulateContract({
      address: VAULT,
      abi: vaultAbi,
      functionName: "deposit",
      args: [0n],
      value: amount,
      account,
    });
    return wallet().client.writeContract({
      address: VAULT,
      abi: vaultAbi,
      functionName: "deposit",
      args: [slip(shares)],
      value: amount,
      account: account!,
      chain: mezoTestnet,
    });
  });
  $<HTMLInputElement>("deposit-amount").value = "";
  renderDepositPreview();
}

async function withdraw() {
  if (!account) return connect();
  if (!user || withdrawPct === 0) return;
  const shares = (user.shares * BigInt(withdrawPct)) / 100n;
  await send(`Withdraw ${withdrawPct}%`, async () => {
    const { result } = await testnet.simulateContract({
      address: VAULT,
      abi: vaultAbi,
      functionName: "withdraw",
      args: [shares, 0n],
      account,
    });
    return wallet().client.writeContract({
      address: VAULT,
      abi: vaultAbi,
      functionName: "withdraw",
      args: [shares, slip(result[0])],
      account: account!,
      chain: mezoTestnet,
    });
  });
  withdrawPct = 0;
  renderWithdrawPreview();
}

function simpleCall(label: string, functionName: "claimRewards" | "rebalance" | "harvest") {
  return send(label, async () => {
    await testnet.simulateContract({ address: VAULT, abi: vaultAbi, functionName, account });
    return wallet().client.writeContract({
      address: VAULT,
      abi: vaultAbi,
      functionName,
      account: account!,
      chain: mezoTestnet,
    });
  });
}

const ERRORS: Record<string, string> = {
  DepositTooSmall: "Below the minimum deposit.",
  ZeroShares: "Amount too small to mint a share.",
  Slippage: "Price moved during the transaction. Try again.",
  OracleUnavailable: "Mezo's oracle is stale; MUSD pauses trove changes until it updates.",
  PoolPriceOffOracle: "The pool price is outside the oracle band. Rebalance waits for arbitrage.",
  NothingToRebalance: "The vault is already balanced.",
  BelowMinCR: "This would put the trove under its minimum collateral ratio.",
  InsolventVault: "Vault value is zero.",
};

function explain(e: unknown): string {
  if (e instanceof BaseError) {
    if (e.walk((x) => x instanceof UserRejectedRequestError)) return "Cancelled in your wallet.";
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName;
    if (name && ERRORS[name]) return ERRORS[name];
    if (revert?.reason) return `Reverted: ${revert.reason}`;
    return e.shortMessage;
  }
  const code = (e as { code?: number })?.code;
  if (code === 4001) return "Cancelled in your wallet.";
  return e instanceof Error ? e.message : String(e);
}

// ---------------------------------------------------------------- activity feed

async function renderActivity() {
  const names = ["Deposit", "Withdraw", "Rebalance", "Harvest", "RewardClaimed", "Unwound"] as const;
  const logs = (
    await Promise.all(
      names.map((eventName) =>
        testnet
          .getContractEvents({ address: VAULT, abi: vaultAbi, eventName, fromBlock: VAULT_DEPLOY_BLOCK })
          .catch(() => []),
      ),
    )
  )
    .flat()
    .sort((a, b) => Number((b.blockNumber ?? 0n) - (a.blockNumber ?? 0n)))
    .slice(0, 15);

  const el = $("activity");
  if (logs.length === 0) {
    el.innerHTML = `<li class="muted">No activity yet.</li>`;
    return;
  }
  const blocks = [...new Set(logs.map((l) => l.blockNumber!))];
  const times = new Map(
    await Promise.all(
      blocks.map(async (n) => [n, await testnet.getBlock({ blockNumber: n }).then((b) => b.timestamp).catch(() => 0n)] as const),
    ),
  );
  el.innerHTML = logs
    .map((log) => {
      const a = log.args as Record<string, bigint | string>;
      let what = log.eventName as string;
      if (log.eventName === "Deposit") what = `${short(String(a.user))} deposited ${btc(a.btcIn as bigint, 6)} BTC`;
      if (log.eventName === "Withdraw")
        what = `${short(String(a.user))} withdrew ${btc(a.btcOut as bigint, 6)} BTC${(a.musdOut as bigint) > 0n ? ` + ${musd(a.musdOut as bigint, 2)} MUSD` : ""}`;
      if (log.eventName === "Rebalance")
        what = `Rebalanced: debt ${musd(a.netDebtBefore as bigint)} → ${musd(a.netDebtAfter as bigint)} MUSD, CR ${pct(ratio(a.crAfter as bigint, WAD), 0)}`;
      if (log.eventName === "Harvest") what = `Harvested ${btc(a.reward as bigint, 6)} rewards`;
      if (log.eventName === "RewardClaimed") what = `${short(String(a.user))} claimed ${btc(a.amount as bigint, 6)} rewards`;
      if (log.eventName === "Unwound") what = `Position unwound, ${musd(a.debtRepaid as bigint)} MUSD repaid`;
      const when = ago(times.get(log.blockNumber!) ?? 0n);
      return `<li><span class="what">${what}</span><span class="when">${when ? `${when} · ` : ""}${txLink(log.transactionHash!)}</span></li>`;
    })
    .join("");
}

// ---------------------------------------------------------------- mainnet yield panel

async function renderMainnetYield() {
  try {
    const [rate, periodFinish, gaugeSupply, reserves, lpSupply, price, slot0, block] = await Promise.all([
      mainnet.readContract({ address: MAINNET.btcMusdGauge, abi: gaugeAbi, functionName: "rewardRate" }),
      mainnet.readContract({ address: MAINNET.btcMusdGauge, abi: gaugeAbi, functionName: "periodFinish" }),
      mainnet.readContract({ address: MAINNET.btcMusdGauge, abi: gaugeAbi, functionName: "totalSupply" }),
      mainnet.readContract({ address: MAINNET.btcMusdPool, abi: poolAbi, functionName: "getReserves" }),
      mainnet.readContract({ address: MAINNET.btcMusdPool, abi: poolAbi, functionName: "totalSupply" }),
      mainnet.readContract({ address: MAINNET.priceFeed, abi: priceFeedAbi, functionName: "fetchPrice" }),
      mainnet.readContract({ address: MAINNET.mezoBtcClPool, abi: clPoolAbi, functionName: "slot0" }),
      mainnet.getBlock(),
    ]);
    const live = block.timestamp < periodFinish;
    const perDay = live ? (rate * 86_400n) / WAD : 0n;

    // BTC/MUSD pool: token0 is BTC
    const [rBtc, rMusd] = reserves;
    const poolValue = (rBtc * price) / WAD + rMusd;
    const staked = lpSupply === 0n ? 0n : (poolValue * gaugeSupply) / lpSupply;

    // MEZO price from the MEZO/BTC CL pool: sqrtPriceX96^2 / 2^192 = MEZO per BTC
    const sqrtP = slot0[0];
    const mezoPriceMusd = (price * 2n ** 192n) / (sqrtP * sqrtP); // MUSD per MEZO, 1e18
    const yearlyUsd = Number(formatUnits(rate * 31_536_000n * (live ? 1n : 0n), 18)) * Number(formatUnits(mezoPriceMusd, 18));
    const lpApr = staked === 0n ? 0 : yearlyUsd / Number(formatUnits(staked, 18));

    // Share of the vault's value that sits in LP (≈50% at target), net of the fee.
    const lpShare = vault?.snap && vault.snap.navMusd > 0n ? ratio(vault.snap.lpFairValue, vault.snap.navMusd) : 0.5;
    const fee = Number(vault?.feeBps ?? 1000n) / 10_000;
    const vaultApr = lpApr * lpShare * (1 - fee);

    $("m-emissions").textContent = `${Number(perDay).toLocaleString("en-US")} MEZO/day · MEZO ≈ $${Number(formatUnits(mezoPriceMusd, 18)).toFixed(4)}`;
    $("m-staked").textContent = `${musd(staked)} MUSD`;
    $("m-lpapr").textContent = pct(lpApr);
    $("m-vaultapr").textContent = `≈ ${pct(vaultApr)} before MUSD interest`;
  } catch {
    $("m-emissions").textContent = "Mainnet RPC unavailable";
  }
}

// ---------------------------------------------------------------- refresh loop

async function refresh() {
  try {
    vault = await readVault();
    renderVault(vault);
  } catch (e) {
    showAlert(`Could not read the vault: ${explain(e)}`);
  }
  if (account) {
    try {
      user = await readUser(account);
    } catch {
      /* keep last */
    }
  } else {
    user = undefined;
  }
  renderUser();
  renderDepositPreview();
  updateNetworkBadge().catch(() => {});
}

function bind() {
  $("connect").addEventListener("click", connect);
  $("deposit-btn").addEventListener("click", deposit);
  $("withdraw-btn").addEventListener("click", withdraw);
  $("claim-btn").addEventListener("click", () => simpleCall("Claim rewards", "claimRewards"));
  $("rebalance-btn").addEventListener("click", () => simpleCall("Rebalance", "rebalance"));
  $("harvest-btn").addEventListener("click", () => simpleCall("Harvest", "harvest"));
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
  document.querySelectorAll<HTMLButtonElement>(".tab").forEach((t) =>
    t.addEventListener("click", () => {
      const tab = t.dataset.tab!;
      document.querySelectorAll<HTMLButtonElement>(".tab").forEach((x) => {
        x.classList.toggle("active", x === t);
        x.setAttribute("aria-selected", String(x === t));
      });
      $("panel-deposit").hidden = tab !== "deposit";
      $("panel-withdraw").hidden = tab !== "withdraw";
    }),
  );

  $("watch-btn").addEventListener("click", watchAsset);
  $("wallet-cancel").addEventListener("click", () => $<HTMLDialogElement>("wallet-picker").close());

  $<HTMLAnchorElement>("vault-link").href = `${EXPLORER}/address/${VAULT}`;
  $<HTMLAnchorElement>("source-link").href = `${EXPLORER}/address/${VAULT}?tab=contract`;
  $<HTMLAnchorElement>("github-link").href = GITHUB;
}

async function init() {
  bind();
  // Give EIP-6963 wallets a moment to announce, then reconnect silently to the last one used.
  await new Promise((r) => setTimeout(r, 150));
  provider = remembered()?.provider ?? provider;
  if (provider) {
    attachListeners(provider);
    const accs = (await provider.request({ method: "eth_accounts" }).catch(() => [])) as Address[];
    account = accs[0];
  }
  await refresh();
  renderActivity();
  renderMainnetYield();
  setInterval(() => {
    if (document.visibilityState === "visible" && !busy) refresh();
  }, 15_000);
  setInterval(() => {
    if (document.visibilityState === "visible") {
      renderActivity();
      renderMainnetYield();
    }
  }, 60_000);
}

init();
