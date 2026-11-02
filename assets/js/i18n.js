// Indonesian interface option. Text is translated by exact-match lookup (dictionary in i18n-id.js, loaded only
// for Indonesian visitors) when a template is cloned (see component-loader.js), when an admin panel is built,
// and when a toast or dialog opens. Dynamic strings with numbers or names inside (`${n} orders`) are not matched.
// No static import: utils.js imports this file, so it must not import utils.js back.
const KEY = "csw.lang"; // same key and JSON format as utils.js `local`

export const lang = (() => { try { return JSON.parse(localStorage.getItem(KEY)) === "id" ? "id" : "en"; } catch { return "en"; } })();
if (typeof document !== "undefined") document.documentElement.lang = lang;

// i18n-extra.js holds the admin/advertise/checkout strings and the sentence patterns; its entries lose to i18n-id.js.
const [main, extra] = lang === "id" ? await Promise.all([import("./i18n-id.js"), import("./i18n-extra.js")]) : [];
const ID = main ? { ...extra.ID_EXTRA, ...main.ID } : {};
const PATTERNS = extra?.PATTERNS ?? [];

export function setLang(next) {
  try { localStorage.setItem(KEY, JSON.stringify(next === "id" ? "id" : "en")); } catch { /* storage blocked: the switch cannot persist */ }
  window.location.reload();
}

const tr = (s) => {
  const key = s.trim().replace(/\s+/g, " ");
  if (Object.hasOwn(ID, key)) return s.replace(s.trim(), () => ID[key]);
  for (const [re, fn] of PATTERNS) {
    const m = re.exec(key);
    if (m) return s.replace(s.trim(), () => fn(...m.slice(1)));
  }
  return s;
};

/** Translate a cloned template fragment or built panel in place. No-op for English. */
export function translate(root) {
  if (lang !== "id") return root;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) if (n.nodeValue.trim()) n.nodeValue = tr(n.nodeValue);
  for (const el of root.querySelectorAll("[placeholder],[aria-label],[title]")) {
    for (const a of ["placeholder", "aria-label", "title"]) if (el.hasAttribute(a)) el.setAttribute(a, tr(el.getAttribute(a)));
  }
  return root;
}
