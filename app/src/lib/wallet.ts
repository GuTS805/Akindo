import { createWalletClient, custom, type Address, type EIP1193Provider, type Hash } from "viem";
import { VAULT, mezoTestnet } from "../config";
import { explain, testnet } from "./chain";
import { $, EXPLORER, esc, short, txLink } from "./format";
import { clearNotice, showNotice } from "./layout";

const injected = (window as { ethereum?: EIP1193Provider }).ethereum;

type Announced = { info: { uuid: string; name: string; icon: string; rdns: string }; provider: EIP1193Provider };
type BitcoinWalletId = "unisat" | "okx" | "xverse";
type Choice = { kind: "evm"; wallet: Announced } | { kind: "btc"; id: BitcoinWalletId };

const BITCOIN_WALLET_NAMES: Record<BitcoinWalletId, string> = { unisat: "Unisat", okx: "OKX Wallet", xverse: "Xverse" };
const BTC_PREFIX = "btc:";

/** Bitcoin wallets injected in this browser (checked without loading Mezo Passport). */
function installedBitcoinWallets(): BitcoinWalletId[] {
  const w = window as unknown as Record<string, unknown>;
  const found: BitcoinWalletId[] = [];
  if (w.unisat) found.push("unisat");
  if ((w.okxwallet as { bitcoin?: unknown } | undefined)?.bitcoin) found.push("okx");
  if (w.XverseProviders || w.BitcoinProvider) found.push("xverse");
  return found;
}

const announced = new Map<string, Announced>();
const WALLET_KEY = "mblp.wallet";
const subscribers = new Set<() => void>();

export const wallet: { account?: Address; provider?: EIP1193Provider; busy: boolean; bitcoin?: string } = {
  provider: injected,
  busy: false,
};

// EIP-6963: wallets announce themselves; several can coexist.
window.addEventListener("eip6963:announceProvider", (e) => {
  const d = (e as CustomEvent<Announced>).detail;
  if (d?.info?.uuid && d.provider) announced.set(d.info.uuid, d);
});
window.dispatchEvent(new Event("eip6963:requestProvider"));

export function onWalletChange(fn: () => void) {
  subscribers.add(fn);
}

function emit() {
  renderConnectButton();
  updateNetworkBadge().catch(() => {});
  for (const fn of subscribers) fn();
}

