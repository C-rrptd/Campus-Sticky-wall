// Advertiser flow: submit -> admin approval -> Midtrans payment -> scheduled -> live -> expired.
// Status, price, payment and approval are never decided in the browser: this page only collects
// the form, shows the server's quote and lists the advertiser's own campaigns.

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { config } from "./config.js";
import { getClient, invoke, query, rpc } from "./supabase-client.js";
import { rememberReceipt } from "./checkout.js";
import { getLocationPref, loadLocations } from "./location.js";
import { adPrice, isEmail, isHttpsUrl } from "./validation.js";
import { busy, el, errorMessage, formatDate, formatRupiah, refs, renderFilePreviews, setInputFiles, toast } from "./utils.js";

const LEVEL_LABEL = { global: "Everywhere", country: "Whole country", region: "Provinces / regions", city: "Cities", campus: "Campuses" };
const LEVEL_ORDER = ["campus", "city", "region", "country", "global"];
const REACH = { campus: "One or more campuses", city: "Cities", region: "Provinces / regions", country: "Whole country", global: "Everywhere" };
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
  if (c.starts_at) return c.status === "canceled" ? "Paid — refund under review" : "Paid";
  if (c.status === "approved") return "Due — pay to schedule";
  if (c.status === "awaiting_payment") return "Awaiting payment";
  if (["pending_approval", "pending_review", "draft"].includes(c.status)) return "Not due yet";
  return "Not charged";
}

function signInRequired(view) {
  const frag = cloneTemplate("tpl-signin-required");
  const r = refs(frag);
  r.title.textContent = "Sign in to advertise";
  r.message.textContent = "Advertisers need an account so campaigns, payments and receipts stay linked to you.";
  view.append(frag);
}

// A start date is a calendar day (Asia/Jakarta), not an instant: format it without any timezone shift.
const dayFmt = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
const fmtDay = (d) => dayFmt.format(new Date(`${d}T00:00:00Z`));

const options = (list) => list.map(([v, label]) => el("option", { value: v }, label));

