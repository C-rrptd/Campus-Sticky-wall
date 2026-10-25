// Application entry point: configuration check, URL callbacks (PKCE auth,
// referral links, Midtrans return), session restore, shell, router.

import { configProblems } from "./config.js";
import { cloneTemplate, loadComponents } from "./component-loader.js";
import { currentUser, initAuth, isAdmin, onUserChange, signOut } from "./auth.js";
import { onRouteChange, rerender, startRouter } from "./router.js";
import { captureReferral } from "./referrals.js";
import { getClient, query } from "./supabase-client.js";
import { clear, el, refs, safeUrl, toast } from "./utils.js";

const view = () => document.getElementById("view");

/** Small filter/sort dropdowns (<details class="dropdown">) close on outside click or Escape. */
function installDropdownClose() {
  document.addEventListener("click", (e) => {
    for (const d of document.querySelectorAll("details.dropdown[open]")) if (!d.contains(e.target)) d.open = false;
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") for (const d of document.querySelectorAll("details.dropdown[open]")) d.open = false;
  });
}

function installGlobalErrorHandlers() {
  window.addEventListener("error", (e) => console.error("Uncaught error", e.error ?? e.message));
  window.addEventListener("unhandledrejection", (e) => {
    if (e.reason?.name === "AbortError") return;
    console.error("Unhandled rejection", e.reason);
    toast("Something went wrong. Please try again.", "error");
  });
  window.addEventListener("offline", () => toast("You are offline. Changes will fail until you reconnect.", "error"));
}

/** Midtrans redirects back to /?payment_return=1&order_id=...; route to the order page. */
function handleUrlCallbacks() {
  const url = new URL(window.location.href);
  const orderId = url.searchParams.get("order_id");
  if (url.searchParams.has("payment_return") || orderId) {
    const hash = orderId && /^[A-Za-z0-9_.~-]{8,50}$/.test(orderId) ? `#/checkout?order=${encodeURIComponent(orderId)}&returned=1` : "#/account";
    window.history.replaceState(null, "", `${url.pathname}${hash}`);
  }
}

/** After supabase-js consumed ?code= (PKCE), drop auth params from the address bar. */
function cleanAuthParams() {
  const url = new URL(window.location.href);
  let changed = false;
  for (const key of ["code", "error", "error_code", "error_description"]) {
    if (url.searchParams.has(key)) {
      if (key === "error_description") toast(url.searchParams.get(key), "error", 8000);
      url.searchParams.delete(key);
      changed = true;
    }
  }
  if (changed) window.history.replaceState(null, "", `${url.pathname}${url.search}${url.hash}`);
}

async function renderHeader() {
  const host = document.getElementById("app-header");
  clear(host);
  host.append(cloneTemplate("tpl-header"));
  const r = refs(host);
  r.navToggle.addEventListener("click", () => {
    const open = r.navToggle.getAttribute("aria-expanded") !== "true";
    r.navToggle.setAttribute("aria-expanded", String(open));
    r.nav.classList.toggle("is-open", open);
  });
  r.signOut.addEventListener("click", () => signOut());
  const update = async () => {
    const user = currentUser();
    r.signInLink.hidden = Boolean(user);
    r.accountMenu.hidden = !user;
    r.accountName.textContent = user ? (user.user_metadata?.display_name || "Account") : "Account";
    r.adminLink.hidden = !(user && (await isAdmin()));
  };
  onUserChange(() => { update(); rerender(); });
  onRouteChange((path) => {
    r.nav.classList.remove("is-open");
    r.navToggle.setAttribute("aria-expanded", "false");
    host.querySelectorAll("[data-nav]").forEach((a) => {
      if (a.dataset.nav === path) a.setAttribute("aria-current", "page");
      else a.removeAttribute("aria-current");
    });
  });
  await update();
}

async function renderFooter() {
  const host = document.getElementById("app-footer");
  clear(host);
  host.append(cloneTemplate("tpl-footer"));
  const r = refs(host);
  try {
    const rows = await query(getClient().from("site_config").select("key,value").in("key", ["official_social_links", "contact_email"]));
    const cfg = Object.fromEntries(rows.map((row) => [row.key, row.value]));
    if (typeof cfg.contact_email === "string" && cfg.contact_email.includes("@")) {
      r.contact.href = `mailto:${cfg.contact_email}`;
      r.contact.hidden = false;
    }
    for (const [name, href] of Object.entries(cfg.official_social_links ?? {})) {
      const safe = safeUrl(href, false);
      if (safe) r.socials.append(el("li", {}, el("a", { href: safe, target: "_blank", rel: "noopener noreferrer" }, name)));
    }
  } catch (err) {
    console.warn("Footer settings unavailable", err);
  }
}

async function boot() {
  installGlobalErrorHandlers();
  installDropdownClose();
  try {
    await loadComponents(["core", "footer"]);
  } catch (err) {
    view().textContent = "The site failed to load its interface files. Please reload the page.";
    console.error(err);
    return;
  }

  const problems = configProblems();
  if (problems.length) {
    clear(view());
    const frag = cloneTemplate("tpl-config-error");
    const r = refs(frag);
    problems.forEach((p) => r.list.append(el("li", {}, p)));
    view().append(frag);
    return;
  }

  captureReferral();
  handleUrlCallbacks();
  try {
    await initAuth();
  } catch (err) {
    console.error("Auth init failed", err);
    toast("Could not restore your session. You can still browse.", "error");
  }
  cleanAuthParams();
  await renderHeader();
  renderFooter();
  startRouter(view());
}

boot();
