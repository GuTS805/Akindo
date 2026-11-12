import { BaseError, decodeAbiParameters, encodeFunctionData, parseAbi, parseEther, type Address, type Hex } from "viem";
import { GITHUB, TESTNET, VAULTS } from "../config";
import { testnet } from "../lib/chain";
import { $, EXPLORER, esc } from "../lib/format";
import { mountShell } from "../lib/layout";
import { initWallet } from "../lib/wallet";
import { vaultAbi } from "../vaultAbi";

const VAULT = VAULTS.v6.address as Address;
const ATTACKER = "0x00000000000000000000000000000000000dbeef" as Address;
const OTHER = "0x00000000000000000000000000000000000dcafe" as Address;
const GAUGE_ABI = parseAbi(["function getReward(address account)"]);

/** Custom errors of the vault, Mezo's gauge and OpenZeppelin that these calls can return. */
const ERROR_NAMES: Record<string, string> = {
  "0x14d4a4e8": "OnlySelf()",
  "0x6ba4a1c7": "DepositTooSmall()",
  "0x3f2d7e37": "DepositCapReached(…)",
  "0x7dd37f70": "Slippage()",
  "0x71645d0b": "NothingToRebalance()",
  "0x9811e0c7": "ZeroShares()",
  "0xea8e4eb5": "NotAuthorized() from Mezo's gauge",
  "0xe450d38c": "ERC20InsufficientBalance(…)",
};

const MUST_REFUSE = "It ran. It should not have.";

type Attack = {
  title: string;
  goal: string;
  call: string;
  to: Address;
  data: Hex;
  value?: bigint;
  /** Shown when the call does not revert; MUST_REFUSE marks a call that should never get through. */
  ranText: string;
};

const vaultCall = (functionName: string, args: unknown[] = []) =>
  encodeFunctionData({ abi: vaultAbi, functionName, args } as never);

const ATTACKS: Attack[] = [
  {
    title: "Call the vault's deployment step directly",
    goal: "Make the vault move its own BTC around without going through a deposit.",
    call: "deployIdle()",
    to: VAULT,
    data: vaultCall("deployIdle"),
    ranText: MUST_REFUSE,
  },
  {
    title: "Spam dust deposits",
    goal: "Fill the vault with 0.0001 BTC deposits to bloat state and rounding.",
    call: "deposit{value: 0.0001 BTC}",
    to: VAULT,
    data: vaultCall("deposit", [0n]),
    value: parseEther("0.0001"),
    ranText: MUST_REFUSE,
  },
  {
    title: "Deposit past the cap",
    goal: "Put in 3 BTC when the unaudited vault is capped at 2 BTC of total value.",
    call: "deposit{value: 3 BTC}",
    to: VAULT,
    data: vaultCall("deposit", [0n]),
    value: parseEther("3"),
    ranText: MUST_REFUSE,
  },
  {
    title: "Get fewer shares than you demanded",
    goal: "Deposit 0.01 BTC but require a million shares. The vault refuses to mint less than your floor.",
    call: "deposit(minShares = 1,000,000e18){value: 0.01 BTC}",
    to: VAULT,
    data: vaultCall("deposit", [parseEther("1000000")]),
    value: parseEther("0.01"),
    ranText: MUST_REFUSE,
  },
  {
    title: "Withdraw shares you do not own",
    goal: "Burn 1 mbLP you never held to take BTC out of the trove.",
    call: "withdraw(1e18, 0)",
    to: VAULT,
    data: vaultCall("withdraw", [parseEther("1"), 0n]),
    ranText: MUST_REFUSE,
  },
  {
    title: "Withdraw with a value floor, no shares",
    goal: "Same theft through the v6 exit that floors the payout's total value.",
    call: "withdrawMinValue(1e18, 0, 1)",
    to: VAULT,
    data: vaultCall("withdrawMinValue", [parseEther("1"), 0n, 1n]),
    ranText: MUST_REFUSE,
  },
  {
    title: "Exit with zero shares",
    goal: "Trigger an exit that burns nothing, to mess with reward accounting.",
    call: "withdraw(0, 0)",
    to: VAULT,
    data: vaultCall("withdraw", [0n, 0n]),
    ranText: MUST_REFUSE,
  },
  {
    title: "Move shares you do not hold",
    goal: "Transfer 1 mbLP to a second address, along with its reward claim.",
    call: "transfer(other, 1e18)",
    to: VAULT,
    data: vaultCall("transfer", [OTHER, parseEther("1")]),
    ranText: MUST_REFUSE,
  },
  {
    title: "Claim someone else's MEZO",
    goal: "Call claimRewards() hoping to be paid the holders' rewards.",
    call: "claimRewards()",
    to: VAULT,
    data: vaultCall("claimRewards"),
    ranText: "Returned 0. You are paid only what your own shares earned, so a stranger gets nothing.",
  },
  {
    title: "Pull the gauge rewards out from outside the vault",
    goal: "Ask Mezo's gauge to pay the vault's rewards somewhere else, or strand them uncredited.",
    call: "gauge.getReward(vault)",
    to: TESTNET.gauge as Address,
    data: encodeFunctionData({ abi: GAUGE_ABI, functionName: "getReward", args: [VAULT] }),
    ranText: MUST_REFUSE,
  },
  {
    title: "Force a pointless rebalance",
    goal: "Burn the vault's fees by rebalancing when there is nothing to do.",
    call: "rebalance()",
    to: VAULT,
    data: vaultCall("rebalance"),
    ranText: "It ran because the vault needed it. Rebalancing is open to anyone and pays the caller nothing.",
  },
  {
    title: "Claim surplus collateral nobody left",
    goal: "Pull MUSD's liquidation surplus into the vault when there is none.",
    call: "claimSurplusCollateral()",
    to: VAULT,
    data: vaultCall("claimSurplusCollateral"),
    ranText: "It ran. It only moves the vault's own surplus BTC back into the vault.",
  },
];

