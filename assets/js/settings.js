// Settings page: skin, theme, language. Reachable by guests too (header cog and Account > Settings).
// Skin and language reload the page (skin decides which stylesheets load; language is applied at boot).

import { cloneTemplate } from "./component-loader.js";
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

export async function mount(view) {
  view.append(cloneTemplate("tpl-settings"));
  const r = refs(view);
  const groups = [
    [r.skin, () => root.dataset.skin ?? "paper", (v) => { store("csw-skin", v); window.location.reload(); }],
    [r.theme, () => (root.dataset.theme === "dark" ? "dark" : "light"), (v) => { root.dataset.theme = v; store("csw-theme", v); paintThemeColor(); }],
    [r.language, () => lang, (v) => { if (v !== lang) setLang(v); }],
  ];
  for (const [group, current, pick] of groups) {
    const paint = () => group.querySelectorAll("button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.value === current())));
    group.addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (!b || b.dataset.value === current()) return;
      pick(b.dataset.value);
      paint();
    });
    paint();
  }
}
