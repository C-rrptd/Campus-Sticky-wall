// Promotions feed (sponsored listings by location) and the advertiser flow:
// submit -> admin approval -> Midtrans payment -> scheduled -> live -> expired (all automatic after approval).
// Status, price, payment and approval are never decided in the browser.

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { config } from "./config.js";
import { creativeUrl, getClient, invoke, query, rpc } from "./supabase-client.js";
import { rememberReceipt } from "./checkout.js";
import { buildLocationPicker, getLocationPref, loadLocations, promotionArgs, setLocationPref } from "./location.js";
import { isEmail, isHttpsUrl } from "./validation.js";
import { busy, el, errorMessage, formatDate, formatRupiah, refs, renderFilePreviews, safeUrl, session, setInputFiles, toast } from "./utils.js";

const CATEGORY_LABELS = {
  local_business: "Local business", student_discount: "Student discount", campus_event: "Campus event",
  workshop: "Workshop", competition: "Competition", recruitment: "Internship / jobs",
  student_service: "Student service", club_event: "Club event", other: "Promotion",
};

/** Featured Placement: up to two pinned spots above the feed (also used on the wall). */
export async function loadFeatured(container, loc, signal) {
  try {
    const items = await rpc("get_promotions", { ...promotionArgs(loc), p_placement: "featured", p_category: null, p_limit: 2 });
    if (!signal?.aborted) container.replaceChildren(...items.map((p) => renderPromotion(p)));
  } catch {
    container.replaceChildren();
  }
}

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
        ...promotionArgs(loc), p_placement: "random", p_category: r.category.value || null, p_limit: 48,
      });
      if (id !== requestId || signal.aborted) return;
      r.grid.replaceChildren(...items.map((p) => renderPromotion(p)));
      r.empty.hidden = items.length > 0;
      if (!r.category.value) await loadFeatured(r.featured, loc, signal);
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

const LEVEL_LABEL = { global: "Everywhere", country: "Whole country", region: "Provinces / regions", city: "Cities", campus: "Campuses" };
const LEVEL_ORDER = ["campus", "city", "region", "country", "global"];
const PLACEMENT = {
  random: { label: "Random Placement", hint: "Shown in the Promotions feed and between notes on the wall, rotating fairly." },
  featured: { label: "Featured Placement", hint: "Pinned at the top of the Wall and Promotions pages." },
};
const group = (p) => (p.placement === "featured" ? "featured" : "random");
const STATUS = {
  pending_approval: ["In review", "warn"], approved: ["Approved — payment due", "ok"], awaiting_payment: ["Payment started", "warn"],
  pending_review: ["Paid — in review", "warn"], paused: ["Paused", "warn"], rejected: ["Rejected", "bad"], canceled: ["Cancelled", "bad"],
  draft: ["Draft", ""], scheduled: ["Scheduled", "ok"], active: ["Live", "ok"], expired: ["Ended", ""],
};

