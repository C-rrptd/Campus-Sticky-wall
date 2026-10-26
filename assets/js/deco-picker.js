// Dropdown whose options show the decoration preview (a native <select> cannot).
// ARIA: button + listbox, arrow keys / Home / End / Enter / Escape, closes on outside click.
import { el } from "./utils.js";

let uid = 0;

/** options: [{ value, name, price, desc, cat }] (cat groups them). Empty value "" = the "none" row. */
export function decoPicker({ options, placeholder, label, signal, onChange }) {
  const id = `picker${++uid}`;
  const rows = [{ value: "", name: placeholder }, ...options];
  let value = "", active = 0, open = false;
  const swatch = (o) => (o.value ? el("span", { class: `deco-swatch deco-${o.value}`, "aria-hidden": "true" }) : null);
  const text = (o) => el("span", {}, o.name, o.price ? el("small", {}, o.price) : null);

  const btn = el("button", { type: "button", class: "picker__btn", "aria-haspopup": "listbox", "aria-expanded": "false", "aria-label": label, "aria-controls": `${id}-list` });
  const list = el("ul", { class: "picker__list", role: "listbox", id: `${id}-list`, "aria-label": label, tabindex: "-1", hidden: true });
  const root = el("div", { class: "picker" }, btn, list);

  const items = rows.map((o, i) => el("li", { class: "picker__opt", role: "option", id: `${id}-o${i}`, title: o.desc || null }, swatch(o), text(o)));
  let lastCat;
  rows.forEach((o, i) => {
    if (o.cat && o.cat !== lastCat) list.append(el("li", { class: "picker__group", role: "presentation" }, o.cat));
    lastCat = o.cat;
    items[i].addEventListener("click", () => choose(i), { signal });
    list.append(items[i]);
  });

  const paintButton = () => {
    const o = rows.find((r) => r.value === value) ?? rows[0];
    btn.replaceChildren(swatch(o) ?? "", text(o));
    items.forEach((li, i) => li.setAttribute("aria-selected", String(rows[i].value === value)));
  };
  const setActive = (i) => {
    active = Math.max(0, Math.min(rows.length - 1, i));
    items.forEach((li, k) => li.classList.toggle("is-active", k === active));
    btn.setAttribute("aria-activedescendant", items[active].id);
    items[active].scrollIntoView({ block: "nearest" });
  };
  const show = (on) => {
    open = on;
    list.hidden = !on;
    btn.setAttribute("aria-expanded", String(on));
    if (on) setActive(Math.max(0, rows.findIndex((r) => r.value === value)));
    else btn.removeAttribute("aria-activedescendant");
  };
  function choose(i) {
    value = rows[i].value;
    paintButton();
    show(false);
    btn.focus();
    onChange?.(value);
  }

  btn.addEventListener("click", () => show(!open), { signal });
  btn.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && open) { e.preventDefault(); show(false); return; }
    if (e.key === "Enter" && open) { e.preventDefault(); choose(active); return; }
    const move = { ArrowDown: active + 1, ArrowUp: active - 1, Home: 0, End: rows.length - 1 }[e.key];
    if (move === undefined) return;
    e.preventDefault();
    if (!open) show(true); else setActive(move);
  }, { signal });
  document.addEventListener("click", (e) => { if (open && !root.contains(e.target)) show(false); }, { signal });
  paintButton();

  return {
    element: root,
    get value() { return value; },
    set value(v) { value = rows.some((r) => r.value === v) ? v : ""; paintButton(); },
    set disabled(d) { btn.disabled = d; if (d) show(false); },
    focus: () => btn.focus(),
  };
}
