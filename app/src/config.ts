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

export const VAULT = "0x187958091532733eF2f8703F8029Cd72aA85B2d4" as const;
export const VAULT_DEPLOY_BLOCK = 16_249_561n;
export const MUSD = "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503" as const;
export const GITHUB = "https://github.com/GuTS805/Akindo";

/** Mainnet contracts used only to show what the same strategy earns there today. */
export const MAINNET = {
  priceFeed: "0xc5aC5A8892230E0A3e1c473881A2de7353fFcA88",
  btcMusdPool: "0x52e604c44417233b6CcEDDDc0d640A405Caacefb",
  btcMusdGauge: "0x8Be20a5fF57E381025aE5E3A121B697269569AaF",
  mezoBtcClPool: "0x907D055978943c69cffD5eD969F5603Af104aCc5", // token0 BTC, token1 MEZO
} as const;

export const erc20Abi = parseAbi([
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
]);