/** Display status from the stored status + dates (the server switches stored status every 15 minutes; this is never behind). */
function campaignStatus(c, now = Date.now()) {
  if (c.status === "expired" && !c.starts_at) return ["Expired — not paid", "bad"];
  if ((c.status === "active" || c.status === "scheduled") && c.starts_at && c.ends_at) {
    if (now >= new Date(c.ends_at).getTime()) return ["Ended", ""];
    if (now < new Date(c.starts_at).getTime()) return ["Scheduled", "ok"];
    return ["Live", "ok"];
  }
  return STATUS[c.status] ?? [c.status, ""];
}
function paymentStatus(c) {
  const paid = Boolean(c.starts_at);
  if (paid) return c.status === "canceled" ? "Paid — refund under review" : "Paid";
  if (c.status === "approved") return "Due — pay to schedule";
  if (c.status === "awaiting_payment") return "Awaiting payment";
  if (["pending_approval", "pending_review", "draft"].includes(c.status)) return "Not due yet";
  return "Not charged";
}

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
  r.form.classList.add("is-loading");

  let products = [];
  let locations = null;
  try {
    // Only packages the admin has enabled are readable; wall-only packages were folded into Random Placement.
    [products, locations] = await Promise.all([
      query(client.from("ad_products").select("id,name,placement,scope_level,duration_days,price_per_target::text").neq("placement", "wall_inline").order("sort_order")),
      loadLocations(),
    ]);
  } catch (err) {
    r.error.textContent = `Advertising options are unavailable: ${errorMessage(err)}`;
    r.submit.disabled = true;
    return;
  }
  r.form.classList.remove("is-loading");

  // WhatsApp is optional and only shown when the admin has set a number.
  query(client.from("site_config").select("value").eq("key", "ad_whatsapp").limit(1)).then((rows) => {
    const digits = String(rows?.[0]?.value ?? "").replace(/\D/g, "");
    if (!/^\d{8,15}$/.test(digits)) return;
    r.whatsappLink.href = `https://wa.me/${digits}?text=${encodeURIComponent("Hi, I have a question about advertising on Campus Sticky Wall.")}`;
    r.whatsapp.hidden = false;
  }).catch(() => {});

  const optionsFor = (level) => {
    if (level === "country") return locations.countries.map((c) => ({ id: c.code, label: c.name }));
    if (level === "region") return locations.regions.map((x) => ({ id: x.id, label: x.name }));
    if (level === "city") return locations.cities.map((x) => ({ id: x.id, label: x.name }));
    if (level === "campus") return locations.campuses.map((x) => ({ id: x.id, label: x.short_name ? `${x.short_name} — ${x.name}` : x.name }));
    return [];
  };
  // A package is offered only if its locations really exist and are enabled.
  const available = products.filter((p) => p.scope_level === "global" || optionsFor(p.scope_level).length > 0);
  if (available.length === 0) {
    r.error.textContent = "No advertising packages are available right now. Please check back soon or contact us.";
    r.submit.disabled = true;
    return;
  }

  const sel = { placement: null, duration: null, scope: null };
  const keep = new Map(); // scope level -> ids the advertiser ticked, so switching placement/duration doesn't lose them
  const radio = (name, value, title, sub, checked) => el("label", { class: "choice" },
    el("input", { type: "radio", name, value, checked: checked || null }), el("span", { class: "choice__body" }, el("strong", {}, title), sub ? el("small", {}, sub) : null));
  const cheapest = (list) => list.reduce((a, b) => (BigInt(a.price_per_target) <= BigInt(b.price_per_target) ? a : b));

  const product = () => available.find((p) => group(p) === sel.placement && p.duration_days === sel.duration && p.scope_level === sel.scope);

  function renderPlacements() {
    const groups = [...new Set(available.map(group))];
    if (!groups.includes(sel.placement)) sel.placement = groups[0];
    r.placements.replaceChildren(...groups.map((g) => radio("placement", g, PLACEMENT[g].label, PLACEMENT[g].hint, g === sel.placement)));
    renderDurations();
  }
  function renderDurations() {
    const list = available.filter((p) => group(p) === sel.placement);
    const days = [...new Set(list.map((p) => p.duration_days))].sort((a, b) => a - b);
    if (!days.includes(sel.duration)) sel.duration = days[0];
    r.durations.replaceChildren(...days.map((d) => radio("duration", String(d), `${d} days`,
      `from ${formatRupiah(String(cheapest(list.filter((p) => p.duration_days === d)).price_per_target))}`, d === sel.duration)));
    renderScopes();
  }
  function renderScopes() {
    const levels = [...new Set(available.filter((p) => group(p) === sel.placement && p.duration_days === sel.duration).map((p) => p.scope_level))]
      .sort((a, b) => LEVEL_ORDER.indexOf(a) - LEVEL_ORDER.indexOf(b));
    if (!levels.includes(sel.scope)) sel.scope = levels[0];
    r.scope.replaceChildren(...levels.map((l) => {
      const p = available.find((x) => group(x) === sel.placement && x.duration_days === sel.duration && x.scope_level === l);
      return el("option", { value: l, selected: l === sel.scope || null },
        `${{ campus: "One or more campuses", city: "Cities", region: "Provinces / regions", country: "Whole country", global: "Everywhere" }[l]} — ${formatRupiah(String(p.price_per_target))}${l === "global" ? "" : " per location"}`);
    }));
    renderTargets();
  }
  function renderTargets() {
    if (sel.scope === "global") {
      r.targets.replaceChildren(el("p", { class: "small" }, "Shown to every visitor, in every area."));
    } else {
      const pref = getLocationPref();
      const kept = keep.get(sel.scope);
      const preselect = { country: pref.country, region: pref.region, city: pref.city, campus: pref.campus }[sel.scope];
      r.targets.replaceChildren(
        el("p", { class: "field__label" }, `${LEVEL_LABEL[sel.scope]} to target`),
        el("div", { class: "check-grid" }, ...optionsFor(sel.scope).map((o) =>
          el("label", { class: "check" }, el("input", { type: "checkbox", name: "target", value: o.id, checked: (kept ? kept.has(o.id) : o.id === preselect) || null }), el("span", {}, o.label)))));
    }
    updatePrice();
  }
  const selectedTargets = () => (sel.scope === "global" ? [{ level: "global" }]
    : [...r.targets.querySelectorAll("input[name=target]:checked")].map((i) => ({ level: sel.scope, id: i.value })));

  function updatePrice() {
    const p = product();
    const count = p ? selectedTargets().length : 0;
    r.sumPlacement.textContent = p ? PLACEMENT[group(p)].label : "—";
    r.sumDuration.textContent = p ? `${p.duration_days} days` : "—";
    r.sumTargets.textContent = String(count);
    r.sumStart.textContent = r.start.value ? formatDate(`${r.start.value}T00:00:00+07:00`) : "—";
    r.sumTotal.textContent = p ? formatRupiah(BigInt(String(p.price_per_target)) * BigInt(count)) : "—";
  }

  r.placements.addEventListener("change", (e) => { sel.placement = e.target.value; renderDurations(); }, { signal });
  r.durations.addEventListener("change", (e) => { sel.duration = Number(e.target.value); renderScopes(); }, { signal });
  r.scope.addEventListener("change", () => { sel.scope = r.scope.value; renderTargets(); }, { signal });
  r.targets.addEventListener("change", () => {
    if (sel.scope !== "global") keep.set(sel.scope, new Set([...r.targets.querySelectorAll("input[name=target]:checked")].map((i) => i.value)));
    updatePrice();
  }, { signal });
  r.start.addEventListener("change", updatePrice, { signal });
  r.form.elements.description.addEventListener("input", (e) => { r.descCount.textContent = String(e.target.value.length); }, { signal });
  renderPlacements();

  // Image: validate + preview before anything is uploaded.
  const imageProblem = (file) => {
    if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) return "Use a PNG, JPG or WebP image.";
    if (file.size > 1024 * 1024) return "Images must be 1 MB or smaller.";
    return null;
  };
  const showImage = () => {
    const files = [...(r.creative.files ?? [])].slice(0, 1);
    renderFilePreviews(r.creativePreview, files, () => { setInputFiles(r.creative, []); showImage(); }, imageProblem);
  };
  r.creative.addEventListener("change", showImage, { signal });
  signal.addEventListener("abort", () => renderFilePreviews(r.creativePreview, [], () => {}), { once: true });

  async function uploadCreative(file) {
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
      const link = String(data.get("destination_url") ?? "").trim();
      const text = (k) => String(data.get(k) ?? "").trim();
      const file = r.creative.files?.[0];
      if (text("advertiser_name").length < 2) { r.error.textContent = "Enter your business name."; return; }
      if (!isEmail(text("contact_email"))) { r.error.textContent = "Enter a valid contact email."; return; }
      if (text("title").length < 3) { r.error.textContent = "The title needs at least 3 characters."; return; }
      if (!text("description")) { r.error.textContent = "Add a short description."; return; }
      if (link && !isHttpsUrl(link)) { r.error.textContent = "The link must start with https:// (or leave it empty)."; return; }
      if (file && imageProblem(file)) { r.error.textContent = imageProblem(file); return; }
      const p = product();
      if (!p) { r.error.textContent = "Choose a placement, duration and reach."; return; }
      if (targets.length === 0) { r.error.textContent = "Choose at least one location."; return; }
      if (!r.start.value || r.start.value < today) { r.error.textContent = "Pick a start date from today onward."; return; }
      if (!r.agree.checked) { r.error.textContent = "Please confirm you have read the advertising policy."; r.agree.focus(); return; }
      try {
        const creativePath = file ? await uploadCreative(file) : null;
        const res = await invoke("create-advertiser-campaign", {
          advertiser_name: text("advertiser_name"), contact_email: text("contact_email"), title: text("title"),
          description: text("description"), category: data.get("category"), destination_url: link || null,
          creative_path: creativePath, product_id: p.id, requested_start: r.start.value, targets,
        });
        toast(`Submitted! Quoted price ${formatRupiah(String(res.price))}. We’ll review it and you can pay once it’s approved.`, "success", 9000);
        r.form.reset();
        r.start.value = today;
        showImage();
        renderPlacements();
        await loadMine();
      } catch (err) {
        r.error.textContent = errorMessage(err);
      }
    });
  }, { signal });

  // ---- Your campaigns --------------------------------------------------------------------
  function campaignItem(c) {
    const [label, tone] = campaignStatus(c);
    const rows = [
      ["Placement", PLACEMENT[c.placement === "featured" ? "featured" : "random"].label],
      ["Duration", `${c.duration_days} days`],
      ["Price", c.price_snapshot != null ? formatRupiah(String(c.price_snapshot)) : "—"],
      ["Payment", paymentStatus(c)],
      [c.starts_at ? "Runs" : "Requested start", c.starts_at ? `${formatDate(c.starts_at)} – ${formatDate(c.ends_at)}` : formatDate(`${c.requested_start}T00:00:00+07:00`)],
    ];
    if (["active", "scheduled", "expired", "paused"].includes(c.status) && c.starts_at) rows.push(["Results", `${c.impressions} views, ${c.clicks} clicks`]);
    const item = el("li", { class: "campaign-item" },
      el("div", { class: "campaign-item__head" }, el("strong", {}, c.title), el("span", { class: `badge${tone ? ` badge--${tone}` : ""}` }, label)),
      el("dl", {}, ...rows.flatMap(([k, v]) => [el("dt", {}, k), el("dd", {}, v)])));
    if (c.status === "rejected" && c.moderation_reason) item.append(el("p", { class: "campaign-item__reason" }, `Rejected: ${c.moderation_reason}`));
    if (c.status === "canceled" && c.moderation_reason) item.append(el("p", { class: "small muted" }, c.moderation_reason));
    if (c.status === "expired" && !c.starts_at) item.append(el("p", { class: "small muted" }, "The payment window passed. Submit the ad again if you still want it."));
    if (c.status === "awaiting_payment") item.append(el("p", { class: "small muted" }, "If you didn’t finish paying, it returns to “payment due” in about 30 minutes."));
    const buttons = [];
    if (c.status === "approved") {
      const pay = el("button", { type: "button", class: "btn btn--small btn--primary" }, `Pay ${formatRupiah(String(c.price_snapshot))}`);
      pay.addEventListener("click", () => busy(pay, async () => {
        try {
          const res = await invoke("create-ad-order", { campaign_id: c.id });
          rememberReceipt(res.order.order_ref, res.access_token);
          navigate("/checkout", { order: res.order.order_ref });
        } catch (err) {
          r.error.textContent = errorMessage(err);
        }
      }), { signal });
      buttons.push(pay);
    }
    const cancellable = ["pending_approval", "approved"].includes(c.status) || (c.status === "scheduled" && c.starts_at && new Date(c.starts_at) > new Date());
    if (cancellable) {
      const cancel = el("button", { type: "button", class: "btn btn--small" }, "Cancel");
      cancel.addEventListener("click", () => busy(cancel, async () => {
        const paid = Boolean(c.starts_at);
        if (!window.confirm(paid ? "Cancel this campaign? You paid for it, so a full refund is due since it hasn’t started." : "Cancel this campaign? Nothing has been charged.")) return;
        try {
          const res = await rpc("cancel_my_campaign", { p_campaign_id: c.id });
          toast(res?.refund_due ? "Cancelled. We’ll refund you through your original payment method." : "Campaign cancelled.", "success");
          await loadMine();
        } catch (err) {
          r.error.textContent = errorMessage(err);
        }
      }), { signal });
      buttons.push(cancel);
    }
    if (buttons.length) item.append(el("div", { class: "row row--tight" }, ...buttons));
    return item;
  }

  async function loadMine() {
    try {
      const mine = await query(client.from("campaigns")
        .select("id,title,status,placement,duration_days,requested_start,starts_at,ends_at,price_snapshot,moderation_reason,impressions,clicks,created_at")
        .order("created_at", { ascending: false }).limit(20));
      r.mine.replaceChildren(...(mine.length ? mine.map(campaignItem) : [el("li", { class: "muted" }, "No campaigns yet.")]));
    } catch {
      r.mine.replaceChildren(el("li", { class: "muted" }, "Couldn’t load your campaigns."));
    }
  }
  await loadMine();
}
