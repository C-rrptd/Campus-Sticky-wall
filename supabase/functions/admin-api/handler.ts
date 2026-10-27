// POST /functions/v1/admin-api  { action, params }
// Explicit allowlist of administrator operations. Each action validates its
// parameters and calls exactly one SQL function AS THE CALLER (their JWT);
// every SQL admin function re-checks is_admin(auth.uid()) and writes the audit
// log. Actions that need server secrets (Midtrans reconciliation, order expiry,
// Auth bans) first confirm admin status through the database.

import { type AuthUser, type Db, type Deps, type Handler, requireUser } from "../_shared/auth.ts";
import { fetchTransactionStatus, midtransConfig, parseNotification, statusToRpcArgs } from "../_shared/payments.ts";
import { HttpError, json, rateLimit, readJson, rpc } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";
import { purgeMediaOrphans } from "../_shared/media.ts";
import { sendEmail } from "../_shared/email.ts";

type P = Record<string, unknown>;
const int = (x: unknown, d: number, max: number) =>
  typeof x === "number" && Number.isInteger(x) && x >= 0 ? Math.min(x, max) : d;
const optStr = (x: unknown, field: string, max = 200) => v.str(x, field, { max, optional: true });
const reason = (x: unknown) => v.str(x, "Reason", { max: 500, optional: true, multiline: true });
const optAmount = (x: unknown) => (x === null || x === undefined || x === "" ? null : v.amount(x));

