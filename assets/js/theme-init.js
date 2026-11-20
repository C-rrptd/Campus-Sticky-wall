// Runs before first paint (blocking, external for CSP): saved theme (else the OS setting) and saved skin.
// Skins: "paper" (classic, default) and "neo". The skin decides which stylesheets are written here, so the other
// skin's CSS is never downloaded. index.html keeps the classic set inside <noscript>.
const SKIN_CSS = {
  paper: ["base", "components", "decorations", "pages", "advertise", "engagement", "responsive"],
  neo: ["neo-tokens", "neo-base", "neo-components", "decorations", "neo-pages", "advertise", "neo-engagement", "neo-responsive", "neo-signature"],
};
(() => {
  let skin = null;
  try { skin = localStorage.getItem("csw-skin"); } catch { /* storage blocked */ }
  if (!Object.hasOwn(SKIN_CSS, skin)) skin = "paper";
  document.documentElement.dataset.skin = skin;
  try {
    const src = new URL(document.currentScript.src); // same ?v= as this script, so one version bump busts every stylesheet
    const url = (path) => { const u = new URL(path, src); u.search = src.search; return u.href; };
    if (skin === "neo") {
      document.write(`<link rel="preload" href="${url("../fonts/dela.woff2")}" as="font" type="font/woff2" crossorigin>`);
      document.querySelector('link[rel="icon"]')?.setAttribute("href", url("../images/neo-favicon.svg"));
    }
    SKIN_CSS[skin].forEach((n) => document.write(`<link rel="stylesheet" href="${url(`../css/${n}.css`)}">`));
  } catch { /* the <noscript> set in index.html is the fallback */ }

  let t = null;
  try { t = localStorage.getItem("csw-theme"); } catch { /* storage blocked */ }
  if (t !== "dark" && t !== "light") t = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  document.documentElement.dataset.theme = t;

  // Fetch what boot needs in parallel with app.js (same ?v= as this script, so the URLs match the real requests).
  try {
    const base = new URL(document.currentScript.src);
    const add = (rel, path, as) => {
      const u = new URL(path, base); u.search = base.search;
      const l = document.createElement("link");
      l.rel = rel; l.href = u.href;
      if (as) { l.as = as; l.crossOrigin = "anonymous"; }
      document.head.append(l);
    };
    const hash = location.hash.replace(/^#/, "");
    const wall = hash === "" || hash === "/" || hash.startsWith("/?") || hash.startsWith("/wall");
    const parts = ["core", "footer", ...(wall ? ["wall", "note-card", "promotion-card", "announcements"] : [])];
    parts.forEach((n) => add("preload", `../../components/${n}.html`, "fetch"));
    let lang = null;
    try { lang = JSON.parse(localStorage.getItem("csw.lang")); } catch { /* storage blocked */ }
    if (lang === "id") ["i18n-id", "i18n-extra"].forEach((n) => add("modulepreload", `${n}.js`));
  } catch { /* preload is only an optimisation */ }
})();
