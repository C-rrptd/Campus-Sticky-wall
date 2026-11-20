// Header settings dropdown: skin, theme, language. Works signed in or out.
// Skin and language reload the page (skin decides which stylesheets load; language is applied at boot).

import { refs } from "./utils.js";
import { lang, setLang } from "./i18n.js";

const root = document.documentElement;
const store = (key, value) => { try { localStorage.setItem(key, value); } catch { /* storage blocked: the choice lasts this visit */ } };
const THEME_COLOR = { paper: { light: "#ece3b0", dark: "#0f1424" }, neo: { light: "#15112e", dark: "#060414" } };

/** Browser UI colour for the current skin + theme. Also called once at boot from app.js. */
export function paintThemeColor() {
  const colors = THEME_COLOR[root.dataset.skin] ?? THEME_COLOR.paper;
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", colors[root.dataset.theme === "dark" ? "dark" : "light"]);
}

/** Wires the three <select>s inside the header's settings <details>. */
export function mountSettings(host) {
  const r = refs(host);
  r.skin.value = root.dataset.skin ?? "paper";
  r.theme.value = root.dataset.theme === "dark" ? "dark" : "light";
  r.language.value = lang;
  r.skin.addEventListener("change", () => { store("csw-skin", r.skin.value); window.location.reload(); });
  r.theme.addEventListener("change", () => { root.dataset.theme = r.theme.value; store("csw-theme", r.theme.value); paintThemeColor(); });
  r.language.addEventListener("change", () => { if (r.language.value !== lang) setLang(r.language.value); });
}
