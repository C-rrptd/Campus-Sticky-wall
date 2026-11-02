// Runs before first paint (blocking, external for CSP): saved choice, else the OS setting.
(() => {
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
