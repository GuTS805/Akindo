import { GITHUB, TESTNET, VAULTS } from "../config";
import { $, EXPLORER } from "../lib/format";
import { mountShell } from "../lib/layout";
import { initWallet } from "../lib/wallet";

const CONTRACTS: [string, string, string][] = [
  ["mbLP vault (MEZO rewards)", VAULTS.rewards.address, "Stakes in the reward gauge below; harvest and claim pay testnet MEZO"],
  ["RewardGauge", VAULTS.rewards.gauge, "Streams testnet MEZO to staked LP; anyone can fund it"],
  ["mbLP vault (official gauge)", VAULTS.official.address, "Same contract, staked in Mezo's official testnet gauge (no emissions)"],
  ["BTC", TESTNET.btc, "Native BTC precompile, ERC-20 view of the balance"],
  ["MUSD", TESTNET.musd, "Mezo's BTC-backed stablecoin"],
  ["BorrowerOperations", TESTNET.borrowerOperations, "Opens, adjusts and closes the trove"],
  ["TroveManager", TESTNET.troveManager, "Trove state, debt and collateral"],
  ["PriceFeed", TESTNET.priceFeed, "BTC price oracle"],
  ["Router", TESTNET.router, "Mezo Pools router"],
  ["BTC/MUSD pool", TESTNET.pool, "Volatile pool the vault provides to"],
  ["Official gauge", TESTNET.gauge, "Mezo's testnet BTC/MUSD gauge; only the Voter can fund it"],
  ["MEZO", "0x7b7C000000000000000000000000000000000001", "MEZO token precompile, the testnet reward token"],
];

function init() {
  mountShell("docs");
  initWallet();
  $("contracts-table").innerHTML =
    `<thead><tr><th>Contract</th><th>Address</th><th>Role</th></tr></thead><tbody>` +
    CONTRACTS.map(
      ([name, addr, role]) =>
        `<tr><td>${name}</td><td><a href="${EXPLORER}/address/${addr}" target="_blank" rel="noopener"><code>${addr}</code></a></td><td>${role}</td></tr>`,
    ).join("") +
    `</tbody>`;
  $("contracts-table").insertAdjacentHTML(
    "afterend",
    `<p class="note">Source, tests and deployment notes: <a href="${GITHUB}" target="_blank" rel="noopener">${GITHUB.replace("https://", "")}</a></p>`,
  );
}

init();
