import { GITHUB, TESTNET, VAULTS } from "../config";
import { $, EXPLORER } from "../lib/format";
import { mountShell } from "../lib/layout";
import { initWallet } from "../lib/wallet";

const CONTRACTS: [string, string, string][] = [
  ["mbLP vault v3 (default)", VAULTS.v3.address, "The v2 contract staked in Mezo's live BTC/MUSD gauge: earns the MEZO emissions Mezo distributes each epoch"],
  ["IncentiveRouter (v3)", "0x28bAf157D84aa72Bf7Ac3800c8243F1557cf2605", "v3's fee recipient: posts half of each fee as a MEZO incentive on the live gauge's incentive contract, the rest to the treasury"],
  ["mbLP vault v2", VAULTS.v2.address, "Shares from the NAV change, 2 BTC deposit cap, isolated deployment; staked in the reward gauge"],
  ["IncentiveRouter (v2)", "0x924b8a4585B659D78041569fE0074719116126F2", "v2's fee recipient; its incentive contract (legacy Voter) does not whitelist MEZO, so fees fall back to the treasury"],
  ["mbLP vault v1", VAULTS.rewards.address, "First release, staked in the same reward gauge; harvest and claim pay testnet MEZO"],
  ["RewardGauge", VAULTS.rewards.gauge, "Streams testnet MEZO to staked LP; anyone can fund it"],
  ["mbLP vault (legacy gauge)", VAULTS.official.address, "Same contract, staked in the BTC/MUSD gauge on Mezo's older testnet Voter (no emissions since Nov 2025)"],
  ["BTC", TESTNET.btc, "Native BTC precompile, ERC-20 view of the balance"],
  ["MUSD", TESTNET.musd, "Mezo's BTC-backed stablecoin"],
  ["BorrowerOperations", TESTNET.borrowerOperations, "Opens, adjusts and closes the trove"],
  ["TroveManager", TESTNET.troveManager, "Trove state, debt and collateral"],
  ["PriceFeed", TESTNET.priceFeed, "BTC price oracle"],
  ["Router", TESTNET.router, "Mezo Pools router"],
  ["BTC/MUSD pool", TESTNET.pool, "Volatile pool the vault provides to"],
  ["BTC/MUSD gauge", TESTNET.gauge, "Mezo's live testnet BTC/MUSD gauge; the Voter pays it MEZO each epoch"],
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
