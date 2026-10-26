// Administrator console. Purely a UI over the admin-api Edge Function: the
// visible menu grants nothing, and every action is re-authorized server-side
// (Edge Function + SQL require_admin()) and written to the audit log.

import { cloneTemplate } from "./component-loader.js";
import { currentUser, isAdmin, isOwner } from "./auth.js";
import { creativeUrl, getClient, invoke, mediaUrl, query } from "./supabase-client.js";
import { busy, el, errorMessage, formatDate, formatRupiah, openDialog, promptReason, refs, toast } from "./utils.js";
import { adPrice, parseRupiah } from "./validation.js";

async function api(action, params = {}) {
  const res = await invoke("admin-api", { action, params });
  return res.data;
}

function table(columns, rows, empty = "Nothing here.") {
  if (!rows.length) return el("p", { class: "muted" }, empty);
  return el("div", { class: "table-wrap" }, el("table", { class: "table" },
    el("thead", {}, el("tr", {}, ...columns.map((c) => el("th", { scope: "col" }, c.label)))),
    el("tbody", {}, ...rows.map((row) => el("tr", {}, ...columns.map((c) => {
      const v = c.render ? c.render(row) : row[c.key];
      return el("td", {}, v instanceof Node ? v : String(v ?? ""));
    }))))));
}

function button(label, onClick, cls = "btn btn--small") {
  const b = el("button", { type: "button", class: cls }, label);
  b.addEventListener("click", () => busy(b, onClick));
  return b;
}

/** "pending_moderation" / "owner.delete" -> "Pending moderation" / "Owner delete". */
const humanize = (v) => {
  const t = String(v ?? "").replace(/[._]+/g, " ").trim();
  return t.charAt(0).toUpperCase() + t.slice(1);
};
const shortId = (id) => (id ? el("code", { title: String(id) }, `${String(id).slice(0, 8)}…`) : "");
const details = (d) => (d && typeof d === "object"
  ? Object.entries(d).map(([k, v]) => `${humanize(k)}: ${typeof v === "object" ? JSON.stringify(v) : v}`).join(" · ")
  : String(d ?? ""));

function actions(...nodes) {
  return el("div", { class: "row row--tight" }, ...nodes.filter(Boolean));
}

/** Owner-only permanent delete. Admins get no button; the server rejects them anyway. */
function ownerDelete(state, kind, id, what, reload) {
  if (!state.owner) return null;
  return button("Delete", async () => {
    const input = el("input", { name: "confirm", required: true, pattern: "DELETE", autocomplete: "off", placeholder: "DELETE" });
    let effects = [];
    try { effects = (await api("owner_delete_preview", { kind, id: String(id) }))?.effects ?? []; } catch (err) { toast(errorMessage(err), "error"); return; }
    const body = el("div", { class: "stack" },
      el("p", {}, `Permanently delete this ${what}? This cannot be undone. Payment and credit history is kept.`),
      effects.length ? el("ul", { class: "small" }, ...effects.map((t) => el("li", {}, t))) : null,
      el("label", { class: "field" }, el("span", { class: "field__label" }, "Type DELETE to confirm"), input));
    const data = await openDialog({ title: `Delete ${what}`, body, okLabel: "Delete permanently", danger: true });
    if (!data || data.get("confirm") !== "DELETE") return;
    try {
      await api("owner_delete", { kind, id: String(id), confirm: "DELETE" });
      toast(`${what} deleted.`, "success");
    } catch (err) {
      toast(errorMessage(err), "error");
    }
    reload();
  }, "btn btn--small btn--danger");
}

const REJECT_REASONS = ["Misleading or false claims", "Not relevant to students", "Prohibited content (see advertising policy)",
  "Image or text is unclear or low quality", "Missing or invalid business information"];
/** Reject needs a reason the advertiser will read: pick a preset and/or write your own. */
async function rejectionReason(action, row, danger) {
  if (action !== "reject") return promptReason(`${humanize(action)} “${row.title}”?`, { danger, okLabel: humanize(action) });
  const preset = el("select", { name: "preset", required: true }, el("option", { value: "" }, "Choose a reason…"), ...REJECT_REASONS.map((t) => el("option", { value: t }, t)));
  const extra = el("textarea", { name: "extra", rows: "3", maxlength: "300", placeholder: "More details for the advertiser (optional)" });
  const data = await openDialog({ title: `Reject “${row.title}”?`, okLabel: "Reject", danger: true,
    body: el("div", { class: "stack" }, el("p", { class: "small" }, "The advertiser sees this reason. Nothing is charged for a rejected ad; a paid ad is flagged for refund."), preset, extra) });
  if (!data) return null;
  const text = [data.get("preset"), String(data.get("extra") ?? "").trim()].filter(Boolean).join(" — ");
  if (text.length < 3) { toast("Give the advertiser a reason.", "error"); return null; }
  return text;
}

function amountInput(name, value, placeholder = "") {
  return el("input", { name, value: value ?? "", inputmode: "numeric", placeholder, class: "input--small" });
}

