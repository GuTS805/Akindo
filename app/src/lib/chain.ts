import {
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  createPublicClient,
  fallback,
  formatUnits,
  http,
  type Address,
} from "viem";
import {
  ACTIVE_VAULT,
  MAINNET,
  MUSD,
  VAULT,
  VAULT_DEPLOY_BLOCK,
  borrowerOpsAbi,
  clPoolAbi,
  erc20Abi,
  gaugeAbi,
  gaugeStreamAbi,
  mezoMainnet,
  mezoTestnet,
  poolAbi,
  priceFeedAbi,
} from "../config";
import { vaultAbi } from "../vaultAbi";
import { ratio } from "./format";

export const WAD = 10n ** 18n;

export const testnet = createPublicClient({
  chain: mezoTestnet,
  transport: http(undefined, { retryCount: 2, timeout: 20_000 }),
  batch: { multicall: true },
});

// Measured: validationcloud and drpc answer 16 parallel calls in under a second; boar drops
// requests beyond ~12 at once, so it is the last fallback. No multicall batching on mainnet.
export const mainnet = createPublicClient({
  chain: mezoMainnet,
  transport: fallback(
    [
      http("https://mainnet.mezo.public.validationcloud.io", { timeout: 8_000, retryCount: 1 }),
      http("https://mezo.drpc.org", { timeout: 8_000, retryCount: 1 }),
      http("https://rpc-http.mezo.boar.network", { timeout: 8_000, retryCount: 1 }),
    ],
    { rank: false },
  ),
});

// ---------------------------------------------------------------- vault

export type Snapshot = {
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

export type VaultState = {
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
  rewardReserve: bigint;
  /** What the vault's gauge is streaming right now (rate per second, until `finish`). */
  stream: { rate: bigint; finish: number; pending: bigint };
};

export type UserState = { btc: bigint; shares: bigint; claimable: bigint; musd: bigint };

const read = <T>(functionName: string, args?: readonly unknown[], blockNumber?: bigint) =>
  testnet.readContract({ address: VAULT, abi: vaultAbi, functionName, args, blockNumber } as never) as Promise<T>;

export async function readVault(): Promise<VaultState> {
  const [snap, supply, needsRebalance, minCR, targetCR, maxCR, maxDeviationBps, feeBps, minDeposit, rewardToken, borrowerOps, rewardReserve] =
    await Promise.all([
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
      read<Address>("borrowerOperations"),
      read<bigint>("rewardReserve"),
    ]);
  // The testnet gauge pays in BTC (the precompile); mainnet gauges pay MEZO.
  const rewardSymbol = rewardToken.toLowerCase() === "0x7b7c000000000000000000000000000000000000" ? "BTC" : "MEZO";
  const gauge = { address: ACTIVE_VAULT.gauge, abi: gaugeStreamAbi } as const;
  const [minNetDebt, rate, finish, pending] = await Promise.all([
    testnet.readContract({ address: borrowerOps, abi: borrowerOpsAbi, functionName: "minNetDebt" }),
    testnet.readContract({ ...gauge, functionName: "rewardRate" }).catch(() => 0n),
    testnet.readContract({ ...gauge, functionName: "periodFinish" }).catch(() => 0n),
    testnet.readContract({ ...gauge, functionName: "earned", args: [VAULT] }).catch(() => 0n),
  ]);
  const live = Number(finish) * 1000 > Date.now();
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
    rewardReserve,
    stream: { rate: live ? rate : 0n, finish: Number(finish), pending },
  };
}

export async function readUser(a: Address): Promise<UserState> {
  const [bal, shares, claimable, musd] = await Promise.all([
    testnet.getBalance({ address: a }),
    read<bigint>("balanceOf", [a]),
    read<bigint>("claimable", [a]),
    testnet.readContract({ address: MUSD, abi: erc20Abi, functionName: "balanceOf", args: [a] }),
  ]);
  return { btc: bal, shares, claimable, musd };
}

export function navBtc(v: VaultState): bigint {
  return v.snap && v.snap.price > 0n ? (v.snap.navMusd * WAD) / v.snap.price : 0n;
}

export function shareValueBtc(v: VaultState, shares: bigint): bigint {
  return v.supply === 0n ? 0n : (navBtc(v) * shares) / v.supply;
}

export function collateralRatio(s: Snapshot): number {
  return s.troveActive && s.debt > 0n ? ratio(s.coll * s.price, s.debt * WAD) : 0;
}

