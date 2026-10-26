// Hash router. Lazily loads each view's components and module, gives every
// view an AbortSignal (listeners/requests are cancelled on navigation) and
// ignores stale renders. The router is NOT an authorization boundary.

import { cloneTemplate, loadComponents } from "./component-loader.js";
import { clear, refs } from "./utils.js";

const routes = {
  "/": { title: "The Wall", components: ["wall", "note-card", "promotion-card", "announcements"], module: () => import("./wall.js") },
  "/compose": { title: "Post a note", components: ["note-composer", "note-card"], module: () => import("./notes.js"), entry: "mountComposer" },
  "/promotions": { title: "Promotions", components: ["promotions", "promotion-card"], module: () => import("./promotions.js") },
  "/advertise": { title: "Advertise", components: ["advertise"], module: () => import("./advertise.js"), entry: "mountAdvertise" },
  "/leaderboard": { title: "Leaderboards", components: ["leaderboard"], module: () => import("./leaderboard.js") },
  "/announcements": { title: "News", components: ["announcements"], module: () => import("./announcements.js") },
  "/auth": { title: "Sign in", components: ["auth"], module: () => import("./auth.js"), entry: "mountAuthView" },
  "/account": { title: "Account", components: ["account", "note-card"], module: () => import("./account.js") },
  "/profile": { title: "Profile", components: ["profile"], module: () => import("./account.js"), entry: "mountProfile" },
  "/referrals": { title: "Referrals", components: ["referrals"], module: () => import("./referrals.js") },
  "/checkout": { title: "Checkout", components: ["checkout", "note-card"], module: () => import("./checkout.js") },
  "/receipt": { title: "Receipt", components: ["checkout", "note-card"], module: () => import("./checkout.js") },
  "/donate": { title: "Support us", components: ["donations"], module: () => import("./donations.js") },
  "/admin": { title: "Administration", components: ["admin"], module: () => import("./admin.js") },
  "/privacy": { title: "Privacy", components: ["legal"], template: "tpl-privacy" },
  "/terms": { title: "Terms", components: ["legal"], template: "tpl-terms" },
};

const current = { cleanup: null, controller: null, token: 0 };
let viewEl = null;
const listeners = new Set();

export function parseHash(hash = window.location.hash) {
  const raw = hash.replace(/^#/, "") || "/";
  const [path, qs = ""] = raw.split("?");
  const clean = ("/" + path.replace(/^\/+/, "")).replace(/\/+$/, "") || "/";
  return { path: clean === "/wall" ? "/" : clean, params: new URLSearchParams(qs) };
}

export function navigate(path, params = {}) {
  const qs = new URLSearchParams(params).toString();
  const target = `#${path}${qs ? `?${qs}` : ""}`;
  if (window.location.hash === target) render();
  else window.location.hash = target;
}

/** Re-render the current route (e.g. after sign-in). */
export function rerender() {
  render();
}

export function onRouteChange(cb) {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

export function startRouter(container) {
  viewEl = container;
  window.addEventListener("hashchange", render);
  render();
}

function showError(err, retry) {
  clear(viewEl);
  const frag = cloneTemplate("tpl-view-error");
  const r = refs(frag);
  r.message.textContent = err?.message || "This page could not be loaded.";
  r.retry.addEventListener("click", retry, { once: true });
  viewEl.append(frag);
}

async function render() {
  const token = ++current.token;
  current.controller?.abort();
  try {
    current.cleanup?.();
  } catch (err) {
    console.error("View cleanup failed", err);
  }
  current.cleanup = null;
  const controller = new AbortController();
  current.controller = controller;

  const { path, params } = parseHash();
  const route = routes[path];
  listeners.forEach((cb) => cb(path));
  viewEl.setAttribute("aria-busy", "true");

  if (!route) {
    clear(viewEl);
    viewEl.append(cloneTemplate("tpl-not-found"));
    document.title = "Not found · Campus Sticky Wall";
    viewEl.removeAttribute("aria-busy");
    return;
  }

  try {
    const [mod] = await Promise.all([route.module ? route.module() : null, loadComponents(route.components)]);
    if (token !== current.token) return; // a newer navigation won
    clear(viewEl);
    document.title = `${route.title} · Campus Sticky Wall`;
    if (route.template) {
      viewEl.append(cloneTemplate(route.template));
    } else {
      const mount = mod[route.entry ?? "mount"];
      const cleanup = await mount(viewEl, { params, signal: controller.signal, navigate, path });
      if (token !== current.token) {
        if (typeof cleanup === "function") cleanup();
        return;
      }
      current.cleanup = typeof cleanup === "function" ? cleanup : null;
    }
    const heading = viewEl.querySelector("h1");
    if (heading) {
      heading.setAttribute("tabindex", "-1");
      heading.focus({ preventScroll: true });
    }
    window.scrollTo({ top: 0 });
  } catch (err) {
    if (token !== current.token || controller.signal.aborted) return;
    console.error(err);
    showError(err, () => render());
  } finally {
    if (token === current.token) viewEl.removeAttribute("aria-busy");
  }
}
