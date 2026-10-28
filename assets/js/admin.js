// Administrator console. Purely a UI over the admin-api Edge Function: the
// visible menu grants nothing, and every action is re-authorized server-side
// (Edge Function + SQL require_admin()) and written to the audit log.

import { cloneTemplate } from "./component-loader.js";
import { translate } from "./i18n.js";
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
  // A failed action must say why (e.g. "This location still has a free slot"), not fall through to a generic error.
  b.addEventListener("click", () => busy(b, async () => {
    try { await onClick(); } catch (err) { toast(errorMessage(err), "error", 8000); }
  }));
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

/** "launch −50% (list Rp…)", "🔒 locked rate Rp…", "founding #2" next to a price. Real fields only; nothing is invented. */
function rateText(r, base) {
  const bits = [];
  if (r.list_price && String(r.list_price) !== String(r.price) && !r.price_locked) bits.push(`launch −${r.launch_discount_pct ?? 0}% (list ${formatRupiah(r.list_price)})`);
  if (r.price_locked) bits.push(`🔒 locked at base ${formatRupiah(r.price_base_used ?? r.locked_base_fee)} (list ${formatRupiah(r.list_price)})`);
  if (r.founding_rank) bits.push(`founding #${r.founding_rank}`);
  return [base, ...bits].filter(Boolean).join(" · ");
}

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

/** Typed-DELETE confirmation shared by the Admin/Owner deletes below. Resolves true when confirmed. */
async function confirmDelete(title, intro, lines = []) {
  const input = el("input", { name: "confirm", required: true, pattern: "DELETE", autocomplete: "off", placeholder: "DELETE" });
  const body = el("div", { class: "stack" }, el("p", {}, intro),
    lines.length ? el("ul", { class: "small" }, ...lines.map((t) => el("li", {}, t))) : null,
    el("label", { class: "field" }, el("span", { class: "field__label" }, "Type DELETE to confirm"), input));
  const data = await openDialog({ title, body, okLabel: "Delete permanently", danger: true });
  return !!data && data.get("confirm") === "DELETE";
}

/** Admin or Owner: delete an account and everything tied to it. Payment records stay (detached). */
function deleteUserButton(row, reload) {
  return button("Delete", async () => {
    let p;
    try { p = await api("delete_user_preview", { user_id: row.id }); } catch (err) { toast(errorMessage(err), "error"); return; }
    if (p.live_campaigns > 0) { toast("This account has a live or unpaid campaign. Cancel it first.", "error"); return; }
    const ok = await confirmDelete(`Delete account “${p.display_name}”`,
      "Permanently delete this account and everything associated with it? This cannot be undone.",
      [`${p.notes} note(s), with their photos and videos`, `${p.votes} vote(s), ${p.bookmarks} bookmark(s)`, `${p.campaigns} campaign(s)`,
        "Profile, referral data and credits", `${p.orders_kept} order(s) stay for accounting but are detached from the account.`]);
    if (!ok) return;
    try { await api("delete_user", { user_id: row.id, confirm: "DELETE" }); toast("Account deleted.", "success"); } catch (err) { toast(errorMessage(err), "error"); }
    reload();
  }, "btn btn--small btn--danger");
}