const panels = {
  async overview(panel, reload) {
    const [o, d] = await Promise.all([api("overview"), api("leaderboard_diagnostics")]);
    panel.replaceChildren(
      el("dl", { class: "stats stats--grid" },
        ...Object.entries({
          "Open reports": o.open_reports, "Notes in moderation": o.notes_pending_moderation,
          "Campaigns awaiting review": o.campaigns_pending_review, "Orders needing review": o.orders_needing_review,
          "Published notes": o.published_notes, "Accounts": o.users, "Qualified referrals": d.qualified_referrals,
          "Opted-in donors": d.opted_in_donors, "Successful donations": d.successful_donations,
        }).map(([k, v]) => el("div", {}, el("dt", {}, k), el("dd", {}, String(v))))),
      actions(button("Expire stale unpaid orders", async () => {
        const res = await api("expire_stale_orders");
        toast(`${res.expired} order(s) expired.`, "success");
        reload();
      })),
    );
  },

  async moderation(panel, reload, state) {
    state.noteStatus ??= "pending_moderation";
    const filter = el("select", {}, ...["pending_moderation", "published", "removed", "rejected", "withdrawn"].map((s) =>
      el("option", { value: s, selected: s === state.noteStatus || null }, humanize(s))));
    filter.addEventListener("change", () => { state.noteStatus = filter.value; reload(); });
    const rows = await api("list_notes", { status: state.noteStatus, limit: 100 });
    const act = (row, action, danger) => button(humanize(action), async () => {
      const reason = await promptReason(`${humanize(action)} this note?`, { danger, okLabel: humanize(action) });
      if (reason === null) return;
      await api("moderate_note", { note_id: row.id, action, reason: reason || null });
      toast(`Note ${action}d.`, "success");
      reload();
    }, danger ? "btn btn--small btn--danger" : "btn btn--small");
    panel.replaceChildren(el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Status"), filter),
      table([
        { label: "Note", render: (r) => el("span", { class: "clamp" }, r.body, ...(r.media ?? []).map((m, i) =>
          el("a", { href: mediaUrl(m.path), target: "_blank", rel: "noopener noreferrer" }, ` [${m.kind} ${i + 1}]`))) },
        { label: "Author", key: "author_name" },
        { label: "Paid", render: (r) => formatRupiah(r.amount) },
        { label: "Votes", key: "vote_count" },
        { label: "Reports", key: "report_count" },
        { label: "Created", render: (r) => formatDate(r.created_at, true) },
        { label: "Actions", render: (r) => actions(
          r.status === "pending_moderation" && act(r, "approve"),
          r.status === "pending_moderation" && act(r, "reject", true),
          ["published", "pending_moderation"].includes(r.status) && act(r, "remove", true),
          r.status === "removed" && act(r, "restore"),
          ownerDelete(state, "note", r.id, "note", reload)) },
      ], rows));
  },

  async reports(panel, reload, state) {
    const rows = await api("list_reports", { status: "open" });
    panel.replaceChildren(table([
      { label: "Reason", key: "reason" },
      { label: "Details", key: "details" },
      { label: "Note", render: (r) => el("span", { class: "clamp" }, r.note_body) },
      { label: "Note status", key: "note_status" },
      { label: "Reports", key: "report_count" },
      { label: "Actions", render: (r) => actions(
        r.note_status === "published" && button("Remove note", async () => {
          const reason = await promptReason("Remove this note?", { danger: true, okLabel: "Remove" });
          if (reason === null) return;
          await api("moderate_note", { note_id: r.note_id, action: "remove", reason: reason || `report: ${r.reason}` });
          await api("resolve_report", { report_id: r.id, status: "resolved", reason: "note removed" });
          reload();
        }, "btn btn--small btn--danger"),
        button("Resolve", async () => { await api("resolve_report", { report_id: r.id, status: "resolved" }); reload(); }),
        button("Dismiss", async () => { await api("resolve_report", { report_id: r.id, status: "dismissed" }); reload(); }),
        ownerDelete(state, "report", r.id, "report", reload)) },
    ], rows, "No open reports."));
  },

  async users(panel, reload, state) {
    const search = el("input", { type: "search", placeholder: "Name or email", value: state.userSearch ?? "" });
    const go = button("Search", async () => { state.userSearch = search.value.trim() || null; reload(); });
    const rows = await api("list_users", { search: state.userSearch ?? null, limit: 100 });
    panel.replaceChildren(actions(search, go), table([
      { label: "Name", key: "display_name" },
      { label: "Email", key: "email" },
      { label: "Verified", render: (r) => (r.email_verified ? "yes" : "no") },
      { label: "Notes", key: "published_notes" },
      { label: "Admin", render: (r) => (r.is_admin ? "yes" : "") },
      { label: "Status", render: (r) => (r.suspended_at ? `suspended (${r.suspension_reason ?? ""})` : "active") },
      { label: "Actions", render: (r) => r.is_admin ? "" : button(r.suspended_at ? "Unsuspend" : "Suspend", async () => {
        const reason = await promptReason(r.suspended_at ? "Unsuspend this account?" : "Suspend this account?", { required: !r.suspended_at, danger: !r.suspended_at });
        if (reason === null) return;
        const res = await invoke("admin-api", { action: "set_user_suspension", params: { user_id: r.id, suspend: !r.suspended_at, reason } });
        if (res.auth_ban === "failed") toast("Saved, but the sign-in ban could not be updated in Supabase Auth.", "error");
        reload();
      }, r.suspended_at ? "btn btn--small" : "btn btn--small btn--danger") },
    ], rows));
  },

  async orders(panel, reload, state) {
    state.orderFilter ??= { kind: "", status: "", review_only: false };
    const f = state.orderFilter;
    const kind = el("select", {}, ...["", "publication", "donation", "advertising"].map((k) => el("option", { value: k, selected: k === f.kind || null }, k || "all kinds")));
    const status = el("select", {}, ...["", "awaiting_payment", "challenge", "paid", "completed_free", "payment_waived", "failed", "canceled", "expired", "partially_refunded", "refunded", "reversed"]
      .map((s) => el("option", { value: s, selected: s === f.status || null }, s || "all statuses")));
    const review = el("input", { type: "checkbox", checked: f.review_only || null });
    const apply = button("Filter", async () => { Object.assign(f, { kind: kind.value, status: status.value, review_only: review.checked }); reload(); });
    const rows = await api("list_orders", { kind: f.kind || null, status: f.status || null, review_only: f.review_only, limit: 100 });
    panel.replaceChildren(actions(kind, status, el("label", { class: "check" }, review, " needs review"), apply), table([
      { label: "Order", key: "order_ref" },
      { label: "Kind", key: "kind" },
      { label: "Status", key: "status" },
      { label: "Total", render: (r) => formatRupiah(r.total_amount) },
      { label: "Refunded", render: (r) => formatRupiah(r.refunded_amount) },
      { label: "Review", render: (r) => (r.review_required ? `⚠ ${r.review_reason ?? ""}` : "") },
      { label: "Created", render: (r) => formatDate(r.created_at, true) },
      { label: "Actions", render: (r) => actions(
        button("Details", async () => {
          const d = await api("order_detail", { order_ref: r.order_ref });
          await openDialog({ title: `Order ${r.order_ref}`, body: el("pre", { class: "code-block" }, JSON.stringify(d, null, 2)), okLabel: "Close" });
        }),
        ["awaiting_payment", "challenge", "paid", "partially_refunded"].includes(r.status) && button("Reconcile with Midtrans", async () => {
          const res = await api("reconcile_order", { order_ref: r.order_ref });
          toast(`Result: ${res.result}`, "info");
          reload();
        }),
        r.kind === "publication" && r.status === "awaiting_payment" && button("Waive payment", async () => {
          const reason = await promptReason("Waive payment for this sticky post? The note publishes without a payment and is recorded as waived, not paid.", { required: true, okLabel: "Waive payment" });
          if (reason === null) return;
          try { await api("waive_order", { order_ref: r.order_ref, reason }); toast("Payment waived.", "success"); } catch (err) { toast(errorMessage(err), "error"); }
          reload();
        }),
        r.review_required && button("Clear review flag", async () => {
          const reason = await promptReason("Clear the review flag?", { required: true });
          if (reason === null) return;
          await api("clear_order_review", { order_ref: r.order_ref, reason });
          reload();
        })) },
    ], rows));
  },

  async campaigns(panel, reload, state) {
    state.campaignStatus ??= "pending_approval";
    const filter = el("select", {}, ...["pending_approval", "approved", "awaiting_payment", "pending_review", "scheduled", "active", "paused", "expired", "rejected", "canceled", ""]
      .map((s) => el("option", { value: s, selected: s === state.campaignStatus || null }, s ? humanize(s) : "All")));
    filter.addEventListener("change", () => { state.campaignStatus = filter.value; reload(); });
    const rows = await api("list_campaigns", { status: state.campaignStatus || null });
    const act = (row, action, danger) => button(humanize(action), async () => {
      const reason = await rejectionReason(action, row, danger);
      if (reason === null) return;
      await api("review_campaign", { campaign_id: row.id, action, reason: reason || null });
      toast(`Campaign ${action}d.`, "success");
      reload();
    }, danger ? "btn btn--small btn--danger" : "btn btn--small");
    panel.replaceChildren(el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Status"), filter), table([
      { label: "Campaign", render: (r) => el("div", {}, el("strong", {}, r.title), el("br"), el("span", { class: "small clamp" }, r.description)) },
      { label: "Advertiser", render: (r) => `${r.advertiser_name} <${r.contact_email}>` },
      { label: "Creative", render: (r) => {
        const u = r.creative_path ? creativeUrl(r.creative_path) : null;
        const img = u && el("a", { href: u, target: "_blank", rel: "noopener noreferrer" }, el("img", { src: u, alt: "", class: "admin-thumb" }));
        const link = r.destination_url && el("a", { href: r.destination_url, target: "_blank", rel: "noopener noreferrer" }, "Link ↗");
        return img || link ? el("div", { class: "stack" }, img, link) : "Text only";
      } },
      { label: "Package", render: (r) => `${r.placement === "featured" ? "Featured" : "Random"} · ${r.duration_days ?? "?"}d · ${formatRupiah(r.price)}` },
      { label: "Targets", render: (r) => (r.targets ?? []).join(", ") },
      { label: "Payment", render: (r) => humanize(r.payment_status) },
      { label: "Status", render: (r) => el("span", { class: `badge${r.status === "active" ? " badge--ok" : ["rejected", "canceled"].includes(r.status) ? " badge--bad" : r.status === "pending_approval" ? " badge--warn" : ""}` }, humanize(r.status)) },
      { label: "Runs", render: (r) => (r.starts_at ? `${formatDate(r.starts_at)} – ${formatDate(r.ends_at)}` : `from ${r.requested_start}`) },
      { label: "Stats", render: (r) => `${r.impressions} / ${r.clicks}` },
      { label: "Actions", render: (r) => actions(
        (r.status === "pending_approval" || (r.status === "pending_review" && r.payment_status === "paid")) && act(r, "approve"),
        ["pending_approval", "approved", "pending_review", "draft"].includes(r.status) && act(r, "reject", true),
        ["active", "scheduled"].includes(r.status) && act(r, "pause"),
        r.status === "paused" && act(r, "resume"),
        ["pending_approval", "approved", "pending_review", "scheduled", "active", "paused"].includes(r.status) && act(r, "cancel", true),
        ownerDelete(state, "campaign", r.id, "campaign", reload)) },
    ], rows));
  },

  async catalog(panel, reload) {
    const c = await api("list_catalog");
    const policy = el("p", { class: "notice" },
      `Publication pricing policy: customers choose their price. Minimum ${formatRupiah(c.pricing_policy.min_publication_price)}; server cap ${formatRupiah(c.config.find((x) => x.key === "max_publication_price")?.value ?? 0)} (site_config: min_publication_price, max_publication_price, price_presets, confirm_above_amount). Referral credit: ${formatRupiah(c.pricing_policy.referral_credit_value)}.`);

    // Decorations: a grid of previews. Click one to edit its name, price and visibility.
    const editDeco = async (d, paint) => {
      const name = el("input", { name: "name", value: d.name, maxlength: "50", minlength: "2", required: true });
      const price = amountInput("price", d.price);
      const enabled = el("input", { type: "checkbox", checked: d.enabled || null });
      const body = el("div", { class: "stack" },
        el("div", { class: "deco-preview" }, el("span", { class: `deco-swatch deco-${d.id}`, "aria-hidden": "true" })),
        el("p", { class: "small muted" }, `${d.id}${d.category ? ` · ${d.category}` : ""}`),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Name"), name),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Price (Rp)"), price),
        el("label", { class: "check" }, enabled, el("span", {}, "Enabled")));
      if (!(await openDialog({ title: d.name, body, okLabel: "Save" }))) return;
      const p = parseRupiah(price.value);
      if (!p.ok) { toast(p.error, "error"); return; }
      await api("upsert_decoration", { id: d.id, name: name.value.trim(), description: d.description, price: p.digits, enabled: enabled.checked, sort: d.sort_order });
      Object.assign(d, { name: name.value.trim(), price: p.digits, enabled: enabled.checked });
      paint();
      toast("Decoration saved. Existing orders keep their original prices.", "success");
    };
    const decoTile = (d) => {
      const b = el("button", { type: "button", class: "deco-tile" },
        el("span", { class: `deco-swatch deco-${d.id}`, "aria-hidden": "true" }), el("span", { class: "deco-tile__name" }), el("small"));
      const paint = () => {
        b.classList.toggle("is-off", !d.enabled);
        b.children[1].textContent = d.name;
        b.children[2].textContent = BigInt(d.price) ? formatRupiah(d.price) : "Free";
      };
      b.addEventListener("click", () => busy(b, () => editDeco(d, paint)));
      paint();
      return b;
    };
    const cats = [...new Set(c.decorations.map((d) => d.category || "Other"))];
    const decoGrid = el("div", { class: "stack" }, ...cats.map((cat) => el("div", {},
      el("h3", { class: "small muted" }, cat),
      el("div", { class: "deco-grid" }, ...c.decorations.filter((d) => (d.category || "Other") === cat).map(decoTile)))));

    const pmRows = c.payment_methods.map((m) => ({ m, min: amountInput("min", m.min_amount, "none"), max: amountInput("max", m.max_amount, "none"),
      enabled: el("input", { type: "checkbox", checked: m.enabled || null }) }));
    const pmTable = table([
      { label: "Method", render: (x) => `${x.m.label} (${x.m.midtrans_codes.join(", ")})` },
      { label: "Min (Rp)", render: (x) => x.min },
      { label: "Max (Rp)", render: (x) => x.max },
      { label: "Enabled", render: (x) => x.enabled },
      { label: "", render: (x) => button("Save", async () => {
        const min = x.min.value.trim() ? parseRupiah(x.min.value) : { ok: true, digits: null };
        const max = x.max.value.trim() ? parseRupiah(x.max.value) : { ok: true, digits: null };
        if (!min.ok || !max.ok) { toast("Limits must be whole rupiah or empty.", "error"); return; }
        await api("upsert_payment_method", { code: x.m.code, label: x.m.label, midtrans_codes: x.m.midtrans_codes, min: min.digits, max: max.digits, enabled: x.enabled.checked, sort: x.m.sort_order });
        toast("Payment method saved.", "success");
      }) },
    ], pmRows);

    const adRows = c.ad_products.map((a) => {
      const price = amountInput("price", a.price_per_target);
      const global = a.scope_level === "global"; // always one location, so no extra-location %
      const pct = el("input", { type: "number", min: "0", max: "1000", step: "1", value: String(a.extra_location_pct), disabled: global || null, class: "input--small" });
      const example = el("span", { class: "small muted" });
      const paint = () => {
        const p = parseRupiah(price.value);
        example.textContent = !p.ok ? "—" : `${global ? "" : "3 locations: "}${formatRupiah(adPrice(p.digits, Number(pct.value) || 0, global ? 1 : 3))}`;
      };
      price.addEventListener("input", paint);
      pct.addEventListener("input", paint);
      paint();
      return { a, price, pct, example,
        days: el("input", { type: "number", min: "1", max: "365", value: String(a.duration_days), class: "input--small" }),
        enabled: el("input", { type: "checkbox", checked: a.enabled || null }) };
    });
    const adTable = table([
      { label: "Package", render: (x) => `${x.a.name} [${x.a.placement} · ${x.a.scope_level}]` },
      { label: "Days", render: (x) => x.days },
      { label: "Base fee (Rp)", render: (x) => x.price },
      { label: "Extra per added location (%)", render: (x) => x.pct },
      { label: "Example", render: (x) => x.example },
      { label: "Enabled", render: (x) => x.enabled },
      { label: "", render: (x) => button("Save", async () => {
        const p = parseRupiah(x.price.value);
        if (!p.ok || p.value < 1n) { toast("Base fee must be a positive whole rupiah amount.", "error"); return; }
        const extra = Number(x.pct.value);
        if (!Number.isInteger(extra) || extra < 0 || extra > 1000) { toast("Extra % must be a whole number from 0 to 1000.", "error"); return; }
        await api("upsert_ad_product", { id: x.a.id, name: x.a.name, placement: x.a.placement, scope_level: x.a.scope_level,
          duration_days: Number(x.days.value), price: p.digits, extra_pct: extra, enabled: x.enabled.checked, sort: x.a.sort_order });
        toast("Package saved.", "success");
      }) },
    ], adRows);

    const cfg = Object.fromEntries(c.config.map((row) => [row.key, row.value]));
    const moderation = el("select", {}, el("option", { value: "post", selected: cfg.note_moderation === "post" || null }, "Publish immediately after payment (post-moderation)"),
      el("option", { value: "pre", selected: cfg.note_moderation === "pre" || null }, "Hold for approval after payment (pre-moderation)"));
    const dmin = amountInput("dmin", String(cfg.donation_min_amount ?? ""));
    const dmax = amountInput("dmax", String(cfg.donation_max_amount ?? ""));
    const ttl = el("input", { type: "number", min: "5", value: String(cfg.unpaid_order_ttl_minutes ?? 120), class: "input--small" });
    const contact = el("input", { type: "email", value: cfg.contact_email ?? "" });
    const socials = el("textarea", { rows: "3" }, JSON.stringify(cfg.official_social_links ?? {}, null, 1));
    const ads = el("input", { type: "checkbox", checked: cfg.display_ads_enabled === true || null });
    const wa = el("input", { type: "tel", inputmode: "numeric", maxlength: "15", placeholder: "6281234567890", value: cfg.ad_whatsapp ?? "" });
    const payDays = el("input", { type: "number", min: "1", max: "60", value: String(cfg.ad_payment_window_days ?? 7), class: "input--small" });
    const setConfig = async (key, value) => { await api("set_config", { key, value }); };
    const saveCfg = button("Save settings", async () => {
      let links;
      try { links = JSON.parse(socials.value || "{}"); } catch { toast("Official social links must be JSON, e.g. {\"instagram\":\"https://instagram.com/…\"}", "error"); return; }
      const lo = parseRupiah(dmin.value);
      const hi = parseRupiah(dmax.value);
      if (!lo.ok || !hi.ok) { toast("Donation limits must be whole rupiah.", "error"); return; }
      await setConfig("note_moderation", moderation.value);
      await setConfig("donation_min_amount", Number(lo.digits));
      await setConfig("donation_max_amount", Number(hi.digits));
      await setConfig("unpaid_order_ttl_minutes", Number(ttl.value));
      await setConfig("contact_email", contact.value.trim());
      await setConfig("official_social_links", links);
      await setConfig("display_ads_enabled", ads.checked);
      if (!/^(\d{8,15})?$/.test(wa.value.trim())) { toast("WhatsApp number: digits only with country code, e.g. 6281234567890.", "error"); return; }
      await setConfig("ad_whatsapp", wa.value.trim());
      await setConfig("ad_payment_window_days", Number(payDays.value));
      toast("Settings saved.", "success");
      reload();
    }, "btn btn--primary");

    panel.replaceChildren(policy,
      el("h2", {}, "Decorations"), decoGrid,
      el("h2", {}, "Payment methods"),
      el("p", { class: "small muted" }, "Set limits from your Midtrans/acquirer agreement. A method is offered only when the order total fits its limits; totals are never reduced to fit."),
      pmTable,
      el("h2", {}, "Advertising packages"),
      el("p", { class: "small muted" }, "Advertisers pick placement (Random or Featured) and duration; only enabled packages with at least one enabled location are offered. The base fee covers the first location; each added location costs the extra % of the base fee (100% = the same price again, 50% = half). The total is frozen when an advertiser submits."),
      adTable,
      el("h2", {}, "Site settings"),
      el("div", { class: "stack narrow" },
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Note moderation"), moderation),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Donation minimum (Rp)"), dmin),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Donation maximum (Rp, donations only)"), dmax),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Unpaid order expiry (minutes)"), ttl),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Public contact email"), contact),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Official social links (JSON)"), socials),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Ads: WhatsApp number for custom packages (digits, country code; empty hides the button)"), wa),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Ads: days to pay after approval"), payDays),
        el("label", { class: "check" }, ads, el("span", {}, "Enable third-party display ad slots (requires provider setup; see OPERATIONS.md)")),
        saveCfg));
  },

  async locations(panel, reload, state) {
    const c = getClient();
    const [countries, regions, cities, campuses] = await Promise.all([
      query(c.from("countries").select("code,name").order("name")),
      query(c.from("regions").select("id,name,country_code,kind").order("name")),
      query(c.from("cities").select("id,name,region_id").order("name")),
      query(c.from("campuses").select("id,name,short_name,city_id").order("name")),
    ]);
    const form = (level, parentOptions, extra = []) => {
      const name = el("input", { placeholder: "Name", required: true });
      const parent = parentOptions ? el("select", {}, ...parentOptions.map((o) => el("option", { value: o.value }, o.label))) : null;
      const code = level === "country" ? el("input", { placeholder: "ISO code (e.g. MY)", maxlength: "2" }) : null;
      const short = level === "campus" ? el("input", { placeholder: "Short name" }) : null;
      return el("div", { class: "row row--tight" }, el("strong", {}, `Add ${level}`), code, parent, name, short, ...extra,
        button("Add", async () => {
          if (!name.value.trim()) { toast("Name is required.", "error"); return; }
          await api("upsert_location", { level, id: code ? code.value.trim().toUpperCase() : null, parent: parent?.value ?? null, name: name.value.trim(), short_name: short?.value.trim() || null });
          toast(`${level} added.`, "success");
          reload();
        }));
    };
    const disable = (level, id) => button("Disable", async () => {
      const ok = await openDialog({ title: `Disable this ${level}?`, body: el("p", {}, "It will disappear from pickers and targeting. Existing campaigns targeting it stop matching it."), danger: true, okLabel: "Disable" });
      if (!ok) return;
      const row = { country: countries, region: regions, city: cities, campus: campuses }[level].find((x) => (x.id ?? x.code) === id);
      await api("upsert_location", { level, id, name: row.name, short_name: row.short_name ?? null, enabled: false });
      reload();
    }, "btn btn--small btn--danger");
    const del = (level, id) => ownerDelete(state, level, id, level, reload);
    const manage = (level, id) => actions(disable(level, id), del(level, id));
    panel.replaceChildren(
      el("p", { class: "small muted" }, "Adding a country is a data change: add the country, then its regions, cities and campuses."),
      form("country"),
      form("region", countries.map((x) => ({ value: x.code, label: x.name }))),
      form("city", regions.map((x) => ({ value: x.id, label: `${x.name} (${x.country_code})` }))),
      form("campus", cities.map((x) => ({ value: x.id, label: x.name }))),
      el("h2", {}, "Countries"),
      table([{ label: "Country", key: "name" }, { label: "Code", key: "code" }, { label: "", render: (x) => manage("country", x.code) }], countries),
      el("h2", {}, "Campuses"),
      table([{ label: "Campus", render: (x) => x.short_name ? `${x.short_name} — ${x.name}` : x.name },
        { label: "City", render: (x) => cities.find((ci) => ci.id === x.city_id)?.name ?? "" },
        { label: "", render: (x) => manage("campus", x.id) }], campuses),
      el("h2", {}, "Cities"),
      table([{ label: "City", key: "name" }, { label: "Region", render: (x) => regions.find((r) => r.id === x.region_id)?.name ?? "" },
        { label: "", render: (x) => manage("city", x.id) }], cities),
      el("h2", {}, "Regions"),
      table([{ label: "Region", key: "name" }, { label: "Country", key: "country_code" }, { label: "", render: (x) => manage("region", x.id) }], regions),
    );
  },

  async promos(panel, reload) {
    const rows = await api("list_promos");
    const f = { code: el("input", { placeholder: "e.g. LAUNCH50", maxlength: "24" }),
      kind: el("select", {}, el("option", { value: "percent" }, "% off the minimum"), el("option", { value: "fixed" }, "Rp off the minimum")),
      value: el("input", { inputmode: "numeric", placeholder: "100 = free post" }),
      max: el("input", { inputmode: "numeric", placeholder: "blank = unlimited" }),
      per: el("input", { inputmode: "numeric", placeholder: "default 1" }),
      exp: el("input", { type: "date" }) };
    f.per.value = "1";
    const lab = (text, node) => el("label", { class: "field" }, el("span", { class: "field__label" }, text), node);
    const create = button("Create code", async () => {
      await api("create_promo", { code: f.code.value, kind: f.kind.value, value: Number(f.value.value), max_uses: f.max.value.trim() || null,
        per_user: Number(f.per.value) || 1, expires_at: f.exp.value || null });
      toast("Code created.", "success"); reload();
    }, "btn btn--primary btn--small");
    panel.replaceChildren(
      el("p", { class: "notice" }, "Discounts apply to the minimum price only; anything paid above it is a tip and is never discounted. Codes need a signed-in account."),
      el("div", { class: "row" },
        lab("Code (4-24 letters/digits)", f.code), lab("Type", f.kind), lab("Value (% or Rp)", f.value),
        lab("Max uses in total", f.max), lab("Uses per person", f.per), lab("Expires on (optional)", f.exp), create),
      table([
        { label: "Code", key: "code" },
        { label: "Discount", render: (r) => (r.kind === "percent" ? `${r.value}%` : formatRupiah(r.value)) },
        { label: "Used", render: (r) => `${r.uses}${r.max_uses ? ` / ${r.max_uses}` : ""}` },
        { label: "Per user", key: "per_user_limit" },
        { label: "Expires", render: (r) => (r.expires_at ? formatDate(r.expires_at) : "never") },
        { label: "On", render: (r) => button(r.enabled ? "Disable" : "Enable", async () => { await api("set_promo_enabled", { id: r.id, enabled: !r.enabled }); reload(); }) },
      ], rows, "No codes yet."));
  },

  async announcements(panel, reload, state) {
    const items = await api("list_announcements");
    const title = el("input", { maxlength: "120" });
    const body = el("textarea", { rows: "6", maxlength: "4000" });
    const pinned = el("input", { type: "checkbox" });
    let editing = null;
    const save = button("Save draft", async () => {
      if (title.value.trim().length < 3 || !body.value.trim()) { toast("Title (3+ chars) and text are required.", "error"); return; }
      await api("upsert_announcement", { id: editing, title: title.value, body: body.value, pinned: pinned.checked });
      toast("Saved. Publish it from the list.", "success");
      reload();
    }, "btn btn--primary");
    const preview = button("Preview", async () => {
      await openDialog({ title: title.value.trim() || "Preview", okLabel: "Close", body: el("p", { class: "announcement__body" }, body.value) });
    });
    const STATUS_LABEL = { published: "Publish", draft: "Unpublish", archived: "Archive" };
    const setStatus = (a, status) => button(STATUS_LABEL[status], async () => { await api("set_announcement_status", { id: a.id, status }); reload(); });
    const field = (label, node) => el("label", { class: "field" }, el("span", { class: "field__label" }, label), node);
    panel.replaceChildren(
      el("div", { class: "stack narrow card" }, el("h2", {}, "Write news"),
        field("Title", title), field("Text", body),
        el("label", { class: "check" }, pinned, el("span", {}, "Pin on the wall")), actions(save, preview)),
      el("h2", {}, "Recent news"),
      table([
        { label: "Title", key: "title" },
        { label: "Status", render: (a) => el("span", { class: `badge${a.status === "published" ? " badge--ok" : ""}` }, humanize(a.status)) },
        { label: "Pinned", render: (a) => (a.pinned ? "Pinned" : "") },
        { label: "Published", render: (a) => formatDate(a.published_at) },
        { label: "Last edited by", render: (a) => a.updated_by_name ?? "" },
        { label: "Actions", render: (a) => actions(
          button("Edit", () => { editing = a.id; title.value = a.title; body.value = a.body; pinned.checked = a.pinned; save.textContent = "Save changes"; title.focus(); }),
          a.status !== "published" && setStatus(a, "published"),
          a.status === "published" && setStatus(a, "draft"),
          a.status !== "archived" && setStatus(a, "archived"),
          ownerDelete(state, "announcement", a.id, "news item", reload)) },
      ], items));
  },

  async referrals(panel, reload, state) {
    const rows = await api("list_referrals", { limit: 200 });
    panel.replaceChildren(table([
      { label: "Referred", key: "referred_name" },
      { label: "Referrer", key: "referrer_name" },
      { label: "Code", key: "code" },
      { label: "Status", render: (r) => `${r.status}${r.reject_reason ? ` (${r.reject_reason})` : ""}` },
      { label: "Credit (old)", key: "credit_status" },
      { label: "Referral credits", render: (r) => String(r.reward_credits ?? 0) },
      { label: "Created", render: (r) => formatDate(r.created_at, true) },
      { label: "", render: (r) => r.credit_status === "available" ? button("Revoke credit", async () => {
        const reason = await promptReason("Revoke this unredeemed credit?", { required: true, danger: true, okLabel: "Revoke" });
        if (reason === null) return;
        await api("revoke_credit", { credit_id: r.credit_id, reason });
        reload();
      }, "btn btn--small btn--danger") : "" },
      { label: "", render: (r) => Number(r.reward_credits) > 0 ? button("Revoke referral credits", async () => {
        const reason = await promptReason("Revoke the UNUSED referral credits from this referral? Credits already used on orders are not affected.", { required: true, danger: true, okLabel: "Revoke" });
        if (reason === null) return;
        try {
          const res = await api("revoke_referral_credits", { referred_user_id: r.referred_user_id, reason });
          toast(`${res?.revoked ?? 0} credit(s) revoked.`, "success");
        } catch (err) { toast(errorMessage(err), "error"); }
        reload();
      }, "btn btn--small btn--danger") : "" },
      { label: "Entry", render: (r) => ownerDelete(state, "referral", r.referred_user_id, "referral entry", reload) ?? "" },
    ], rows));
  },

  async revenue(panel, reload, state) {
    const now = new Date();
    state.range ??= { from: new Date(now.getFullYear(), now.getMonth(), 1).toISOString().slice(0, 10), to: new Date(now.getTime() + 86400e3).toISOString().slice(0, 10) };
    const from = el("input", { type: "date", value: state.range.from });
    const to = el("input", { type: "date", value: state.range.to });
    const go = button("Run report", async () => { state.range = { from: from.value, to: to.value }; reload(); });
    const d = await api("revenue_report", { from: `${state.range.from}T00:00:00+07:00`, to: `${state.range.to}T00:00:00+07:00` });
    const money = ["publication_revenue", "decoration_revenue", "donations", "advertising_revenue", "gross_payment_volume", "refunds_and_reversals", "net_collected", "credit_discounts_given", "average_order_value"];
    const pct = (v) => (v === null || v === undefined ? "n/a" : `${(Number(v) * 100).toFixed(1)}%`);
    const items = [
      ...money.map((k) => [k, formatRupiah(d[k])]),
      ["processing_fees", d.processing_fees === null ? "not available (see Midtrans settlement reports)" : formatRupiah(d.processing_fees)],
      ["paid_orders", d.paid_orders], ["free_publications", d.free_publications], ["checkout_sessions", d.checkout_sessions],
      ["checkout_completion_rate", pct(d.checkout_completion_rate)], ["decoration_attachment_rate", pct(d.decoration_attachment_rate)],
      ["credits_issued", d.credits_issued], ["credits_redeemed", d.credits_redeemed],
      ["campaign_impressions", d.campaign_impressions], ["campaign_clicks", d.campaign_clicks], ["campaign_renewals", d.campaign_renewals],
    ];
    panel.replaceChildren(actions(el("span", {}, "From"), from, el("span", {}, "to (exclusive)"), to, go),
      el("dl", { class: "stats stats--grid" }, ...items.map(([k, v]) => el("div", {}, el("dt", { title: d.definitions?.[k] ?? "" }, k.replace(/_/g, " ")), el("dd", {}, String(v))))),
      el("h3", {}, "Definitions"),
      el("ul", { class: "small" }, ...Object.entries(d.definitions ?? {}).map(([k, v]) => el("li", {}, el("strong", {}, k.replace(/_/g, " ")), `: ${v}`))));
  },

  async audit(panel, reload, state) {
    const rows = await api("audit_log", { limit: 200 });
    panel.replaceChildren(table([
      { label: "When", render: (r) => formatDate(r.created_at, true) },
      { label: "Admin", key: "actor_name" },
      { label: "Action", render: (r) => humanize(r.action) },
      { label: "Target", render: (r) => el("span", {}, `${humanize(r.target_type)} `, shortId(r.target_id)) },
      { label: "Reason", key: "reason" },
      { label: "", render: (r) => ownerDelete(state, "audit_entry", r.id, "audit log entry", reload) ?? "" },
    ], rows));
  },

  // Append-only trail of Owner deletions. It has no delete control anywhere.
  async security(panel) {
    const rows = await api("security_events", { limit: 200 });
    panel.replaceChildren(table([
      { label: "When", render: (r) => formatDate(r.created_at, true) },
      { label: "Action", render: (r) => humanize(r.action) },
      { label: "Type", render: (r) => humanize(r.target_type) },
      { label: "Target", render: (r) => shortId(r.target_id) },
      { label: "Details", render: (r) => details(r.details) },
    ], rows, "No security events."));
  },
};

