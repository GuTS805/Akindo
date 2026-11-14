import type { Address } from "viem";
import { DEPLOYER, FAUCET, GITHUB, TEAM_WALLETS, VAULTS } from "../config";
import { readDeposits, type DepositLog } from "../lib/chain";
import { $, EXPLORER, addressLink, ago, btc, esc, txLink } from "../lib/format";
import { mountShell, pageUrl } from "../lib/layout";
import { connect, initWallet, onWalletChange, wallet } from "../lib/wallet";

/** The Wave 2 vaults: the live-gauge vaults with the review fixes. */
const SCANNED = [VAULTS.v6, VAULTS.v5, VAULTS.v4].map((v) => ({
  id: v.id as string,
  address: v.address as Address,
  deployBlock: v.deployBlock,
}));

let deposits: DepositLog[] | undefined;

const TEAM = new Set(TEAM_WALLETS.map((a) => a.toLowerCase()));
const isTeam = (a: string) => TEAM.has(a.toLowerCase());
const isDeployer = (a: string) => a.toLowerCase() === DEPLOYER.toLowerCase();

function render() {
  if (!deposits) return;
  const others = deposits.filter((d) => !isTeam(d.user));
  const mine = deposits.filter((d) => isDeployer(d.user));
  const byUser = new Map<string, DepositLog[]>();
  for (const d of others) byUser.set(d.user.toLowerCase(), [...(byUser.get(d.user.toLowerCase()) ?? []), d]);

  const total = others.reduce((s, d) => s + d.btcIn, 0n);
  $("c-users").textContent = String(byUser.size);
  $("c-count").textContent = String(others.length);
  $("c-btc").textContent = `${btc(total, 4)} BTC`;
  $("c-seed").textContent = `${btc(mine.filter((d) => d.vault === "v6").reduce((s, d) => s + d.btcIn, 0n), 2)} BTC`;

  if (byUser.size === 0) {
    $("c-table").innerHTML = `<tbody><tr><td>No one outside the team has deposited into v4, v5 or v6 yet. Be the first: the three steps above take about three minutes.</td></tr></tbody>`;
  } else {
    const rows = [...byUser.values()]
      .map((list) => ({
        user: list[0].user,
        btc: list.reduce((s, d) => s + d.btcIn, 0n),
        count: list.length,
        vaults: [...new Set(list.map((d) => d.vault))].join(", "),
        latest: list[0],
      }))
      .sort((a, b) => Number(b.latest.block - a.latest.block));
    $("c-table").innerHTML =
      `<thead><tr><th>Address</th><th>Deposited</th><th>Deposits</th><th>Vault</th><th>Last deposit</th></tr></thead><tbody>` +
      rows
        .map(
          (r) =>
            `<tr><td>${addressLink(r.user)}</td><td>${btc(r.btc, 4)} BTC</td><td>${r.count}</td><td>${esc(r.vaults)}</td><td>${ago(r.latest.time)} · ${txLink(r.latest.tx)}</td></tr>`,
        )
        .join("") +
      `</tbody>`;
  }
  $("c-note").textContent =
    "Counted from the Deposit events of v4, v5 and v6. The team's own wallets (deployer, keeper, a test wallet and three demo wallets, listed in the app's config) are excluded.";

  const me = wallet.account?.toLowerCase();
  const deposited = !!me && others.some((d) => d.user.toLowerCase() === me);
  $("s2").classList.toggle("done", !!me);
  $("s3").classList.toggle("done", deposited);
  $("c-you").textContent = deposited
    ? "Your wallet has deposited into the Wave 2 vaults. Thank you."
    : me
      ? "Your wallet is connected. Open the vault and make your first deposit."
      : "";
}

async function load() {
  try {
    deposits = await readDeposits(SCANNED);
    render();
  } catch {
    $("c-table").innerHTML = `<tbody><tr><td class="muted">The testnet RPC did not answer. Reload to retry.</td></tr></tbody>`;
  }
}

function init() {
  mountShell("community");
  initWallet();
  ($("c-faucet") as HTMLAnchorElement).href = FAUCET;
  ($("c-deposit") as HTMLAnchorElement).href = pageUrl("vault");
  ($("c-break") as HTMLAnchorElement).href = pageUrl("break");
  ($("c-issues") as HTMLAnchorElement).href = `${GITHUB}/issues`;
  ($("c-write") as HTMLAnchorElement).href = `${EXPLORER}/address/${VAULTS.v6.address}?tab=write_contract`;
  $("c-connect").addEventListener("click", () => void connect());
  onWalletChange(render);
  void load();
}
init();