/** Admin or Owner: find a note by receipt ID (or pasted receipt link) and delete it. Works for guest notes. */
function receiptLookup(reload) {
  const input = el("input", { type: "search", placeholder: "Receipt ID or receipt link", autocomplete: "off" });
  const go = button("Find note", async () => {
    const raw = input.value.trim();
    const ref = (raw.match(/[?&]order=([^&#\s]+)/)?.[1] ?? raw).replace(/^#?\/?/, "");
    if (!ref) return;
    let r;
    try { r = await api("find_note_by_receipt", { order_ref: decodeURIComponent(ref) }); } catch (err) { toast(errorMessage(err), "error"); return; }
    if (!r.note) { toast(`Order ${r.order_ref} has no note (${r.order_status}).`, "info"); return; }
    const ok = await confirmDelete("Delete note",
      `Permanently delete this ${r.is_guest ? "guest " : ""}note? This cannot be undone.`,
      [`Receipt: ${r.order_ref} (${r.order_status}, ${formatRupiah(r.total_amount)})`, `Status: ${r.note.status} · by ${r.note.author_name}`, `“${r.note.body}”`,
        "Votes, bookmarks, reports and media go with it. The order and payment record stay."]);
    if (!ok) return;
    try { await api("delete_note_by_receipt", { order_ref: r.order_ref, confirm: "DELETE" }); toast("Note deleted.", "success"); input.value = ""; } catch (err) { toast(errorMessage(err), "error"); }
    reload();
  });
  return actions(input, go);
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
  async overview(panel, reload, state) {
    const jakarta = (offsetDays) => new Date(Date.now() + 7 * 3600e3 + offsetDays * 864e5).toISOString().slice(0, 10);
    const [o, d, rev] = await Promise.all([api("overview"), api("leaderboard_diagnostics"),
      api("revenue_report", { from: `${jakarta(-6)}T00:00:00+07:00`, to: `${jakarta(1)}T00:00:00+07:00` })]);
    const go = (tab) => { state.tab = tab; reload(); };
    const stat = (title, items) => el("dl", { class: "stats stats--grid", "aria-label": title },
      ...Object.entries(items).map(([k, v]) => el("div", {}, el("dt", {}, k), el("dd", {}, String(v ?? 0)))));
    // Things waiting for a human, each with a button that opens the right tab. Zero items = nothing to do.
    const todo = [
      [o.campaigns_pending_review, "ad(s) waiting for your review", "campaigns", "Review ads"],
      [o.notes_pending_moderation, "note(s) waiting for approval", "moderation", "Review notes"],
      [o.open_reports, "open report(s) about notes", "reports", "Open reports"],
      [o.orders_needing_review, "payment(s) that need a check", "orders", "Check payments"],
    ].filter(([n]) => Number(n) > 0);
    panel.replaceChildren(
      el("h2", {}, "Needs your attention"),
      todo.length
        ? el("ul", { class: "todo-list" }, ...todo.map(([n, text, tab, label]) =>
          el("li", {}, el("span", {}, el("span", { class: "todo-n" }, String(n)), text), button(label, () => go(tab), "btn btn--small btn--primary"))))
        : el("p", { class: "notice" }, "All clear. Nothing is waiting for you right now."),
      el("h2", {}, "Last 7 days"),
      stat("Last 7 days", { "Money in, after refunds": formatRupiah(rev.net_collected), "Paid orders": rev.paid_orders,
        "Notes posted today": o.notes_today, "Notes posted this week": o.notes_7d }),
      el("h2", {}, "Whole site"),
      stat("Whole site", { "Notes on the wall": o.published_notes, "Accounts": o.users, "Referrals that counted": d.qualified_referrals,
        "Donors who opted in": d.opted_in_donors, "Successful donations": d.successful_donations }),
      el("h2", {}, "Common tasks"),
      actions(button("Change prices & settings", () => go("catalog")), button("Post site news", () => go("announcements")),
        button("See all payments", () => go("orders")), button("Revenue report", () => go("revenue"))),
      el("h2", {}, "Housekeeping"),
      el("p", { class: "small muted" }, "Unpaid orders close by themselves after their time limit. Use this if you want to close them right now."),
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
      { label: "Actions", render: (r) => r.is_admin ? "" : actions(button(r.suspended_at ? "Unsuspend" : "Suspend", async () => {
        const reason = await promptReason(r.suspended_at ? "Unsuspend this account?" : "Suspend this account?", { required: !r.suspended_at, danger: !r.suspended_at });
        if (reason === null) return;
        const res = await invoke("admin-api", { action: "set_user_suspension", params: { user_id: r.id, suspend: !r.suspended_at, reason } });
        if (res.auth_ban === "failed") toast("Saved, but the sign-in ban could not be updated in Supabase Auth.", "error");
        reload();
      }, r.suspended_at ? "btn btn--small" : "btn btn--small btn--danger"), deleteUserButton(r, reload)) },
    ], rows));
  },

  async orders(panel, reload, state) {
    state.orderFilter ??= { kind: "", status: "", review_only: false };
    const f = state.orderFilter;
    const kind = el("select", {}, ...["", "publication", "donation", "advertising"].map((k) => el("option", { value: k, selected: k === f.kind || null }, k ? humanize(k) : "all kinds")));
    const status = el("select", {}, ...["", "awaiting_payment", "challenge", "paid", "completed_free", "payment_waived", "failed", "canceled", "expired", "partially_refunded", "refunded", "reversed"]
      .map((s) => el("option", { value: s, selected: s === f.status || null }, s ? humanize(s) : "all statuses")));
    const review = el("input", { type: "checkbox", checked: f.review_only || null });
    const apply = button("Filter", async () => { Object.assign(f, { kind: kind.value, status: status.value, review_only: review.checked }); reload(); });
    const rows = await api("list_orders", { kind: f.kind || null, status: f.status || null, review_only: f.review_only, limit: 100 });
    panel.replaceChildren(receiptLookup(reload), actions(kind, status, el("label", { class: "check" }, review, " needs review"), apply), table([
      { label: "Order", key: "order_ref" },
      { label: "Kind", key: "kind" },
      { label: "Status", key: "status" },
      { label: "Total", render: (r) => formatRupiah(r.total_amount) },
      { label: "Rate", render: (r) => (r.kind === "advertising" ? rateText({ ...r, price: r.total_amount, price_base_used: r.locked_base_fee }, "") : "") },
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
      { label: "Package", render: (r) => rateText(r, `${r.placement === "featured" ? "Featured" : "Random"} · ${r.duration_days ?? "?"}d · ${formatRupiah(r.price)}`) },
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
    const decoList = el("div", { class: "stack" });
    const catSel = el("select", { "aria-label": "Decoration category" },
      el("option", { value: "" }, "All categories"), ...cats.map((cat) => el("option", { value: cat }, cat)));
    const paintDecos = () => decoList.replaceChildren(...cats.filter((cat) => !catSel.value || cat === catSel.value).map((cat) => el("div", {},
      el("h3", { class: "small muted" }, cat),
      el("div", { class: "deco-grid" }, ...c.decorations.filter((d) => (d.category || "Other") === cat).map(decoTile)))));
    catSel.addEventListener("change", paintDecos);
    paintDecos();
    const decoGrid = el("div", { class: "stack" },
      el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Category"), catSel), decoList);

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

    const cfgNow = Object.fromEntries(c.config.map((row) => [row.key, row.value]));
    const allowedDays = Array.isArray(cfgNow.ad_allowed_durations) ? cfgNow.ad_allowed_durations : [7, 30, 60, 90];
    const launchOn = cfgNow.launch_mode_enabled === true;
    const launchGlobal = Number(cfgNow.launch_discount_pct ?? 50);
    const FORMULA = "total = base + (extra locations × % × base)";
    // Retired lengths (e.g. 14 days) stay in the database but are not listed here unless still enabled.
    const adRows = c.ad_products.filter((a) => allowedDays.includes(a.duration_days) || a.enabled).map((a) => {
      const price = amountInput("price", a.price_per_target);
      const global = a.scope_level === "global"; // always one location, so no extra-location %
      const pct = el("input", { type: "number", min: "0", max: "100", step: "1", value: String(a.extra_location_pct), disabled: global || null, class: "input--small", title: FORMULA, "aria-label": "Extra-location surcharge (%)" });
      const launch = el("input", { type: "number", min: "0", max: "90", step: "1", value: a.launch_discount_pct ?? "", placeholder: `${launchGlobal}`, class: "input--small", "aria-label": "Launch discount override (%), empty = global" });
      const days = el("select", { class: "input--small", "aria-label": "Duration in days" },
        ...[...new Set([...allowedDays, a.duration_days])].sort((x, y) => x - y).map((d) => el("option", { value: String(d), selected: d === a.duration_days || null }, String(d))));
      const example = el("span", { class: "small" });
      const paint = () => {
        const p = parseRupiah(price.value);
        const extra = global ? 0 : Number(pct.value);
        if (!p.ok || BigInt(p.digits) < 1n || !Number.isInteger(extra) || extra < 0 || extra > 100) { example.textContent = "—"; return; }
        const n = global ? 1 : 3;
        let text = `${global ? "" : "3 locations: "}${formatRupiah(adPrice(p.digits, extra, n))}`;
        if (launchOn) {
          const d = launch.value === "" ? launchGlobal : Number(launch.value);
          const disc = (BigInt(p.digits) * BigInt(100 - (Number.isFinite(d) ? d : 0)) + 50n) / 100n;
          text += ` → launch ${formatRupiah(adPrice(String(disc), extra, n))}`;
        }
        example.textContent = text;
      };
      [price, pct, launch].forEach((i) => i.addEventListener("input", paint));
      paint();
      return { a, price, pct, launch, days, example, global,
        enabled: el("input", { type: "checkbox", checked: a.enabled || null }) };
    });
    const saveAd = async (x) => {
      const p = parseRupiah(x.price.value);
      if (!p.ok || BigInt(p.digits) < 1n) { toast("Base fee must be more than Rp0.", "error"); return; }
      const extra = x.global ? 100 : Number(x.pct.value);
      if (!Number.isInteger(extra) || extra < 0 || extra > 100) { toast("Extra-location surcharge must be a whole number from 0 to 100.", "error"); return; }
      const lp = x.launch.value === "" ? null : Number(x.launch.value);
      if (lp !== null && (!Number.isInteger(lp) || lp < 0 || lp > 90)) { toast("Launch discount must be a whole number from 0 to 90.", "error"); return; }
      const params = { id: x.a.id, name: x.a.name, placement: x.a.placement, scope_level: x.a.scope_level, duration_days: Number(x.days.value),
        price: p.digits, extra_pct: extra, launch_pct: lp, enabled: x.enabled.checked, sort: x.a.sort_order };
      // The server asks for each confirmation it needs; we show it and resend with the matching flag.
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          await api("upsert_ad_product", params);
          Object.assign(x.a, { price_per_target: p.digits, extra_location_pct: extra, launch_discount_pct: lp, duration_days: params.duration_days, enabled: params.enabled });
          toast(`Saved “${x.a.name}”. Existing campaigns and orders keep their original price; only new quotes use this.`, "success");
          return;
        } catch (err) {
          const flag = { PRICE_CHANGE_CONFIRM_BIG: "confirm_big", PRICE_CHANGE_CONFIRM_ACTIVE: "confirm_active" }[err.code];
          if (!flag) { toast(`Not saved: ${errorMessage(err)}`, "error"); return; }
          const ok = await openDialog({ title: err.code === "PRICE_CHANGE_CONFIRM_BIG" ? "Large price change" : "Campaigns use this package",
            body: el("p", {}, errorMessage(err)), okLabel: "Yes, save", danger: true });
          if (!ok) return;
          params[flag] = true;
        }
      }
    };
    const surchargeHead = el("span", {}, "Extra-location surcharge (%) ", el("span", { class: "help", tabindex: "0", title: FORMULA, "aria-label": `Formula: ${FORMULA}` }, "ⓘ"));
    const adTable = table([
      { label: "Package", render: (x) => `${x.a.name} [${x.a.placement} · ${x.a.scope_level}]` },
      { label: "Days", render: (x) => x.days },
      { label: "Base fee (Rp)", render: (x) => x.price },
      { label: surchargeHead, render: (x) => x.pct },
      { label: "Launch % (blank = global)", render: (x) => x.launch },
      { label: "Computed (live, before Save)", render: (x) => x.example },
      { label: "Active", render: (x) => x.enabled },
      { label: "", render: (x) => button("Save", () => saveAd(x)) },
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
    const launchMode = el("input", { type: "checkbox", checked: cfg.launch_mode_enabled === true || null });
    const launchPct = el("input", { type: "number", min: "0", max: "90", step: "1", value: String(cfg.launch_discount_pct ?? 50), class: "input--small" });
    const foundingCount = el("input", { type: "number", min: "0", max: "1000", step: "1", value: String(cfg.founding_advertiser_count ?? 10), class: "input--small" });
    const graceDays = el("input", { type: "number", min: "0", max: "365", step: "1", value: String(cfg.price_lock_grace_days ?? 7), class: "input--small" });
    const durations = el("input", { value: (cfg.ad_allowed_durations ?? [7, 30, 60, 90]).join(", "), placeholder: "7, 30, 60, 90" });
    const reportMail = el("input", { type: "checkbox", checked: cfg.ad_report_email_enabled !== false || null });
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
      const dur = durations.value.split(",").map((t) => Number(t.trim())).filter((n) => n);
      if (!dur.length || dur.some((n) => !Number.isInteger(n) || n < 1 || n > 365)) { toast("Allowed durations: whole days separated by commas, e.g. 7, 30, 60, 90.", "error"); return; }
      await setConfig("launch_mode_enabled", launchMode.checked);
      await setConfig("launch_discount_pct", Number(launchPct.value));
      await setConfig("founding_advertiser_count", Number(foundingCount.value));
      await setConfig("price_lock_grace_days", Number(graceDays.value));
      await setConfig("ad_allowed_durations", dur);
      await setConfig("ad_report_email_enabled", reportMail.checked);
      toast("Settings saved. Launch mode and price changes affect new quotes only.", "success");
      reload();
    }, "btn btn--primary");

    panel.replaceChildren(policy,
      el("h2", {}, "Decorations"), decoGrid,
      el("h2", {}, "Payment methods"),
      el("p", { class: "small muted" }, "Set limits from your Midtrans/acquirer agreement. A method is offered only when the order total fits its limits; totals are never reduced to fit."),
      pmTable,
      el("h2", {}, "Advertising packages"),
      el("p", { class: "small muted" }, "Advertisers pick placement (Random or Featured) and duration; only enabled packages with at least one enabled location are offered. The base fee covers the first location; each added location costs the extra % of the base fee (100% = the same price again, 50% = half). The total is frozen when an advertiser submits, and changing a price never changes an existing campaign or order. Hover ⓘ for the formula."),
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
        el("h3", {}, "Launch pricing and price lock"),
        el("label", { class: "check" }, launchMode, el("span", {}, "Launch mode: show “Founding advertiser rate” (struck-through list price) for new quotes. Existing campaigns and orders never change.")),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Launch discount % off the base fee (a package can override it)"), launchPct),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Founding advertisers: how many first paying advertisers get a locked rate"), foundingCount),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Price lock: renew within this many days of expiry to keep the rate"), graceDays),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Allowed campaign lengths in days (comma separated)"), durations),
        el("label", { class: "check" }, reportMail, el("span", {}, "Email advertisers a summary when their campaign ends")),
        el("label", { class: "check" }, ads, el("span", {}, "Enable third-party display ad slots (requires provider setup; see OPERATIONS.md)")),
        saveCfg));
  },

  /** Ad insights: per spot and location views/visitors/clicks/CTR/fill, the CPM-based suggested price, waitlist demand. */
  async adinsights(panel, reload, state) {
    state.insightDays ??= 30;
    const [res, wl, cat] = await Promise.all([api("pricing_analytics", { days: state.insightDays }), api("waitlist_counts"), api("list_catalog")]);
    const days = el("select", { "aria-label": "Window" }, ...[7, 30].map((d) => el("option", { value: String(d), selected: d === state.insightDays || null }, `Last ${d} days`)));
    days.addEventListener("change", () => { state.insightDays = Number(days.value); reload(); });
    const cpm = amountInput("cpm", res.target_cpm ? String(res.target_cpm) : "", "e.g. 15000");
    const saveCpm = button("Save target CPM", async () => {
      const v = cpm.value.trim() === "" ? { ok: true, digits: "0" } : parseRupiah(cpm.value);
      if (!v.ok) { toast("Enter whole rupiah per 1,000 views.", "error"); return; }
      await api("set_config", { key: "target_cpm", value: Number(v.digits) });
      toast("Target CPM saved.", "success");
      reload();
    });
    const spotName = (s) => (s === "featured" ? "Featured" : "Random");
    const rows = res.rows.map((r) => r);
    const price = (n) => (n == null ? "—" : formatRupiah(String(Math.round(Number(n)))));
    const suggest = (r) => {
      if (!r.enough) return el("span", { class: "muted" }, `Not enough data (${r.days_of_data}/${res.min_days_required} days)`);
      if (!res.target_cpm) return el("span", { class: "muted" }, "Set a target CPM");
      return el("span", {}, price(r.suggested_weekly_price));
    };
    const warn = (r) => (r.price_warning
      ? el("span", { class: "badge badge--warn" }, r.price_warning === "above" ? "Current price >30% above suggestion" : "Current price >30% below suggestion") : "");
    const wlRows = wl.rows;
    panel.replaceChildren(
      el("p", { class: "small muted" }, "Real numbers only. A spot needs 14 days of data before a price is suggested. Suggested weekly price = average weekly views × target CPM ÷ 1,000. Fill rate counts sold slot-days ÷ available slot-days (Featured spots; Random rotation has no fixed slots)."),
      actions(el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Window"), days),
        el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Target price per 1,000 views (Rp)"), cpm), saveCpm,
        button("Run ad jobs now", async () => {
          const out = await api("run_ad_jobs");
          toast(`Ad jobs ran: ${JSON.stringify(out)}`, "success");
        })),
      table([
        { label: "Spot", render: (r) => spotName(r.spot) },
        { label: "Location", key: "label" },
        { label: "Views", key: "impressions" },
        { label: "Unique visitors", key: "unique_visitors" },
        { label: "Clicks", key: "clicks" },
        { label: "CTR", render: (r) => (r.ctr_pct == null ? "—" : `${r.ctr_pct}%`) },
        { label: "Fill rate", render: (r) => (r.fill_rate_pct == null ? "n/a" : `${r.fill_rate_pct}%`) },
        { label: "Current weekly price (1 location)", render: (r) => price(r.current_weekly_price) },
        { label: "Suggested weekly price", render: suggest },
        { label: "Check", render: warn },
      ], rows, "No ad data yet. New platform: launch pricing applies."),
      el("h2", {}, `Waitlist (${wl.total_waiting} waiting)`),
      table([
        { label: "Spot", render: (r) => spotName(r.spot) },
        { label: "Reach", key: "scope_level" },
        { label: "Location", render: (r) => r.label ?? "any" },
        { label: "Days wanted", key: "desired_duration" },
        { label: "Waiting", key: "waiting" },
      ], wlRows, "Nobody is on the waitlist yet."));
  },

  /** Slots & utilization: per-location slot settings, fill/status metrics, waitlist price proposals, price history. */
  async slots(panel, reload, state) {
    const c = getClient();
    const [util, cfgs, props, cat, countries, regions, cities, campuses] = await Promise.all([
      api("utilization"), api("list_slot_configs"), api("list_price_proposals"), api("list_catalog"),
      query(c.from("countries").select("code,name").order("name")), query(c.from("regions").select("id,name").order("name")),
      query(c.from("cities").select("id,name").order("name")), query(c.from("campuses").select("id,name,short_name").order("name")),
    ]);
    const cfg = Object.fromEntries(cat.config.map((row) => [row.key, row.value]));
    const cv = (k, d) => cfg[k] ?? d;
    const num = (value, attrs = {}) => el("input", { type: "number", value: String(value), ...attrs });
    const under = num(cv("slot_underfilled_pct", 50), { min: "1", max: "99" });
    const sold = num(cv("slot_soldout_pct", 85), { min: "2", max: "100" });
    const hold = num(cv("waitlist_hold_hours", 24), { min: "1", max: "168" });
    const stepOn = el("input", { type: "checkbox", checked: cv("ad_auto_price_step_enabled", false) || null });
    const step = num(cv("ad_auto_price_step_pct", 20), { min: "0", max: "30" });
    const saveSet = button("Save settings", async () => {
      await api("set_config", { key: "slot_underfilled_pct", value: Number(under.value) });
      await api("set_config", { key: "slot_soldout_pct", value: Number(sold.value) });
      await api("set_config", { key: "waitlist_hold_hours", value: Number(hold.value) });
      await api("set_config", { key: "ad_auto_price_step_pct", value: Number(step.value) });
      await api("set_config", { key: "ad_auto_price_step_enabled", value: stepOn.checked });
      toast("Saved.", "success");
      reload();
    });
    const badge = (st) => el("span", { class: `badge ${st === "sold_out" ? "badge--warn" : ""}` },
      { sold_out: "Sold out", healthy: "Healthy", underfilled: "Underfilled", no_data: "Not enough data" }[st] ?? st);
    const pct = (n) => (n == null ? "—" : `${n}%`);

    // location picker for the slot editor
    const locs = [["global:*", "Everywhere"], ...countries.map((x) => [`country:${x.code}`, `Country: ${x.name}`]),
      ...regions.map((x) => [`region:${x.id}`, `Region: ${x.name}`]), ...cities.map((x) => [`city:${x.id}`, `City: ${x.name}`]),
      ...campuses.map((x) => [`campus:${x.id}`, `Campus: ${x.short_name ?? x.name}`])];
    // One editable row per location (every location that exists, so new ones appear on their own), one Save for all.
    const dflt = { slots: cfgs.default_slots, top_slots: 0, top_multiplier: 1.5, standard_multiplier: 1, rotation_mode: "equal_share" };
    const byKey = new Map(cfgs.rows.map((x) => [x.key, x]));
    const slotRows = [...locs.map(([key, label]) => ({ key, label: byKey.get(key)?.label ?? label })),
      ...cfgs.rows.filter((x) => !locs.some(([k]) => k === x.key)).map((x) => ({ key: x.key, label: x.label }))]
      .map((r) => {
        const cfg = byKey.get(r.key)?.cfg ?? dflt;
        const f = {
          slots: num(cfg.slots, { min: "1", max: "10" }), top: num(cfg.top_slots, { min: "0", max: "10" }),
          topM: num(cfg.top_multiplier, { min: "1", max: "5", step: "0.1" }), stdM: num(cfg.standard_multiplier, { min: "0.5", max: "5", step: "0.1" }),
          rot: el("select", {}, el("option", { value: "equal_share" }, "Equal share (rotation)"), el("option", { value: "fixed_position" }, "Fixed position")),
        };
        f.rot.value = cfg.rotation_mode;
        const read = () => ({ slots: Number(f.slots.value), top_slots: Number(f.top.value), top_multiplier: Number(f.topM.value),
          standard_multiplier: Number(f.stdM.value), rotation_mode: f.rot.value });
        return { ...r, f, read, orig: JSON.stringify(read()), peak: byKey.get(r.key)?.in_use_peak_30d ?? 0 };
      });
    const saveSlots = button("Save all", async () => {
      const changed = slotRows.filter((r) => JSON.stringify(r.read()) !== r.orig);
      if (!changed.length) return toast("No changes.", "success");
      const failed = []; let blocked = false;
      for (const r of changed) {
        try { const res = await api("set_slot_config", { key: r.key, ...r.read() }); blocked ||= !!res.blocks_new_sales; r.orig = JSON.stringify(r.read()); }
        catch (e) { failed.push(`${r.label}: ${e?.message ?? "failed"}`); }
      }
      if (failed.length) toast(`Saved ${changed.length - failed.length}, failed ${failed.length}. ${failed.join("; ")}`, "error", 9000);
      else toast(blocked ? "Saved. Running campaigns are untouched; new sales are blocked where a location is full." : "Saved.", "success", 7000);
      reload();
    });

    // price history for one package
    const histBox = el("div", {});
    const histSel = el("select", { "aria-label": "Package" }, ...cat.ad_products.filter((x) => x.placement === "featured").map((x) => el("option", { value: x.id }, x.name)));
    const showHist = async () => {
      const rows = await api("price_history", { id: histSel.value });
      histBox.replaceChildren(table([
        { label: "When", render: (r) => formatDate(r.changed_at) },
        { label: "Base fee", render: (r) => (r.old_base == null || r.new_base == null || r.old_base === r.new_base) ? "unchanged" : `${formatRupiah(r.old_base)} → ${formatRupiah(r.new_base)}` },
        { label: "Fill 30d before", render: (r) => pct(r.fill_before_30d) },
        { label: "Fill 30d after", render: (r) => pct(r.fill_after_30d) },
      ], rows, "No price changes yet."));
    };
    histSel.addEventListener("change", showHist);

    panel.replaceChildren(
      el("p", { class: "small muted" }, "Recommendations only: nothing here changes a price or a slot by itself. Fill rate = sold slot-days ÷ available slot-days at the current slot count. Reducing slots never ends a running campaign; it only blocks new sales."),
      el("h2", {}, "Utilization"),
      table([
        { label: "Location", key: "label" },
        { label: "Slots", key: "slots" },
        { label: "Fill 7d", render: (r) => pct(r.fill_7) },
        { label: "Fill 30d", render: (r) => pct(r.fill_30) },
        { label: "Fill 90d", render: (r) => pct(r.fill_90) },
        { label: "Avg days to sell out", render: (r) => (r.avg_days_to_sell_out == null ? "—" : r.avg_days_to_sell_out) },
        { label: "Waitlist", key: "waitlist" },
        { label: "Status", render: (r) => badge(r.status) },
        { label: "Recommendation", render: (r) => r.recommendation ?? "" },
      ], util.rows, util.enough_data ? "No featured locations yet. New platform: launch pricing applies." : "Not enough data yet (14 days of featured sales are needed)."),
      el("h2", {}, "Settings"),
      el("div", { class: "form-grid" },
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Underfilled below (% fill, 30 days)"), under),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Sold out above (% fill, 30 days)"), sold),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Waitlist hold (hours)"), hold),
        el("label", { class: "check" }, stepOn, el("span", {}, "Suggest a price step for locations that sold out (you approve each one; never automatic)")),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Price step % (max 30)"), step), saveSet),
      el("h2", {}, "Slots per location"),
      table([
        { label: "Location", key: "label" },
        { label: "Slots (1–10)", render: (r) => r.f.slots },
        { label: "Top slots", render: (r) => r.f.top },
        { label: "Top ×", render: (r) => r.f.topM },
        { label: "Standard ×", render: (r) => r.f.stdM },
        { label: "Rotation", render: (r) => r.f.rot },
        { label: "Running now (peak 30d)", render: (r) => String(r.peak) },
      ], slotRows, `All locations use the default of ${cfgs.default_slots} slots until you change one.`),
      actions(saveSlots),
      el("h2", {}, "Price proposals"),
      actions(button("Check for proposals now", async () => {
        const out = await api("generate_price_proposals");
        toast(`${out.created} new proposal(s).`, "success");
        reload();
      })),
      table([
        { label: "Package", key: "product_name" },
        { label: "Change", render: (r) => `${formatRupiah(r.old_base)} → ${formatRupiah(r.new_base)} (+${r.step_pct}%)` },
        { label: "Why", key: "reason" },
        { label: "Status", key: "status" },
        { label: "", render: (r) => (r.status !== "pending" ? "" : actions(
          button("Approve", async () => {
            const ok = await openDialog({ title: "Apply this price?", body: el("p", {}, "It applies to NEW submissions only. Existing campaigns and orders keep the price they were sold at."), okLabel: "Approve" });
            if (!ok) return;
            await api("decide_price_proposal", { id: r.id, approve: true });
            toast("Price updated for new quotes.", "success");
            reload();
          }),
          button("Reject", async () => { await api("decide_price_proposal", { id: r.id, approve: false }); reload(); }, "btn btn--small btn--danger"))) },
      ], props, "No proposals."),
      el("h2", {}, "Price history"),
      actions(el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Package"), histSel)),
      histBox);
    fill(locs[0][0]);
    if (histSel.value) showHist();
  },

  /** Auctions: OFF by default. Global switch + kill switch, per-location flags with a readiness check, open/cancel, bid log. */
  async auctions(panel, reload) {
    const [o, cat] = await Promise.all([api("auction_overview"), api("list_catalog")]);
    const cfg = Object.fromEntries(cat.config.map((row) => [row.key, row.value]));
    const num = (k, d, attrs = {}) => el("input", { type: "number", value: String(cfg[k] ?? d), ...attrs });
    const hours = num("auction_hours", 72, { min: "1", max: "168" });
    const incr = num("auction_min_increment", 10000, { min: "1000", step: "1000" });
    const payH = num("auction_pay_hours", 24, { min: "1", max: "168" });
    const strikes = num("auction_max_strikes", 3, { min: "1", max: "10" });
    const fillPct = num("auction_min_fill_pct", 85, { min: "1", max: "100" });
    const fillWeeks = num("auction_fill_weeks", 4, { min: "1", max: "12" });
    const wlMult = num("auction_waitlist_multiple", 2, { min: "1", max: "20" });
    const saveCfg = button("Save auction settings", async () => {
      for (const [k, i] of [["auction_hours", hours], ["auction_min_increment", incr], ["auction_pay_hours", payH], ["auction_max_strikes", strikes],
        ["auction_min_fill_pct", fillPct], ["auction_fill_weeks", fillWeeks], ["auction_waitlist_multiple", wlMult]]) await api("set_config", { key: k, value: Number(i.value) });
      toast("Saved.", "success");
      reload();
    });

    const toggleGlobal = button(o.enabled ? "Turn auctions off" : "Turn auctions on…", async () => {
      if (o.enabled) { await api("auction_set_enabled", { enabled: false }); reload(); return; }
      const input = el("input", { name: "confirm", autocomplete: "off" });
      const data = await openDialog({ title: "Turn auctions on?", okLabel: "Turn on", danger: true,
        body: el("div", { class: "stack" }, el("p", {}, "Auctions only run on locations you enable below, and only for the next period of a sold-out slot. Type ENABLE AUCTIONS to continue."), input) });
      if (!data) return;
      await api("auction_set_enabled", { enabled: true, confirm: String(data.get("confirm") ?? "") });
      toast("Auctions are on.", "success");
      reload();
    }, o.enabled ? "btn btn--small" : "btn btn--small btn--primary");
    const kill = button("Kill switch", async () => {
      const reason = await promptReason("Kill switch: turn auctions off and cancel every open auction?", { required: true, danger: true, okLabel: "Cancel all auctions" });
      if (!reason) return;
      const res = await api("auction_kill_switch", { reason });
      toast(`Auctions off. ${res.canceled} open auction(s) canceled. Fixed prices continue.`, "success", 8000);
      reload();
    }, "btn btn--small btn--danger");

    const readiness = (r) => {
      const x = r.readiness;
      return el("span", { class: x.ready ? "" : "muted" }, `${x.weeks_ok}/${x.weeks_required} weeks above ${x.fill_threshold}% · waitlist ${x.waitlist}/${x.waitlist_needed}`);
    };
    const locationFlag = (r) => (r.enabled
      ? button("Disable", async () => { await api("auction_set_location", { key: r.key, enabled: false }); reload(); }, "btn btn--small")
      : button("Enable", async () => {
        let override = null;
        if (!r.readiness.ready) {
          override = await promptReason("This location is not ready for auctions. Enable anyway?", { required: true, okLabel: "Override and enable", danger: true });
          if (!override) return;
        }
        await api("auction_set_location", { key: r.key, enabled: true, override_reason: override });
        reload();
      }, "btn btn--small"));

    const locSel = el("select", { "aria-label": "Location" }, ...o.locations.filter((l) => l.enabled).map((l) => el("option", { value: l.key }, l.label)));
    const prodSel = el("select", { "aria-label": "Package" });
    // The server only accepts a package whose reach matches the location (campus package for a campus, and so on).
    const fillProducts = () => {
      const level = String(locSel.value).split(":")[0];
      const ok = cat.ad_products.filter((x) => x.placement === "featured" && x.enabled && x.scope_level === level);
      prodSel.replaceChildren(...(ok.length ? ok : []).map((x) => el("option", { value: x.id }, x.name)));
    };
    locSel.addEventListener("change", fillProducts);
    fillProducts();
    const open = button("Start auction", async () => {
      if (!locSel.value) { toast("Enable auctions for a location first (table above).", "error"); return; }
      if (!prodSel.value) { toast("No enabled Featured package matches this location's reach.", "error"); return; }
      const res = await api("auction_open", { key: locSel.value, product_id: prodSel.value });
      toast(`Auction started. Reserve ${formatRupiah(res.reserve)}; slot starts ${res.period_start}.`, "success", 8000);
      reload();
    });

    const bidLog = async (a) => {
      const d = await api("auction_bids", { id: a.id });
      const rows = d.bids.map((b) => el("tr", {},
        el("td", {}, formatDate(b.created_at, true)), el("td", {}, b.email ?? b.bidder_id), el("td", {}, formatRupiah(b.amount)),
        el("td", {}, `${b.status}${b.buy_now ? " (buy now)" : ""}${b.cancel_reason ? `: ${b.cancel_reason}` : ""}`), el("td", {}, b.ip),
        el("td", {}, b.status === "valid" && a.status === "open" ? button("Cancel bid", async () => {
          const reason = await promptReason("Cancel this bid?", { required: true, danger: true, okLabel: "Cancel bid" });
          if (!reason) return;
          await api("auction_cancel_bid", { id: b.id, reason });
          toast("Bid canceled.", "success");
          reload();
        }, "btn btn--small btn--danger") : "")));
      await openDialog({ title: `Bid log · ${a.label}`, okLabel: "Close",
        body: el("div", { class: "stack" },
          d.flags.length ? el("p", { class: "notice" }, `Flags: ${d.flags.map((f) => `${f.kind} (${f.details.bidders?.length ?? 0} accounts on one network)`).join("; ")}`) : "",
          el("table", { class: "table" }, el("thead", {}, el("tr", {}, ...["Time", "Bidder", "Amount", "Status", "Network", ""].map((h) => el("th", {}, h)))), el("tbody", {}, ...rows)),
          d.offers.length ? el("p", { class: "small" }, `Offers: ${d.offers.map((x) => `${x.bidder} ${formatRupiah(x.amount)} (${x.status})`).join("; ")}`) : "") });
    };

    panel.replaceChildren(
      el("p", { class: o.enabled ? "notice" : "notice notice--warn" }, o.enabled ? "Auctions are ON globally." : "Auctions are OFF. Nothing here affects fixed-price sales while they are off."),
      actions(toggleGlobal, kill),
      el("p", { class: "small muted" }, "Rules: next period of a full slot only · reserve = current fixed price · buy now = 1.5× reserve · highest valid bid wins, earliest bid breaks ties · anti-sniping +5 min (max 6) · no money is taken at bid time (Midtrans has no authorization hold here): the winner gets a payment window, unpaid goes to the next bidder and earns a strike."),
      el("h2", {}, "Settings"),
      el("div", { class: "form-grid" },
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Auction length (hours)"), hours),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Minimum raise (Rp)"), incr),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Winner payment window (hours)"), payH),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Strikes before bidding is blocked"), strikes),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Readiness: fill above (%)"), fillPct),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Readiness: consecutive weeks"), fillWeeks),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Readiness: waitlist ≥ this × slots"), wlMult), saveCfg),
      el("h2", {}, "Auction readiness"),
      table([
        { label: "Location", key: "label" },
        { label: "Readiness", render: readiness },
        { label: "Ready", render: (r) => (r.readiness.ready ? "Yes" : "No") },
        { label: "Auctions", render: (r) => (r.enabled ? "On" : "Off") },
        { label: "", render: locationFlag },
      ], o.locations, "No featured locations yet."),
      el("h2", {}, "Start an auction"),
      actions(el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Location"), locSel),
        el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Package"), prodSel), open),
      el("h2", {}, "Auctions"),
      table([
        { label: "Location", key: "label" },
        { label: "Status", render: (a) => ({ open: "Open for bids", awaiting_payment: "Winner must pay", settled: "Sold", no_winner: "No winner", canceled: "Canceled" }[a.status] ?? humanize(a.status)) },
        { label: "Slot starts", key: "period_start" },
        { label: "Reserve", render: (a) => formatRupiah(a.reserve) },
        { label: "High bid", render: (a) => (a.high ? formatRupiah(a.high) : "—") },
        { label: "Bids", key: "bids" },
        { label: "Ends", render: (a) => `${formatDate(a.ends_at, true)}${a.extensions ? ` (+${a.extensions})` : ""}` },
        { label: "Flags", key: "flags" },
        { label: "", render: (a) => actions(button("Bid log", () => bidLog(a), "btn btn--small"),
          ["open", "awaiting_payment"].includes(a.status) ? button("Cancel", async () => {
            const reason = await promptReason("Cancel this auction?", { required: true, danger: true, okLabel: "Cancel auction" });
            if (!reason) return;
            await api("auction_cancel", { id: a.id, reason });
            reload();
          }, "btn btn--small btn--danger") : "") },
      ], o.auctions, "No auctions yet."),
      el("h2", {}, "Accounts with unpaid-win strikes"),
      table([
        { label: "Account", render: (x) => x.email ?? x.user_id },
        { label: "Strikes", key: "strikes" },
        { label: "", render: (x) => button("Clear", async () => {
          const reason = await promptReason("Clear this account's strikes?", { required: true, okLabel: "Clear" });
          if (!reason) return;
          await api("auction_clear_strikes", { user_id: x.user_id, reason });
          reload();
        }, "btn btn--small") },
      ], o.strikes, "No strikes."));
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

