import { defineChain, parseAbi } from "viem";

const multicall3 = { address: "0xcA11bde05977b3631167028862bE2a173976CA11" as const };

export const mezoTestnet = defineChain({
  id: 31611,
  name: "Mezo Testnet",
  nativeCurrency: { name: "Bitcoin", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.test.mezo.org"] } },
  blockExplorers: { default: { name: "Mezo Explorer", url: "https://explorer.test.mezo.org" } },
  contracts: { multicall3 },
  testnet: true,
});

export const mezoMainnet = defineChain({
  id: 31612,
  name: "Mezo",
  nativeCurrency: { name: "Bitcoin", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc-http.mezo.boar.network"] } },
  blockExplorers: { default: { name: "Mezo Explorer", url: "https://explorer.mezo.org" } },
  contracts: { multicall3 },
});

/**
 * Two deployments of the same vault contract. The official testnet BTC/MUSD gauge has no
 * emissions (only Mezo's Voter can fund it), so the second one stakes in a RewardGauge that
 * streams testnet MEZO, which is where harvest and claim actually pay out.
 */
export const VAULTS = {
  v2: {
    id: "v2",
    label: "v2",
    address: "0x652e31Ba2658CC27ff0E36431cA008De7D439102",
    deployBlock: 16_262_383n,
    gauge: "0x204ef88B33e5d35De7b52F8c1FFa58cf89d4f45b",
    rewardSymbol: "MEZO",
    hasCap: true,
    gaugeNote:
      "v2: a deposit pays its own MUSD borrowing fee, 2 BTC cap, fees go to the incentive router. Streams testnet MEZO.",
  },
  rewards: {
    id: "rewards",
    label: "v1",
    address: "0xc41192A186C0ee2F593D611b0D0C00501B5Eea03",
    deployBlock: 16_252_391n,
    gauge: "0x204ef88B33e5d35De7b52F8c1FFa58cf89d4f45b",
    rewardSymbol: "MEZO",
    hasCap: false,
    gaugeNote: "v1: stakes in a reward gauge that streams testnet MEZO, so rewards accrue and can be claimed.",
  },
  official: {
    id: "official",
    label: "Official",
    address: "0x187958091532733eF2f8703F8029Cd72aA85B2d4",
    deployBlock: 16_249_561n,
    gauge: "0xeF07B6852f4F877fB3BBD90b8f358Fb3E07D0Cc3",
    rewardSymbol: "BTC", // Mezo's testnet gauges pay in the BTC precompile
    hasCap: false,
    gaugeNote: "Stakes in Mezo's official testnet BTC/MUSD gauge, which has no emissions on testnet.",
  },
} as const;
export type VaultId = keyof typeof VAULTS;

const VAULT_KEY = "mblp.vault";
const DEFAULT_VAULT: VaultId = "v2";

/** Selected with ?vault=<id> (remembered) or a previous choice; pages reload to switch. */
function pickVault(): VaultId {
  const isId = (v: string | null): v is VaultId => !!v && v in VAULTS;
  const fromUrl = new URLSearchParams(location.search).get("vault");
  try {
    if (isId(fromUrl)) localStorage.setItem(VAULT_KEY, fromUrl);
    const saved = localStorage.getItem(VAULT_KEY);
    if (isId(saved)) return saved;
  } catch {
    /* storage blocked */
  }
  return isId(fromUrl) ? fromUrl : DEFAULT_VAULT;
}

export const ACTIVE_VAULT = VAULTS[pickVault()];
export const VAULT = ACTIVE_VAULT.address;
export const VAULT_DEPLOY_BLOCK = ACTIVE_VAULT.deployBlock;

export function selectVault(id: VaultId) {
  try {
    localStorage.setItem(VAULT_KEY, id);
  } catch {
    /* storage blocked: the URL still carries it */
  }
  const url = new URL(location.href);
  url.searchParams.set("vault", id);
  location.href = url.toString();
}
export const MUSD = "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503" as const;
export const GITHUB = "https://github.com/GuTS805/Akindo";

/** Mainnet contracts used only to show what the same strategy earns there today. */
export const MAINNET = {
  priceFeed: "0xc5aC5A8892230E0A3e1c473881A2de7353fFcA88",
  btcMusdPool: "0x52e604c44417233b6CcEDDDc0d640A405Caacefb",
  btcMusdGauge: "0x8Be20a5fF57E381025aE5E3A121B697269569AaF",
  mezoBtcClPool: "0x907D055978943c69cffD5eD969F5603Af104aCc5", // token0 BTC, token1 MEZO
  clBtcMusdPool: "0x9CBc1537d255768b431488305b1C7EFc2ac95022", // concentrated, tick spacing 200
  clBtcMusdGauge: "0x21d7AcB0D128fA039064B6aCe8Db88c0aDe0209E",
  musd: "0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186",
  veBtc: "0x3D4b1b884A7a1E59fE8589a3296EC8f8cBB6f279",
} as const;

export const TESTNET = {
  borrowerOperations: "0xCdF7028ceAB81fA0C6971208e83fa7872994beE5",
  troveManager: "0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0",
  priceFeed: "0x86bCF0841622a5dAC14A313a15f96A95421b9366",
  router: "0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9",
  pool: "0xd16A5Df82120ED8D626a1a15232bFcE2366d6AA9",
  gauge: "0xeF07B6852f4F877fB3BBD90b8f358Fb3E07D0Cc3",
  btc: "0x7b7C000000000000000000000000000000000000",
  musd: "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503",
} as const;

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
]);

export const gaugeStreamAbi = parseAbi([
  "function rewardRate() view returns (uint256)",
  "function periodFinish() view returns (uint256)",
  "function earned(address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
]);

export const poolAbi = parseAbi([
  "function getReserves() view returns (uint256, uint256, uint256)",
  "function totalSupply() view returns (uint256)",
  "function token0() view returns (address)",
]);

export const gaugeAbi = parseAbi([
  "function rewardRate() view returns (uint256)",
  "function periodFinish() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
]);

export const priceFeedAbi = parseAbi(["function fetchPrice() view returns (uint256)"]);

export const borrowerOpsAbi = parseAbi(["function minNetDebt() view returns (uint256)"]);

export const clPoolAbi = parseAbi([
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool)",
  "function liquidity() view returns (uint128)",
  "function stakedLiquidity() view returns (uint128)",
]);