/** action -> [sql function, argument builder] */
const SQL_ACTIONS: Record<string, [string, (p: P) => P]> = {
  overview: ["admin_overview", () => ({})],
  list_notes: ["admin_list_notes", (p) => ({ p_status: optStr(p.status, "status", 40), p_limit: int(p.limit, 50, 200), p_offset: int(p.offset, 0, 100000) })],
  moderate_note: ["admin_moderate_note", (p) => ({
    p_note_id: v.uuid(p.note_id, "note_id"),
    p_action: v.oneOf(p.action, "action", ["approve", "reject", "remove", "restore"] as const),
    p_reason: reason(p.reason),
  })],
  list_reports: ["admin_list_reports", (p) => ({ p_status: optStr(p.status, "status", 20), p_limit: int(p.limit, 100, 500) })],
  resolve_report: ["admin_resolve_report", (p) => ({
    p_report_id: v.uuid(p.report_id, "report_id"),
    p_status: v.oneOf(p.status, "status", ["resolved", "dismissed"] as const),
    p_reason: reason(p.reason),
  })],
  list_users: ["admin_list_users", (p) => ({ p_search: optStr(p.search, "search", 100), p_limit: int(p.limit, 50, 200), p_offset: int(p.offset, 0, 100000) })],
  list_catalog: ["admin_list_catalog", () => ({})],
  upsert_decoration: ["admin_upsert_decoration", (p) => ({
    p_id: v.str(p.id, "id", { min: 2, max: 40 }),
    p_name: v.str(p.name, "name", { min: 2, max: 50 }),
    p_description: optStr(p.description, "description", 200),
    p_price: v.amount(p.price, "price"),
    p_enabled: v.bool(p.enabled, "enabled", true),
    p_sort: int(p.sort, 0, 1000),
  })],
  upsert_payment_method: ["admin_upsert_payment_method", (p) => ({
    p_code: v.str(p.code, "code", { min: 2, max: 40 }),
    p_label: v.str(p.label, "label", { max: 80 }),
    p_midtrans_codes: Array.isArray(p.midtrans_codes) && p.midtrans_codes.length > 0 && p.midtrans_codes.length <= 20 &&
        p.midtrans_codes.every((c) => typeof c === "string" && /^[a-z0-9_]{2,40}$/.test(c))
      ? p.midtrans_codes
      : (() => { throw new HttpError(400, "INVALID_FIELD", "midtrans_codes must be a list of channel codes."); })(),
    p_min: optAmount(p.min),
    p_max: optAmount(p.max),
    p_enabled: v.bool(p.enabled, "enabled", true),
    p_sort: int(p.sort, 0, 1000),
  })],
  upsert_ad_product: ["admin_upsert_ad_product", (p) => ({
    p_id: v.str(p.id, "id", { min: 2, max: 60 }),
    p_name: v.str(p.name, "name", { max: 120 }),
    p_placement: v.oneOf(p.placement, "placement", ["promotions_feed", "wall_inline", "featured"] as const),
    p_scope_level: v.oneOf(p.scope_level, "scope_level", ["global", "country", "region", "city", "campus"] as const),
    p_duration_days: int(p.duration_days, 7, 365) || 7,
    p_price: v.amount(p.price, "price"),
    p_enabled: v.bool(p.enabled, "enabled", true),
    p_sort: int(p.sort, 0, 1000),
    p_extra_pct: int(p.extra_pct, 100, 1000),
  })],
  set_config: ["admin_set_config", (p) => ({ p_key: v.str(p.key, "key", { max: 60 }), p_value: p.value ?? null })],
  list_orders: ["admin_list_orders", (p) => ({
    p_kind: optStr(p.kind, "kind", 20), p_status: optStr(p.status, "status", 30),
    p_review_only: v.bool(p.review_only, "review_only", false), p_limit: int(p.limit, 50, 200), p_offset: int(p.offset, 0, 100000),
  })],
  order_detail: ["admin_order_detail", (p) => ({ p_order_ref: v.orderRef(p.order_ref) })],
  clear_order_review: ["admin_clear_order_review", (p) => ({ p_order_ref: v.orderRef(p.order_ref), p_reason: reason(p.reason) })],
  list_campaigns: ["admin_list_campaigns", (p) => ({ p_status: optStr(p.status, "status", 30) })],
  review_campaign: ["admin_review_campaign", (p) => ({
    p_campaign_id: v.uuid(p.campaign_id, "campaign_id"),
    p_action: v.oneOf(p.action, "action", ["approve", "reject", "pause", "resume", "cancel"] as const),
    p_reason: reason(p.reason),
  })],
  upsert_location: ["admin_upsert_location", (p) => ({
    p_level: v.oneOf(p.level, "level", ["country", "region", "city", "campus"] as const),
    p_id: optStr(p.id, "id", 40), p_parent: optStr(p.parent, "parent", 40),
    p_name: v.str(p.name, "name", { max: 120 }), p_short_name: optStr(p.short_name, "short_name", 40),
    p_enabled: v.bool(p.enabled, "enabled", true), p_kind: optStr(p.kind, "kind", 40),
  })],
  list_announcements: ["admin_list_announcements", () => ({})],
  upsert_announcement: ["admin_upsert_announcement", (p) => ({
    p_id: v.uuid(p.id, "id", true),
    p_title: v.str(p.title, "title", { min: 3, max: 120 }),
    p_body: v.str(p.body, "body", { max: 4000, multiline: true }),
    p_pinned: v.bool(p.pinned, "pinned", false),
  })],
  set_announcement_status: ["admin_set_announcement_status", (p) => ({
    p_id: v.uuid(p.id, "id"), p_status: v.oneOf(p.status, "status", ["draft", "published", "archived"] as const),
  })],
  list_referrals: ["admin_list_referrals", (p) => ({ p_limit: int(p.limit, 100, 500) })],
  revoke_credit: ["admin_revoke_credit", (p) => ({ p_credit_id: v.uuid(p.credit_id, "credit_id"), p_reason: reason(p.reason) })],
  list_promos: ["admin_list_promos", () => ({})],
  create_promo: ["admin_create_promo", (p) => ({
    p_code: v.str(p.code, "code", { min: 4, max: 24 }),
    p_kind: v.oneOf(p.kind, "kind", ["percent", "fixed"] as const),
    p_value: Number.isSafeInteger(p.value) && (p.value as number) > 0 ? p.value : (() => { throw new HttpError(400, "INVALID_FIELD", "value must be a positive whole number."); })(),
    p_max_uses: p.max_uses === null || p.max_uses === undefined || p.max_uses === "" ? null : int(p.max_uses, 1, 1000000) || null,
    p_per_user: int(p.per_user, 1, 1000) || 1,
    p_expires: p.expires_at ? v.isoDate(p.expires_at, "expires_at") : null,
  })],
  set_promo_enabled: ["admin_set_promo_enabled", (p) => ({ p_id: v.uuid(p.id, "id"), p_enabled: v.bool(p.enabled, "enabled", true) })],
  audit_log: ["admin_audit_entries", (p) => ({ p_limit: int(p.limit, 100, 500), p_offset: int(p.offset, 0, 100000) })],
  leaderboard_diagnostics: ["admin_leaderboard_diagnostics", () => ({})],
  revoke_referral_credits: ["admin_revoke_referral_credits", (p) => ({
    p_referred_user_id: v.uuid(p.referred_user_id, "referred_user_id") as string,
    p_reason: v.str(p.reason, "Reason", { min: 5, max: 500, multiline: true }),
  })],
  waive_order: ["admin_waive_order", (p) => ({
    p_order_ref: v.orderRef(p.order_ref),
    p_reason: v.str(p.reason, "Reason", { min: 5, max: 500, multiline: true }),
  })],
  // Owner-only: SQL re-checks require_owner(); an Admin's call is rejected with 403.
  owner_delete: ["owner_delete_record", (p) => ({
    p_kind: v.oneOf(p.kind, "kind", ["report", "note", "announcement", "campaign", "referral", "audit_entry", "country", "region", "city", "campus"] as const),
    p_id: v.str(p.id, "id", { min: 1, max: 40 }),
    p_confirm: v.str(p.confirm, "confirm", { min: 1, max: 20 }),
  })],
  owner_delete_preview: ["owner_delete_preview", (p) => ({
    p_kind: v.oneOf(p.kind, "kind", ["report", "note", "announcement", "campaign", "referral", "audit_entry", "country", "region", "city", "campus"] as const),
    p_id: v.str(p.id, "id", { min: 1, max: 40 }),
  })],
  // Admin or Owner (SQL re-checks require_admin()).
  delete_user_preview: ["admin_delete_user_preview", (p) => ({ p_user_id: v.uuid(p.user_id, "user_id") })],
  delete_user: ["admin_delete_user", (p) => ({
    p_user_id: v.uuid(p.user_id, "user_id"), p_confirm: v.str(p.confirm, "confirm", { min: 1, max: 20 }),
  })],
  find_note_by_receipt: ["admin_find_note_by_receipt", (p) => ({ p_order_ref: v.orderRef(p.order_ref) })],
  delete_note_by_receipt: ["admin_delete_note_by_receipt", (p) => ({
    p_order_ref: v.orderRef(p.order_ref), p_confirm: v.str(p.confirm, "confirm", { min: 1, max: 20 }),
  })],
  security_events: ["owner_list_security_events", (p) => ({ p_limit: int(p.limit, 100, 500) })],
  revenue_report: ["admin_revenue_report", (p) => {
    const from = typeof p.from === "string" && !Number.isNaN(Date.parse(p.from)) ? p.from : null;
    const to = typeof p.to === "string" && !Number.isNaN(Date.parse(p.to)) ? p.to : null;
    if (!from || !to) throw new HttpError(400, "INVALID_FIELD", "from and to must be dates.");
    return { p_from: from, p_to: to };
  }],
};

