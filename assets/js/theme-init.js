// Runs before first paint (blocking, external for CSP): saved choice, else the OS setting.
(() => {
  let t = null;
  try { t = localStorage.getItem("csw-theme"); } catch { /* storage blocked */ }
  if (t !== "dark" && t !== "light") t = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  document.documentElement.dataset.theme = t;
})();
