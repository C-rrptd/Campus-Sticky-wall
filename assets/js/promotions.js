// Promotions feed (sponsored listings by location) and the advertiser flow:
// draft campaign -> server-priced order -> Midtrans -> admin review -> live.
// Status, price, payment and approval are never decided in the browser.

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { config } from "./config.js";
import { creativeUrl, getClient, invoke, query, rpc } from "./supabase-client.js";
import { rememberReceipt } from "./checkout.js";
import { buildLocationPicker, getLocationPref, loadLocations, promotionArgs, setLocationPref } from "./location.js";
import { isEmail, isHttpsUrl } from "./validation.js";
import { busy, el, errorMessage, formatDate, formatRupiah, refs, safeUrl, session } from "./utils.js";

const CATEGORY_LABELS = {
  local_business: "Local business", student_discount: "Student discount", campus_event: "Campus event",
  workshop: "Workshop", competition: "Competition", recruitment: "Internship / jobs",
  student_service: "Student service", club_event: "Club event", other: "Promotion",
};

let observer = null;
function trackImpression(node, id) {
  const key = `csw.seen.${id}`;
  if (session.get(key)) return;
  if (!("IntersectionObserver" in window)) return;
  observer ??= new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const cid = entry.target.dataset.campaignId;
      observer.unobserve(entry.target);
      if (session.get(`csw.seen.${cid}`)) continue;
      session.set(`csw.seen.${cid}`, true);
      rpc("record_campaign_event", { p_campaign_id: cid, p_kind: "impression" }).catch(() => {});
    }
  }, { threshold: 0.5 });
  observer.observe(node);
}

/** Render one sponsored listing (always labelled "Sponsored"). */
export function renderPromotion(p, { compact = false } = {}) {
  const frag = cloneTemplate("tpl-promotion-card");
  const r = refs(frag);
  r.root.dataset.campaignId = p.id;
  if (compact) r.root.classList.add("promo--inline");
  r.category.textContent = CATEGORY_LABELS[p.category] ?? "Promotion";
  r.title.textContent = p.title;
  r.description.textContent = p.description;
  r.advertiser.textContent = p.advertiser_name;
  r.ends.textContent = p.ends_at ? `until ${formatDate(p.ends_at)}` : "";
  const img = creativeUrl(p.creative_path);
  if (img) {
    r.image.src = img;
    r.image.alt = p.title;
    r.image.hidden = false;
  }
  const href = safeUrl(p.destination_url, false);
  if (href) {
    r.link.href = href;
    r.link.addEventListener("click", () => {
      rpc("record_campaign_event", { p_campaign_id: p.id, p_kind: "click" }).catch(() => {});
    });
  } else r.link.hidden = true;
  trackImpression(r.root, p.id);
  return frag;
}

export async function mount(view, { signal }) {
  view.append(cloneTemplate("tpl-promotions"));
  const r = refs(view);
  let loc = getLocationPref();
  let requestId = 0;

  const load = async () => {
    const id = ++requestId;
    r.grid.setAttribute("aria-busy", "true");
    r.error.hidden = true;
    try {
      const items = await rpc("get_promotions", {
        ...promotionArgs(loc), p_placement: "promotions_feed", p_category: r.category.value || null, p_limit: 48,
      });
      if (id !== requestId || signal.aborted) return;
      r.grid.replaceChildren(...items.map((p) => renderPromotion(p)));
      r.empty.hidden = items.length > 0;
    } catch (err) {
      if (id !== requestId) return;
      r.error.textContent = `Couldn’t load promotions: ${errorMessage(err)}`;
      r.error.hidden = false;
    } finally {
      if (id === requestId) r.grid.setAttribute("aria-busy", "false");
    }
  };

  r.location.append(buildLocationPicker({ value: loc, compact: true, signal, onChange: (v) => { loc = v; setLocationPref(v); load(); } }));
  r.category.addEventListener("change", load, { signal });
  await load();
}

// ------------------------------------------------------------- advertising

const LEVEL_LABEL = { global: "Everywhere", country: "Countries", region: "Provinces / regions", city: "Cities", campus: "Campuses" };

function signInRequired(view, message) {
  const frag = cloneTemplate("tpl-signin-required");
  const r = refs(frag);
  r.title.textContent = "Sign in to advertise";
  r.message.textContent = message;
  view.append(frag);
}

