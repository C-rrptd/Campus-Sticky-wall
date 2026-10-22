// Optional country / region / city / campus preference and cascading pickers.
// Never uses GPS. The preference is a convenience (stored in this browser and,
// for signed-in users, on their profile); it is not a security or billing boundary.

import { getClient, query } from "./supabase-client.js";
import { currentUser } from "./auth.js";
import { el, local } from "./utils.js";

const KEY = "csw.location";
let cache = null;

export function loadLocations() {
  if (!cache) {
    const c = getClient();
    cache = Promise.all([
      query(c.from("countries").select("code,name").order("sort_order").order("name")),
      query(c.from("regions").select("id,name,country_code,kind").order("name")),
      query(c.from("cities").select("id,name,region_id").order("name")),
      query(c.from("campuses").select("id,name,short_name,city_id").order("name")),
    ]).then(([countries, regions, cities, campuses]) => ({ countries, regions, cities, campuses }));
    cache.catch(() => { cache = null; });
  }
  return cache;
}

/** {country, region, city, campus} — any subset. */
export function getLocationPref() {
  const pref = local.get(KEY, {});
  return pref && typeof pref === "object" ? pref : {};
}

export async function setLocationPref(pref) {
  local.set(KEY, pref);
  const user = currentUser();
  if (!user) return;
  try {
    await query(getClient().from("profiles").update({
      country_code: pref.country || null, region_id: pref.region || null, city_id: pref.city || null, campus_id: pref.campus || null,
    }).eq("id", user.id));
  } catch (err) {
    console.warn("Could not save location preference", err);
  }
}

/** Parameters for get_promotions from a preference. */
export function promotionArgs(pref = getLocationPref()) {
  return { p_country: pref.country || null, p_region: pref.region || null, p_city: pref.city || null, p_campus: pref.campus || null };
}

function select(label, name) {
  const s = el("select", { name, "aria-label": label });
  return { wrap: el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, label), s), select: s };
}

function fill(sel, placeholder, items, value) {
  sel.replaceChildren(el("option", { value: "" }, placeholder), ...items.map((i) => el("option", { value: i.value }, i.label)));
  sel.value = items.some((i) => i.value === value) ? value : "";
  sel.disabled = items.length === 0;
}

/**
 * Cascading picker. onChange receives the full {country, region, city, campus}.
 * Returns the element immediately; options fill in when locations load.
 */
export function buildLocationPicker({ value = getLocationPref(), onChange, signal, compact = false }) {
  const country = select("Country", "country");
  const region = select("Province / region", "region");
  const city = select("City", "city");
  const campus = select("Campus", "campus");
  const root = el("div", { class: `location-picker${compact ? " location-picker--compact" : ""}` },
    country.wrap, region.wrap, city.wrap, campus.wrap);
  let data = null;
  const state = { ...value };

  const refresh = () => {
    if (!data) return;
    fill(country.select, "Any country", data.countries.map((c) => ({ value: c.code, label: c.name })), state.country);
    state.country = country.select.value;
    fill(region.select, "Any region", data.regions.filter((r) => r.country_code === state.country).map((r) => ({ value: r.id, label: r.name })), state.region);
    state.region = region.select.value;
    fill(city.select, "Any city", data.cities.filter((c) => c.region_id === state.region).map((c) => ({ value: c.id, label: c.name })), state.city);
    state.city = city.select.value;
    fill(campus.select, "Any campus", data.campuses.filter((c) => c.city_id === state.city).map((c) => ({ value: c.id, label: c.short_name ? `${c.short_name} — ${c.name}` : c.name })), state.campus);
    state.campus = campus.select.value;
  };

  const handler = (level) => () => {
    const order = ["country", "region", "city", "campus"];
    const idx = order.indexOf(level);
    const sel = { country, region, city, campus }[level].select;
    state[level] = sel.value;
    order.slice(idx + 1).forEach((k) => { state[k] = ""; });
    refresh();
    onChange?.({ ...state });
  };
  country.select.addEventListener("change", handler("country"), { signal });
  region.select.addEventListener("change", handler("region"), { signal });
  city.select.addEventListener("change", handler("city"), { signal });
  campus.select.addEventListener("change", handler("campus"), { signal });

  [country, region, city, campus].forEach((s) => { s.select.disabled = true; });
  loadLocations().then((d) => { data = d; refresh(); }).catch(() => {
    root.replaceChildren(el("p", { class: "muted small" }, "Locations are unavailable right now."));
  });
  return root;
}

/** Flat campus <select> (for composing a note). */
export function buildCampusSelect({ value = "", signal, onChange }) {
  const s = el("select", { name: "campus_id" }, el("option", { value: "" }, "No specific campus"));
  const wrap = el("label", { class: "field" }, el("span", { class: "field__label" }, "Campus (optional)"), s);
  loadLocations().then((d) => {
    d.campuses.forEach((c) => s.append(el("option", { value: c.id }, c.short_name ? `${c.short_name} — ${c.name}` : c.name)));
    s.value = value;
  }).catch(() => { s.disabled = true; });
  s.addEventListener("change", () => onChange?.(s.value), { signal });
  return { element: wrap, select: s };
}