// Per-tab help shown above each panel: what the tab is for, and what to do in it.
// `sub` describes each section heading (h2) inside the tab; it is added only where the panel has no text of its own.
const GUIDE = {
  overview: { what: "Your starting page: what needs doing now, and how the site is doing.",
    steps: ["Start with “Needs your attention”. Each line has a button that opens the right tab.", "When it says “All clear”, nothing is waiting for you.", "Last 7 days and Whole site are just for reading. Nothing on them changes anything.", "Use Common tasks for the jobs you will do most. The left menu has everything else."],
    sub: { "Needs your attention": "Work that only you can do. Clear these first.", "Last 7 days": "Recent money and activity.", "Whole site": "Totals since the site started.", "Common tasks": "Shortcuts to the tabs you will use most.", "Housekeeping": "Optional cleanup." } },
  moderation: { what: "Every sticky note on the wall. Approve, reject or remove notes.",
    steps: ["Status filter starts on Pending moderation: notes waiting for a decision (only filled when Note moderation is set to hold for approval).", "Read the note and open its media links. Approve to publish, Reject to refuse it.", "Use Remove on a published note that breaks the rules. Restore brings a removed note back.", "A reason is optional but write one: it goes into the Audit log."] },
  reports: { what: "Notes that visitors reported. Only open reports are listed.",
    steps: ["Read the reason, details and the note text.", "Note breaks the rules: Remove note (also closes the report).", "Report is valid but needs no removal: Resolve. Report is wrong or spam: Dismiss."] },
  users: { what: "All accounts. Find a person, suspend them, or delete the account.",
    steps: ["Search by name or email.", "Suspend blocks the account and its sign-in. A reason is required. Unsuspend reverses it.", "Admin accounts have no buttons here. Delete account is permanent: use it only when truly needed."] },
  announcements: { what: "Site news shown to visitors. Pinned news stays on top of the wall.",
    steps: ["Fill Title and Text, tick “Pin on the wall” if needed, then Save draft. Use Preview to check it first.", "A draft is not visible. Press Publish in the list to make it live.", "Unpublish moves it back to draft. Archive hides it for good. Edit loads it back into the form."],
    sub: { "Write news": "Form for a new item, or for the item you pressed Edit on.", "Recent news": "All news items and their status. Publish, unpublish, archive or edit here." } },
  orders: { what: "Every payment: sticky posts, donations and advertising orders.",
    steps: ["Filter by kind and status. Tick “needs review” to see only orders the system flagged.", "Details shows the full record. Reconcile with Midtrans asks the payment provider for the true status: use it when a customer says they paid but the order did not update.", "Waive payment publishes an unpaid sticky post for free (reason required, recorded as waived).", "Clear review flag after you checked a flagged order.", "Customer sends a receipt ID? Paste it in the lookup box at the top to find that note."] },
  revenue: { what: "Money report for a date range, in Jakarta time.",
    steps: ["Pick From and To. “To” is not included, so use the next day to include a whole last day.", "Press Run report.", "Hover a figure name or read Definitions below to see how it is counted. Net collected is money in minus refunds."] },
  promos: { what: "Discount codes for sticky posts.",
    steps: ["Enter a code (4–24 letters/digits), type (% or Rp), and value. 100% makes the post free.", "Set Max uses, Uses per person and an expiry date if wanted. Press Create code.", "Disable a code to stop it. Enable brings it back. Codes cannot be deleted from here.", "The discount only cuts the minimum price. Anything paid above it is a tip."] },
  referrals: { what: "Who invited whom, and the credits earned.",
    steps: ["Check Status and reject reason to see if a referral counted.", "Credits are used to pay for posts. Revoke referral credits takes back unused credits from fraud or abuse (reason required). Credits already spent stay spent.", "“Credit (old)” and “Revoke credit” are for the old credit system."] },
  campaigns: { what: "Advertiser campaigns. Review, approve and control every ad.",
    steps: ["Status filter starts on Pending approval. Read the ad, check the creative image and the link.", "Approve a good ad. The advertiser then has a set number of days to pay (see Prices & settings). Reject a bad one and give a reason.", "Pending review + paid: approve to schedule it.", "Pause stops a running ad. Resume restarts it. Cancel ends it for good.", "Stats column is views / clicks."] },
  adinsights: { what: "Performance per ad spot and location, plus a price suggestion.",
    steps: ["Choose the window (7 or 30 days).", "Set Target price per 1,000 views, then Save.", "Read Views, Clicks, CTR and Fill rate. A suggested price shows only after 14 days of data.", "Waitlist shows advertisers waiting for a full location: demand to raise prices or add slots.", "Nothing here changes prices by itself."],
    sub: { "Waitlist": "Advertisers waiting for a spot, by location and days wanted." } },
  slots: { what: "How many ad slots each location has, how full they are, and price proposals.",
    steps: ["Read Utilization: Fill 7d/30d/90d and status show which locations are underfilled or sold out.", "Set the thresholds and waitlist hold in Settings.", "Change a location’s slots, top slots, price multipliers and rotation in Slots per location. Fewer slots never ends a running ad.", "Review Price proposals (a sold-out location may suggest a price rise). Approve or reject each one: nothing is automatic.", "Price history shows past changes and fill before and after."],
    sub: { "Utilization": "How full each location is over 7, 30 and 90 days, with a recommendation.", "Settings": "Where “underfilled” and “sold out” start, how long a waitlist spot is held, and the optional price-step suggestion.", "Slots per location": "Slot count, top slots and price multipliers per location. Edit any row, then press Save all.", "Price proposals": "Suggested price rises for sold-out locations. Approve or reject each.", "Price history": "Past base-fee changes for a Featured package, with fill before and after." } },
  auctions: { what: "Auctions for the next period of a sold-out Featured slot. Off by default.",
    steps: ["Set the rules in Settings, then Save auction settings.", "Check Auction readiness. A location is ready when it was full for enough weeks and has enough waitlist.", "Turn auctions on (type ENABLE AUCTIONS), then Enable them per location. Enabling an unready location needs a reason.", "Pick location and package, then Start auction.", "Watch Auctions: Bid log shows every bid, Cancel stops one auction.", "Kill switch turns auctions off and cancels all open auctions. Fixed prices keep working.", "Clear strikes for a bidder who won and did not pay, when appropriate."],
    sub: { "Settings": "Length, minimum raise, payment time, strike limit and readiness rules.", "Auction readiness": "Which locations may run auctions, and whether they meet the rules.", "Start an auction": "Open a new auction. Only locations with auctions enabled appear.", "Auctions": "All auctions with status, bids and end time.", "Accounts with unpaid-win strikes": "Bidders who won and did not pay. At the strike limit they cannot bid." } },
  catalog: { what: "Everything that sets what customers pay, plus general site settings.",
    steps: ["Decorations: click one to change its name, price or visibility.", "Payment methods: set limits from your Midtrans agreement.", "Advertising packages: change base fee, extra-location %, and enable or disable packages. Old orders keep their old price.", "Site settings: change values, then press the save button at the bottom."],
    sub: { "Decorations": "Stickers and decorations people add to notes. Click one to edit.", "Site settings": "Moderation mode, donation limits, order expiry, contact details, ad payment days, launch pricing and allowed campaign lengths." } },
  locations: { what: "The places ads and notes can target: countries, regions, cities and campuses.",
    steps: ["Add from the top down: country, then region, then city, then campus.", "Each form picks its parent, then a name. Press Add.", "Disable hides a place from pickers. Campaigns that targeted it stop matching it."],
    sub: { "Countries": "Top level. Needs a 2-letter ISO code.", "Regions": "Provinces or states inside a country.", "Cities": "Cities inside a region.", "Campuses": "Individual campuses inside a city." } },
  audit: { what: "Record of every admin action: who, what, on which item, and why.",
    steps: ["Use it to check who changed something.", "Newest first, last 200 entries.", "The Reason column is what the admin typed, so ask admins to write real reasons."] },
  security: { what: "Owner only. Permanent record of deletions made by the Owner.",
    steps: ["Read-only. Nothing here can be deleted.", "Use it to confirm what was permanently deleted, when, and which item."] },
};

