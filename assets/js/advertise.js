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
import { busy, el, errorMessage, formatDate, formatRupiah, openDialog, refs, renderFilePreviews, setInputFiles, toast } from "./utils.js";

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

  const targetKey = (level, id) => (level === "global" ? "global:*" : `${level}:${id}`);
  let trustSeq = 0;
  /** Real recent views for the selected locations, or the launch message when there is no data yet. */
  async function refreshTrust() {
    const p = product();
    const t = p ? selectedTargets() : [];
    if (!p || t.length === 0) { r.trust.textContent = ""; return; }
    const seq = ++trustSeq;
    try {
      const rows = await rpc("get_locations_recent_views", { p_spot: group(p), p_keys: t.map((x) => targetKey(x.level, x.id)) });
      if (seq !== trustSeq) return;
      const total = rows.reduce((sum, x) => sum + Number(x.views_7d), 0);
      r.trust.textContent = total > 0
        ? `${total.toLocaleString("en-US")} ad views at ${rows.length === 1 ? rows[0].label : "the selected locations"} in the last 7 days.`
        : "New platform, launch pricing applies.";
    } catch { if (seq === trustSeq) r.trust.textContent = ""; }
  }
  // ---- Slots: "1 of 3 slots left", next free date, rotation share, top-slot price ------------------------
  let availSeq = 0;
  let slotMult = 1; // display only: the server prices at submit
  async function refreshAvailability() {
    const p = product();
    const t = p ? selectedTargets() : [];
    const seq = ++availSeq;
    if (!p || group(p) !== "featured" || !t.length || !r.start.value) {
      r.avail.replaceChildren(); r.slotField.hidden = true; slotMult = 1; return;
    }
    try {
      const slot = r.slotType.value === "top" ? "top" : "standard";
      const rows = await rpc("get_ad_availability", { p_keys: t.map((x) => targetKey(x.level, x.id)), p_slot_type: slot, p_start: r.start.value, p_days: p.duration_days });
      if (seq !== availSeq) return;
      r.slotField.hidden = !rows.some((x) => x.top_slots > 0);
      if (r.slotField.hidden) r.slotType.value = "standard";
      slotMult = Math.max(1, ...rows.map((x) => Number(slot === "top" ? x.top_multiplier : x.standard_multiplier)));
      r.slotHint.textContent = `Top slot costs ${Math.max(...rows.map((x) => Number(x.top_multiplier)))}× the standard price.`;
      r.avail.replaceChildren(...rows.map((x) => el("li", {},
        x.total === 0 ? `No ${slot} slot at this location.`
        : x.available > 0 ? `${x.available} of ${x.total} ${slot} slot${x.total === 1 ? "" : "s"} left. ${x.rotation_mode === "equal_share" ? `Expected share of views: about ${x.expected_share_pct}% (rotation).` : "Fixed position."}`
        : `Sold out.${x.next_free_date ? ` Next free from ${fmtDay(x.next_free_date)}.` : ""} Use “Notify me” below.`)));
      updatePrice(false);
    } catch { if (seq === availSeq) r.avail.replaceChildren(); }
  }
  const priceText = (p) => (p.launch ? `${formatRupiah(p.list_price_per_target)} → ${formatRupiah(p.price_per_target)}` : formatRupiah(p.price_per_target));

  function updatePrice(refresh = true) {
    const p = product();
    const count = p ? selectedTargets().length : 0;
    r.sumPlacement.textContent = p ? PLACEMENT[group(p)].label : "—";
    r.sumDuration.textContent = p ? `${p.duration_days} days` : "—";
    r.sumTargets.textContent = String(count);
    r.sumStart.textContent = r.start.value ? fmtDay(r.start.value) : "—";
    const total = p ? Math.round(Number(adPrice(p.price_per_target, p.extra_location_pct, count)) * slotMult) : null;
    const list = p ? Math.round(Number(adPrice(p.list_price_per_target, p.extra_location_pct, count)) * slotMult) : null;
    r.sumTotal.textContent = p ? formatRupiah(total) : "—";
    const discounted = Boolean(p && p.launch && count > 0 && list > total);
    r.sumList.hidden = !discounted;
    r.sumList.textContent = discounted ? formatRupiah(list) : "";
    r.sumBadge.hidden = !discounted;
    if (refresh) { refreshTrust(); refreshAvailability(); }
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
      return [l, `${REACH[l]} — ${priceText(p)}${l === "global" ? "" : p.extra_location_pct ? ` for the first location, +${p.extra_location_pct}% for each extra` : " for any number of locations"}`];
    })));
    r.scope.value = sel.scope;
    renderTargets();
  }
  function renderDuration() {
    const list = available.filter((p) => group(p) === sel.placement);
    const days = [...new Set(list.map((p) => p.duration_days))].sort((a, b) => a - b);
    if (!days.includes(sel.duration)) sel.duration = days[0];
    r.duration.replaceChildren(...options(days.map((d) => [String(d), `${d} days — from ${priceText(cheapest(list.filter((p) => p.duration_days === d)))}`])));
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
  r.start.addEventListener("change", () => updatePrice(), { signal });
  r.slotType.addEventListener("change", () => updatePrice(), { signal });
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
          creative_path: file ? uploaded.path : reuseCreative, product_id: p.id, requested_start: r.start.value, targets, slot_type: r.slotType.value,
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
        if (err?.code === "SOLD_OUT") { // offer the waitlist with the current choices filled in
          r.waitlistForm.elements.spot.value = group(p);
          r.waitlistForm.elements.scope.value = sel.scope;
          r.waitlistForm.elements.duration.value = String(sel.duration);
          r.waitlistBox.open = true;
        }
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
          el("p", { class: "small muted" }, "Views count once per visitor per hour; bots and our own admins are excluded. Clicks are counted by our server."));
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

  // ---- Price cell, report download, locked rate ------------------------------------------------------
  function priceCell(c) {
    if (c.price_snapshot == null) return "—";
    const now = formatRupiah(String(c.price_snapshot));
    if (c.price_locked) return el("span", {}, now, " ", el("span", { class: "badge badge--founding" }, "Locked founding rate"), " ", el("s", { class: "price-was" }, formatRupiah(String(c.list_price_snapshot))));
    if (c.list_price_snapshot != null && BigInt(c.list_price_snapshot) > BigInt(c.price_snapshot)) {
      return el("span", {}, now, " ", el("s", { class: "price-was" }, formatRupiah(String(c.list_price_snapshot))), " ", el("span", { class: "badge badge--founding" }, "Founding advertiser rate"));
    }
    return now;
  }
  const csvCell = (v) => {
    let t = String(v ?? "");
    if (/^[=+\-@\t\r]/.test(t)) t = `'${t}`; // stop spreadsheet formula injection from advertiser-controlled text
    return /[",\n]/.test(t) ? `"${t.replaceAll('"', '""')}"` : t;
  };
  /** CSV with the totals, the daily numbers and where the clicks came from. */
  async function downloadReport(c) {
    const rep = await rpc("campaign_report", { p_campaign_id: c.id });
    const t = rep.totals;
    const lines = [
      ["Campaign", rep.campaign.title], ["Package", rep.campaign.product], ["Runs", `${rep.campaign.starts_at ?? ""} to ${rep.campaign.ends_at ?? ""}`],
      ["Price paid (Rp)", rep.campaign.price_paid ?? ""], ["Views", t.impressions], ["Unique visitors", t.unique_visitors], ["Clicks", t.clicks], ["CTR %", t.ctr ?? ""], [],
      ["Day", "Views", "Clicks", "CTR %"], ...rep.daily.map((d) => [d.day, d.impressions, d.clicks, d.ctr ?? ""]), [],
      ["Click source (referrer)", "Clicks"], ...rep.referrers.map((x) => [x.host, x.clicks]), [],
      ["UTM source", "Clicks"], ...rep.utm_sources.map((x) => [x.source, x.clicks]),
    ];
    const blob = new Blob([`\ufeff${lines.map((l) => l.map(csvCell).join(",")).join("\r\n")}\r\n`], { type: "text/csv;charset=utf-8" });
    const a = el("a", { href: URL.createObjectURL(blob), download: `campaign-report-${c.id.slice(0, 8)}.csv` });
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }
  function reportButton(c) {
    const b = el("button", { type: "button", class: "btn btn--small" }, "Download report (CSV)");
    b.addEventListener("click", () => busy(b, async () => {
      try { await downloadReport(c); } catch (err) { toast(errorMessage(err), "error"); }
    }), { signal });
    return b;
  }
  async function loadLocks() {
    if (!user) return;
    try {
      const res = await rpc("my_price_locks");
      r.locks.replaceChildren(...(res.locks ?? []).map((l) => el("p", { class: "notice lock-note" },
        el("strong", {}, `Your rate is locked at ${formatRupiah(l.base_fee)}`), ` for “${l.name}” (first location). `,
        l.renewal_open ? `Renew now to keep it.` : `Renew within ${res.grace_days} days of your campaign ending to keep it.`)));
    } catch { /* the banner is a nicety; the price is decided by the server anyway */ }
  }

  // ---- Waitlist ("Notify me") -------------------------------------------------------------------------
  r.waitlistForm.addEventListener("submit", (e) => {
    e.preventDefault();
    busy(r.waitSubmit, async () => {
      r.waitError.textContent = "";
      const f = new FormData(r.waitlistForm);
      const email = String(f.get("email") ?? "").trim();
      if (!isEmail(email)) { r.waitError.textContent = "Enter a valid email address."; return; }
      const scope = String(f.get("scope"));
      const t = selectedTargets();
      const key = t.length === 1 && t[0].level === scope ? targetKey(scope, t[0].id) : null; // a specific location only when exactly that one is ticked
      try {
        await rpc("join_ad_waitlist", { p_email: email, p_spot: f.get("spot"), p_scope_level: scope, p_target_key: key, p_duration: Number(f.get("duration")), p_max_budget: f.get("max_budget") ? Number(f.get("max_budget")) : null });
        toast("You are on the list. We will email you when it opens.", "success");
        r.waitlistForm.reset();
        fillWaitDurations();
      } catch (err) { r.waitError.textContent = errorMessage(err); }
    });
  }, { signal });
  function fillWaitDurations() {
    const days = [...new Set([7, 30, 60, 90, ...available.map((p) => p.duration_days)])].sort((a, b) => a - b);
    r.waitDuration.replaceChildren(...options(days.map((d) => [String(d), `${d} days`])));
  }

  // ---- Your campaigns ---------------------------------------------------------------------------
  function campaignItem(c) {
    const [label, tone] = campaignStatus(c);
    const rows = [
      ["Placement", PLACEMENT[group(c)].label],
      ["Duration", `${c.duration_days} days`],
      ["Price", priceCell(c)],
      ["Payment", paymentStatus(c)],
      [c.starts_at ? "Runs" : "Requested start", c.starts_at ? `${formatDate(c.starts_at)} – ${formatDate(c.ends_at)}` : fmtDay(c.requested_start)],
    ];
    if (["active", "scheduled", "expired", "paused"].includes(c.status) && c.starts_at) {
      rows.push(["Results", `${c.impressions} views, ${c.clicks} clicks, CTR ${Number(c.impressions) > 0 ? ((Number(c.clicks) * 100) / Number(c.impressions)).toFixed(2) : "0.00"}%`]);
    }
    const item = el("li", { class: "campaign-item" },
      el("div", { class: "campaign-item__head" }, el("strong", {}, c.title), el("span", { class: `badge${tone ? ` badge--${tone}` : ""}` }, label)),
      el("dl", {}, ...rows.flatMap(([k, v]) => [el("dt", {}, k), el("dd", {}, v)])));
    const msLeft = c.ends_at ? new Date(c.ends_at).getTime() - Date.now() : 0;
    const ended = ["active", "scheduled", "expired"].includes(c.status) && c.starts_at && msLeft <= 0;
    const endingSoon = c.status === "active" && msLeft > 0 && msLeft <= 3 * 864e5;
    if (endingSoon) item.append(el("p", { class: "campaign-item__reason" }, `Ends in ${Math.ceil(msLeft / 864e5)} day(s). Run it again to keep your spot.`));
    if (c.starts_at && ["active", "scheduled", "expired", "paused"].includes(c.status)) item.append(resultsChart(c), reportButton(c));
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
        .select("id,title,status,placement,duration_days,requested_start,starts_at,ends_at,price_snapshot,list_price_snapshot,launch_discount_pct,price_locked,moderation_reason,created_at,product_id,description,category,advertiser_name,contact_email,destination_url,creative_path")
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
  loadLocks();
  fillWaitDurations();

  // Only packages the admin has enabled are readable; wall-only packages were folded into Random Placement.
  // A package is offered only if its locations really exist and are enabled.
  const fetchProducts = async () => (await rpc("ad_catalog"))
    .filter((p) => p.placement !== "wall_inline")
    .filter((p) => p.scope_level === "global" || optionsFor(p.scope_level).length > 0);
  try {
    locations = await loadLocations();
    available = await fetchProducts();
  } catch (err) {
    r.error.textContent = `Advertising options are unavailable: ${errorMessage(err)}`;
    return;
  }
  if (available.length === 0) {
    r.error.textContent = "No advertising packages are available right now. Please check back soon or contact us.";
    return;
  }
  // Pick up admin price / "% per extra location" changes without a reload: re-check every minute and when the tab regains focus.
  // The server always prices from the current package at submit, so this only keeps the screen honest.
  const syncPrices = async () => {
    if (document.hidden) return;
    try {
      const next = await fetchProducts();
      if (next.length && JSON.stringify(next) !== JSON.stringify(available)) { available = next; renderPlacement(); }
    } catch { /* keep showing the last good prices */ }
  };
  const timer = setInterval(syncPrices, 60000);
  document.addEventListener("visibilitychange", syncPrices, { signal });
  signal.addEventListener("abort", () => clearInterval(timer));
  fillWaitDurations();
  renderPlacement();
  r.submit.disabled = false;

  // ---- Auctions (shown only while an admin has switched them on and one is open) --------------------------------
  const fmtLeft = (ms) => {
    if (ms <= 0) return "ended";
    const s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
    return h >= 24 ? `${Math.floor(h / 24)}d ${h % 24}h left` : h > 0 ? `${h}h ${m}m left` : `${m}m ${s % 60}s left`;
  };
  let auctions = [];
  const ticks = [];
  const drafts = new Map(); // auction id -> { ad, amount }: survives the 20-second refresh so typing is never wiped
  let loadSeq = 0;
  async function loadAuctions(poll = false) {
    // Never redraw under someone who is typing a bid or picking an ad.
    if (poll && r.auctionList.contains(document.activeElement) && document.activeElement !== r.auctionList) return;
    const seq = ++loadSeq;
    let list = [], offers = [];
    try {
      list = (await rpc("list_open_auctions")) ?? [];
      if (user) offers = (await rpc("my_auction_offers")) ?? [];
    } catch { /* auctions are optional; the fixed-price flow never depends on them */ }
    if (seq !== loadSeq || signal.aborted) return; // a newer load is running: drop this stale answer
    auctions = list;
    r.auctionBox.hidden = list.length === 0 && offers.length === 0;
    r.offerBanner.hidden = offers.length === 0;
    r.offerBanner.textContent = offers.map((o) => `You won ${o.label} at ${formatRupiah(o.amount)}. Pay before ${formatDate(o.pay_by, true)} in “Your campaigns” below.`).join(" ");
    ticks.length = 0;
    if (!user) { r.auctionList.replaceChildren(...list.map((a) => el("p", { class: "small" }, `${a.label}: ${a.high_amount ? `highest bid ${formatRupiah(a.high_amount)}` : `reserve ${formatRupiah(a.reserve)}`}. Sign in to bid.`))); return; }
    // Only ads the server will accept: approved, your own, same package, and aimed at exactly this one location.
    let ads = [];
    const targets = new Map();
    try {
      const { data } = await client.from("campaigns").select("id,title,product_id").eq("owner_id", user.id).eq("status", "approved");
      ads = data ?? [];
      if (ads.length) {
        const { data: t } = await client.from("campaign_targets").select("campaign_id,target_key").in("campaign_id", ads.map((c) => c.id));
        for (const row of t ?? []) targets.set(row.campaign_id, [...(targets.get(row.campaign_id) ?? []), row.target_key]);
      }
    } catch { /* show auctions without bid controls rather than nothing */ }
    if (seq !== loadSeq || signal.aborted) return;
    r.auctionList.replaceChildren(...list.map((a) => {
      const mine = ads.filter((c) => c.product_id === a.product_id && (targets.get(c.id) ?? []).length === 1 && targets.get(c.id)[0] === a.target_key);
      const d = drafts.get(a.id) ?? {};
      const left = el("strong", {});
      const state = a.leading ? el("span", { class: "badge" }, "You are leading") : a.my_bid ? el("span", { class: "badge badge--warn" }, "You were outbid") : "";
      const head = [
        el("h3", {}, `${a.label} · ${a.duration_days} days`),
        el("p", { class: "small" }, `Slot starts ${fmtDay(a.period_start)}. `, left, ` · ${a.bid_count} bid${a.bid_count === 1 ? "" : "s"}`),
        el("p", {}, a.high_amount ? `Highest bid: ${formatRupiah(a.high_amount)}` : `No bids yet. Reserve: ${formatRupiah(a.reserve)}`, " ", state),
        el("p", { class: "small muted" }, `Minimum next bid ${formatRupiah(a.min_next_bid)} (raise by ${formatRupiah(a.min_increment)}). Buy now ${formatRupiah(a.buy_now)}. Bids cannot be withdrawn. A bid in the last 5 minutes extends the auction by 5 minutes.`),
      ];
      if (!mine.length) {
        ticks.push(() => { left.textContent = fmtLeft(new Date(a.ends_at).getTime() - Date.now()); });
        return el("div", { class: "auction card" }, ...head,
          el("p", { class: "notice" }, "To bid you need an approved ad for this exact package and one location. Submit one in the form (free), wait for approval, then come back."));
      }
      const pick = el("select", { "aria-label": "Your ad" }, ...mine.map((c) => el("option", { value: c.id, selected: c.id === d.ad || null }, c.title)));
      const amount = el("input", { type: "number", min: a.min_next_bid, step: "1000", value: String(Math.max(Number(d.amount ?? 0), Number(a.min_next_bid))), inputmode: "numeric", "aria-label": "Your bid in rupiah" });
      pick.addEventListener("change", () => drafts.set(a.id, { ...drafts.get(a.id), ad: pick.value }));
      amount.addEventListener("input", () => drafts.set(a.id, { ...drafts.get(a.id), amount: amount.value }));
      const bid = async (buy) => {
        const value = Number(amount.value);
        if (!buy && !(value >= Number(a.min_next_bid))) { toast(`The minimum bid is ${formatRupiah(a.min_next_bid)}.`, "error"); return; }
        const ok = await openDialog({ title: buy ? "Buy now?" : "Place this bid?", okLabel: buy ? "Buy now" : "Place bid",
          body: el("p", {}, `${buy ? "Buy" : "Bid"} ${formatRupiah(buy ? a.buy_now : String(value))} for ${a.label}. A bid cannot be withdrawn. Nothing is charged now: if you win, we email you the payment deadline.`) });
        if (!ok) return;
        try {
          const res = await invoke("auction-bid", { auction_id: a.id, campaign_id: pick.value, amount: buy ? undefined : String(value), buy_now: buy });
          drafts.delete(a.id);
          toast(res.bought ? `Bought at ${formatRupiah(res.amount)}. Pay it in “Your campaigns” below.` : res.extended ? "Bid placed. The auction was extended by 5 minutes." : "Bid placed.", "success", 7000);
        } catch (err) { toast(errorMessage(err), "error", 8000); }
        loadAuctions();
      };
      const placeBtn = el("button", { type: "button", class: "btn btn--small btn--primary" }, "Place bid");
      const buyBtn = el("button", { type: "button", class: "btn btn--small" }, "Buy now");
      placeBtn.addEventListener("click", () => busy(placeBtn, () => bid(false)));
      buyBtn.addEventListener("click", () => busy(buyBtn, () => bid(true)));
      ticks.push(() => {
        const ms = new Date(a.ends_at).getTime() - Date.now();
        left.textContent = fmtLeft(ms);
        // The server refuses both once the auction ended or when you already lead, so do not offer them.
        const off = ms <= 0 || a.leading;
        for (const b of [placeBtn, buyBtn]) if (b.dataset.busy !== "1") { b.disabled = off; b.title = a.leading ? "You already have the highest bid." : ""; }
      });
      return el("div", { class: "auction card" }, ...head, el("div", { class: "row row--tight" }, pick, amount, placeBtn, buyBtn));
    }));
    ticks.forEach((t) => t());
  }
  const auctionClock = setInterval(() => ticks.forEach((t) => t()), 1000);
  const auctionPoll = setInterval(() => { if (!document.hidden) loadAuctions(true); }, 20000);
  signal.addEventListener("abort", () => { clearInterval(auctionClock); clearInterval(auctionPoll); });
  loadAuctions();
}
