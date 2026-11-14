// POST /functions/v1/doku-webhook  (DOKU HTTP notification)
// verify_jwt is disabled for this function (DOKU cannot send a Supabase JWT).
// Authenticity is the DOKU Signature header: HMAC-SHA256 of Client-Id, Request-Id,
// Request-Timestamp, Request-Target and the body Digest, keyed with the secret key.
// A bad signature is rejected. The database then checks order id and amount against
// the stored order and applies an idempotent, transition-checked state change.
// Set the Notification URL in DOKU Back Office to https://<project>.supabase.co/functions/v1/doku-webhook

import { type Deps, type Handler } from "../_shared/auth.ts";
import { dokuConfig, parsePayload, statusToRpcArgs, verifyNotification } from "../_shared/payments.ts";
import { clientIp, HttpError, json, rateLimit, rpc } from "../_shared/security.ts";

const MAX_BYTES = 64 * 1024;
// Request-Target is the path DOKU was given. Behind the Supabase gateway the runtime may or may not see the
// "/functions/v1" prefix, so accept both spellings.
const FULL_PATH = "/functions/v1/doku-webhook";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const cfg = dokuConfig(deps.env);
  if (!cfg) throw new HttpError(503, "PAYMENTS_NOT_CONFIGURED");
  if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED", "Use POST.");
  if (Number(req.headers.get("content-length") ?? "0") > MAX_BYTES) throw new HttpError(413, "PAYLOAD_TOO_LARGE");

  await rateLimit(deps.db, `doku-webhook:ip:${clientIp(req)}`, 600, 60);
  const raw = await req.text();
  if (raw.length > MAX_BYTES) throw new HttpError(413, "PAYLOAD_TOO_LARGE");

  const seen = new URL(req.url).pathname;
  if (!(await verifyNotification(cfg, req.headers, raw, [...new Set([FULL_PATH, seen])]))) {
    console.warn("DOKU notification signature mismatch", { path: seen });
    throw new HttpError(401, "INVALID_SIGNATURE");
  }

  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new HttpError(400, "INVALID_JSON", "Malformed JSON.");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new HttpError(400, "INVALID_JSON", "Expected a JSON object.");

  const status = parsePayload(body as Record<string, unknown>);
  const result = await rpc<{ result: string }>(deps.db, "apply_payment_notification", statusToRpcArgs(status));
  return json(req, 200, result, deps.env);
};