type Outcome = { kind: "refused" | "ran"; detail: string };

/** The error name or reason string of a reverted eth_call. */
function revertOf(e: unknown): string {
  if (e instanceof BaseError) {
    const hit = e.walk(
      (x) => typeof (x as { data?: unknown })?.data === "string" && /^0x[0-9a-fA-F]{8}/.test((x as { data: string }).data),
    );
    const data = (hit as { data?: string } | null)?.data;
    if (data) {
      const selector = data.slice(0, 10).toLowerCase();
      if (selector === "0x08c379a0") {
        try {
          return `Error("${decodeAbiParameters([{ type: "string" }], `0x${data.slice(10)}`)[0]}")`;
        } catch {
          return "Error(string)";
        }
      }
      return ERROR_NAMES[selector] ?? `custom error ${selector}`;
    }
    const m = /execution reverted:?\s*(.*)/i.exec(e.details ?? e.shortMessage ?? "");
    if (m && m[1]) return m[1].trim().slice(0, 120);
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}

async function attempt(a: Attack): Promise<Outcome> {
  try {
    await testnet.call({
      account: ATTACKER,
      to: a.to,
      data: a.data,
      value: a.value,
      stateOverride: [{ address: ATTACKER, balance: parseEther("10") }],
    });
    return { kind: "ran", detail: a.ranText };
  } catch (e) {
    return { kind: "refused", detail: revertOf(e) };
  }
}

const gotThrough = (a: Attack, r: Outcome) => r.kind === "ran" && a.ranText === MUST_REFUSE;

function renderRows(results: (Outcome | undefined)[]) {
  $("b-table").innerHTML =
    `<thead><tr><th>#</th><th>Attack</th><th>The call</th><th>Result</th></tr></thead><tbody>` +
    ATTACKS.map((a, i) => {
      const r = results[i];
      let cell = `<span class="muted">running…</span>`;
      if (r) {
        const bad = gotThrough(a, r);
        const cls = bad ? "bad" : r.kind === "refused" ? "good" : "";
        const label = bad ? "Got through" : r.kind === "refused" ? "Refused" : "Ran, gained nothing";
        cell = `<strong class="${cls}">${label}</strong><br/><span class="muted small-text">${esc(r.detail)}</span>`;
      }
      return `<tr><td>${i + 1}</td><td style="white-space:normal"><strong>${esc(a.title)}</strong><br/><span class="muted small-text">${esc(a.goal)}</span></td><td><code>${esc(a.call)}</code></td><td style="white-space:normal">${cell}</td></tr>`;
    }).join("") +
    `</tbody>`;
}

async function runAll() {
  const btn = $<HTMLButtonElement>("b-run");
  btn.disabled = true;
  const results: (Outcome | undefined)[] = new Array(ATTACKS.length).fill(undefined);
  renderRows(results);
  await Promise.all(
    ATTACKS.map(async (a, i) => {
      results[i] = await attempt(a);
      renderRows(results);
    }),
  );
  const done = results as Outcome[];
  const bad = ATTACKS.filter((a, i) => gotThrough(a, done[i])).length;
  const refused = done.filter((r) => r.kind === "refused").length;
  $("b-total").textContent = String(ATTACKS.length);
  $("b-refused").textContent = String(refused);
  $("b-noop").textContent = String(ATTACKS.length - refused - bad);
  $("b-bad").textContent = String(bad);
  $("b-bad").className = `value ${bad === 0 ? "good" : "bad"}`;
  $("b-note").innerHTML =
    `Sent as <code>${ATTACKER}</code> with a 10 BTC balance set for the call only, against ` +
    `<a href="${EXPLORER}/address/${VAULT}" target="_blank" rel="noopener"><code>${VAULT}</code></a>. ` +
    `An <code>eth_call</code> changes nothing on chain, so you can repeat it freely.`;
  btn.disabled = false;
}

/** Attacker profit in sats from SandwichTest (forge test --match-contract SandwichTest -vv), least negative of up and down. */
const ECON: [string, string, string, string][] = [
  ["Sandwich a keeper step (rebalance)", "−53,035", "−98,271", "−52,019"],
  ["Sandwich someone's deposit", "−63,699", "−185,763", "−301,248"],
  ["Sandwich someone's withdrawal", "−66,948", "−222,239", "−403,379"],
];

const OTHER_TESTS: [string, string][] = [
  ["Deposit, push the pool off the oracle, withdraw, push back", "Manipulation.t.sol: never profitable in a 512-run fuzz over 1 to 2,000 BTC and 2 to 80% skews"],
  ["First-depositor and donation attacks", "Dead shares plus oracle-priced shares: a donation only raises everyone's share price"],
  ["Reentrancy through BTC sends and Mezo calls", "Every entry point is nonReentrant; invariant suite of 65,536 random actions"],
  ["A fall with the pool left behind, then an attacker pushes the pool further", "CrashExit.t.sol and SandwichTest: the attacker earns no more than the plain arbitrage"],
  ["Liquidation, redemption and Recovery Mode", "Recovery.t.sol, RecoveryMode.t.sol and the testnet and mainnet fork suites"],
  ["Slither static analysis", "48 results, every one reviewed in contracts/SECURITY.md"],
];

function renderStatic() {
  $("b-econ").innerHTML =
    `<thead><tr><th>Attack</th><th>2% band (mainnet)</th><th>6% band</th><th>10% band (testnet)</th></tr></thead><tbody>` +
    ECON.map(([n, a, b, c]) => `<tr><td>${esc(n)}</td><td class="good">${a}</td><td class="good">${b}</td><td class="good">${c}</td></tr>`).join("") +
    `</tbody>`;
  $("b-tests").innerHTML = OTHER_TESTS.map(
    ([a, b]) => `<li><strong>${esc(a)}</strong><br/><span class="muted small-text">${esc(b)}</span></li>`,
  ).join("");
  $("b-target").textContent = `v6 · ${VAULT.slice(0, 8)}…${VAULT.slice(-6)}`;
  ($("b-issues") as HTMLAnchorElement).href = `${GITHUB}/issues`;
}

function init() {
  mountShell("break");
  initWallet();
  renderStatic();
  $("b-run").addEventListener("click", () => void runAll());
  void runAll();
}
init();