/** Adds the guide above a freshly built panel and a one-line description under each known section heading. */
function addGuide(tab, panel, state) {
  const g = GUIDE[tab];
  if (!g) return;
  for (const h of panel.querySelectorAll("h2")) {
    const key = Object.keys(g.sub ?? {}).find((k) => h.textContent.startsWith(k));
    const next = h.nextElementSibling;
    if (key && !(next?.matches("p.small.muted"))) h.after(el("p", { class: "small muted" }, g.sub[key]));
  }
  const d = el("details", { class: "notice admin-guide" }, el("summary", {}, "What this does & how to use it"),
    el("p", {}, g.what), el("ol", {}, ...g.steps.map((s) => el("li", {}, s))));
  d.open = state.guideOpen !== false;
  d.addEventListener("toggle", () => { state.guideOpen = d.open; });
  panel.prepend(d);
}

export async function mount(view, { signal }) {
  const user = currentUser();
  if (!user || !(await isAdmin())) {
    const frag = cloneTemplate("tpl-signin-required");
    const r = refs(frag);
    r.title.textContent = "Administrators only";
    r.message.textContent = user ? "Your account does not have administrator access." : "Sign in with an administrator account.";
    view.append(translate(frag));
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
    r.tabs.querySelector(`[data-tab="${state.tab}"]`)?.closest("details")?.setAttribute("open", "");
    r.panel.replaceChildren(el("p", { class: "muted" }, "Loading…"));
    try {
      const panel = el("div");
      await panels[state.tab](panel, show, state);
      addGuide(state.tab, panel, state);
      translate(panel);
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