/** Throws 403 unless the caller is an admin (admin_check runs require_admin() in SQL). */
async function assertAdmin(userDb: Db, _user: AuthUser) {
  await rpc(userDb, "admin_check", {});
}

// Actions after which queued media files are deleted from Storage.
const PURGE_AFTER = new Set(["overview", "moderate_note", "owner_delete", "delete_user", "delete_note_by_receipt"]);

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req, 32 * 1024);
  const { user, jwt } = await requireUser(req, deps);
  await rateLimit(deps.db, `admin-api:user:${user.id}`, 120, 60);

  const action = typeof body.action === "string" ? body.action : "";
  const params = (body.params && typeof body.params === "object" && !Array.isArray(body.params) ? body.params : {}) as P;
  const userDb = deps.userDb(jwt);

  const sql = SQL_ACTIONS[action];
  if (sql) {
    const [fn, build] = sql;
    const data = await rpc(userDb, fn, build(params));
    // Removing/rejecting/deleting a note queues its files; delete them now (also on each overview load).
    if (PURGE_AFTER.has(action)) await purgeMediaOrphans(deps);
    if (action === "review_campaign" && (params.action === "approve" || params.action === "reject")) await emailAdvertiser(deps, userDb, params).catch((e) => console.error("Advertiser email skipped", e instanceof Error ? e.message : String(e)));
    return json(req, 200, { data }, deps.env);
  }

  if (action === "set_user_suspension") {
    const args = {
      p_user_id: v.uuid(params.user_id, "user_id"),
      p_suspend: v.bool(params.suspend, "suspend"),
      p_reason: reason(params.reason),
    };
    const data = await rpc(userDb, "admin_set_user_suspension", args);
    let authBan = "skipped";
    if (deps.setUserBan) {
      try {
        await deps.setUserBan(args.p_user_id!, args.p_suspend);
        authBan = "applied";
      } catch (err) {
        console.error("Auth ban update failed", err instanceof Error ? err.message : err);
        authBan = "failed";
      }
    }
    return json(req, 200, { data, auth_ban: authBan }, deps.env);
  }

  if (action === "reconcile_order") {
    await assertAdmin(userDb, user);
    const ref = v.orderRef(params.order_ref);
    const cfg = midtransConfig(deps.env);
    if (!cfg) throw new HttpError(503, "PAYMENTS_NOT_CONFIGURED");
    const status = await fetchTransactionStatus(cfg, ref, deps.fetch);
    if (status.status_code === "404" || status.order_id !== ref) {
      return json(req, 200, { data: { result: "not_found_at_provider" } }, deps.env);
    }
    const fallback = parseNotification({ ...status, signature_key: "n/a" });
    const data = await rpc(deps.db, "apply_payment_notification", statusToRpcArgs(status, fallback));
    return json(req, 200, { data }, deps.env);
  }

  if (action === "expire_stale_orders") {
    await assertAdmin(userDb, user);
    const data = await rpc(deps.db, "expire_stale_orders", {});
    return json(req, 200, { data: { expired: data } }, deps.env);
  }

  throw new HttpError(400, "UNKNOWN_ACTION", "Unknown admin action.");
};


