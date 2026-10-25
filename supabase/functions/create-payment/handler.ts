// POST /functions/v1/create-payment  { order_ref, access_token? }
// Creates (or reuses) the Midtrans Snap transaction for an existing unpaid
// order. The amount, items and allowed payment channels all come from the
// database record; nothing price-related is read from the request.

import { type Deps, type Handler, optionalUser } from "../_shared/auth.ts";
import { buildSnapBody, createSnapTransaction, midtransConfig, type SnapItem } from "../_shared/payments.ts";
import { clientIp, HttpError, json, rateLimit, readJson, rpc, sha256Hex } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

interface LockResult {
  reused: boolean;
  order_ref: string;
  token?: string;
  redirect_url?: string;
  total_amount?: string;
  enabled_payments?: string[];
  items?: SnapItem[];
}

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user } = await optionalUser(req, deps);
  const ref = v.orderRef(body.order_ref);
  const token = v.accessToken(body.access_token);
  if (!user && !token) throw new HttpError(401, "AUTH_REQUIRED", "Sign in or use your receipt link.");

  await rateLimit(deps.db, `create-payment:ip:${clientIp(req)}`, 30, 600);
  await rateLimit(deps.db, `create-payment:order:${ref}`, 5, 600); // double-click / retry storms on one order

  const cfg = midtransConfig(deps.env);
  if (!cfg) {
    throw new HttpError(503, "PAYMENTS_NOT_CONFIGURED", "Online payments are not configured yet. Your order was saved; please try again later.");
  }
  const siteUrl = deps.env("SITE_URL");
  if (!siteUrl?.startsWith("https://") && !siteUrl?.startsWith("http://localhost")) {
    throw new HttpError(503, "SITE_URL_NOT_CONFIGURED", "Payments are not configured yet.");
  }

  const lock = await rpc<LockResult>(deps.db, "lock_order_for_payment", {
    p_order_ref: ref,
    p_user_id: user?.id ?? null,
    p_token_hash: token ? await sha256Hex(token) : null,
  });
  if (lock.reused) {
    return json(req, 200, { order_ref: ref, redirect_url: lock.redirect_url, reused: true }, deps.env);
  }

  try {
    const snapBody = buildSnapBody({
      orderRef: ref,
      grossAmount: lock.total_amount!,
      items: lock.items!,
      enabledPayments: lock.enabled_payments!,
      // Midtrans appends order_id/status_code/transaction_status. The hash route
      // works whether those land in the query (app.js reads order_id) or after
      // the fragment (the router still sees order=...).
      finishUrl: `${siteUrl.replace(/\/$/, "")}/#/checkout?order=${encodeURIComponent(ref)}&returned=1`,
      expiryMinutes: 30, // matches record_payment_session (+5 min grace) and the 30-minute unpaid-post rule
    });
    const session = await createSnapTransaction(cfg, snapBody, deps.fetch);
    await rpc(deps.db, "record_payment_session", {
      p_order_ref: ref,
      p_token: session.token,
      p_redirect_url: session.redirect_url,
    });
    return json(req, 200, { order_ref: ref, redirect_url: session.redirect_url, reused: false }, deps.env);
  } catch (err) {
    // Let the customer retry; the order and its amount stay unchanged.
    await deps.db.rpc("release_payment_lock", { p_order_ref: ref });
    throw err;
  }
};

