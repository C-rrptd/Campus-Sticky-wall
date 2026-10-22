// POST /functions/v1/manage-guest-publication
//   { action: "receipt" | "withdraw", order_ref, access_token? }
// Receipt access for guests (high-entropy token, only its hash is stored) and
// for signed-in owners. The only mutation offered is withdrawing your own
// visible note. Failed lookups are rate limited per IP.

import { type Deps, type Handler, optionalUser } from "../_shared/auth.ts";
import { clientIp, HttpError, json, rateLimit, readJson, rpc, sha256Hex } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user } = await optionalUser(req, deps);
  const action = v.oneOf(body.action ?? "receipt", "action", ["receipt", "withdraw"] as const);
  const ref = v.orderRef(body.order_ref);
  const token = v.accessToken(body.access_token);
  if (!user && !token) throw new HttpError(401, "AUTH_REQUIRED", "Use the receipt link you received or sign in.");

  const ip = clientIp(req);
  await rateLimit(deps.db, `receipt:ip:${ip}`, 120, 600);

  const args = { p_order_ref: ref, p_user_id: user?.id ?? null, p_token_hash: token ? await sha256Hex(token) : null };
  try {
    const order = await rpc(deps.db, action === "withdraw" ? "withdraw_own_note" : "get_order_receipt", args);
    return json(req, 200, { order }, deps.env);
  } catch (err) {
    if (err instanceof HttpError && err.status === 404) {
      // Throttle guessing: at most 20 failed lookups per IP per 10 minutes.
      await rateLimit(deps.db, `receipt-miss:ip:${ip}`, 20, 600);
    }
    throw err;
  }
};