/** Tells the advertiser a campaign was approved (payment due) or rejected. Best effort; see _shared/email.ts. */
async function emailAdvertiser(deps: Deps, userDb: Db, params: P) {
  const id = v.uuid(params.campaign_id, "campaign_id");
  // Read as the calling admin (admin_get_campaign re-checks admin status).
  const c = await rpc<{ title: string; contact_email: string; price: string | null; moderation_reason: string | null } | null>(
    userDb, "admin_get_campaign", { p_campaign_id: id });
  if (!c?.contact_email) return;
  const site = (deps.env("SITE_URL") ?? "").replace(/\/$/, "");
  const approved = params.action === "approve";
  const price = c.price != null ? `Rp${Number(c.price).toLocaleString("id-ID")}` : "the quoted price";
  await sendEmail(deps.env, deps.fetch, c.contact_email,
    approved ? `Approved: pay ${price} to schedule "${c.title}"` : `Your campaign "${c.title}" was not approved`,
    approved
      ? `Your campaign "${c.title}" was approved.\n\nPayment of ${price} is now due. It is scheduled as soon as you pay:\n${site}/#/advertise\n`
      : `Your campaign "${c.title}" was not approved.${c.moderation_reason ? `\n\nReason: ${c.moderation_reason}` : ""}\n\nYou can edit and submit it again:\n${site}/#/advertise\n`);
}
