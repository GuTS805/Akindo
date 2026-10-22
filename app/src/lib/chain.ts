import {
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  createPublicClient,
  custom,
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

const mezoTestnetRpc = createPublicClient({ chain: mezoTestnet, transport: http(undefined, { retryCount: 1, timeout: 10_000 }) });
const drpcTestnet = createPublicClient({ chain: mezoTestnet, transport: http("https://mezo-testnet.drpc.org", { timeout: 10_000 }) });

/**
 * rpc.test.mezo.org spreads requests over several backends, and one of them has run days behind
 * (about 99,000 blocks in October 2026). It answers "latest" with old state (a funded wallet at
 * zero, a new vault with no code), reports an old block number, and returns an empty list for
 * logs past its head. So reads are pinned to the highest block seen from several samples: a
 * lagging backend then rejects the block and the request is retried, and an empty log query is
 * asked again before it is believed.
 */
let head = 0n;
let headAt = 0;
let headPending: Promise<bigint> | undefined;
const hex = (n: bigint) => `0x${n.toString(16)}`;
function freshHead(): Promise<bigint> {
  if (head > 0n && Date.now() - headAt < 6_000) return Promise.resolve(head);
  const sample = () => mezoTestnetRpc.request({ method: "eth_blockNumber" });
  headPending ??= Promise.allSettled([sample(), sample(), sample(), sample()])
    .then(async (rs) => {
      let seen = 0n;
      for (const r of rs) if (r.status === "fulfilled" && BigInt(r.value) > seen) seen = BigInt(r.value);
      if (seen === 0n) seen = BigInt(await drpcTestnet.request({ method: "eth_blockNumber" }));
      // A few blocks back: every current backend has them, the lagging one does not.
      if (seen - 3n > head) head = seen - 3n;
      headAt = Date.now();
      return head;
    })
    .finally(() => (headPending = undefined));
  return headPending;
}
const LAGGING = /must be less than or equal to the current block|header not found|unknown block|block not found|missing trie node/i;
/** Position of the block-tag parameter for state reads. */
const BLOCK_ARG: Record<string, number> = { eth_call: 1, eth_estimateGas: 1, eth_getBalance: 1, eth_getCode: 1, eth_getTransactionCount: 1, eth_getStorageAt: 2 };

async function guarded({ method, params }: { method: string; params?: unknown }): Promise<unknown> {
  const p = Array.isArray(params) ? [...params] : [];
  // Mezo's RPC first; drpc only when Mezo's cannot be reached (drpc's testnet endpoint no longer
  // serves eth_call or eth_getLogs, so it cannot stand in for those).
  const send = () =>
    (mezoTestnetRpc.request({ method, params: p } as never) as Promise<unknown>).catch((e) => {
      if (LAGGING.test(String((e as Error)?.message ?? e))) throw e;
      return drpcTestnet.request({ method, params: p } as never) as Promise<unknown>;
    });
  if (method === "eth_blockNumber") return hex(await freshHead());
  if (method === "eth_getBlockByNumber" && (p[0] === "latest" || p[0] === undefined)) p[0] = hex(await freshHead());
  const at = BLOCK_ARG[method];
  if (at !== undefined && (p[at] === undefined || p[at] === "latest")) p[at] = hex(await freshHead());
  if (method === "eth_getLogs" && p[0] && typeof p[0] === "object") {
    const f = { ...(p[0] as Record<string, unknown>) };
    if (f.toBlock === undefined || f.toBlock === "latest") f.toBlock = hex(await freshHead());
    p[0] = f;
  }
  for (let attempt = 0; ; attempt++) {
    try {
      const out = await send();
      // An empty log list may come from the lagging backend: ask twice more before believing it.
      if (method === "eth_getLogs" && Array.isArray(out) && out.length === 0 && attempt < 2) continue;
      // So may a missing block at a height the chain has reached.
      if (method === "eth_getBlockByNumber" && out == null && attempt < 3) continue;
      return out;
    } catch (e) {
      if (attempt < 4 && LAGGING.test(String((e as Error)?.message ?? e))) continue;
      throw e;
    }
  }
}

export const testnet = createPublicClient({
  chain: mezoTestnet,
  transport: custom({ request: guarded }, { retryCount: 0 }),
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
  /** Max vault value in BTC after a deposit (v2); 0 = no cap. */
  depositCap: bigint;
  /** What the vault's gauge is streaming right now (rate per second, until `finish`). */
  stream: { rate: bigint; finish: number; pending: bigint; staked: bigint; gaugeTotal: bigint; readAt: number };
};

export type UserState = { btc: bigint; shares: bigint; claimable: bigint; musd: bigint };

const read = <T>(functionName: string, args?: readonly unknown[], blockNumber?: bigint) =>
  testnet.readContract({ address: VAULT, abi: vaultAbi, functionName, args, blockNumber } as never) as Promise<T>;

export async function readVault(): Promise<VaultState> {
  const [snap, supply, needsRebalance, minCR, targetCR, maxCR, maxDeviationBps, feeBps, minDeposit, rewardToken, borrowerOps, rewardReserve] =
    await Promise.all([
      // Only the vault's own "oracle unavailable" revert means a stale price; RPC errors propagate.
      read<Snapshot>("snapshot").catch((e) => {
        if (revertName(e) === "OracleUnavailable") return undefined;
        throw e;
      }),
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
  const depositCap = ACTIVE_VAULT.hasCap ? await read<bigint>("depositCap") : 0n;
  // The testnet gauge pays in BTC (the precompile); mainnet gauges pay MEZO.
  const rewardSymbol = rewardToken.toLowerCase() === "0x7b7c000000000000000000000000000000000000" ? "BTC" : "MEZO";
  const gauge = { address: ACTIVE_VAULT.gauge, abi: gaugeStreamAbi } as const;
  const [minNetDebt, rate, finish, pending, staked, gaugeTotal] = await Promise.all([
    testnet.readContract({ address: borrowerOps, abi: borrowerOpsAbi, functionName: "minNetDebt" }),
    testnet.readContract({ ...gauge, functionName: "rewardRate" }).catch(() => 0n),
    testnet.readContract({ ...gauge, functionName: "periodFinish" }).catch(() => 0n),
    testnet.readContract({ ...gauge, functionName: "earned", args: [VAULT] }).catch(() => 0n),
    testnet.readContract({ ...gauge, functionName: "balanceOf", args: [VAULT] }).catch(() => 0n),
    testnet.readContract({ ...gauge, functionName: "totalSupply" }).catch(() => 0n),
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
    depositCap,
    stream: { rate: live ? rate : 0n, finish: Number(finish), pending, staked, gaugeTotal, readAt: Date.now() },
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

/** Reward tokens per second (as a float) that `shares` earn right now, after the vault fee. */
export function rewardsPerSecond(v: VaultState, shares: bigint): number {
  const { rate, staked, gaugeTotal } = v.stream;
  if (rate === 0n || gaugeTotal === 0n || v.supply === 0n) return 0;
  const toVault = (rate * staked) / gaugeTotal;
  const afterFee = (toVault * (10_000n - v.feeBps)) / 10_000n;
  return Number((afterFee * shares) / v.supply) / 1e18;
}

/** Claimable rewards extrapolated from the last read, so the number can tick between reads. */
export function claimableNow(v: VaultState, u: UserState): number {
  const perSec = rewardsPerSecond(v, u.shares);
  const secs = Math.max(0, Math.min(Date.now() / 1000, v.stream.finish) - v.stream.readAt / 1000);
  return Number(u.claimable) / 1e18 + perSec * secs;
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

/** Mezo's testnet RPC serves at most 10,000 blocks of logs per request. */
const LOG_RANGE = 10_000n;
const LOG_CONCURRENCY = 4;

/** All vault events since deployment, newest first, with block times. Throws if any range fails. */
export async function readEvents(user?: Address): Promise<VaultEvent[]> {
  const latest = await testnet.getBlockNumber();
  const ranges: [bigint, bigint][] = [];
  for (let from = VAULT_DEPLOY_BLOCK; from <= latest; from += LOG_RANGE) {
    const to = from + LOG_RANGE - 1n;
    ranges.push([from, to < latest ? to : latest]);
  }
  const chunks: Awaited<ReturnType<typeof vaultLogs>>[] = [];
  for (let i = 0; i < ranges.length; i += LOG_CONCURRENCY) {
    chunks.push(...(await Promise.all(ranges.slice(i, i + LOG_CONCURRENCY).map(([f, t]) => vaultLogs(f, t)))));
  }
  const logs = chunks.flat().filter((l) => (EVENT_NAMES as readonly string[]).includes(l.eventName));
  const mine = user
    ? logs.filter((l) => String((l.args as Record<string, unknown>).user ?? "").toLowerCase() === user.toLowerCase())
    : logs;
  const blocks = [...new Set(mine.map((l) => l.blockNumber!))];
  const times = new Map(
    await Promise.all(
      blocks.map(
        async (n) => [n, (await testnet.getBlock({ blockNumber: n })).timestamp] as const,
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

/** Every vault event in one block range, retried once (the public RPC drops the odd request). */
function vaultLogs(fromBlock: bigint, toBlock: bigint) {
  const get = () => testnet.getContractEvents({ address: VAULT, abi: vaultAbi, fromBlock, toBlock });
  return get().catch(get);
}

export type PricePoint ={ time: number; pps: number; navBtc: number };

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
  DepositCapReached: "This deposit would take the vault past its deposit cap.",
};

function revertName(e: unknown): string | undefined {
  if (!(e instanceof BaseError)) return undefined;
  const revert = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
  return revert?.data?.errorName;
}

export function explain(e: unknown): string {
  if (e instanceof BaseError && e.name === "WaitForTransactionReceiptTimeoutError")
    return "Still waiting for the block after 3 minutes. The transaction may yet confirm: check the explorer before sending it again.";
  if (e instanceof BaseError) {
    if (e.walk((x) => x instanceof UserRejectedRequestError)) return "Cancelled in your wallet.";
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName;
    if (name && ERRORS[name]) return ERRORS[name];
    if (revert?.reason) return `Reverted: ${revert.reason}`;
    // Generic wrappers ("An unknown RPC error occurred") hide the wallet's own reason in `details`.
    return e.details && e.details !== e.shortMessage ? `${e.shortMessage} ${e.details}` : e.shortMessage;
  }
  const code = (e as { code?: number })?.code;
  if (code === 4001) return "Cancelled in your wallet.";
  if (code === -32002)
    return "Your wallet already has a request waiting. Click its icon in the browser toolbar (the MetaMask fox), finish or reject it, then try again.";
  if (code === 4100) return "Your wallet is locked or has not authorised this site. Unlock it and try again.";
  return e instanceof Error ? e.message : String(e);
}