export function poolGap(s: Snapshot): number {
  return s.poolPrice === 0n ? 0 : ratio(s.poolPrice, s.price) - 1;
}

// ---------------------------------------------------------------- events

export type VaultEvent = {
  name: "Deposit" | "Withdraw" | "Rebalance" | "Harvest" | "RewardClaimed" | "Unwound";
  args: Record<string, bigint | string>;
  block: bigint;
  tx: string;
  time: bigint;
};

const EVENT_NAMES = ["Deposit", "Withdraw", "Rebalance", "Harvest", "RewardClaimed", "Unwound"] as const;

/** All vault events since deployment, newest first, with block times. */
export async function readEvents(user?: Address): Promise<VaultEvent[]> {
  const logs = (
    await Promise.all(
      EVENT_NAMES.map((eventName) =>
        testnet
          .getContractEvents({ address: VAULT, abi: vaultAbi, eventName, fromBlock: VAULT_DEPLOY_BLOCK })
          .catch(() => []),
      ),
    )
  ).flat();
  const mine = user
    ? logs.filter((l) => String((l.args as Record<string, unknown>).user ?? "").toLowerCase() === user.toLowerCase())
    : logs;
  const blocks = [...new Set(mine.map((l) => l.blockNumber!))];
  const times = new Map(
    await Promise.all(
      blocks.map(
        async (n) => [n, await testnet.getBlock({ blockNumber: n }).then((b) => b.timestamp).catch(() => 0n)] as const,
      ),
    ),
  );
  return mine
    .map((l) => ({
      name: l.eventName as VaultEvent["name"],
      args: l.args as Record<string, bigint | string>,
      block: l.blockNumber!,
      tx: l.transactionHash!,
      time: times.get(l.blockNumber!) ?? 0n,
    }))
    .sort((a, b) => Number(b.block - a.block) || 0);
}

export type PricePoint = { time: number; pps: number; navBtc: number };

/** Share price sampled at evenly spaced blocks since the first deposit (needs historical state). */
export async function readShareHistory(firstBlock: bigint, samples = 24): Promise<PricePoint[]> {
  const latest = await testnet.getBlockNumber();
  if (latest <= firstBlock) return [];
  const step = (latest - firstBlock) / BigInt(samples - 1) || 1n;
  const blocks: bigint[] = [];
  for (let b = firstBlock; b <= latest; b += step) blocks.push(b);
  if (blocks[blocks.length - 1] !== latest) blocks.push(latest);

  const points = await Promise.all(
    blocks.map(async (b) => {
      try {
        const [pps, supply, block] = await Promise.all([
          read<bigint>("pricePerShare", [], b),
          read<bigint>("totalSupply", [], b),
          testnet.getBlock({ blockNumber: b }),
        ]);
        return {
          time: Number(block.timestamp),
          pps: Number(formatUnits(pps, 18)),
          navBtc: Number(formatUnits((pps * supply) / WAD, 18)),
        };
      } catch {
        return undefined;
      }
    }),
  );
  return points.filter((p): p is PricePoint => !!p);
}

// ---------------------------------------------------------------- Mezo mainnet market

export type Market = {
  price: number; // BTC in MUSD
  mezoPrice: number; // MEZO in MUSD
  musdSupply: number;
  veBtcLocked: number; // BTC
  vamm: { tvl: number; btc: number; staked: number; perDay: number; apr: number };
  cl: { tvl: number; btc: number; stakedShare: number; perDay: number; apr: number };
};

const YEAR = 31_536_000n;

const MARKET_KEY = "mblp.market";
const MARKET_TTL_MS = 3 * 60_000;

/** Live Mezo mainnet market; cached for a few minutes so moving between pages is instant. */
export async function readMarket(): Promise<Market> {
  try {
    const hit = JSON.parse(sessionStorage.getItem(MARKET_KEY) ?? "null") as { at: number; m: Market } | null;
    if (hit && Date.now() - hit.at < MARKET_TTL_MS) return hit.m;
  } catch {
    /* storage unavailable */
  }
  const m = await fetchMarket();
  try {
    sessionStorage.setItem(MARKET_KEY, JSON.stringify({ at: Date.now(), m }));
  } catch {
    /* storage unavailable */
  }
  return m;
}

