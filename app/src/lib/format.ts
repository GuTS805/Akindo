import { formatUnits } from "viem";
import { mezoTestnet } from "../config";

export const EXPLORER = mezoTestnet.blockExplorers.default.url;

export function btc(wei: bigint, dp = 8): string {
  const neg = wei < 0n;
  const [i, f = ""] = formatUnits(neg ? -wei : wei, 18).split(".");
  const whole = `${neg ? "-" : ""}${BigInt(i).toLocaleString("en-US")}`;
  return dp === 0 ? whole : `${whole}.${(f + "0".repeat(dp)).slice(0, dp)}`;
}

export function sats(wei: bigint): string {
  return `${(wei / 10n ** 10n).toLocaleString("en-US")} sats`;
}

export function musd(wei: bigint, dp = 0): string {
  return Number(formatUnits(wei, 18)).toLocaleString("en-US", { maximumFractionDigits: dp, minimumFractionDigits: dp });
}

export function num(x: number, dp = 0): string {
  return x.toLocaleString("en-US", { maximumFractionDigits: dp, minimumFractionDigits: dp });
}

export function pct(x: number, dp = 1): string {
  return `${(x * 100).toFixed(dp)}%`;
}

export function ratio(a: bigint, b: bigint): number {
  return b === 0n ? 0 : Number((a * 1_000_000n) / b) / 1_000_000;
}

export function short(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function ago(ts: bigint): string {
  if (ts === 0n) return "";
  const s = Math.max(0, Math.floor(Date.now() / 1000) - Number(ts));
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86_400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86_400)}d ago`;
}

/** Text that goes into innerHTML (error messages can carry revert strings from the chain). */
export function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

export function txLink(hash: string): string {
  return `<a href="${EXPLORER}/tx/${hash}" target="_blank" rel="noopener">${short(hash)}</a>`;
}

export function addressLink(address: string, label = short(address)): string {
  return `<a href="${EXPLORER}/address/${address}" target="_blank" rel="noopener">${label}</a>`;
}

export const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
