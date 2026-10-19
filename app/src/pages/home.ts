import { collateralRatio, depositorApr, navBtc, readMarket, readVault, type VaultState } from "../lib/chain";
import { $, btc, num, pct } from "../lib/format";
import { mountShell } from "../lib/layout";
import { initWallet } from "../lib/wallet";

let vault: VaultState | undefined;

async function renderVault() {
  try {
    vault = await readVault();
    if (!vault.snap) return;
    $("h-tvl").textContent = `${btc(navBtc(vault), 4)} BTC`;
    $("h-cr").textContent = vault.snap.troveActive ? pct(collateralRatio(vault.snap), 0) : "No trove";
  } catch {
    $("h-tvl-sub").textContent = "testnet RPC unavailable";
  }
}

async function renderMarket() {
  try {
    const m = await readMarket();
    $("h-apr").textContent = `≈ ${pct(depositorApr(m.vamm.apr, vault))}`;
    $("w-vebtc").textContent = `${num(m.veBtcLocked, 0)} BTC`;
    $("w-liq").textContent = `${num(m.vamm.btc + m.cl.btc, 2)} BTC`;
    $("w-liq-sub").textContent = `≈ ${num((m.vamm.tvl + m.cl.tvl) / 1000, 0)}k MUSD of total pool value`;
    $("w-emissions").textContent = num(m.vamm.perDay + m.cl.perDay, 0);
    $("w-emissions-sub").textContent = `MEZO per day ≈ $${num((m.vamm.perDay + m.cl.perDay) * m.mezoPrice, 0)}`;
    $("w-musd").textContent = `${num(m.musdSupply / 1e6, 1)}M`;
  } catch {
    $("w-liq-sub").textContent = "mainnet RPC unavailable, try again shortly";
  }
}

async function init() {
  mountShell("home");
  initWallet();
  await renderVault();
  renderMarket();
}

init();