function remember(rdns: string) {
  try {
    localStorage.setItem(WALLET_KEY, rdns);
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

function option(label: string, icon: string | undefined, onClick: () => void, note?: string, disabled = false) {
  const li = document.createElement("li");
  const btn = document.createElement("button");
  btn.className = "btn wide wallet-option";
  if (icon) {
    const img = document.createElement("img");
    img.src = icon;
    img.alt = "";
    btn.append(img);
  }
  btn.append(document.createTextNode(label));
  if (note) {
    const small = document.createElement("small");
    small.className = "muted";
    small.textContent = note;
    btn.append(small);
  }
  btn.disabled = disabled;
  btn.addEventListener("click", onClick);
  li.append(btn);
  return li;
}

function heading(text: string) {
  const li = document.createElement("li");
  li.className = "wallet-group";
  li.textContent = text;
  return li;
}

function rememberedBitcoin(): BitcoinWalletId | undefined {
  try {
    const v = localStorage.getItem(WALLET_KEY);
    return v?.startsWith(BTC_PREFIX) ? (v.slice(BTC_PREFIX.length) as BitcoinWalletId) : undefined;
  } catch {
    return undefined;
  }
}

function pickWallet(): Promise<Choice> {
  const dialog = $<HTMLDialogElement>("wallet-picker");
  const ul = $("wallet-list");
  ul.innerHTML = "";
  return new Promise((resolve, reject) => {
    const choose = (c: Choice) => {
      dialog.close();
      resolve(c);
    };
    if (announced.size > 0) ul.append(heading("EVM wallets"));
    for (const a of announced.values()) ul.append(option(a.info.name, a.info.icon, () => choose({ kind: "evm", wallet: a })));
    const btc = installedBitcoinWallets();
    ul.append(heading("Bitcoin wallets · Mezo Passport"));
    for (const id of Object.keys(BITCOIN_WALLET_NAMES) as BitcoinWalletId[]) {
      const installed = btc.includes(id);
      ul.append(
        option(
          BITCOIN_WALLET_NAMES[id],
          undefined,
          () => choose({ kind: "btc", id }),
          installed ? "signs for a Mezo smart account" : "not detected in this browser",
          !installed,
        ),
      );
    }
    if (announced.size === 0 && btc.length === 0) {
      const li = document.createElement("li");
      li.className = "wallet-empty";
      li.textContent =
        "No wallet found in this browser. On a phone, open this page inside your wallet app's browser (MetaMask, OKX or Unisat).";
      ul.prepend(li);
    }
    dialog.addEventListener("close", () => reject(new Error("No wallet chosen.")), { once: true });
    dialog.showModal();
  });
}

async function useBitcoinWallet(id: BitcoinWalletId) {
  const { connectBitcoinWallet } = await import("./passport");
  const { account, provider } = await connectBitcoinWallet(id);
  wallet.provider = provider;
  wallet.account = account;
  wallet.bitcoin = BITCOIN_WALLET_NAMES[id];
  remember(BTC_PREFIX + id);
}

function eth(): EIP1193Provider {
  if (!wallet.provider) throw new Error("No browser wallet found. Install MetaMask or another EVM wallet.");
  return wallet.provider;
}

/**
 * Wallet client whose writes carry a gas limit with headroom. Mezo's estimates for vault calls
 * can land just short (trove hint searches vary from block to block), and an exit that runs out
 * of gas reverts after the user paid for it: one live withdrawal used 1,291,830 of 1,298,688.
 */
export function walletClient() {
  const client = createWalletClient({ chain: mezoTestnet, transport: custom(eth()), account: wallet.account! });
  const write = client.writeContract.bind(client);
  const writeContract = (async (args: Parameters<typeof write>[0]) => {
    const estimate = await testnet.estimateContractGas({ ...(args as object), account: wallet.account! } as never);
    const gas = estimate + (estimate / 2n > 300_000n ? estimate / 2n : 300_000n);
    return write({ ...args, gas } as never);
  }) as typeof write;
  return { ...client, writeContract };
}

const listening = new WeakSet<EIP1193Provider>();
function attachListeners(p: EIP1193Provider) {
  if (listening.has(p)) return;
  listening.add(p);
  p.on?.("accountsChanged", (accs: Address[]) => {
    if (p !== wallet.provider) return;
    wallet.account = accs[0];
    emit();
  });
  p.on?.("chainChanged", () => {
    if (p === wallet.provider) updateNetworkBadge().catch(() => {});
  });
}

export async function ensureChain() {
  const p = eth();
  const chainId = "0x" + mezoTestnet.id.toString(16);
  if ((await p.request({ method: "eth_chainId" })) === chainId) return;
  try {
    await p.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] });
  } catch (e) {
    const code = (e as { code?: number }).code;
    const inner = (e as { data?: { originalError?: { code?: number } } }).data?.originalError?.code;
    if (code !== 4902 && inner !== 4902) throw e;
    await p.request({
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

export async function connect() {
  try {
    // Several wallets (or a Bitcoin wallet): let the user choose; one: use it; none: injected.
    if (announced.size > 1 || installedBitcoinWallets().length > 0 || (announced.size === 0 && !injected)) {
      const chosen = await pickWallet();
      if (chosen.kind === "btc") {
        await useBitcoinWallet(chosen.id);
        clearNotice();
        emit();
        return;
      }
      wallet.provider = chosen.wallet.provider;
      wallet.bitcoin = undefined;
      remember(chosen.wallet.info.rdns);
    } else if (announced.size === 1) {
      const only = [...announced.values()][0];
      wallet.provider = only.provider;
      remember(only.info.rdns);
    }
    const p = eth();
    attachListeners(p);
    clearNotice();
    const btn = $<HTMLButtonElement>("connect");
    btn.textContent = "Check your wallet…";
    btn.disabled = true;
    // Wallet popups often open behind the browser or only badge the toolbar icon.
    const hint = setTimeout(
      () =>
        showNotice(
          "Waiting for your wallet. No popup? Click the wallet's icon in the browser toolbar (the MetaMask fox) and approve the request there.",
        ),
      4_000,
    );
    try {
      const accounts = (await p.request({ method: "eth_requestAccounts" })) as Address[];
      wallet.account = accounts[0];
      await ensureChain();
    } finally {
      clearTimeout(hint);
      btn.disabled = false;
    }
    clearNotice();
  } catch (e) {
    console.error("connect failed", e);
    if (!(e instanceof Error && e.message === "No wallet chosen.")) showNotice(explain(e));
  }
  emit();
}

/** Rejects if `p` has not settled in `ms`; a locked wallet can leave a request pending forever. */
function within<T>(ms: number, p: Promise<T>): Promise<T> {
  return Promise.race([p, new Promise<T>((_, reject) => setTimeout(() => reject(new Error("timeout")), ms))]);
}

/** Reconnect silently to the last wallet used, if it already authorised this site. */
export async function initWallet() {
  $("connect").addEventListener("click", () => (wallet.account ? copyAddress() : connect()));
  await new Promise((r) => setTimeout(r, 150)); // let EIP-6963 wallets announce
  const btc = rememberedBitcoin();
  if (btc && installedBitcoinWallets().includes(btc)) {
    await within(8_000, useBitcoinWallet(btc)).catch(() => undefined);
    if (wallet.account) {
      emit();
      return;
    }
  }
  wallet.provider = remembered()?.provider ?? wallet.provider;
  if (wallet.provider) {
    attachListeners(wallet.provider);
    const accs = (await within(5_000, wallet.provider.request({ method: "eth_accounts" })).catch(() => [])) as Address[];
    wallet.account = accs[0];
  }
  emit();
}

/** Connected: a click copies the full address (for the faucet, or to share). */
async function copyAddress() {
  const btn = $<HTMLButtonElement>("connect");
  try {
    await navigator.clipboard.writeText(wallet.account!);
    btn.textContent = "Address copied";
  } catch {
    showNotice(`Your address: ${wallet.account}`);
    return;
  }
  setTimeout(renderConnectButton, 1_500);
}

function renderConnectButton() {
  const btn = $<HTMLButtonElement>("connect");
  if (btn && !btn.disabled)
    btn.textContent = wallet.account ? `${wallet.bitcoin ? "₿ " : ""}${short(wallet.account)}` : "Connect wallet";
  if (btn)
    btn.title = !wallet.account
      ? ""
      : wallet.bitcoin
        ? `${wallet.bitcoin} via Mezo Passport, smart account ${wallet.account}. Click to copy.`
        : `${wallet.account}. Click to copy.`;
}

export async function updateNetworkBadge() {
  const badge = $("network-badge");
  if (!wallet.provider || !wallet.account) {
    badge.textContent = "Mezo Testnet";
    badge.classList.remove("wrong");
    return;
  }
  const id = parseInt((await wallet.provider.request({ method: "eth_chainId" })) as string, 16);
  const right = id === mezoTestnet.id;
  badge.textContent = right ? "Mezo Testnet" : "Wrong network";
  badge.classList.toggle("wrong", !right);
}

export async function watchAsset() {
  try {
    await eth().request({
      method: "wallet_watchAsset",
      params: { type: "ERC20", options: { address: VAULT, symbol: "mbLP", decimals: 18 } },
    });
  } catch (e) {
    showNotice(explain(e));
  }
}

/** Send a transaction and report progress; returns true when it confirmed. */
export async function sendTx(
  label: string,
  write: () => Promise<Hash>,
  status: (html: string, isError?: boolean) => void,
): Promise<boolean> {
  if (wallet.busy) return false;
  wallet.busy = true;
  emit();
  status(`${label}: confirm in your wallet…`);
  let hash: Hash | undefined;
  try {
    await ensureChain();
    hash = await write();
    status(`${label}: sent ${txLink(hash)}, waiting for the block…`);
    const receipt = await testnet.waitForTransactionReceipt({ hash, pollingInterval: 2_000, timeout: 180_000 });
    const ok = receipt.status === "success";
    status(ok ? `${label} confirmed ${txLink(hash)}` : `${label} reverted ${txLink(hash)}`, !ok);
    return ok;
  } catch (e) {
    status(esc(explain(e)) + (hash ? ` ${txLink(hash)}` : ""), true);
    return false;
  } finally {
    wallet.busy = false;
    emit();
  }
}
