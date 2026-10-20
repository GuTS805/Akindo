import {
  WAD,
  collateralRatio,
  depositorApr,
  navBtc,
  poolGap,
  readEvents,
  readMarket,
  readShareHistory,
  readVault,
  type VaultEvent,
  type VaultState,
} from "../lib/chain";
import { lineChart } from "../lib/chart";
import { renderEvents } from "../lib/events";
import { $, ago, btc, musd, num, pct, ratio } from "../lib/format";
import { mountShell } from "../lib/layout";
import { initWallet } from "../lib/wallet";

let vault: VaultState | undefined;
let events: VaultEvent[] = [];
let filter = "all";

function renderVault(v: VaultState) {
  const s = v.snap;
  $("alert").hidden = !!s;
  if (!s) {
    $("alert").textContent = "Mezo's price oracle is stale right now, so live vault values are unavailable.";
    return;
  }
  const nav = navBtc(v);
  $("a-tvl").textContent = `${btc(nav, 4)} BTC`;
  $("a-tvl-sub").textContent = `≈ ${musd(s.navMusd)} MUSD`;
  $("a-pps").textContent = v.supply === 0n ? "1.0000" : btc((nav * WAD) / v.supply, 6);
  const cr = collateralRatio(s);
  $("a-cr").textContent = s.troveActive ? pct(cr, 0) : "No trove";
  $("a-cr-sub").textContent = `band ${pct(ratio(v.minCR, WAD), 0)}–${pct(ratio(v.maxCR, WAD), 0)}`;
  const gap = poolGap(s);
  const band = Number(v.maxDeviationBps) / 10_000;
  $("a-gap").textContent = `${gap >= 0 ? "+" : ""}${pct(gap, 2)}`;
  $("a-gap").className = `value ${Math.abs(gap) <= band ? "good" : "bad"}`;
  $("a-gap-sub").textContent = `band ±${pct(band, 0)}`;

  // Holdings by value
  const collV = (s.coll * s.price) / WAD;
  const lpV = s.lpFairValue;
  const idleV = (s.idleBtc * s.price) / WAD + s.idleMusd;
  const total = collV + lpV + idleV;
  const share = (x: bigint) => (total > 0n ? ratio(x, total) : 0);
  $("a-stack").innerHTML = [
    ["Collateral", collV, "var(--accent)"],
    ["LP", lpV, "#102144"],
    ["Idle", idleV, "#c9b79f"],
  ]
    .map(([name, x, color]) => `<span style="width:${(share(x as bigint) * 100).toFixed(2)}%;background:${color}" title="${name}"></span>`)
    .join("");
  $("a-coll").textContent = `${btc(s.coll, 6)} BTC · ${pct(share(collV), 0)}`;
  $("a-lp").textContent = `${btc(s.lpBtc, 6)} BTC + ${musd(s.lpMusd)} MUSD · ${pct(share(lpV), 0)}`;
  $("a-idle").textContent = `${btc(s.idleBtc, 6)} BTC + ${musd(s.idleMusd)} MUSD`;
  $("a-debt").textContent = `${musd(s.netDebt)} MUSD (+200 MUSD gas reserve)`;
  $("a-cover").textContent = s.netDebt > 0n ? pct(ratio(s.lpMusd + s.idleMusd, s.netDebt), 1) : "–";

  $("k-needs").textContent = v.needsRebalance ? "Yes" : "No";
  $("k-needs").className = v.needsRebalance ? "warn" : "";
  $("k-reserve").textContent = `${btc(v.rewardReserve, 6)} ${v.rewardSymbol}`;
  $("k-stream").textContent =
    v.stream.rate > 0n
      ? `${num(Number(v.stream.rate * 86_400n) / 1e18, 2)} ${v.rewardSymbol}/day until ${new Date(v.stream.finish * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric" })}`
      : "Not streaming";
  $("k-pending").textContent = `${btc(v.stream.pending, 6)} ${v.rewardSymbol}`;
}

function renderHistory() {
  const shown = events.filter((e) =>
    filter === "all" ? true : filter === "rewards" ? e.name === "Harvest" || e.name === "RewardClaimed" : e.name === filter,
  );
  renderEvents($("a-history"), shown);
  const last = events.find((e) => e.name === "Rebalance");
  $("k-last").textContent = last ? ago(last.time) || `block ${last.block}` : "never";
}

async function renderCharts() {
  const deposits = events.filter((e) => e.name === "Deposit");
  if (deposits.length === 0) {
    $("chart-pps").innerHTML = $("chart-nav").innerHTML = `<p class="muted">No deposits yet.</p>`;
    return;
  }
  const first = deposits[deposits.length - 1].block;
  const points = await readShareHistory(first, 24);
  if (points.length < 2) {
    $("chart-pps").innerHTML = $("chart-nav").innerHTML = `<p class="muted">Not enough history yet.</p>`;
    return;
  }
  const span = points[points.length - 1].time - points[0].time;
  const xFormat = (t: number) => {
    const d = new Date(t * 1000);
    return span < 2 * 86_400
      ? d.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit" })
      : d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
  };
  // At least a 1% window, so oracle noise in the 6th decimal reads as the flat line it is.
  lineChart($("chart-pps"), [{ name: "Share price", points: points.map((p) => [p.time, p.pps]), color: "var(--accent)" }], {
    yFormat: (y) => y.toFixed(4),
    xFormat,
    minRelSpan: 0.01,
  });
  lineChart($("chart-nav"), [{ name: "Vault value", points: points.map((p) => [p.time, p.navBtc]), color: "#102144" }], {
    yFormat: (y) => y.toFixed(4),
    xFormat,
    minRelSpan: 0.01,
  });
}