async function fetchMarket(): Promise<Market> {
  const g = MAINNET.btcMusdGauge;
  const cg = MAINNET.clBtcMusdGauge;
  const cp = MAINNET.clBtcMusdPool;
  // One parallel round: total time is the slowest single call.
  const [
    price,
    slot0,
    block,
    musdSupply,
    veBtc,
    vRate,
    vFinish,
    vGaugeSupply,
    vReserves,
    vLpSupply,
    cRate,
    cFinish,
    cBtc,
    cMusd,
    cLiq,
    cStaked,
  ] = await Promise.all([
    mainnet.readContract({ address: MAINNET.priceFeed, abi: priceFeedAbi, functionName: "fetchPrice" }),
    mainnet.readContract({ address: MAINNET.mezoBtcClPool, abi: clPoolAbi, functionName: "slot0" }),
    mainnet.getBlock(),
    mainnet.readContract({ address: MAINNET.musd, abi: erc20Abi, functionName: "totalSupply" }),
    mainnet.getBalance({ address: MAINNET.veBtc }),
    mainnet.readContract({ address: g, abi: gaugeAbi, functionName: "rewardRate" }),
    mainnet.readContract({ address: g, abi: gaugeAbi, functionName: "periodFinish" }),
    mainnet.readContract({ address: g, abi: gaugeAbi, functionName: "totalSupply" }),
    mainnet.readContract({ address: MAINNET.btcMusdPool, abi: poolAbi, functionName: "getReserves" }),
    mainnet.readContract({ address: MAINNET.btcMusdPool, abi: poolAbi, functionName: "totalSupply" }),
    mainnet.readContract({ address: cg, abi: gaugeAbi, functionName: "rewardRate" }),
    mainnet.readContract({ address: cg, abi: gaugeAbi, functionName: "periodFinish" }),
    mainnet.getBalance({ address: cp }),
    mainnet.readContract({ address: MAINNET.musd, abi: erc20Abi, functionName: "balanceOf", args: [cp] }),
    mainnet.readContract({ address: cp, abi: clPoolAbi, functionName: "liquidity" }),
    mainnet.readContract({ address: cp, abi: clPoolAbi, functionName: "stakedLiquidity" }),
  ]);
  const sqrtP = slot0[0];
  const mezoPriceWad = (price * 2n ** 192n) / (sqrtP * sqrtP); // MUSD per MEZO
  const f = (x: bigint) => Number(formatUnits(x, 18));
  const mezoPrice = f(mezoPriceWad);
  const live = (finish: bigint) => block.timestamp < finish;

  // Volatile BTC/MUSD pool (token0 = BTC)
  const vTvl = f((vReserves[0] * price) / WAD + vReserves[1]);
  const vStaked = vLpSupply === 0n ? 0 : (vTvl * f(vGaugeSupply)) / f(vLpSupply);
  const vRateNow = live(vFinish) ? vRate : 0n;

  // Concentrated BTC/MUSD pool: value from token balances, staked share from liquidity
  const cTvl = f((cBtc * price) / WAD + cMusd);
  const cStakedShare = cLiq === 0n ? 0 : Number(cStaked) / Number(cLiq);
  const cRateNow = live(cFinish) ? cRate : 0n;

  const apr = (rate: bigint, stakedValue: number) => (stakedValue > 0 ? (f(rate * YEAR) * mezoPrice) / stakedValue : 0);

  return {
    price: f(price),
    mezoPrice,
    musdSupply: f(musdSupply),
    veBtcLocked: f(veBtc),
    vamm: {
      tvl: vTvl,
      btc: f(vReserves[0]),
      staked: vStaked,
      perDay: f(vRateNow * 86_400n),
      apr: apr(vRateNow, vStaked),
    },
    cl: {
      tvl: cTvl,
      btc: f(cBtc),
      stakedShare: cStakedShare,
      perDay: f(cRateNow * 86_400n),
      apr: apr(cRateNow, cTvl * cStakedShare),
    },
  };
}

/** What a vault depositor earns from a given LP APR: the LP share of value, net of the fee. */
export function depositorApr(lpApr: number, v?: VaultState): number {
  const lpShare = v?.snap && v.snap.navMusd > 0n ? ratio(v.snap.lpFairValue, v.snap.navMusd) : 0.5;
  const fee = Number(v?.feeBps ?? 1000n) / 10_000;
  return lpApr * lpShare * (1 - fee);
}

// ---------------------------------------------------------------- errors

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

export function explain(e: unknown): string {
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
  if (code === -32002)
    return "Your wallet already has a request waiting. Click its icon in the browser toolbar (the MetaMask fox), finish or reject it, then try again.";
  if (code === 4100) return "Your wallet is locked or has not authorised this site. Unlock it and try again.";
  return e instanceof Error ? e.message : String(e);
}
