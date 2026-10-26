// POST /functions/v1/midtrans-webhook  (Midtrans HTTP notification)
// verify_jwt is disabled for this function (Midtrans cannot send a Supabase
// JWT). Authenticity is established by:
//   1. the SHA-512 signature_key over order_id+status_code+gross_amount+server key, and
//   2. re-reading the transaction from the Midtrans Get Status API.
// Only the verified status is applied. The database then checks order id,
// amount and currency against the stored order and applies an idempotent,
// transition-checked state change.

import { type Deps, type Handler } from "../_shared/auth.ts";
import {
  fetchTransactionStatus,
  midtransConfig,
  parseNotification,
  statusToRpcArgs,
  verifySignature,
} from "../_shared/payments.ts";
import { clientIp, HttpError, json, rateLimit, readJson, rpc } from "../_shared/security.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const cfg = midtransConfig(deps.env);
  if (!cfg) throw new HttpError(503, "PAYMENTS_NOT_CONFIGURED");

  const body = await readJson(req, 64 * 1024);
  await rateLimit(deps.db, `midtrans-webhook:ip:${clientIp(req)}`, 600, 60);
  const notification = parseNotification(body);

  if (!(await verifySignature(notification, cfg.serverKey))) {
    console.warn("Rejected notification with invalid signature", { order: notification.order_id.slice(0, 50) });
    throw new HttpError(401, "INVALID_SIGNATURE");
  }

  const status = await fetchTransactionStatus(cfg, notification.order_id, deps.fetch);
  // Unknown order (also what Midtrans' "Test notification URL" sends): ack with 200. Must precede the order_id check.
  if (String(status.status_code) === "404") {
    return json(req, 200, { result: "unknown_transaction" }, deps.env);
  }
  if (status.order_id !== notification.order_id) {
    throw new HttpError(409, "STATUS_ORDER_MISMATCH");
  }

  const result = await rpc<{ result: string }>(deps.db, "apply_payment_notification", statusToRpcArgs(status, notification));
  return json(req, 200, result, deps.env);
};

