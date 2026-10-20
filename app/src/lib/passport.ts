import "./node-globals";
import { connect, createConfig, disconnect, getConnectorClient, http, type Connector } from "@wagmi/core";
import { okxWalletMezoTestnet, unisatWalletMezoTestnet, xverseWalletMezoTestnet } from "@mezo-org/passport";
import type { Address, EIP1193Provider, Hex } from "viem";
import { mezoTestnet } from "../config";
import { testnet } from "./chain";

/**
 * Bitcoin wallets through Mezo Passport. Passport's connectors (OrangeKit) give each Bitcoin
 * wallet a Mezo smart account: the Bitcoin wallet signs, the smart account sends the Mezo
 * transaction through Mezo's relayer. The rest of the app speaks EIP-1193, so the connected
 * account is wrapped in a small provider: transactions go to the smart account, reads go to
 * the Mezo RPC.
 */
export const BITCOIN_WALLETS = [
  { id: "unisat", name: "Unisat", create: unisatWalletMezoTestnet },
  { id: "okx", name: "OKX Wallet", create: okxWalletMezoTestnet },
  { id: "xverse", name: "Xverse", create: xverseWalletMezoTestnet },
] as const;
export type BitcoinWalletId = (typeof BITCOIN_WALLETS)[number]["id"];

/**
 * Passport's testnet relayer host, test.mezo.org, no longer resolves (Cloudflare error 1000 as of
 * October 2026). Mezo's testnet relayer answers at testnet.mezo.org, with CORS open to this app,
 * and is still relaying Safe transactions. Passport has no option to change the host and calls
 * two paths under it (/transactions, and /deploy-safe for a new smart account), so every request
 * under the relay prefix is redirected.
 */
const DEAD_RELAY = "https://test.mezo.org/api/v2/relay/";
const LIVE_RELAY = "https://testnet.mezo.org/api/v2/relay/";
export function redirectRelay(url: string): string {
  return url.startsWith(DEAD_RELAY) ? LIVE_RELAY + url.slice(DEAD_RELAY.length) : url;
}
const nativeFetch = window.fetch.bind(window);
window.fetch = (input, init) => {
  if (typeof input === "string") return nativeFetch(redirectRelay(input), init);
  if (input instanceof URL) return nativeFetch(redirectRelay(input.href), init);
  if (input instanceof Request && input.url.startsWith(DEAD_RELAY)) return nativeFetch(new Request(redirectRelay(input.url), input), init);
  return nativeFetch(input, init);
};

type SmartAccountClient = {
  sendTransaction(tx: { to?: Address; value?: bigint; data?: Hex }): Promise<Hex>;
};

let config: ReturnType<typeof createConfig> | undefined;
const connectors = new Map<BitcoinWalletId, Connector>();

function setup() {
  if (config) return config;
  const created = BITCOIN_WALLETS.map((w) => {
    const wallet = w.create();
    return { id: w.id, installed: wallet.installed !== false, fn: (wallet.createConnector as () => never)() };
  });
  config = createConfig({
    chains: [mezoTestnet],
    connectors: created.map((c) => c.fn),
    transports: { [mezoTestnet.id]: http(mezoTestnet.rpcUrls.default.http[0]) },
  });
  config.connectors.forEach((c, i) => connectors.set(created[i].id, c));
  return config;
}

/** Connect a Bitcoin wallet and return its Mezo smart-account address plus an EIP-1193 provider. */
export async function connectBitcoinWallet(id: BitcoinWalletId): Promise<{ account: Address; provider: EIP1193Provider }> {
  const cfg = setup();
  const connector = connectors.get(id);
  if (!connector) throw new Error("Unknown Bitcoin wallet.");
  const result = await connect(cfg, { connector, chainId: mezoTestnet.id });
  const account = result.accounts[0];
  const client = (await getConnectorClient(cfg, { connector, chainId: mezoTestnet.id })) as unknown as SmartAccountClient;

  const provider = {
    async request({ method, params }: { method: string; params?: unknown[] }) {
      switch (method) {
        case "eth_accounts":
        case "eth_requestAccounts":
          return [account];
        case "eth_chainId":
          return `0x${mezoTestnet.id.toString(16)}`;
        case "wallet_switchEthereumChain":
          return null;
        case "eth_sendTransaction": {
          const tx = (params?.[0] ?? {}) as { to?: Address; value?: Hex; data?: Hex };
          const hash = await client.sendTransaction({ to: tx.to, value: tx.value ? BigInt(tx.value) : 0n, data: tx.data ?? "0x" });
          // On a relayer error Passport returns "0x" instead of throwing.
          if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) {
            throw new Error("Mezo's relayer did not accept the transaction. Check the smart account has testnet BTC, then try again.");
          }
          return hash;
        }
        case "wallet_watchAsset":
        case "wallet_addEthereumChain":
          throw Object.assign(new Error("Not supported by Bitcoin wallets."), { code: 4200 });
        default:
          return testnet.request({ method, params } as never);
      }
    },
    on() {},
    removeListener() {},
  } as unknown as EIP1193Provider;

  return { account, provider };
}

export async function disconnectBitcoinWallet() {
  if (config) await disconnect(config).catch(() => {});
}
