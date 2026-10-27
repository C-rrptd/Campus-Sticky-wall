// Administrator console. Purely a UI over the admin-api Edge Function: the
// visible menu grants nothing, and every action is re-authorized server-side
// (Edge Function + SQL require_admin()) and written to the audit log.

import { cloneTemplate } from "./component-loader.js";
import { currentUser, isAdmin, isOwner } from "./auth.js";
import { creativeUrl, getClient, invoke, mediaUrl, query } from "./supabase-client.js";
import { busy, el, errorMessage, formatDate, formatRupiah, openDialog, promptReason, refs, toast } from "./utils.js";
import { adPrice, parseRupiah } from "./validation.js";
import { t, translate } from "./i18n.js";

async function api(action, params = {}) {
  const res = await invoke("admin-api", { action, params });
  return res.data;
}

function table(columns, rows, empty = "Nothing to show yet.") {
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
/** Plain-language names for the codes the server uses (statuses, order types). Unknown codes fall back to humanize(). */
const WORDS = {
  pending_moderation: "Waiting for your review", published: "Live on the wall", removed: "Taken down by an admin", rejected: "Rejected", withdrawn: "Taken down by the person who posted it",
  pending_approval: "Waiting for your approval", approved: "Approved, waiting for payment", awaiting_payment: "Waiting for payment", pending_review: "Paid, waiting for your check",
  scheduled: "Paid, starts on its start date", active: "Running now", paused: "Paused", expired: "Finished or timed out", canceled: "Cancelled",
  draft: "Draft (nobody sees it)", archived: "Archived (hidden)",
  challenge: "Midtrans wants a manual check", paid: "Paid", completed_free: "Done with a free credit", payment_waived: "Payment skipped by an admin", failed: "Payment failed",
  partially_refunded: "Part of the money was returned", refunded: "All money returned", reversed: "Payment was reversed (money taken back)",
  publication: "Sticky note", donation: "Donation", advertising: "Ad",
  open: "Open", resolved: "Handled", dismissed: "Ignored", valid: "Counts", pending: "Waiting for a decision",
  none: "None", available: "Available", used: "Used", revoked: "Taken back", qualified: "Counted", disqualified: "Did not count",
  featured: "Featured (pinned on top)", random: "Random (rotating)",
};
const PAST = { approve: "approved", reject: "rejected", remove: "removed", restore: "restored", pause: "paused", resume: "resumed", cancel: "cancelled" };
const word = (v) => WORDS[v] ?? humanize(v);
const yesNo = (v) => (v ? "Yes" : "No");
const shortId = (id) => (id ? el("code", { title: String(id) }, `${String(id).slice(0, 8)}…`) : "");
const details = (d) => (d && typeof d === "object"
  ? Object.entries(d).map(([k, v]) => `${humanize(k)}: ${typeof v === "object" ? JSON.stringify(v) : v}`).join(" · ")
  : String(d ?? ""));

/** "launch −50% (list Rp…)", "🔒 locked rate Rp…", "founding #2" next to a price. Real fields only; nothing is invented. */
function rateText(r, base) {
  const bits = [];
  if (r.list_price && String(r.list_price) !== String(r.price) && !r.price_locked) bits.push(`launch discount −${r.launch_discount_pct ?? 0}% (normal price ${formatRupiah(r.list_price)})`);
  if (r.price_locked) bits.push(`🔒 price locked at base fee ${formatRupiah(r.price_base_used ?? r.locked_base_fee)} (normal price ${formatRupiah(r.list_price)})`);
  if (r.founding_rank) bits.push(`founding advertiser #${r.founding_rank}`);
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
      el("p", {}, `Permanently delete this ${what}? This cannot be undone. Payment and credit records are kept.`),
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
  return button("Delete account", async () => {
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
  const input = el("input", { type: "search", placeholder: "Paste a receipt code or receipt link to find a note", autocomplete: "off" });
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
  "Image or text is unclear or poor quality", "Missing or invalid business information"];
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

// Plain names and meanings for the money report. Keys are the field names the server sends.
const REVENUE = {
  publication_revenue: ["Money from sticky notes", "What people paid to publish notes, after free-credit discounts, for orders paid in this period. Orders that were refunded later are still counted here."],
  decoration_revenue: ["Money from decorations", "What people paid for stickers and decorations on their notes."],
  donations: ["Donations", "Money people donated."],
  advertising_revenue: ["Money from ads", "What advertisers paid for ads."],
  gross_payment_volume: ["All money received (before refunds)", "The total of every order paid through Midtrans in this period."],
  refunds_and_reversals: ["Money given back", "Refunds and payments that were reversed (chargebacks)."],
  net_collected: ["Money kept (after refunds)", "All money received minus money given back. This is NOT profit: Midtrans fees and your costs are not subtracted."],
  credit_discounts_given: ["Value of free credits used", "How much price was taken off orders because people used free credits."],
  average_order_value: ["Average amount per order", "Total money received divided by the number of paid orders."],
  processing_fees: ["Midtrans fees", "Midtrans does not send us this number. Check your Midtrans settlement reports."],
  paid_orders: ["Number of paid orders", "Orders that were paid in this period."],
  free_publications: ["Notes posted for free", "Notes that went live without any payment (free post or free credit)."],
  checkout_sessions: ["Times someone started checkout", "How many times someone opened the payment step."],
  checkout_completion_rate: ["% of checkouts that were paid", "Of the checkouts that ended in this period, the share that ended with payment."],
  decoration_attachment_rate: ["% of notes with a paid decoration", "Of the notes that went live, the share that had at least one paid decoration."],
  credits_issued: ["Free credits given out", "How many free credits people earned."],
  credits_redeemed: ["Free credits used", "How many free credits were spent on orders."],
  campaign_impressions: ["Times ads were shown", "An approximate count sent by visitors’ browsers."],
  campaign_clicks: ["Ad clicks", "How many times people clicked an ad."],
  campaign_renewals: ["Ads renewed", "Orders from advertisers who had already paid for an ad before."],
};

// Plain names for the actions saved in the admin activity log. Unknown codes fall back to humanize().
const ACTIONS = {
  "note.approve": "Approved a note", "note.reject": "Rejected a note", "note.remove": "Took a note down", "note.restore": "Put a note back",
  "campaign.approve": "Approved an ad", "campaign.reject": "Rejected an ad", "campaign.pause": "Paused an ad", "campaign.resume": "Resumed an ad", "campaign.cancel": "Cancelled an ad",
  "report.resolve": "Marked a report as handled", "report.dismiss": "Ignored a report",
  "user.suspend": "Blocked an account", "user.unsuspend": "Unblocked an account",
  "admin.delete_user": "Deleted an account", "admin.delete_note_by_receipt": "Deleted a note found by its receipt", "owner.delete": "Owner permanently deleted something",
  "order.waive": "Skipped payment for an order", "order.review_cleared": "Marked a payment as checked",
  "announcement.upsert": "Saved a news item", "announcement.publish": "Published a news item", "announcement.draft": "Hid a news item", "announcement.archive": "Archived a news item",
  "promo.create": "Created a promo code", "promo.set_enabled": "Turned a promo code on or off",
  "config.set": "Changed a site setting", "decoration.upsert": "Changed a decoration", "payment_method.upsert": "Changed a payment method",
  "ad_product.upsert": "Changed an ad package", "ad_product.change": "Changed an ad package price", "ad_slots.change": "Changed the ad slots of a location",
  "price_proposal.decide": "Decided on a suggested price change", "location.upsert": "Added or changed a location",
  "auction.global": "Turned auctions on or off", "auction.location": "Turned auctions on or off for a location", "auction.open": "Started an auction",
  "auction.cancel": "Cancelled an auction", "auction.cancel_bid": "Cancelled a bid", "auction.clear_strikes": "Removed strikes", "auction.kill_switch": "Used the emergency stop for auctions",
  "credit.revoke": "Took back a credit", "referral.credits_issued": "Gave referral credits", "referral.credits_revoked": "Took back referral credits",
};
const TARGETS = { note: "Note", campaign: "Ad", report: "Report", user: "Account", order: "Order", announcement: "News item", promo: "Promo code", config: "Setting",
  decoration: "Decoration", payment_method: "Payment method", ad_product: "Ad package", ad_location: "Ad location", ad_auction: "Auction", ad_bid: "Bid", credit: "Credit", referral: "Referral" };
const actionName = (a) => ACTIONS[a] ?? humanize(a);
const targetName = (a) => TARGETS[a] ?? humanize(a);

const panels = {
  async overview(panel, reload) {
    const jakarta = (offsetDays) => new Date(Date.now() + 7 * 3600e3 + offsetDays * 864e5).toISOString().slice(0, 10);
    const [o, d, rev] = await Promise.all([api("overview"), api("leaderboard_diagnostics"),
      api("revenue_report", { from: `${jakarta(-6)}T00:00:00+07:00`, to: `${jakarta(1)}T00:00:00+07:00` })]);
    panel.replaceChildren(
      el("dl", { class: "stats stats--grid" },
        ...Object.entries({
          "Money kept in the last 7 days (after refunds)": formatRupiah(rev.net_collected), "Paid orders in the last 7 days": rev.paid_orders,
          "Notes posted today": o.notes_today, "Notes posted in the last 7 days": o.notes_7d,
          "Ads waiting for your approval": o.campaigns_pending_review,
          "Reports nobody has handled yet": o.open_reports, "Notes waiting for your review": o.notes_pending_moderation,
          "Payments that need checking": o.orders_needing_review,
          "Notes live on the wall": o.published_notes, "Accounts": o.users, "Invites that counted": d.qualified_referrals,
          "Donors who agreed to be shown": d.opted_in_donors, "Donations received": d.successful_donations,
        }).map(([k, v]) => el("div", {}, el("dt", {}, k), el("dd", {}, String(v))))),
      actions(button("Close old unpaid orders", async () => {
        const res = await api("expire_stale_orders");
        toast(`${res.expired} unpaid order(s) closed.`, "success");
        reload();
      })),
    );
  },

  async moderation(panel, reload, state) {
    state.noteStatus ??= "pending_moderation";
    const filter = el("select", {}, ...["pending_moderation", "published", "removed", "rejected", "withdrawn"].map((s) =>
      el("option", { value: s, selected: s === state.noteStatus || null }, word(s))));
    filter.addEventListener("change", () => { state.noteStatus = filter.value; reload(); });
    const rows = await api("list_notes", { status: state.noteStatus, limit: 100 });
    const act = (row, action, danger) => button(humanize(action), async () => {
      const reason = await promptReason(`${humanize(action)} this note?`, { danger, okLabel: humanize(action) });
      if (reason === null) return;
      await api("moderate_note", { note_id: row.id, action, reason: reason || null });
      toast(`Note ${PAST[action] ?? action}.`, "success");
      reload();
    }, danger ? "btn btn--small btn--danger" : "btn btn--small");
    panel.replaceChildren(el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Show notes that are"), filter),
      table([
        { label: "Note", render: (r) => el("span", { class: "clamp" }, r.body, ...(r.media ?? []).map((m, i) =>
          el("a", { href: mediaUrl(m.path), target: "_blank", rel: "noopener noreferrer" }, ` [${m.kind} ${i + 1}]`))) },
        { label: "Author", key: "author_name" },
        { label: "Amount paid", render: (r) => formatRupiah(r.amount) },
        { label: "Votes", key: "vote_count" },
        { label: "Times reported", key: "report_count" },
        { label: "Posted on", render: (r) => formatDate(r.created_at, true) },
        { label: "What you can do", render: (r) => actions(
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
      { label: "Why it was reported", key: "reason" },
      { label: "What the reporter wrote", key: "details" },
      { label: "The note", render: (r) => el("span", { class: "clamp" }, r.note_body) },
      { label: "The note is now", render: (r) => word(r.note_status) },
      { label: "Times reported", key: "report_count" },
      { label: "What you can do", render: (r) => actions(
        r.note_status === "published" && button("Remove note", async () => {
          const reason = await promptReason("Remove this note?", { danger: true, okLabel: "Remove" });
          if (reason === null) return;
          await api("moderate_note", { note_id: r.note_id, action: "remove", reason: reason || `report: ${r.reason}` });
          await api("resolve_report", { report_id: r.id, status: "resolved", reason: "note removed" });
          reload();
        }, "btn btn--small btn--danger"),
        button("Mark as handled", async () => { await api("resolve_report", { report_id: r.id, status: "resolved" }); reload(); }),
        button("Ignore (report is wrong)", async () => { await api("resolve_report", { report_id: r.id, status: "dismissed" }); reload(); }),
        ownerDelete(state, "report", r.id, "report", reload)) },
    ], rows, "Nobody has reported anything. Nice."));
  },

  async users(panel, reload, state) {
    const search = el("input", { type: "search", placeholder: "Search by name or email", value: state.userSearch ?? "" });
    const go = button("Search", async () => { state.userSearch = search.value.trim() || null; reload(); });
    const rows = await api("list_users", { search: state.userSearch ?? null, limit: 100 });
    panel.replaceChildren(actions(search, go), table([
      { label: "Name", key: "display_name" },
      { label: "Email", key: "email" },
      { label: "Email confirmed?", render: (r) => yesNo(r.email_verified) },
      { label: "Notes posted", key: "published_notes" },
      { label: "Is an admin?", render: (r) => (r.is_admin ? "Yes" : "No") },
      { label: "Account is", render: (r) => (r.suspended_at ? `Blocked (${r.suspension_reason ?? ""})` : "Fine") },
      { label: "What you can do", render: (r) => r.is_admin ? "" : actions(button(r.suspended_at ? "Unblock account" : "Block account", async () => {
        const reason = await promptReason(r.suspended_at ? "Unblock this account? The person can sign in again." : "Block this account? The person can no longer sign in.", { required: !r.suspended_at, danger: !r.suspended_at });
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
    const kind = el("select", {}, ...["", "publication", "donation", "advertising"].map((k) => el("option", { value: k, selected: k === f.kind || null }, k ? word(k) : "All types of payment")));
    const status = el("select", {}, ...["", "awaiting_payment", "challenge", "paid", "completed_free", "payment_waived", "failed", "canceled", "expired", "partially_refunded", "refunded", "reversed"]
      .map((s) => el("option", { value: s, selected: s === f.status || null }, s ? word(s) : "All payment statuses")));
    const review = el("input", { type: "checkbox", checked: f.review_only || null });
    const apply = button("Filter", async () => { Object.assign(f, { kind: kind.value, status: status.value, review_only: review.checked }); reload(); });
    const rows = await api("list_orders", { kind: f.kind || null, status: f.status || null, review_only: f.review_only, limit: 100 });
    panel.replaceChildren(receiptLookup(reload), actions(kind, status, el("label", { class: "check" }, review, " Only payments that need checking"), apply), table([
      { label: "Order code", key: "order_ref" },
      { label: "What was bought", render: (r) => word(r.kind) },
      { label: "Payment status", render: (r) => word(r.status) },
      { label: "Total price", render: (r) => formatRupiah(r.total_amount) },
      { label: "Price details (ads only)", render: (r) => (r.kind === "advertising" ? rateText({ ...r, price: r.total_amount, price_base_used: r.locked_base_fee }, "") : "") },
      { label: "Money returned", render: (r) => formatRupiah(r.refunded_amount) },
      { label: "Needs checking?", render: (r) => (r.review_required ? `⚠ ${r.review_reason ?? "Please check this payment"}` : "No") },
      { label: "Ordered on", render: (r) => formatDate(r.created_at, true) },
      { label: "What you can do", render: (r) => actions(
        button("Details", async () => {
          const d = await api("order_detail", { order_ref: r.order_ref });
          await openDialog({ title: `Order ${r.order_ref}`, body: el("pre", { class: "code-block" }, JSON.stringify(d, null, 2)), okLabel: "Close" });
        }),
        ["awaiting_payment", "challenge", "paid", "partially_refunded"].includes(r.status) && button("Check with Midtrans", async () => {
          const res = await api("reconcile_order", { order_ref: r.order_ref });
          toast(`Midtrans says: ${res.result}`, "info");
          reload();
        }),
        r.kind === "publication" && r.status === "awaiting_payment" && button("Skip payment (post for free)", async () => {
          const reason = await promptReason("Let this sticky note go live without payment? It is recorded as “payment skipped”, not as paid.", { required: true, okLabel: "Skip payment" });
          if (reason === null) return;
          try { await api("waive_order", { order_ref: r.order_ref, reason }); toast("Payment skipped. The note is live.", "success"); } catch (err) { toast(errorMessage(err), "error"); }
          reload();
        }),
        r.review_required && button("Mark as checked", async () => {
          const reason = await promptReason("Mark this payment as checked? Write what you checked.", { required: true });
          if (reason === null) return;
          await api("clear_order_review", { order_ref: r.order_ref, reason });
          reload();
        })) },
    ], rows));
  },

  async campaigns(panel, reload, state) {
    state.campaignStatus ??= "pending_approval";
    const filter = el("select", {}, ...["pending_approval", "approved", "awaiting_payment", "pending_review", "scheduled", "active", "paused", "expired", "rejected", "canceled", ""]
      .map((s) => el("option", { value: s, selected: s === state.campaignStatus || null }, s ? word(s) : "All")));
    filter.addEventListener("change", () => { state.campaignStatus = filter.value; reload(); });
    const rows = await api("list_campaigns", { status: state.campaignStatus || null });
    const act = (row, action, danger) => button(humanize(action), async () => {
      const reason = await rejectionReason(action, row, danger);
      if (reason === null) return;
      await api("review_campaign", { campaign_id: row.id, action, reason: reason || null });
      toast(`Campaign ${PAST[action] ?? action}.`, "success");
      reload();
    }, danger ? "btn btn--small btn--danger" : "btn btn--small");
    panel.replaceChildren(el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Show ads that are"), filter), table([
      { label: "Ad", render: (r) => el("div", {}, el("strong", {}, r.title), el("br"), el("span", { class: "small clamp" }, r.description)) },
      { label: "Advertiser", render: (r) => `${r.advertiser_name} <${r.contact_email}>` },
      { label: "Ad image / link", render: (r) => {
        const u = r.creative_path ? creativeUrl(r.creative_path) : null;
        const img = u && el("a", { href: u, target: "_blank", rel: "noopener noreferrer" }, el("img", { src: u, alt: "", class: "admin-thumb" }));
        const link = r.destination_url && el("a", { href: r.destination_url, target: "_blank", rel: "noopener noreferrer" }, "Link ↗");
        return img || link ? el("div", { class: "stack" }, img, link) : "Text only (no image or link)";
      } },
      { label: "Package bought", render: (r) => rateText(r, `${r.placement === "featured" ? "Featured (pinned on top)" : "Random (rotating)"} · ${r.duration_days ?? "?"} days · ${formatRupiah(r.price)}`) },
      { label: "Where it shows", render: (r) => (r.targets ?? []).join(", ") },
      { label: "Payment", render: (r) => word(r.payment_status) },
      { label: "Where it is now", render: (r) => el("span", { class: `badge${r.status === "active" ? " badge--ok" : ["rejected", "canceled"].includes(r.status) ? " badge--bad" : r.status === "pending_approval" ? " badge--warn" : ""}` }, word(r.status)) },
      { label: "Runs from – to", render: (r) => (r.starts_at ? `${formatDate(r.starts_at)} – ${formatDate(r.ends_at)}` : `Wants to start on ${r.requested_start}`) },
      { label: "Times shown / clicks", render: (r) => `${r.impressions} / ${r.clicks}` },
      { label: "What you can do", render: (r) => actions(
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
      `How note pricing works: people choose their own price. The lowest allowed is ${formatRupiah(c.pricing_policy.min_publication_price)} and the highest is ${formatRupiah(c.config.find((x) => x.key === "max_publication_price")?.value ?? 0)}. One referral credit is worth ${formatRupiah(c.pricing_policy.referral_credit_value)}.`);

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
        el("label", { class: "check" }, enabled, el("span", {}, "Turned on (people can pick it)")));
      if (!(await openDialog({ title: d.name, body, okLabel: "Save" }))) return;
      const p = parseRupiah(price.value);
      if (!p.ok) { toast(p.error, "error"); return; }
      await api("upsert_decoration", { id: d.id, name: name.value.trim(), description: d.description, price: p.digits, enabled: enabled.checked, sort: d.sort_order });
      Object.assign(d, { name: name.value.trim(), price: p.digits, enabled: enabled.checked });
      paint();
      toast("Decoration saved. Orders that were already placed keep their old price.", "success");
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
      { label: "Payment method", render: (x) => `${x.m.label} (${x.m.midtrans_codes.join(", ")})` },
      { label: "Smallest total allowed (Rp, empty = no limit)", render: (x) => x.min },
      { label: "Largest total allowed (Rp, empty = no limit)", render: (x) => x.max },
      { label: "Turned on?", render: (x) => x.enabled },
      { label: "", render: (x) => button("Save", async () => {
        const min = x.min.value.trim() ? parseRupiah(x.min.value) : { ok: true, digits: null };
        const max = x.max.value.trim() ? parseRupiah(x.max.value) : { ok: true, digits: null };
        if (!min.ok || !max.ok) { toast("Limits must be whole rupiah numbers, or left empty.", "error"); return; }
        await api("upsert_payment_method", { code: x.m.code, label: x.m.label, midtrans_codes: x.m.midtrans_codes, min: min.digits, max: max.digits, enabled: x.enabled.checked, sort: x.m.sort_order });
        toast("Payment method saved.", "success");
      }) },
    ], pmRows);

    const cfgNow = Object.fromEntries(c.config.map((row) => [row.key, row.value]));
    const allowedDays = Array.isArray(cfgNow.ad_allowed_durations) ? cfgNow.ad_allowed_durations : [7, 30, 60, 90];
    const launchOn = cfgNow.launch_mode_enabled === true;
    const launchGlobal = Number(cfgNow.launch_discount_pct ?? 50);
    const FORMULA = "total price = first-location price + (number of extra locations × extra % × first-location price)";
    // Retired lengths (e.g. 14 days) stay in the database but are not listed here unless still enabled.
    const adRows = c.ad_products.filter((a) => allowedDays.includes(a.duration_days) || a.enabled).map((a) => {
      const price = amountInput("price", a.price_per_target);
      const global = a.scope_level === "global"; // always one location, so no extra-location %
      const pct = el("input", { type: "number", min: "0", max: "100", step: "1", value: String(a.extra_location_pct), disabled: global || null, class: "input--small", title: FORMULA, "aria-label": "Extra price for each added location (%)" });
      const launch = el("input", { type: "number", min: "0", max: "90", step: "1", value: a.launch_discount_pct ?? "", placeholder: `${launchGlobal}`, class: "input--small", "aria-label": "Launch discount for this package (%), empty = use the site-wide discount" });
      const days = el("select", { class: "input--small", "aria-label": "Duration in days" },
        ...[...new Set([...allowedDays, a.duration_days])].sort((x, y) => x - y).map((d) => el("option", { value: String(d), selected: d === a.duration_days || null }, String(d))));
      const example = el("span", { class: "small" });
      const paint = () => {
        const p = parseRupiah(price.value);
        const extra = global ? 0 : Number(pct.value);
        if (!p.ok || BigInt(p.digits) < 1n || !Number.isInteger(extra) || extra < 0 || extra > 100) { example.textContent = "—"; return; }
        const n = global ? 1 : 3;
        let text = `${global ? "" : "For 3 locations: "}${formatRupiah(adPrice(p.digits, extra, n))}`;
        if (launchOn) {
          const d = launch.value === "" ? launchGlobal : Number(launch.value);
          const disc = (BigInt(p.digits) * BigInt(100 - (Number.isFinite(d) ? d : 0)) + 50n) / 100n;
          text += ` → with launch discount ${formatRupiah(adPrice(String(disc), extra, n))}`;
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
      if (!p.ok || BigInt(p.digits) < 1n) { toast("The price for the first location must be more than Rp0.", "error"); return; }
      const extra = x.global ? 100 : Number(x.pct.value);
      if (!Number.isInteger(extra) || extra < 0 || extra > 100) { toast("The extra price per added location must be a whole number from 0 to 100.", "error"); return; }
      const lp = x.launch.value === "" ? null : Number(x.launch.value);
      if (lp !== null && (!Number.isInteger(lp) || lp < 0 || lp > 90)) { toast("Launch discount must be a whole number from 0 to 90.", "error"); return; }
      const params = { id: x.a.id, name: x.a.name, placement: x.a.placement, scope_level: x.a.scope_level, duration_days: Number(x.days.value),
        price: p.digits, extra_pct: extra, launch_pct: lp, enabled: x.enabled.checked, sort: x.a.sort_order };
      // The server asks for each confirmation it needs; we show it and resend with the matching flag.
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          await api("upsert_ad_product", params);
          Object.assign(x.a, { price_per_target: p.digits, extra_location_pct: extra, launch_discount_pct: lp, duration_days: params.duration_days, enabled: params.enabled });
          toast(`Saved “${x.a.name}”. Ads that were already bought keep their old price; only new quotes use this.`, "success");
          return;
        } catch (err) {
          const flag = { PRICE_CHANGE_CONFIRM_BIG: "confirm_big", PRICE_CHANGE_CONFIRM_ACTIVE: "confirm_active" }[err.code];
          if (!flag) { toast(`Not saved: ${errorMessage(err)}`, "error"); return; }
          const ok = await openDialog({ title: err.code === "PRICE_CHANGE_CONFIRM_BIG" ? "This is a big price change" : "Ads are already using this package",
            body: el("p", {}, errorMessage(err)), okLabel: "Yes, save", danger: true });
          if (!ok) return;
          params[flag] = true;
        }
      }
    };
    const surchargeHead = el("span", {}, "Extra price per added location (% of the first-location price) ", el("span", { class: "help", tabindex: "0", title: FORMULA, "aria-label": `How the price is worked out: ${FORMULA}` }, "ⓘ"));
    const adTable = table([
      { label: "Package", render: (x) => `${x.a.name} [${word(x.a.placement)} · ${x.a.scope_level}]` },
      { label: "Length (days)", render: (x) => x.days },
      { label: "Price for the first location (Rp)", render: (x) => x.price },
      { label: surchargeHead, render: (x) => x.pct },
      { label: "Launch discount % (empty = use the site-wide one)", render: (x) => x.launch },
      { label: "Example price (changes as you type, not saved yet)", render: (x) => x.example },
      { label: "Turned on?", render: (x) => x.enabled },
      { label: "", render: (x) => button("Save", () => saveAd(x)) },
    ], adRows);

    const cfg = Object.fromEntries(c.config.map((row) => [row.key, row.value]));
    const moderation = el("select", {}, el("option", { value: "post", selected: cfg.note_moderation === "post" || null }, "Publish right after payment, I check later"),
      el("option", { value: "pre", selected: cfg.note_moderation === "pre" || null }, "Hold each note until I approve it"));
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
      try { links = JSON.parse(socials.value || "{}"); } catch { toast("Official social links must be written like this: {\"instagram\":\"https://instagram.com/…\"}", "error"); return; }
      const lo = parseRupiah(dmin.value);
      const hi = parseRupiah(dmax.value);
      if (!lo.ok || !hi.ok) { toast("Donation limits must be whole rupiah numbers.", "error"); return; }
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
      toast("Settings saved. Launch pricing and price changes only affect new quotes.", "success");
      reload();
    }, "btn btn--primary");

    panel.replaceChildren(policy,
      el("h2", {}, "Decorations"), decoGrid,
      el("h2", {}, "Payment methods"),
      el("p", { class: "small muted" }, "Fill in the smallest and largest amounts from your Midtrans agreement. A payment method is only offered when the order total fits inside its limits. We never lower a price to make it fit."),
      pmTable,
      el("h2", {}, "Ad packages and prices"),
      el("p", { class: "small muted" }, "Advertisers choose Random (rotating) or Featured (pinned on top) and how many days. Only packages that are turned on, and have at least one turned-on location, are offered. The first-location price covers one location. Each extra location costs the extra % of that price (100% = the same price again, 50% = half the price). The total price is fixed the moment an advertiser submits, so changing a price later never changes an ad that was already bought. Hover over ⓘ to see the formula."),
      adTable,
      el("h2", {}, "Site settings"),
      el("div", { class: "stack narrow" },
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Do you check notes before they go live?"), moderation),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Donation minimum (Rp)"), dmin),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Donation maximum (Rp)"), dmax),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Cancel unpaid orders after this many minutes"), ttl),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Public contact email"), contact),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Official social links (written as {\"instagram\":\"https://…\"})"), socials),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Ads: WhatsApp number for custom packages (digits only, with country code like 62…; leave empty to hide the button)"), wa),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Ads: days an advertiser has to pay after you approve"), payDays),
        el("h3", {}, "Launch pricing and price lock"),
        el("label", { class: "check" }, launchMode, el("span", {}, "Launch pricing: show a “Founding advertiser rate” (normal price crossed out) on new quotes. Ads already bought never change.")),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Launch discount (% off the first-location price). A single package can set its own."), launchPct),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Founding advertisers: how many of the very first paying advertisers get their price locked"), foundingCount),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Price lock: an advertiser keeps their locked price if they renew within this many days after their ad ends"), graceDays),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Ad lengths people can choose, in days (separate with commas, e.g. 7, 30, 60, 90)"), durations),
        el("label", { class: "check" }, reportMail, el("span", {}, "Email advertisers a results summary when their ad ends")),
        el("label", { class: "check" }, ads, el("span", {}, "Turn on ad slots from an outside ad network (needs extra setup, see OPERATIONS.md)")),
        saveCfg));
  },

  /** Ad insights: per spot and location views/visitors/clicks/CTR/fill, the CPM-based suggested price, waitlist demand. */
  async adinsights(panel, reload, state) {
    state.insightDays ??= 30;
    const [res, wl, cat] = await Promise.all([api("pricing_analytics", { days: state.insightDays }), api("waitlist_counts"), api("list_catalog")]);
    const days = el("select", { "aria-label": "Period" }, ...[7, 30].map((d) => el("option", { value: String(d), selected: d === state.insightDays || null }, `Last ${d} days`)));
    days.addEventListener("change", () => { state.insightDays = Number(days.value); reload(); });
    const cpm = amountInput("cpm", res.target_cpm ? String(res.target_cpm) : "", "e.g. 15000");
    const saveCpm = button("Save target price", async () => {
      const v = cpm.value.trim() === "" ? { ok: true, digits: "0" } : parseRupiah(cpm.value);
      if (!v.ok) { toast("Enter a whole rupiah amount for every 1,000 views.", "error"); return; }
      await api("set_config", { key: "target_cpm", value: Number(v.digits) });
      toast("Target price saved.", "success");
      reload();
    });
    const spotName = (s) => word(s === "featured" ? "featured" : "random");
    const rows = res.rows.map((r) => r);
    const price = (n) => (n == null ? "—" : formatRupiah(String(Math.round(Number(n)))));
    const suggest = (r) => {
      if (!r.enough) return el("span", { class: "muted" }, `Not enough data yet (${r.days_of_data} of ${res.min_days_required} days collected)`);
      if (!res.target_cpm) return el("span", { class: "muted" }, "Fill in the target price per 1,000 views first");
      return el("span", {}, price(r.suggested_weekly_price));
    };
    const warn = (r) => (r.price_warning
      ? el("span", { class: "badge badge--warn" }, r.price_warning === "above" ? "Your price is more than 30% higher than suggested" : "Your price is more than 30% lower than suggested") : "");
    const wlRows = wl.rows;
    panel.replaceChildren(
      el("p", { class: "small muted" }, "These are real numbers from the site, nothing is made up. A price is only suggested after an ad spot has 14 days of data. Suggested weekly price = average views per week × your target price for 1,000 views ÷ 1,000. “% of slots sold” = days sold ÷ days available (only for Featured spots; Random spots rotate and have no fixed slots)."),
      actions(el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Period"), days),
        el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Target price per 1,000 views (Rp)"), cpm), saveCpm,
        button("Run the daily ad tasks now", async () => {
          const out = await api("run_ad_jobs");
          toast(`Daily ad tasks done: ${JSON.stringify(out)}`, "success");
        })),
      table([
        { label: "Ad type", render: (r) => spotName(r.spot) },
        { label: "Location", key: "label" },
        { label: "Times shown", key: "impressions" },
        { label: "Different people who saw it", key: "unique_visitors" },
        { label: "Clicks", key: "clicks" },
        { label: "Click rate (clicks ÷ times shown)", render: (r) => (r.ctr_pct == null ? "—" : `${r.ctr_pct}%`) },
        { label: "% of slots sold", render: (r) => (r.fill_rate_pct == null ? "Not applicable" : `${r.fill_rate_pct}%`) },
        { label: "Price now (per week, 1 location)", render: (r) => price(r.current_weekly_price) },
        { label: "Suggested price (per week)", render: suggest },
        { label: "Is the price OK?", render: warn },
      ], rows, "No ad data yet. Numbers appear once ads start running."),
      el("h2", {}, `Waiting list (${wl.total_waiting} waiting)`),
      table([
        { label: "Ad type", render: (r) => spotName(r.spot) },
        { label: "Area", key: "scope_level" },
        { label: "Location", render: (r) => r.label ?? "Any" },
        { label: "Days wanted", key: "desired_duration" },
        { label: "People waiting", key: "waiting" },
      ], wlRows, "Nobody is on the waiting list yet."));
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
      { sold_out: "Full: every slot is sold", healthy: "Fine", underfilled: "Too empty: few slots sold", no_data: "Not enough data yet" }[st] ?? st);
    const pct = (n) => (n == null ? "—" : `${n}%`);
    // The server sends these sentences in English with technical words; show plain ones instead.
    const REC = {
      "Sold out with a waitlist: consider raising the price or adding a slot.": "Every slot is sold and people are waiting. Think about raising the price or adding another slot.",
      "Sold out: consider raising the price.": "Every slot is sold. Think about raising the price.",
      "Underfilled: fix traffic or demand before changing price.": "Few slots are sold. Get more visitors or advertisers first. Don’t change the price yet.",
    };

    // location picker for the slot editor
    const locs = [["global:*", "Everywhere"], ...countries.map((x) => [`country:${x.code}`, `Country: ${x.name}`]),
      ...regions.map((x) => [`region:${x.id}`, `Region: ${x.name}`]), ...cities.map((x) => [`city:${x.id}`, `City: ${x.name}`]),
      ...campuses.map((x) => [`campus:${x.id}`, `Campus: ${x.short_name ?? x.name}`])];
    const pick = el("select", { "aria-label": "Location" }, ...locs.map(([v, l]) => el("option", { value: v }, l)));
    const eSlots = num(cfgs.default_slots, { min: "1", max: "10" });
    const eTop = num(0, { min: "0", max: "10" });
    const eTopM = num(1.5, { min: "1", max: "5", step: "0.1" });
    const eStdM = num(1, { min: "0.5", max: "5", step: "0.1" });
    const eRot = el("select", {}, el("option", { value: "equal_share" }, "Equal turns (ads take turns being shown)"), el("option", { value: "fixed_position" }, "Fixed spot (no taking turns)"));
    const fill = (key) => {
      const row = cfgs.rows.find((x) => x.key === key);
      const k = row?.cfg ?? { slots: cfgs.default_slots, top_slots: 0, top_multiplier: 1.5, standard_multiplier: 1, rotation_mode: "equal_share" };
      eSlots.value = k.slots; eTop.value = k.top_slots; eTopM.value = k.top_multiplier; eStdM.value = k.standard_multiplier; eRot.value = k.rotation_mode;
      pick.value = key;
    };
    pick.addEventListener("change", () => fill(pick.value));
    const saveSlots = button("Save these slots", async () => {
      const res = await api("set_slot_config", { key: pick.value, slots: Number(eSlots.value), top_slots: Number(eTop.value),
        top_multiplier: Number(eTopM.value), standard_multiplier: Number(eStdM.value), rotation_mode: eRot.value });
      toast(res.blocks_new_sales ? "Saved. Ads that are already running are not touched. No new ads can be sold here until a slot becomes free." : "Saved.", "success", 7000);
      reload();
    });

    // price history for one package
    const histBox = el("div", {});
    const histSel = el("select", { "aria-label": "Package" }, ...cat.ad_products.filter((x) => x.placement === "featured").map((x) => el("option", { value: x.id }, x.name)));
    const showHist = async () => {
      const rows = await api("price_history", { id: histSel.value });
      histBox.replaceChildren(table([
        { label: "When", render: (r) => formatDate(r.changed_at) },
        { label: "Price for the first location", render: (r) => (r.old_base == null || r.new_base == null || r.old_base === r.new_base) ? "not changed" : `${formatRupiah(r.old_base)} → ${formatRupiah(r.new_base)}` },
        { label: "% of slots sold, 30 days before", render: (r) => pct(r.fill_before_30d) },
        { label: "% of slots sold, 30 days after", render: (r) => pct(r.fill_after_30d) },
      ], rows, "No price changes yet."));
    };
    histSel.addEventListener("change", showHist);

    panel.replaceChildren(
      el("p", { class: "small muted" }, "These are only suggestions. Nothing here changes a price or a slot by itself. “% sold” = days sold ÷ days available, using today’s number of slots. Lowering the number of slots never stops an ad that is already running; it only stops new ads from being sold."),
      el("h2", {}, "How full the ad slots are"),
      table([
        { label: "Location", key: "label" },
        { label: "Number of slots", key: "slots" },
        { label: "% of slots sold, last 7 days", render: (r) => pct(r.fill_7) },
        { label: "% of slots sold, last 30 days", render: (r) => pct(r.fill_30) },
        { label: "% of slots sold, last 90 days", render: (r) => pct(r.fill_90) },
        { label: "Average days until every slot is sold", render: (r) => (r.avg_days_to_sell_out == null ? "—" : r.avg_days_to_sell_out) },
        { label: "People waiting", key: "waitlist" },
        { label: "How it is going", render: (r) => badge(r.status) },
        { label: "What you could do", render: (r) => REC[r.recommendation] ?? r.recommendation ?? "" },
      ], util.rows, util.enough_data ? "No Featured locations yet. Numbers appear once ads start running." : "Not enough data yet. We need 14 days of Featured ad sales first."),
      el("h2", {}, "Settings"),
      el("div", { class: "form-grid" },
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Call a location “too empty” when fewer than this % of its slots were sold in the last 30 days"), under),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Call a location “full” when more than this % of its slots were sold in the last 30 days"), sold),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "When a slot frees up, how long (hours) the next person in line has to take it"), hold),
        el("label", { class: "check" }, stepOn, el("span", {}, "When a location is full, suggest a price increase (you approve each one; nothing changes by itself)")),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Size of each suggested price increase (%, max 30)"), step), saveSet),
      el("h2", {}, "Ad slots in each location"),
      table([
        { label: "Location", key: "label" },
        { label: "Number of slots", render: (r) => r.cfg.slots },
        { label: "Top slots (shown first)", render: (r) => r.cfg.top_slots },
        { label: "Top slot price × (1.5 = 50% more)", render: (r) => r.cfg.top_multiplier },
        { label: "Normal slot price × (1 = normal price)", render: (r) => r.cfg.standard_multiplier },
        { label: "How ads take turns", render: (r) => (r.cfg.rotation_mode === "equal_share" ? "Equal turns" : "Fixed spot") },
        { label: "Ads running now (busiest day, last 30 days)", key: "in_use_peak_30d" },
        { label: "", render: (r) => button("Edit", () => { fill(r.key); pick.scrollIntoView({ block: "center" }); }, "btn btn--small") },
      ], cfgs.rows, `Every location has ${cfgs.default_slots} slots until you change it.`),
      el("div", { class: "form-grid" },
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Location"), pick),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Number of slots (1–10)"), eSlots),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "How many of them are top slots"), eTop),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Top slot price multiplier (1.5 = 50% more than normal)"), eTopM),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Normal slot price multiplier (1 = normal price)"), eStdM),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "How ads take turns"), eRot), saveSlots),
      el("h2", {}, "Suggested price changes"),
      actions(button("Look for price suggestions now", async () => {
        const out = await api("generate_price_proposals");
        toast(`${out.created} new suggestion(s).`, "success");
        reload();
      })),
      table([
        { label: "Package", key: "product_name" },
        { label: "Suggested change", render: (r) => `${formatRupiah(r.old_base)} → ${formatRupiah(r.new_base)} (+${r.step_pct}%)` },
        { label: "Why", key: "reason" },
        { label: "Status", render: (r) => word(r.status) },
        { label: "", render: (r) => (r.status !== "pending" ? "" : actions(
          button("Approve", async () => {
            const ok = await openDialog({ title: "Apply this price?", body: el("p", {}, "This only applies to new ads. Ads that were already bought keep the price they were sold at."), okLabel: "Approve" });
            if (!ok) return;
            await api("decide_price_proposal", { id: r.id, approve: true });
            toast("Price changed for new quotes.", "success");
            reload();
          }),
          button("Reject", async () => { await api("decide_price_proposal", { id: r.id, approve: false }); reload(); }, "btn btn--small btn--danger"))) },
      ], props, "No suggestions right now."),
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
        body: el("div", { class: "stack" }, el("p", {}, "Auctions only run in locations you turn on below, and only for the next period of a slot that is fully sold. Type ENABLE AUCTIONS to continue."), input) });
      if (!data) return;
      await api("auction_set_enabled", { enabled: true, confirm: String(data.get("confirm") ?? "") });
      toast("Auctions are on.", "success");
      reload();
    }, o.enabled ? "btn btn--small" : "btn btn--small btn--primary");
    const kill = button("Emergency stop", async () => {
      const reason = await promptReason("Emergency stop: turn auctions off and cancel every auction that is still open?", { required: true, danger: true, okLabel: "Cancel all auctions" });
      if (!reason) return;
      const res = await api("auction_kill_switch", { reason });
      toast(`Auctions are off. ${res.canceled} open auction(s) cancelled. Normal fixed prices keep working.`, "success", 8000);
      reload();
    }, "btn btn--small btn--danger");

    const readiness = (r) => {
      const x = r.readiness;
      return el("span", { class: x.ready ? "" : "muted" }, `${x.weeks_ok} of ${x.weeks_required} weeks with more than ${x.fill_threshold}% of slots sold · ${x.waitlist} people waiting (need ${x.waitlist_needed})`);
    };
    const locationFlag = (r) => (r.enabled
      ? button("Turn off here", async () => { await api("auction_set_location", { key: r.key, enabled: false }); reload(); }, "btn btn--small")
      : button("Turn on here", async () => {
        let override = null;
        if (!r.readiness.ready) {
          override = await promptReason("This location does not meet the rules for auctions yet. Turn them on anyway? Write why.", { required: true, okLabel: "Turn on anyway", danger: true });
          if (!override) return;
        }
        await api("auction_set_location", { key: r.key, enabled: true, override_reason: override });
        reload();
      }, "btn btn--small"));

    const locSel = el("select", { "aria-label": "Location" }, ...o.locations.filter((l) => l.enabled).map((l) => el("option", { value: l.key }, l.label)));
    const prodSel = el("select", { "aria-label": "Package" }, ...cat.ad_products.filter((x) => x.placement === "featured" && x.enabled).map((x) => el("option", { value: x.id }, x.name)));
    const open = button("Start auction", async () => {
      if (!locSel.value) { toast("Turn auctions on for a location first.", "error"); return; }
      const res = await api("auction_open", { key: locSel.value, product_id: prodSel.value });
      toast(`Auction started. Starting price ${formatRupiah(res.reserve)}; the ad slot begins ${res.period_start}.`, "success", 8000);
      reload();
    });

    const bidLog = async (a) => {
      const d = await api("auction_bids", { id: a.id });
      const rows = d.bids.map((b) => el("tr", {},
        el("td", {}, formatDate(b.created_at, true)), el("td", {}, b.email ?? b.bidder_id), el("td", {}, formatRupiah(b.amount)),
        el("td", {}, `${word(b.status)}${b.buy_now ? " (bought instantly)" : ""}${b.cancel_reason ? `: ${b.cancel_reason}` : ""}`), el("td", {}, b.ip),
        el("td", {}, b.status === "valid" && a.status === "open" ? button("Cancel bid", async () => {
          const reason = await promptReason("Cancel this bid?", { required: true, danger: true, okLabel: "Cancel bid" });
          if (!reason) return;
          await api("auction_cancel_bid", { id: b.id, reason });
          toast("Bid canceled.", "success");
          reload();
        }, "btn btn--small btn--danger") : "")));
      await openDialog({ title: `Bid log · ${a.label}`, okLabel: "Close",
        body: el("div", { class: "stack" },
          d.flags.length ? el("p", { class: "notice" }, `Warnings: ${d.flags.map((f) => `${humanize(f.kind)} (${f.details.bidders?.length ?? 0} accounts on the same network)`).join("; ")}`) : "",
          el("table", { class: "table" }, el("thead", {}, el("tr", {}, ...["Time", "Bidder", "Amount", "Status", "Network (IP address)", ""].map((h) => el("th", {}, h)))), el("tbody", {}, ...rows)),
          d.offers.length ? el("p", { class: "small" }, `Offers made to the next bidders: ${d.offers.map((x) => `${x.bidder} ${formatRupiah(x.amount)} (${word(x.status)})`).join("; ")}`) : "") });
    };

    panel.replaceChildren(
      el("p", { class: o.enabled ? "notice" : "notice notice--warn" }, o.enabled ? "Auctions are ON for the whole site." : "Auctions are OFF. Normal fixed-price sales are not affected."),
      actions(toggleGlobal, kill),
      el("p", { class: "small muted" }, "How auctions work: only the next period of a slot that is fully sold can be auctioned. The starting price is the current fixed price. “Buy now” costs 1.5 times the starting price. The highest valid bid wins; if two bids are equal, the earlier one wins. A bid in the last minutes adds 5 minutes to the auction (at most 6 times). No money is taken when someone bids. The winner gets a time window to pay. If they do not pay, the next bidder gets the chance and the first person gets a strike."),
      el("h2", {}, "Settings"),
      el("div", { class: "form-grid" },
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Auction length (hours)"), hours),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Smallest bid increase (Rp)"), incr),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Hours the winner has to pay"), payH),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Unpaid wins allowed before someone is blocked from bidding"), strikes),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "Ready when more than this % of slots are sold…"), fillPct),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "…for this many weeks in a row…"), fillWeeks),
        el("label", { class: "field" }, el("span", { class: "field__label" }, "…and the number of people waiting is at least this many times the number of slots"), wlMult), saveCfg),
      el("h2", {}, "Which locations are ready for auctions"),
      table([
        { label: "Location", key: "label" },
        { label: "Rule check", render: readiness },
        { label: "Ready?", render: (r) => (r.readiness.ready ? "Yes" : "No") },
        { label: "Auctions here", render: (r) => (r.enabled ? "On" : "Off") },
        { label: "", render: locationFlag },
      ], o.locations, "No Featured locations yet."),
      el("h2", {}, "Start an auction"),
      actions(el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Location"), locSel),
        el("label", { class: "field field--inline" }, el("span", { class: "field__label" }, "Package"), prodSel), open),
      el("h2", {}, "Auctions"),
      table([
        { label: "Location", key: "label" },
        { label: "Status", render: (a) => word(a.status) },
        { label: "Ad slot begins", key: "period_start" },
        { label: "Starting price", render: (a) => formatRupiah(a.reserve) },
        { label: "Highest bid", render: (a) => (a.high ? formatRupiah(a.high) : "—") },
        { label: "Number of bids", key: "bids" },
        { label: "Auction ends", render: (a) => `${formatDate(a.ends_at, true)}${a.extensions ? ` (+${a.extensions})` : ""}` },
        { label: "Warnings", key: "flags" },
        { label: "", render: (a) => actions(button("Bid log", () => bidLog(a), "btn btn--small"),
          ["open", "awaiting_payment"].includes(a.status) ? button("Cancel", async () => {
            const reason = await promptReason("Cancel this auction? Write why.", { required: true, danger: true, okLabel: "Cancel auction" });
            if (!reason) return;
            await api("auction_cancel", { id: a.id, reason });
            reload();
          }, "btn btn--small btn--danger") : "") },
      ], o.auctions, "No auctions yet."),
      el("h2", {}, "People who won but did not pay (strikes)"),
      table([
        { label: "Account", render: (x) => x.email ?? x.user_id },
        { label: "Strikes (unpaid wins)", key: "strikes" },
        { label: "", render: (x) => button("Remove strikes", async () => {
          const reason = await promptReason("Remove this person’s strikes? Write why.", { required: true, okLabel: "Remove strikes" });
          if (!reason) return;
          await api("auction_clear_strikes", { user_id: x.user_id, reason });
          reload();
        }, "btn btn--small") },
      ], o.strikes, "Nobody has strikes."));
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
      const code = level === "country" ? el("input", { placeholder: "2-letter country code (e.g. MY)", maxlength: "2" }) : null;
      const short = level === "campus" ? el("input", { placeholder: "Short name" }) : null;
      return el("div", { class: "row row--tight" }, el("strong", {}, `Add a ${level}`), code, parent, name, short, ...extra,
        button("Add", async () => {
          if (!name.value.trim()) { toast("Name is required.", "error"); return; }
          await api("upsert_location", { level, id: code ? code.value.trim().toUpperCase() : null, parent: parent?.value ?? null, name: name.value.trim(), short_name: short?.value.trim() || null });
          toast(`Added: ${level}.`, "success");
          reload();
        }));
    };
    const disable = (level, id) => button("Hide", async () => {
      const ok = await openDialog({ title: `Hide this ${level}?`, body: el("p", {}, "It will no longer appear in the location lists. Ads that were aimed at it will no longer show there."), danger: true, okLabel: "Hide" });
      if (!ok) return;
      const row = { country: countries, region: regions, city: cities, campus: campuses }[level].find((x) => (x.id ?? x.code) === id);
      await api("upsert_location", { level, id, name: row.name, short_name: row.short_name ?? null, enabled: false });
      reload();
    }, "btn btn--small btn--danger");
    const del = (level, id) => ownerDelete(state, level, id, level, reload);
    const manage = (level, id) => actions(disable(level, id), del(level, id));
    panel.replaceChildren(
      el("p", { class: "small muted" }, "To add a new country, add the country first, then its regions, then its cities, then its campuses. Add them from top to bottom."),
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
      kind: el("select", {}, el("option", { value: "percent" }, "Percent off the lowest price"), el("option", { value: "fixed" }, "Rupiah off the lowest price")),
      value: el("input", { inputmode: "numeric", placeholder: "100% = free post" }),
      max: el("input", { inputmode: "numeric", placeholder: "blank = unlimited" }),
      per: el("input", { inputmode: "numeric", placeholder: "default 1" }),
      exp: el("input", { type: "date" }) };
    f.per.value = "1";
    const lab = (text, node) => el("label", { class: "field" }, el("span", { class: "field__label" }, text), node);
    const create = button("Create code", async () => {
      await api("create_promo", { code: f.code.value, kind: f.kind.value, value: Number(f.value.value), max_uses: f.max.value.trim() || null,
        per_user: Number(f.per.value) || 1, expires_at: f.exp.value || null });
      toast("Promo code created.", "success"); reload();
    }, "btn btn--primary btn--small");
    panel.replaceChildren(
      el("p", { class: "notice" }, "A discount only lowers the lowest allowed price. Anything a person pays above that is a tip and is never discounted. People need to be signed in to use a code."),
      el("div", { class: "row" },
        lab("Code (4-24 letters or digits)", f.code), lab("Kind of discount", f.kind), lab("How much (% or Rp)", f.value),
        lab("Most times it can be used in total", f.max), lab("Times each person can use it", f.per), lab("Stops working on (optional)", f.exp), create),
      table([
        { label: "Code", key: "code" },
        { label: "Discount", render: (r) => (r.kind === "percent" ? `${r.value}%` : formatRupiah(r.value)) },
        { label: "Times used", render: (r) => `${r.uses}${r.max_uses ? ` of ${r.max_uses}` : ""}` },
        { label: "Times each person can use it", key: "per_user_limit" },
        { label: "Stops working on", render: (r) => (r.expires_at ? formatDate(r.expires_at) : "Never") },
        { label: "Turned on?", render: (r) => button(r.enabled ? "Turn off" : "Turn on", async () => { await api("set_promo_enabled", { id: r.id, enabled: !r.enabled }); reload(); }) },
      ], rows, "No promo codes yet."));
  },

  async announcements(panel, reload, state) {
    const items = await api("list_announcements");
    const title = el("input", { maxlength: "120" });
    const body = el("textarea", { rows: "6", maxlength: "4000" });
    const pinned = el("input", { type: "checkbox" });
    let editing = null;
    const save = button("Save draft", async () => {
      if (title.value.trim().length < 3 || !body.value.trim()) { toast("Write a title (at least 3 letters) and some text.", "error"); return; }
      await api("upsert_announcement", { id: editing, title: title.value, body: body.value, pinned: pinned.checked });
      toast("Saved as a draft. Press Publish in the list below to show it.", "success");
      reload();
    }, "btn btn--primary");
    const preview = button("Preview", async () => {
      await openDialog({ title: title.value.trim() || "Preview", okLabel: "Close", body: el("p", { class: "announcement__body" }, body.value) });
    });
    const STATUS_LABEL = { published: "Publish", draft: "Hide again", archived: "Archive" };
    const setStatus = (a, status) => button(STATUS_LABEL[status], async () => { await api("set_announcement_status", { id: a.id, status }); reload(); });
    const field = (label, node) => el("label", { class: "field" }, el("span", { class: "field__label" }, label), node);
    panel.replaceChildren(
      el("div", { class: "stack narrow card" }, el("h2", {}, "Write news"),
        field("Title", title), field("Text", body),
        el("label", { class: "check" }, pinned, el("span", {}, "Pin on the wall")), actions(save, preview)),
      el("h2", {}, "Recent news"),
      table([
        { label: "Title", key: "title" },
        { label: "Status", render: (a) => el("span", { class: `badge${a.status === "published" ? " badge--ok" : ""}` }, word(a.status)) },
        { label: "Pinned on the wall?", render: (a) => (a.pinned ? "Yes" : "No") },
        { label: "Published on", render: (a) => formatDate(a.published_at) },
        { label: "Last edited by", render: (a) => a.updated_by_name ?? "" },
        { label: "What you can do", render: (a) => actions(
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
      { label: "Person who joined", key: "referred_name" },
      { label: "Who invited them", key: "referrer_name" },
      { label: "Invite code", key: "code" },
      { label: "Did it count?", render: (r) => `${word(r.status)}${r.reject_reason ? ` (${r.reject_reason})` : ""}` },
      { label: "Old-style credit", render: (r) => word(r.credit_status) },
      { label: "Free credits earned", render: (r) => String(r.reward_credits ?? 0) },
      { label: "Joined on", render: (r) => formatDate(r.created_at, true) },
      { label: "", render: (r) => r.credit_status === "available" ? button("Take back old credit", async () => {
        const reason = await promptReason("Take back this unused credit? Write why.", { required: true, danger: true, okLabel: "Take back" });
        if (reason === null) return;
        await api("revoke_credit", { credit_id: r.credit_id, reason });
        reload();
      }, "btn btn--small btn--danger") : "" },
      { label: "", render: (r) => Number(r.reward_credits) > 0 ? button("Take back free credits", async () => {
        const reason = await promptReason("Take back the UNUSED free credits this invite earned? Credits that were already used on orders stay used. Write why.", { required: true, danger: true, okLabel: "Take back" });
        if (reason === null) return;
        try {
          const res = await api("revoke_referral_credits", { referred_user_id: r.referred_user_id, reason });
          toast(`${res?.revoked ?? 0} credit(s) taken back.`, "success");
        } catch (err) { toast(errorMessage(err), "error"); }
        reload();
      }, "btn btn--small btn--danger") : "" },
      { label: "Remove this row", render: (r) => ownerDelete(state, "referral", r.referred_user_id, "referral entry", reload) ?? "" },
    ], rows));
  },

  async revenue(panel, reload, state) {
    const now = new Date();
    state.range ??= { from: new Date(now.getFullYear(), now.getMonth(), 1).toISOString().slice(0, 10), to: new Date(now.getTime() + 86400e3).toISOString().slice(0, 10) };
    const from = el("input", { type: "date", value: state.range.from });
    const to = el("input", { type: "date", value: state.range.to });
    const go = button("Show report", async () => { state.range = { from: from.value, to: to.value }; reload(); });
    const d = await api("revenue_report", { from: `${state.range.from}T00:00:00+07:00`, to: `${state.range.to}T00:00:00+07:00` });
    const money = ["publication_revenue", "decoration_revenue", "donations", "advertising_revenue", "gross_payment_volume", "refunds_and_reversals", "net_collected", "credit_discounts_given", "average_order_value"];
    const pct = (v) => (v === null || v === undefined ? "Not applicable" : `${(Number(v) * 100).toFixed(1)}%`);
    const items = [
      ...money.map((k) => [k, formatRupiah(d[k])]),
      ["processing_fees", d.processing_fees === null ? "Not available here (see your Midtrans settlement reports)" : formatRupiah(d.processing_fees)],
      ["paid_orders", d.paid_orders], ["free_publications", d.free_publications], ["checkout_sessions", d.checkout_sessions],
      ["checkout_completion_rate", pct(d.checkout_completion_rate)], ["decoration_attachment_rate", pct(d.decoration_attachment_rate)],
      ["credits_issued", d.credits_issued], ["credits_redeemed", d.credits_redeemed],
      ["campaign_impressions", d.campaign_impressions], ["campaign_clicks", d.campaign_clicks], ["campaign_renewals", d.campaign_renewals],
    ];
    panel.replaceChildren(actions(el("span", {}, "From"), from, el("span", {}, "to (this last day is not included)"), to, go),
      el("dl", { class: "stats stats--grid" }, ...items.map(([k, v]) => el("div", {}, el("dt", { title: REVENUE[k]?.[1] ?? "" }, REVENUE[k]?.[0] ?? k.replace(/_/g, " ")), el("dd", {}, String(v))))),
      el("h3", {}, "What each number means"),
      el("ul", { class: "small" }, ...Object.entries(REVENUE).map(([k, [name, meaning]]) => el("li", {}, el("strong", {}, name), ": ", el("span", {}, meaning)))));
  },

  async audit(panel, reload, state) {
    const rows = await api("audit_log", { limit: 200 });
    panel.replaceChildren(table([
      { label: "When", render: (r) => formatDate(r.created_at, true) },
      { label: "Who did it", key: "actor_name" },
      { label: "What they did", render: (r) => actionName(r.action) },
      { label: "On what", render: (r) => el("span", {}, `${targetName(r.target_type)} `, shortId(r.target_id)) },
      { label: "Reason they wrote", key: "reason" },
      { label: "", render: (r) => ownerDelete(state, "audit_entry", r.id, "audit log entry", reload) ?? "" },
    ], rows));
  },

  // Append-only trail of Owner deletions. It has no delete control anywhere.
  async security(panel) {
    const rows = await api("security_events", { limit: 200 });
    panel.replaceChildren(table([
      { label: "When", render: (r) => formatDate(r.created_at, true) },
      { label: "What happened", render: (r) => actionName(r.action) },
      { label: "Kind of item", render: (r) => targetName(r.target_type) },
      { label: "Item", render: (r) => shortId(r.target_id) },
      { label: "More information", render: (r) => details(r.details) },
    ], rows, "Nothing has been permanently deleted."));
  },
};

// Per-tab help shown above each panel: what the tab is for, and what to do in it.
// `sub` describes each section heading (h2) inside the tab; it is added only where the panel has no text of its own.
const GUIDE = {
  overview: { what: "A quick look at how the whole site is doing: money, activity, and anything waiting for you.",
    steps: ["Look at the numbers that need action first: ads waiting for your approval, reports nobody has handled, notes waiting for your review, and payments that need checking.", "If any of those numbers is more than zero, open the matching tab in the menu and deal with them.", "Press “Close old unpaid orders” once in a while. It cancels orders that nobody paid within the time limit."] },
  moderation: { what: "All the sticky notes on the wall. Approve, reject or take down notes here.",
    steps: ["The list starts with notes that are waiting for your review. This only has notes in it when “Do you check notes before they go live?” is set to hold each note (see Prices & settings).", "Read the note and open its photo or video links. Press Approve to put it on the wall, or Reject to refuse it.", "Use Remove on a live note that breaks the rules. Restore puts a removed note back on the wall.", "Writing a reason is optional, but please write one. It is saved in the admin activity log."] },
  reports: { what: "Notes that visitors reported. Only reports nobody has handled yet are shown.",
    steps: ["Read why it was reported, what the reporter wrote, and the note itself.", "If the note breaks the rules, press Remove note. This also closes the report.", "If the report is fair but the note can stay, press Mark as handled. If the report is wrong or spam, press Ignore."] },
  users: { what: "Everyone who has an account. Find a person, block them, or delete their account.",
    steps: ["Search by name or email.", "Block account stops the person from signing in. You must write a reason. Unblock account lets them back in.", "Admin accounts have no buttons here. Delete account is permanent, so only use it when you really have to."] },
  announcements: { what: "News that visitors can read. Pinned news stays at the top of the wall.",
    steps: ["Write a title and text. Tick “Pin on the wall” if you want it at the top. Press Preview to see it, then Save draft.", "A draft is not visible to anyone. Press Publish in the list to show it.", "Hide again turns it back into a draft. Archive hides it for good. Edit loads it back into the form."],
    sub: { "Write news": "Write a new news item, or change the one you pressed Edit on.", "Recent news": "All news items and where they are now. Publish, hide, archive or edit them here." } },
  orders: { what: "Every payment: sticky notes, donations and ads.",
    steps: ["Use the filters to pick a type and a payment status. Tick “Only payments that need checking” to see only the payments the system flagged.", "Details shows everything about the order. “Check with Midtrans” asks Midtrans what really happened. Use it when someone says they paid but the order still says unpaid.", "“Skip payment (post for free)” lets an unpaid sticky note go live without payment. You must write a reason, and it is saved as “payment skipped”.", "“Mark as checked” removes the warning after you looked into a flagged payment.", "If someone sends you a receipt code, paste it in the box at the top to find their note."] },
  revenue: { what: "How much money came in during the dates you choose (Jakarta time).",
    steps: ["Pick the From and To dates. The last day is not included, so pick the day after if you want a whole last day.", "Press Show report.", "Hover over a name, or read “What each number means” at the bottom. “Money kept” is the money received minus the money given back."] },
  promos: { what: "Discount codes for sticky notes.",
    steps: ["Type a code (4–24 letters or digits), pick the kind of discount, and type how much. 100% makes the note free.", "If you want, set how many times the code can be used and when it stops working. Then press Create promo code.", "Turn a code off to stop people using it. Turn it on again to bring it back. Codes cannot be deleted here.", "A discount only lowers the lowest allowed price. Anything a person pays above that is a tip."] },
  referrals: { what: "Who invited whom, and the free credits they earned.",
    steps: ["“Did it count?” tells you whether the invite was accepted or why it was not.", "Free credits pay for notes. “Take back free credits” removes credits nobody has used yet, for example after cheating. Credits that were already used stay used. You must write a reason.", "“Old-style credit” and “Take back old credit” are only for the old credit system."] },
  campaigns: { what: "Ads that advertisers submitted. Check, approve and control every ad here.",
    steps: ["The list starts with ads waiting for your approval. Read the ad and check its image and link.", "Approve a good ad. The advertiser then has some days to pay (you set the number of days in Prices & settings). Reject a bad ad and give the advertiser a reason.", "“Paid, waiting for your check”: approve it so it gets scheduled.", "Pause stops a running ad. Resume starts it again. Cancel ends it for good.", "The “Times shown / clicks” column shows how often the ad was seen and clicked."] },
  adinsights: { what: "How each kind of ad spot and each location is doing, plus a suggested price.",
    steps: ["Choose the period (last 7 or 30 days).", "Type the price you want to earn for every 1,000 times an ad is shown, then press Save target price.", "Read “Times shown”, “Clicks”, “Click rate” and “% of slots sold”. A price is only suggested after 14 days of data.", "The waiting list shows advertisers who want a spot in a location that is full. It is a hint to raise prices or add slots.", "Nothing on this page changes a price by itself."],
    sub: { "Waiting list": "Advertisers waiting for a spot, by location and number of days wanted." } },
  slots: { what: "How many ad slots each location has, how full they are, and suggested price changes.",
    steps: ["“How full the ad slots are” shows what share of the slots were sold in the last 7, 30 and 90 days. “Too empty” means few were sold. “Full” means almost all were sold.", "In Settings, choose at what % a location counts as “too empty” or “full”, and how long a waiting advertiser has to take a freed slot.", "In “Ad slots in each location”, change how many slots a location has, how many are top slots, the price multipliers, and how ads take turns. Fewer slots never stops an ad that is already running.", "Look at “Suggested price changes” (a full location may suggest a higher price). Approve or reject each one. Nothing happens by itself.", "“Price history” shows past price changes and the % of slots sold before and after."],
    sub: { "How full the ad slots are": "What share of each location’s ad slots were sold in the last 7, 30 and 90 days, and what you could do about it.", "Settings": "When a location counts as “too empty” or “full”, how long a waiting advertiser keeps their turn, and the optional price-increase suggestion.", "Ad slots in each location": "How many slots each location has, how many are top slots, and the price multipliers. Press Edit to load one into the form below.", "Suggested price changes": "Price increases suggested for locations that are full. Approve or reject each one.", "Price history": "Past price changes for a Featured package, with the % of slots sold before and after." } },
  auctions: { what: "Auctions for the next period of a Featured slot that is fully sold. Off by default.",
    steps: ["Set the rules in Settings, then press Save auction settings.", "Check “Which locations are ready for auctions”. A location is ready when its slots were mostly sold for enough weeks in a row and enough people are waiting.", "Turn auctions on for the whole site (you must type ENABLE AUCTIONS), then turn them on for each location. Turning them on for a location that is not ready needs a reason.", "Pick a location and package, then press Start auction.", "In the Auctions list, “Bid log” shows every bid, and Cancel stops one auction.", "“Emergency stop” turns auctions off and cancels every open auction. Normal fixed prices keep working.", "Use “Remove strikes” to forgive someone who won but did not pay, when it makes sense."],
    sub: { "Settings": "How long an auction runs, the smallest bid increase, how long the winner has to pay, how many unpaid wins are allowed, and the rules for being ready.", "Which locations are ready for auctions": "Which locations may run auctions, and whether they follow the rules.", "Start an auction": "Open a new auction. Only locations with auctions turned on are listed.", "Auctions": "All auctions with their status, bids and end time.", "People who won but did not pay (strikes)": "People who won an auction and did not pay. When they reach the limit they cannot bid anymore." } },
  catalog: { what: "Everything that decides what customers pay, plus the general site settings.",
    steps: ["Decorations: click one to change its name, price, or whether people can pick it.", "Payment methods: type the smallest and largest amounts from your Midtrans agreement.", "Ad packages and prices: change the price, the extra price per added location, and turn packages on or off. Ads that were already bought keep their old price.", "Site settings: change the values, then press the save button at the bottom."],
    sub: { "Decorations": "Stickers and decorations people can add to notes. Click one to edit it.", "Site settings": "Checking notes before they go live, donation limits, when unpaid orders are cancelled, contact details, days to pay for ads, launch pricing, and the ad lengths people can choose." } },
  locations: { what: "The places that ads and notes can be aimed at: countries, regions, cities and campuses.",
    steps: ["Add places from the top down: country first, then region, then city, then campus.", "Each form asks for the parent place and a name. Press Add.", "Hide removes a place from the lists. Ads that were aimed at it will not show there anymore."],
    sub: { "Countries": "The top level. Needs a 2-letter country code.", "Regions": "Provinces or states inside a country.", "Cities": "Cities inside a region.", "Campuses": "Individual campuses inside a city." } },
  audit: { what: "A list of everything admins did: who did it, what they did, to which item, and why.",
    steps: ["Use it to find out who changed something.", "The newest entries are first. It shows the last 200.", "“Reason they wrote” is what the admin typed, so ask admins to write real reasons."] },
  security: { what: "Owner only. A permanent record of everything the Owner deleted for good.",
    steps: ["You can only read it. Nothing here can be deleted.", "Use it to check what was deleted for good, when, and which item it was."] },
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
  const d = el("details", { class: "notice admin-guide" }, el("summary", {}, "What is this page? How do I use it?"),
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
    r.title.textContent = t("Administrators only");
    r.message.textContent = t(user ? "Your account does not have administrator access." : "Sign in with an administrator account.");
    view.append(frag);
    return;
  }
  view.append(cloneTemplate("tpl-admin"));
  const r = refs(view);
  const state = { tab: "overview", owner: await isOwner() };
  let req = 0;
  if (!state.owner) r.tabs.querySelectorAll("[data-owner-only]").forEach((tab) => tab.remove());

  // Each menu heading (Community, Money, …) is a dropdown: press it to show or hide its tabs.
  const openGroup = (g, on) => {
    if (!g) return;
    g.setAttribute("aria-expanded", String(on));
    g.nextElementSibling.hidden = !on;
  };
  r.tabs.querySelectorAll(".admin-group").forEach((g) => {
    openGroup(g, false);
    g.addEventListener("click", () => openGroup(g, g.getAttribute("aria-expanded") !== "true"), { signal });
  });

  const show = async () => {
    const id = ++req;
    r.tabs.querySelectorAll("[data-tab]").forEach((t) => t.setAttribute("aria-selected", String(t.dataset.tab === state.tab)));
    openGroup(r.tabs.querySelector(`[data-tab="${state.tab}"]`)?.closest(".admin-items")?.previousElementSibling, true);
    r.panel.replaceChildren(el("p", { class: "muted" }, t("Loading…")));
    try {
      const panel = el("div");
      await panels[state.tab](panel, show, state);
      addGuide(state.tab, panel, state);
      translate(panel); // Indonesian mode: the panel is built in English first
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
