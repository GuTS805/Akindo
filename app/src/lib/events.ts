import { ACTIVE_VAULT } from "../config";
import { WAD, type VaultEvent } from "./chain";
import { ago, btc, musd, pct, ratio, short, txLink } from "./format";

/** One line of plain language per vault event. */
export function describe(e: VaultEvent, rewardSymbol: string = ACTIVE_VAULT.rewardSymbol): string {
  const a = e.args;
  switch (e.name) {
    case "Deposit":
      return `${short(String(a.user))} deposited ${btc(a.btcIn as bigint, 6)} BTC`;
    case "Withdraw":
      return `${short(String(a.user))} withdrew ${btc(a.btcOut as bigint, 6)} BTC${
        (a.musdOut as bigint) > 0n ? ` + ${musd(a.musdOut as bigint, 2)} MUSD` : ""
      }`;
    case "Rebalance":
      return `Rebalanced: debt ${musd(a.netDebtBefore as bigint)} → ${musd(a.netDebtAfter as bigint)} MUSD, CR ${pct(
        ratio(a.crAfter as bigint, WAD),
        0,
      )}`;
    case "Harvest":
      return `Harvested ${btc(a.reward as bigint, 6)} ${rewardSymbol}`;
    case "RewardClaimed":
      return `${short(String(a.user))} claimed ${btc(a.amount as bigint, 6)} ${rewardSymbol}`;
    case "Unwound":
      return `Position unwound, ${musd(a.debtRepaid as bigint)} MUSD repaid`;
  }
}

export function renderEvents(el: HTMLElement, events: VaultEvent[], empty = "No activity yet.") {
  if (events.length === 0) {
    el.innerHTML = `<li class="muted">${empty}</li>`;
    return;
  }
  el.innerHTML = events
    .map((e) => {
      const when = ago(e.time);
      return `<li><span class="what">${describe(e)}</span><span class="when">${when ? `${when} · ` : ""}${txLink(e.tx)}</span></li>`;
    })
    .join("");
}