export async function mount(view, { signal }) {
  const user = currentUser();
  if (!user || !(await isAdmin())) {
    const frag = cloneTemplate("tpl-signin-required");
    const r = refs(frag);
    r.title.textContent = "Administrators only";
    r.message.textContent = user ? "Your account does not have administrator access." : "Sign in with an administrator account.";
    view.append(frag);
    return;
  }
  view.append(cloneTemplate("tpl-admin"));
  const r = refs(view);
  const state = { tab: "overview", owner: await isOwner() };
  let req = 0;
  if (!state.owner) r.tabs.querySelectorAll("[data-owner-only]").forEach((t) => t.remove());

  const show = async () => {
    const id = ++req;
    r.tabs.querySelectorAll("[data-tab]").forEach((t) => t.setAttribute("aria-selected", String(t.dataset.tab === state.tab)));
    r.panel.replaceChildren(el("p", { class: "muted" }, "Loading…"));
    try {
      const panel = el("div");
      await panels[state.tab](panel, show, state);
      if (id === req && !signal.aborted) r.panel.replaceChildren(panel);
    } catch (err) {
      if (id === req) r.panel.replaceChildren(el("p", { class: "wall-error", role: "alert" }, errorMessage(err)));
    }
  };
  r.tabs.addEventListener("click", (e) => {
    const tab = e.target.closest("[data-tab]");
    if (!tab || !panels[tab.dataset.tab]) return;
    state.tab = tab.dataset.tab;
    show();
  }, { signal });
  await show();
}
