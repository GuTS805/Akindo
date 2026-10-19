import { ACTIVE_VAULT, GITHUB, VAULT, VAULTS, selectVault, type VaultId } from "../config";
import { $, EXPLORER } from "./format";

export type PageId = "home" | "vault" | "portfolio" | "analytics" | "simulator" | "docs";

/** Pages that show one vault's state get the vault switch. */
const VAULT_PAGES: PageId[] = ["vault", "portfolio", "analytics"];

const PAGES: { id: PageId; label: string; path: string }[] = [
  { id: "home", label: "Home", path: "" },
  { id: "vault", label: "Vault", path: "vault/" },
  { id: "portfolio", label: "Portfolio", path: "portfolio/" },
  { id: "analytics", label: "Analytics", path: "analytics/" },
  { id: "simulator", label: "Simulator", path: "simulator/" },
  { id: "docs", label: "Docs", path: "docs/" },
];

/** Site-relative URL that works under both "/" (Vercel) and "/Akindo/" (GitHub Pages). */
export function pageUrl(id: PageId, hash = ""): string {
  const page = PAGES.find((p) => p.id === id)!;
  return `${import.meta.env.BASE_URL}${page.path}${hash}`;
}

/** Header, navigation, notice banner, wallet picker and footer around a page's <main>. */
export function mountShell(active: PageId) {
  const nav = PAGES.map(
    (p) => `<a href="${pageUrl(p.id)}"${p.id === active ? ' aria-current="page"' : ""}>${p.label}</a>`,
  ).join("");

  document.body.insertAdjacentHTML(
    "afterbegin",
    `<header class="topbar">
      <a class="brand" href="${pageUrl("home")}" aria-label="mbLP home">
        <span class="logo" aria-hidden="true"><span class="logo-sun"></span><span class="logo-hill"></span></span>
        <div><strong>mbLP</strong><span class="muted">BTC LP Vault on Mezo</span></div>
      </a>
      <nav class="site-nav" id="site-nav" aria-label="Main navigation">${nav}</nav>
      <div class="topbar-right">
        <span class="badge" id="network-badge">Mezo Testnet</span>
        <button class="btn" id="connect">Connect wallet</button>
        <button class="menu-btn" id="menu-btn" aria-label="Menu" aria-expanded="false" aria-controls="site-nav">☰</button>
      </div>
    </header>`,
  );

  const main = document.querySelector("main")!;
  if (VAULT_PAGES.includes(active)) {
    const options = Object.values(VAULTS)
      .map(
        (v) =>
          `<button class="seg${v.id === ACTIVE_VAULT.id ? " active" : ""}" data-vault="${v.id}" aria-pressed="${
            v.id === ACTIVE_VAULT.id
          }">${v.label}</button>`,
      )
      .join("");
    main.insertAdjacentHTML(
      "afterbegin",
      `<div class="vault-switch" role="group" aria-label="Choose vault">
        <span class="muted">Vault</span>
        <div class="segmented">${options}</div>
        <span class="muted vault-note">${ACTIVE_VAULT.gaugeNote}</span>
      </div>`,
    );
    main.querySelectorAll<HTMLButtonElement>("[data-vault]").forEach((b) =>
      b.addEventListener("click", () => {
        if (b.dataset.vault !== ACTIVE_VAULT.id) selectVault(b.dataset.vault as VaultId);
      }),
    );
  }
  main.insertAdjacentHTML(
    "afterbegin",
    `<div id="notice" class="alert notice" role="alert" hidden>
      <span id="notice-text"></span>
      <button class="btn ghost small" id="notice-close" aria-label="Dismiss">×</button>
    </div>`,
  );

  document.body.insertAdjacentHTML(
    "beforeend",
    `<footer class="footer">
      <a href="${EXPLORER}/address/${VAULT}" target="_blank" rel="noopener">Vault contract</a><span>·</span>
      <a href="${EXPLORER}/address/${VAULT}?tab=contract" target="_blank" rel="noopener">Verified source</a><span>·</span>
      <a href="${GITHUB}" target="_blank" rel="noopener">GitHub</a><span>·</span>
      <a href="https://faucet.test.mezo.org" target="_blank" rel="noopener">Testnet faucet</a><span>·</span>
      <a href="${pageUrl("docs")}">Docs</a>
    </footer>
    <dialog id="wallet-picker" aria-labelledby="wallet-picker-title">
      <h2 id="wallet-picker-title">Choose a wallet</h2>
      <ul id="wallet-list" class="wallet-list"></ul>
      <button class="btn ghost wide" id="wallet-cancel">Cancel</button>
    </dialog>`,
  );

  // In-page links that point at other pages: <a data-page="vault" data-hash="#withdraw">
  document.querySelectorAll<HTMLAnchorElement>("a[data-page]").forEach((a) => {
    a.href = pageUrl(a.dataset.page as PageId, a.dataset.hash ?? "");
  });

  $("notice-close").addEventListener("click", clearNotice);
  $("wallet-cancel").addEventListener("click", () => $<HTMLDialogElement>("wallet-picker").close());
  $("menu-btn").addEventListener("click", () => {
    const open = $("site-nav").classList.toggle("open");
    $("menu-btn").setAttribute("aria-expanded", String(open));
  });
}

/** Errors and hints that stay until dismissed. */
export function showNotice(msg: string) {
  $("notice-text").textContent = msg;
  $("notice").hidden = false;
}

export function clearNotice() {
  $("notice").hidden = true;
}
