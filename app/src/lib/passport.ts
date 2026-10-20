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
          return client.sendTransaction({ to: tx.to, value: tx.value ? BigInt(tx.value) : 0n, data: tx.data ?? "0x" });
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