export async function mountAdvertise(view, { signal, navigate }) {
  const user = currentUser();
  if (!user) return signInRequired(view);

  view.append(cloneTemplate("tpl-advertise-v2"));
  const r = refs(view);
  const client = getClient();
  const day = (offsetDays) => new Date(Date.now() + 7 * 3600e3 + offsetDays * 864e5).toISOString().slice(0, 10); // Asia/Jakarta date
  const today = day(0);
  const lastDay = day(180); // the server accepts start dates up to 180 days ahead
  r.start.min = today;
  r.start.max = lastDay;
  r.start.value = today;

  // The form is fully usable from the start; only Submit waits for the packages.
  const sel = { placement: null, duration: null, scope: null };
  const keep = new Map(); // scope level -> ids the advertiser ticked, so switching package doesn't lose them
  let available = [];
  let locations = null;

  const optionsFor = (level) => {
    if (level === "country") return locations.countries.map((c) => ({ id: c.code, label: c.name }));
    if (level === "region") return locations.regions.map((x) => ({ id: x.id, label: x.name }));
    if (level === "city") return locations.cities.map((x) => ({ id: x.id, label: x.name }));
    if (level === "campus") return locations.campuses.map((x) => ({ id: x.id, label: x.short_name ? `${x.short_name} — ${x.name}` : x.name }));
    return [];
  };
  const cheapest = (list) => list.reduce((a, b) => (BigInt(a.price_per_target) <= BigInt(b.price_per_target) ? a : b));
  const product = () => available.find((p) => group(p) === sel.placement && p.duration_days === sel.duration && p.scope_level === sel.scope);
  const selectedTargets = () => (sel.scope === "global" ? [{ level: "global" }]
    : [...r.targets.querySelectorAll("input[name=target]:checked")].map((i) => ({ level: sel.scope, id: i.value })));

  function updatePrice() {
    const p = product();
    const count = p ? selectedTargets().length : 0;
    r.sumPlacement.textContent = p ? PLACEMENT[group(p)].label : "—";
    r.sumDuration.textContent = p ? `${p.duration_days} days` : "—";
    r.sumTargets.textContent = String(count);
    r.sumStart.textContent = r.start.value ? fmtDay(r.start.value) : "—";
    r.sumTotal.textContent = p ? formatRupiah(adPrice(p.price_per_target, p.extra_location_pct, count)) : "—";
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
  function renderScope() {
    const levels = [...new Set(available.filter((p) => group(p) === sel.placement && p.duration_days === sel.duration).map((p) => p.scope_level))]
      .sort((a, b) => LEVEL_ORDER.indexOf(a) - LEVEL_ORDER.indexOf(b));
    if (!levels.includes(sel.scope)) sel.scope = levels[0];
    r.scope.replaceChildren(...options(levels.map((l) => {
      const p = available.find((x) => group(x) === sel.placement && x.duration_days === sel.duration && x.scope_level === l);
      return [l, `${REACH[l]} — ${formatRupiah(String(p.price_per_target))}${l === "global" ? "" : p.extra_location_pct ? ` for the first location, +${p.extra_location_pct}% for each extra` : " for any number of locations"}`];
    })));
    r.scope.value = sel.scope;
    renderTargets();
  }
  function renderDuration() {
    const list = available.filter((p) => group(p) === sel.placement);
    const days = [...new Set(list.map((p) => p.duration_days))].sort((a, b) => a - b);
    if (!days.includes(sel.duration)) sel.duration = days[0];
    r.duration.replaceChildren(...options(days.map((d) => [String(d), `${d} days — from ${formatRupiah(String(cheapest(list.filter((p) => p.duration_days === d)).price_per_target))}`])));
    r.duration.value = String(sel.duration);
    renderScope();
  }
  function renderPlacement() {
    const groups = [...new Set(available.map(group))];
    if (!groups.includes(sel.placement)) sel.placement = groups[0];
    r.placement.replaceChildren(...options(groups.map((g) => [g, PLACEMENT[g].label])));
    r.placement.value = sel.placement;
    r.placementHint.textContent = PLACEMENT[sel.placement].hint;
    renderDuration();
  }

  r.placement.addEventListener("change", () => { sel.placement = r.placement.value; r.placementHint.textContent = PLACEMENT[sel.placement].hint; renderDuration(); }, { signal });
  r.duration.addEventListener("change", () => { sel.duration = Number(r.duration.value); renderScope(); }, { signal });
  r.scope.addEventListener("change", () => { sel.scope = r.scope.value; renderTargets(); }, { signal });
  r.targets.addEventListener("change", () => {
    if (sel.scope !== "global") keep.set(sel.scope, new Set([...r.targets.querySelectorAll("input[name=target]:checked")].map((i) => i.value)));
    updatePrice();
  }, { signal });
  r.start.addEventListener("change", updatePrice, { signal });
  r.form.elements.description.addEventListener("input", (e) => { r.descCount.textContent = String(e.target.value.length); }, { signal });

  // ---- Image: validate + preview before anything is uploaded ---------------------------------
  const imageProblem = (file) => {
    if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) return "Use a PNG, JPG or WebP image.";
    if (file.size > 1024 * 1024) return "Images must be 1 MB or smaller.";
    return null;
  };
  const showImage = () => renderFilePreviews(r.creativePreview, [...(r.creative.files ?? [])].slice(0, 1), () => { setInputFiles(r.creative, []); showImage(); }, imageProblem);
  r.creative.addEventListener("change", showImage, { signal });
  signal.addEventListener("abort", () => renderFilePreviews(r.creativePreview, [], () => {}), { once: true });

  let uploaded = null; // { file, path }: a retry after a failed submit reuses the same upload
  async function uploadCreative(file) {
    const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
    const path = `${user.id}/${crypto.randomUUID()}.${ext}`;
    const { error } = await client.storage.from(config.creativeBucket).upload(path, file, { contentType: file.type, upsert: false });
    if (error) throw new Error("Image upload failed. Please try again.");
    return path;
  }

  // ---- Submit ----------------------------------------------------------------------------------
  r.form.addEventListener("submit", (e) => {
    e.preventDefault();
    busy(r.submit, async () => {
      r.error.textContent = "";
      const data = new FormData(r.form);
      const text = (k) => String(data.get(k) ?? "").trim();
      const link = text("destination_url");
      const file = r.creative.files?.[0];
      const p = product();
      const targets = selectedTargets();
      const problem =
        text("advertiser_name").length < 2 ? "Enter your business name."
        : !isEmail(text("contact_email")) ? "Enter a valid contact email."
        : text("title").length < 3 ? "The title needs at least 3 characters."
        : !text("description") ? "Add a short description."
        : link && !isHttpsUrl(link) ? "The link must start with https:// (or leave it empty)."
        : file && imageProblem(file) ? imageProblem(file)
        : !p ? "Choose a placement, duration and reach."
        : targets.length === 0 ? "Choose at least one location."
        : !r.start.value || r.start.value < today || r.start.value > lastDay ? "Pick a start date within the next 180 days."
        : !r.agree.checked ? "Please confirm you have read the advertising policy."
        : null;
      if (problem) { r.error.textContent = problem; return; }
      try {
        if (file && uploaded?.file !== file) uploaded = { file, path: await uploadCreative(file) };
        const res = await invoke("create-advertiser-campaign", {
          advertiser_name: text("advertiser_name"), contact_email: text("contact_email"), title: text("title"),
          description: text("description"), category: data.get("category"), destination_url: link || null,
          creative_path: file ? uploaded.path : null, product_id: p.id, requested_start: r.start.value, targets,
        });
        toast(`Submitted! Quoted price ${formatRupiah(String(res.price))}. We’ll review it and you can pay once it’s approved.`, "success", 9000);
        uploaded = null;
        r.form.reset();
        r.descCount.textContent = "0";
        r.start.value = today;
        showImage();
        renderPlacement();
        await loadMine();
      } catch (err) {
        r.error.textContent = errorMessage(err);
      }
    });
  }, { signal });

  // ---- Your campaigns ---------------------------------------------------------------------------
  function campaignItem(c) {
    const [label, tone] = campaignStatus(c);
    const rows = [
      ["Placement", PLACEMENT[group(c)].label],
      ["Duration", `${c.duration_days} days`],
      ["Price", c.price_snapshot != null ? formatRupiah(String(c.price_snapshot)) : "—"],
      ["Payment", paymentStatus(c)],
      [c.starts_at ? "Runs" : "Requested start", c.starts_at ? `${formatDate(c.starts_at)} – ${formatDate(c.ends_at)}` : fmtDay(c.requested_start)],
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
          toast(errorMessage(err), "error");
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
          toast(errorMessage(err), "error");
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

  // ---- Load packages, locations, WhatsApp contact (in parallel) ---------------------------------
  query(client.from("site_config").select("value").eq("key", "ad_whatsapp").limit(1)).then((rows) => {
    const digits = String(rows?.[0]?.value ?? "").replace(/\D/g, "");
    if (!/^\d{8,15}$/.test(digits)) return;
    r.whatsappLink.href = `https://wa.me/${digits}?text=${encodeURIComponent("Hi, I have a question about advertising on Campus Sticky Wall.")}`;
    r.whatsapp.hidden = false;
  }).catch(() => {});
  loadMine();

  try {
    // Only packages the admin has enabled are readable; wall-only packages were folded into Random Placement.
    const [products, locs] = await Promise.all([
      query(client.from("ad_products").select("id,name,placement,scope_level,duration_days,price_per_target::text,extra_location_pct").neq("placement", "wall_inline").order("sort_order")),
      loadLocations(),
    ]);
    locations = locs;
    // A package is offered only if its locations really exist and are enabled.
    available = products.filter((p) => p.scope_level === "global" || optionsFor(p.scope_level).length > 0);
  } catch (err) {
    r.error.textContent = `Advertising options are unavailable: ${errorMessage(err)}`;
    return;
  }
  if (available.length === 0) {
    r.error.textContent = "No advertising packages are available right now. Please check back soon or contact us.";
    return;
  }
  renderPlacement();
  r.submit.disabled = false;
}