async function renderMarket() {
  try {
    const m = await readMarket();
    const row = (id: string, p: Market["vamm"] | Market["cl"]) => {
      $(`m-${id}-tvl`).textContent = `${num(p.tvl)} MUSD`;
      $(`m-${id}-btc`).textContent = `${num(p.btc, 3)} BTC`;
      $(`m-${id}-day`).textContent = `${num(p.perDay)} MEZO/day`;
      $(`m-${id}-apr`).textContent = pct(p.apr);
      $(`m-${id}-dep`).textContent = `≈ ${pct(depositorApr(p.apr, vault))}`;
    };
    row("v", m.vamm);
    row("c", m.cl);
    $("m-price").textContent = `${num(m.price)} MUSD`;
    $("m-mezo").textContent = `$${m.mezoPrice.toFixed(4)}`;
    $("m-musd").textContent = `${num(m.musdSupply)} MUSD`;
    $("m-vebtc").textContent = `${num(m.veBtcLocked, 1)} BTC`;
  } catch {
    $("m-v-tvl").textContent = "Mainnet RPC unavailable, retrying in a minute";
  }
}

type Market = Awaited<ReturnType<typeof readMarket>>;

/** Gauge rewards the vault has earned (harvested plus still pending) and what holders claimed. */
function renderRewards() {
  const el = $("chart-rewards");
  const symbol = vault?.rewardSymbol ?? "";
  const ordered = [...events].reverse().filter((e) => e.time > 0n);
  const harvests = ordered.filter((e) => e.name === "Harvest");
  if (harvests.length === 0) {
    el.innerHTML = `<p class="muted">No rewards harvested yet${vault && vault.stream.rate === 0n ? ": this vault's gauge is not streaming" : ""}.</p>`;
    return;
  }
  const start = Number(ordered[0].time);
  const earned: [number, number][] = [[start, 0]];
  const claimed: [number, number][] = [[start, 0]];
  let e = 0;
  let c = 0;
  for (const ev of ordered) {
    const t = Number(ev.time);
    if (ev.name === "Harvest") earned.push([t, (e += Number(ev.args.reward as bigint) / 1e18)]);
    if (ev.name === "RewardClaimed") claimed.push([t, (c += Number(ev.args.amount as bigint) / 1e18)]);
  }
  const now = Math.floor(Date.now() / 1000);
  earned.push([now, e + Number(vault?.stream.pending ?? 0n) / 1e18]);
  claimed.push([now, c]);
  const span = now - start;
  lineChart(
    el,
    [
      { name: `Earned by the vault (${symbol})`, points: earned, color: "var(--accent)" },
      { name: `Claimed by holders (${symbol})`, points: claimed, color: "#102144", dashed: true },
    ],
    {
      yFormat: (y) => y.toFixed(y < 10 ? 2 : 0),
      floor: 0,
      xFormat: (t) => {
        const d = new Date(t * 1000);
        return span < 2 * 86_400
          ? d.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit" })
          : d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
      },
    },
  );
}

async function init() {
  mountShell("analytics");
  initWallet();
  document.querySelectorAll<HTMLButtonElement>(".chip").forEach((c) =>
    c.addEventListener("click", () => {
      filter = c.dataset.filter!;
      document.querySelectorAll(".chip").forEach((x) => x.classList.toggle("active", x === c));
      renderHistory();
    }),
  );
  try {
    vault = await readVault();
    renderVault(vault);
  } catch {
    /* shown as dashes */
  }
  renderMarket();
  try {
    events = await readEvents();
    renderHistory();
    renderRewards();
  } catch (e) {
    console.error("events", e);
    $("a-history").innerHTML = `<li class="muted">History unavailable from the RPC right now. Reload to retry.</li>`;
    $("chart-rewards").innerHTML = `<p class="muted">Reward history unavailable from the RPC right now.</p>`;
    $("k-last").textContent = "–";
  }
  renderCharts().catch(() => {
    $("chart-pps").innerHTML = $("chart-nav").innerHTML = `<p class="muted">History unavailable from the RPC right now.</p>`;
  });
  setInterval(async () => {
    if (document.visibilityState !== "visible") return;
    try {
      vault = await readVault();
      renderVault(vault);
    } catch {
      /* keep last */
    }
  }, 30_000);
  setInterval(() => {
    if (document.visibilityState === "visible") renderMarket();
  }, 120_000);
}

init();