export async function mountAdvertise(view, { signal, navigate }) {
  const user = currentUser();
  if (!user) {
    signInRequired(view, "Advertisers need an account so campaigns, payments and receipts stay linked to you.");
    return;
  }
  view.append(cloneTemplate("tpl-advertise"));
  const r = refs(view);
  const client = getClient();
  const today = new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10); // Asia/Jakarta date
  r.start.min = today;
  r.start.value = today;

  let products = [];
  let locations = null;
  try {
    [products, locations] = await Promise.all([
      query(client.from("ad_products").select("id,name,placement,scope_level,duration_days,price_per_target::text").order("sort_order")),
      loadLocations(),
    ]);
  } catch (err) {
    r.error.textContent = `Advertising options are unavailable: ${errorMessage(err)}`;
    return;
  }
  r.product.replaceChildren(...products.map((p) =>
    el("option", { value: p.id }, `${p.name} — ${formatRupiah(String(p.price_per_target))} per location`)));

  const product = () => products.find((p) => p.id === r.product.value);
  const optionsFor = (level) => {
    if (level === "country") return locations.countries.map((c) => ({ id: c.code, label: c.name }));
    if (level === "region") return locations.regions.map((x) => ({ id: x.id, label: x.name }));
    if (level === "city") return locations.cities.map((x) => ({ id: x.id, label: x.name }));
    if (level === "campus") return locations.campuses.map((x) => ({ id: x.id, label: x.short_name ? `${x.short_name} — ${x.name}` : x.name }));
    return [];
  };

  const renderTargets = () => {
    const p = product();
    if (!p) return;
    if (p.scope_level === "global") {
      r.targets.replaceChildren(el("p", { class: "small" }, "Shown to every visitor, in every area."));
    } else {
      const pref = getLocationPref();
      const preselect = { country: pref.country, region: pref.region, city: pref.city, campus: pref.campus }[p.scope_level];
      r.targets.replaceChildren(
        el("p", { class: "field__label" }, `${LEVEL_LABEL[p.scope_level]} to target`),
        el("div", { class: "check-grid" }, ...optionsFor(p.scope_level).map((o) =>
          el("label", { class: "check" }, el("input", { type: "checkbox", name: "target", value: o.id, checked: o.id === preselect || null }), el("span", {}, o.label)))),
      );
    }
    updatePrice();
  };

  const selectedTargets = () => {
    const p = product();
    if (!p) return [];
    if (p.scope_level === "global") return [{ level: "global" }];
    return [...r.targets.querySelectorAll("input[name=target]:checked")].map((i) => ({ level: p.scope_level, id: i.value }));
  };

  const updatePrice = () => {
    const p = product();
    const count = selectedTargets().length;
    r.sumProduct.textContent = p?.name ?? "—";
    r.sumTargets.textContent = String(count);
    r.sumDuration.textContent = p ? `${p.duration_days} days` : "—";
    r.sumTotal.textContent = p ? formatRupiah(BigInt(String(p.price_per_target)) * BigInt(count)) : "—";
  };

  r.product.addEventListener("change", renderTargets, { signal });
  r.targets.addEventListener("change", updatePrice, { signal });
  renderTargets();

  async function uploadCreative(file) {
    if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) throw new Error("Images must be PNG, JPG or WebP.");
    if (file.size > 1024 * 1024) throw new Error("Images must be 1 MB or smaller.");
    const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
    const path = `${user.id}/${crypto.randomUUID()}.${ext}`;
    const { error } = await client.storage.from(config.creativeBucket).upload(path, file, { contentType: file.type, upsert: false });
    if (error) throw new Error("Image upload failed. Please try again.");
    return path;
  }

  r.form.addEventListener("submit", (e) => {
    e.preventDefault();
    busy(r.submit, async () => {
      r.error.textContent = "";
      const data = new FormData(r.form);
      const targets = selectedTargets();
      if (!isEmail(data.get("contact_email"))) { r.error.textContent = "Enter a valid contact email."; return; }
      if (!isHttpsUrl(String(data.get("destination_url") ?? ""))) { r.error.textContent = "The destination link must start with https://"; return; }
      if (targets.length === 0) { r.error.textContent = "Choose at least one location."; return; }
      try {
        const file = r.creative.files?.[0];
        const creativePath = file ? await uploadCreative(file) : null;
        const draft = await invoke("create-advertiser-campaign", {
          advertiser_name: String(data.get("advertiser_name") ?? "").trim(),
          contact_email: String(data.get("contact_email") ?? "").trim(),
          title: String(data.get("title") ?? "").trim(),
          description: String(data.get("description") ?? "").trim(),
          category: data.get("category"),
          destination_url: String(data.get("destination_url") ?? "").trim(),
          creative_path: creativePath,
          product_id: r.product.value,
          requested_start: r.start.value,
          targets,
        });
        const res = await invoke("create-ad-order", { campaign_id: draft.campaign_id });
        rememberReceipt(res.order.order_ref, res.access_token);
        navigate("/checkout", { order: res.order.order_ref });
      } catch (err) {
        r.error.textContent = errorMessage(err);
      }
    });
  }, { signal });

  // Own campaigns
  try {
    const mine = await query(client.from("campaigns")
      .select("id,title,status,starts_at,ends_at,price_snapshot,impressions,clicks,created_at")
      .order("created_at", { ascending: false }).limit(20));
    const STATUS = { draft: "Draft (unpaid)", awaiting_payment: "Awaiting payment", pending_review: "Paid — in review", active: "Live",
      paused: "Paused", rejected: "Rejected", canceled: "Cancelled" };
    r.mine.replaceChildren(...(mine.length ? mine.map((c) => {
      const li = el("li", {}, el("strong", {}, c.title), " · ", STATUS[c.status] ?? c.status,
        c.ends_at ? ` · until ${formatDate(c.ends_at)}` : "", ` · ${c.impressions} views, ${c.clicks} clicks`);
      if (c.status === "draft") {
        const pay = el("button", { type: "button", class: "btn btn--small" }, "Pay now");
        pay.addEventListener("click", () => busy(pay, async () => {
          try {
            const res = await invoke("create-ad-order", { campaign_id: c.id });
            rememberReceipt(res.order.order_ref, res.access_token);
            navigate("/checkout", { order: res.order.order_ref });
          } catch (err) {
            r.error.textContent = errorMessage(err);
          }
        }), { signal });
        li.append(" ", pay);
      }
      return li;
    }) : [el("li", { class: "muted" }, "No campaigns yet.")]));
  } catch {
    r.mine.replaceChildren(el("li", { class: "muted" }, "Couldn’t load your campaigns."));
  }
}
