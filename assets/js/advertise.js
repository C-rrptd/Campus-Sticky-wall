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

// Paid ads can be cancelled for a refund only until 24 hours before they start (also enforced in cancel_my_campaign).
const CANCEL_CUTOFF_MS = 24 * 3600e3;

/** Display status from the stored status + dates (the server switches stored status every 15 minutes; this is never behind). */
function campaignStatus(c, now = Date.now()) {
  if (c.status === "expired" && !c.starts_at) return ["Expired", "bad"];
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

// A start date is a calendar day (Asia/Jakarta), not an instant: format it without any timezone shift.
const dayFmt = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
const fmtDay = (d) => dayFmt.format(new Date(`${d}T00:00:00Z`));

const options = (list) => list.map(([v, label]) => el("option", { value: v }, label));

export async function mountAdvertise(view, { signal, navigate }) {
  // Anyone can read the packages and prices; an account is only needed to submit (campaigns and receipts are linked to it).
  const user = currentUser();

  view.append(cloneTemplate("tpl-advertise-v2"));
  const r = refs(view);
  if (!user) {
    view.querySelector(".page-lead").after(el("p", { class: "panel" }, "Look around and try the price calculator without an account. To submit your ad, ",
      el("a", { href: "#/auth?next=/advertise" }, "sign in or create an account"), " (so your campaigns, payments and receipts stay linked to you)."));
    r.submit.textContent = "Sign in to submit";
  }
  const client = getClient();
  const day = (offsetDays) => new Date(Date.now() + 7 * 3600e3 + offsetDays * 864e5).toISOString().slice(0, 10); // Asia/Jakarta date
  const today = day(0);
  const lastDay = day(14); // the server accepts start dates up to 14 days ahead
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
  let reuseCreative = null; // image path of the campaign being run again, when no new image is chosen
  async function uploadCreative(file) {
    const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
    const path = `${user.id}/${crypto.randomUUID()}.${ext}`;
    const { error } = await client.storage.from(config.creativeBucket).upload(path, file, { contentType: file.type, upsert: false, cacheControl: "31536000" });
    if (error) throw new Error("Image upload failed. Please try again.");
    return path;
  }

  // ---- Submit ----------------------------------------------------------------------------------
  r.form.addEventListener("submit", (e) => {
    e.preventDefault();
    busy(r.submit, async () => {
      r.error.textContent = "";
      if (!user) { navigate("/auth", { next: "/advertise" }); return; }
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
        : !r.start.value || r.start.value < today || r.start.value > lastDay ? "Pick a start date within the next 14 days."
        : !r.agree.checked ? "Please confirm you have read the advertising policy."
        : null;
      if (problem) { r.error.textContent = problem; return; }
      try {
        if (file && uploaded?.file !== file) uploaded = { file, path: await uploadCreative(file) };
        const res = await invoke("create-advertiser-campaign", {
          advertiser_name: text("advertiser_name"), contact_email: text("contact_email"), title: text("title"),
          description: text("description"), category: data.get("category"), destination_url: link || null,
          creative_path: file ? uploaded.path : reuseCreative, product_id: p.id, requested_start: r.start.value, targets,
        });
        toast(`Submitted! Quoted price ${formatRupiah(String(res.price))}. We’ll review it and you can pay once it’s approved.`, "success", 9000);
        uploaded = null;
        reuseCreative = null;
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

  // ---- Daily results chart + "run it again" -------------------------------------------------------
  const SVG = "http://www.w3.org/2000/svg";
  const svg = (tag, attrs = {}, ...kids) => {
    const n = document.createElementNS(SVG, tag);
    for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
    n.append(...kids);
    return n;
  };
  /** One bar per day. Views and clicks get separate charts: clicks are far smaller, a shared scale would hide them. */
  function barChart(rows, key, label, cls) {
    const W = 300, H = 90, max = Math.max(1, ...rows.map((x) => Number(x[key])));
    const bw = W / rows.length;
    const chart = svg("svg", { viewBox: `0 0 ${W} ${H + 14}`, class: `chart ${cls}`, role: "img", "aria-label": `${label} per day, last ${rows.length} days` },
      ...rows.map((x, i) => {
        const h = (Number(x[key]) / max) * H;
        return svg("rect", { x: i * bw + 1, y: H - h, width: Math.max(1, bw - 2), height: h }, svg("title", {}, `${x.day}: ${x[key]} ${label.toLowerCase()}`));
      }),
      svg("text", { x: 0, y: H + 11, class: "chart__axis" }, rows[0].day.slice(5)),
      svg("text", { x: W, y: H + 11, class: "chart__axis", "text-anchor": "end" }, rows.at(-1).day.slice(5)));
    return el("figure", { class: "chart-fig" }, el("figcaption", { class: "small" }, `${label} (peak ${max})`), chart);
  }
  function resultsChart(c) {
    const box = el("details", { class: "campaign-item__chart" }, el("summary", {}, "Daily views and clicks"));
    let loaded = false;
    box.addEventListener("toggle", async () => {
      if (!box.open || loaded) return;
      loaded = true;
      const from = new Date(Math.max(new Date(c.starts_at).getTime(), Date.now() - 29 * 864e5) + 7 * 3600e3).toISOString().slice(0, 10);
      try {
        const rows = await query(client.from("campaign_daily_stats").select("day,impressions,clicks").eq("campaign_id", c.id).gte("day", from).order("day"));
        if (rows.length === 0) { box.append(el("p", { class: "small muted" }, "No views yet.")); return; }
        box.append(barChart(rows, "impressions", "Views", "chart--views"), barChart(rows, "clicks", "Clicks", "chart--clicks"),
          el("p", { class: "small muted" }, "Views are approximate (counted in the visitor’s browser)."));
      } catch {
        loaded = false;
        box.append(el("p", { class: "small muted" }, "Couldn’t load the chart."));
      }
    }, { signal });
    return box;
  }
  /** Copy a past campaign into the form (text, package, locations, image); the advertiser reviews and submits as usual. */
  async function runAgain(c) {
    const f = r.form.elements;
    for (const k of ["advertiser_name", "contact_email", "title", "description", "destination_url", "category"]) if (f[k]) f[k].value = c[k] ?? "";
    r.descCount.textContent = String((c.description ?? "").length);
    reuseCreative = c.creative_path ?? null;
    const endDay = c.ends_at ? new Date(new Date(c.ends_at).getTime() + 7 * 3600e3).toISOString().slice(0, 10) : today;
    r.start.value = endDay > today && endDay <= lastDay ? endDay : today;
    const p = available.find((x) => x.id === c.product_id);
    if (p) {
      Object.assign(sel, { placement: group(p), duration: p.duration_days, scope: p.scope_level });
      try {
        const rows = await query(client.from("campaign_targets").select("target_key").eq("campaign_id", c.id));
        keep.set(p.scope_level, new Set(rows.map((t) => t.target_key.split(":")[1])));
      } catch { keep.delete(p.scope_level); }
      renderPlacement();
    } else {
      updatePrice();
    }
    r.form.scrollIntoView({ behavior: "smooth" });
    toast(p ? "Copied into the form. Check the dates and submit to run it again." : "Copied the text. That package is no longer offered, so choose a new one.", "info", 7000);
  }

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
    const msLeft = c.ends_at ? new Date(c.ends_at).getTime() - Date.now() : 0;
    const ended = ["active", "scheduled", "expired"].includes(c.status) && c.starts_at && msLeft <= 0;
    const endingSoon = c.status === "active" && msLeft > 0 && msLeft <= 3 * 864e5;
    if (endingSoon) item.append(el("p", { class: "campaign-item__reason" }, `Ends in ${Math.ceil(msLeft / 864e5)} day(s). Run it again to keep your spot.`));
    if (c.starts_at && ["active", "scheduled", "expired", "paused"].includes(c.status)) item.append(resultsChart(c));
    if (c.status === "rejected" && c.moderation_reason) item.append(el("p", { class: "campaign-item__reason" }, `Rejected: ${c.moderation_reason}`));
    if (c.status === "canceled" && c.moderation_reason) item.append(el("p", { class: "small muted" }, c.moderation_reason));
    if (c.status === "expired" && !c.starts_at) item.append(el("p", { class: "small muted" }, `${c.moderation_reason || "Expired"}. Submit the ad again if you still want it.`));
    if (c.status === "awaiting_payment") item.append(el("p", { class: "small muted" }, "If you didn’t finish paying, it returns to “payment due” in about 30 minutes."));
    const buttons = [];
    if (c.status === "approved" && c.requested_start < today) {
      // The chosen live date has passed: let the advertiser pick a new one (still unpaid, still approved).
      const pick = el("input", { type: "date", min: today, max: lastDay, value: today, "aria-label": "New start date" });
      const save = el("button", { type: "button", class: "btn btn--small" }, "Change start date");
      save.addEventListener("click", () => busy(save, async () => {
        if (!pick.value || pick.value < today || pick.value > lastDay) { toast("Pick a start date within the next 14 days.", "error"); return; }
        try {
          await rpc("reschedule_my_campaign", { p_campaign_id: c.id, p_new_start: pick.value });
          toast("Start date updated.", "success");
          await loadMine();
        } catch (err) { toast(errorMessage(err), "error"); }
      }), { signal });
      item.append(el("p", { class: "campaign-item__reason" }, `Your chosen start date (${fmtDay(c.requested_start)}) has passed. Pick a new one, or pay now to start today.`),
        el("div", { class: "row row--tight" }, pick, save));
    }
    if (c.status === "approved") {
      // Payment starts the ad at the requested date (Jakarta midnight), or immediately if that has passed.
      const start = Math.max(Date.now(), new Date(`${c.requested_start}T00:00:00+07:00`).getTime());
      const cutoff = start - CANCEL_CUTOFF_MS;
      item.append(el("p", { class: "small muted" }, cutoff > Date.now()
        ? `Free cancellation with full refund until ${formatDate(new Date(cutoff).toISOString(), true)}. After that, no cancellation or refund.`
        : "This ad would start within 24 hours, so there is no cancellation or refund after you pay."));
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
    const cancellable = ["pending_approval", "approved"].includes(c.status) || (c.status === "scheduled" && c.starts_at && new Date(c.starts_at) > new Date(Date.now() + CANCEL_CUTOFF_MS));
    if (cancellable) {
      const cancel = el("button", { type: "button", class: "btn btn--small" }, "Cancel");
      cancel.addEventListener("click", () => busy(cancel, async () => {
        const paid = Boolean(c.starts_at);
        if (!window.confirm(paid ? "Cancel this campaign? You paid for it and it starts more than 24 hours from now, so a full refund is due." : "Cancel this campaign? Nothing has been charged.")) return;
        try {
          const res = await rpc("cancel_my_campaign", { p_campaign_id: c.id });
          toast(res?.refund_due ? "Cancelled. We’ll refund you through your original payment method." : res?.refund_review ? "Cancelled. You’ve reached the refund limit, so we’ll review your refund and email you." : "Campaign cancelled.", "success");
          await loadMine();
        } catch (err) {
          toast(errorMessage(err), "error");
        }
      }), { signal });
      buttons.push(cancel);
    }
    if (ended || endingSoon) {
      const again = el("button", { type: "button", class: "btn btn--small btn--primary" }, "Run it again");
      again.addEventListener("click", () => busy(again, () => runAgain(c)), { signal });
      buttons.push(again);
    }
    if (buttons.length) item.append(el("div", { class: "row row--tight" }, ...buttons));
    return item;
  }
  async function loadMine() {
    if (!user) { r.mine.replaceChildren(el("li", { class: "muted" }, "Sign in to see your campaigns.")); return; }
    try {
      const mine = await query(client.from("campaigns")
        .select("id,title,status,placement,duration_days,requested_start,starts_at,ends_at,price_snapshot,moderation_reason,created_at,product_id,description,category,advertiser_name,contact_email,destination_url,creative_path")
        .order("created_at", { ascending: false }).limit(20));
      // Views/clicks live in campaign_daily_stats only (campaigns.impressions is frozen).
      const totals = mine.length ? await rpc("campaign_totals", { p_ids: mine.map((c) => c.id) }).catch(() => []) : [];
      for (const c of mine) Object.assign(c, { impressions: 0, clicks: 0 }, totals.find((t) => t.campaign_id === c.id));
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
