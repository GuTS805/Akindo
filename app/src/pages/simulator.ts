import { readMarket } from "../lib/chain";
import { lineChart } from "../lib/chart";
import { $, num, pct } from "../lib/format";
import { mountShell } from "../lib/layout";
import { initWallet } from "../lib/wallet";

const TARGET_CR = 3;
const FEE = 0.1;
let days = 180;

type Inputs = { amount: number; r: number; days: number; apr: number; mezo: number; rate: number };

/** Vault outcome in BTC after a price move by factor r, from the target state, without rebalancing. */
function outcome(i: Inputs) {
  // In units of the starting price: NAV0 = amount, debt D = NAV0 / (CR + 1).
  const D = i.amount / (TARGET_CR + 1);
  const t = i.days / 365;
  const coll = TARGET_CR * D * i.r;
  const lp = 2 * D * Math.sqrt(i.r);
  const interest = D * i.rate * t;
  const navNoRewards = coll + lp - D - interest; // in start-price BTC units
  const lpAvg = (2 * D + lp) / 2;
  const rewards = i.apr * lpAvg * (1 - FEE) * t * (1 + i.mezo);
  // Convert to BTC at the new price.
  const toBtc = (x: number) => x / i.r;
  const hold = i.amount;
  const vault = toBtc(navNoRewards + rewards);
  const holdLp = D * i.r + D; // the pool share if held as BTC + MUSD outside the pool
  return {
    hold,
    vault,
    rewards: toBtc(rewards),
    il: toBtc(lp - holdLp),
    interest: -toBtc(interest),
    cr: coll / (D * (1 + i.rate * t)),
  };
}

function inputs(): Inputs {
  const n = (id: string, fallback: number) => {
    const v = parseFloat($<HTMLInputElement>(id).value);
    return Number.isFinite(v) ? v : fallback;
  };
  return {
    amount: Math.max(0, n("i-amount", 0.1)),
    r: 1 + n("i-move", 0) / 100,
    days,
    apr: Math.max(0, n("i-apr", 36)) / 100,
    mezo: n("i-mezo", 0) / 100,
    rate: Math.max(0, n("i-rate", 1)) / 100,
  };
}

const fmt = (x: number, dp = 6) => `${x >= 0 ? "" : "−"}${num(Math.abs(x), dp)} BTC`;
const signed = (x: number, dp = 6) => `${x >= 0 ? "+" : "−"}${num(Math.abs(x), dp)} BTC`;

function render() {
  const i = inputs();
  $("i-move-out").textContent = `${i.r >= 1 ? "+" : ""}${Math.round((i.r - 1) * 100)}%`;
  const o = outcome(i);
  const diff = o.vault - o.hold;

  $("o-hold").textContent = fmt(o.hold, 5);
  const move = Math.round((i.r - 1) * 100);
  $("o-hold-sub").textContent = move === 0 ? "same BTC, same dollar value" : `same BTC, dollar value ${move > 0 ? "+" : "−"}${Math.abs(move)}%`;
  $("o-vault").textContent = fmt(o.vault, 5);
  $("o-vault-sub").textContent = `${pct(o.vault / o.hold - 1, 2)} vs holding, in BTC`;
  $("o-diff").textContent = signed(diff, 5);
  $("o-diff").className = `value ${diff >= 0 ? "good" : "warn"}`;
  $("o-diff-sub").textContent = `${diff >= 0 ? "ahead of" : "behind"} holding after ${i.days} days`;

  $("o-rewards").textContent = signed(o.rewards);
  $("o-il").textContent = signed(o.il);
  $("o-interest").textContent = signed(o.interest);
  $("o-cr").textContent = `${pct(o.cr, 0)}${o.cr < 2.5 ? " · the keeper would repay debt here" : o.cr > 3.5 ? " · the keeper would borrow more here" : ""}`;

  // Curve across price moves for the chosen period.
  const vaultPts: [number, number][] = [];
  const noRewardPts: [number, number][] = [];
  const holdPts: [number, number][] = [];
  for (let m = -50; m <= 100; m += 5) {
    const r = 1 + m / 100;
    const res = outcome({ ...i, r });
    vaultPts.push([m, res.vault]);
    noRewardPts.push([m, res.vault - res.rewards]);
    holdPts.push([m, res.hold]);
  }
  lineChart(
    $("sim-chart"),
    [
      { name: "mbLP with rewards", points: vaultPts, color: "var(--accent)" },
      { name: "mbLP without rewards", points: noRewardPts, color: "#102144", dashed: true },
      { name: "Hold BTC", points: holdPts, color: "#8a93a6" },
    ],
    { yFormat: (y) => y.toFixed(4), xFormat: (x) => `${x > 0 ? "+" : ""}${Math.round(x)}%`, marker: Math.round((i.r - 1) * 100), xTicks: 6 },
  );
}

async function loadApr() {
  try {
    const m = await readMarket();
    $<HTMLInputElement>("i-apr").value = (m.vamm.apr * 100).toFixed(1);
    $("i-apr-src").textContent = `live: volatile BTC/MUSD gauge, MEZO $${m.mezoPrice.toFixed(4)}`;
  } catch {
    $("i-apr-src").textContent = "mainnet unavailable, using 36%";
  }
  render();
}

function init() {
  mountShell("simulator");
  initWallet();
  for (const id of ["i-amount", "i-move", "i-apr", "i-mezo", "i-rate"]) $(id).addEventListener("input", render);
  document.querySelectorAll<HTMLButtonElement>("#i-days .chip").forEach((c) =>
    c.addEventListener("click", (e) => {
      e.preventDefault();
      days = Number(c.dataset.days);
      document.querySelectorAll("#i-days .chip").forEach((x) => x.classList.toggle("active", x === c));
      render();
    }),
  );
  render();
  loadApr();
}

init();
