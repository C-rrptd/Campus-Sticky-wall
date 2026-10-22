// POST /functions/v1/create-donation  { amount, confirm_amount }
// Creates a voluntary donation order (separate from any purchase). Payment is
// started afterwards through create-payment.

import { type Deps, type Handler, optionalUser } from "../_shared/auth.ts";
import { clientIp, json, randomToken, rateLimit, readJson, rpc, sha256Hex } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user } = await optionalUser(req, deps);
  await rateLimit(deps.db, `create-donation:ip:${clientIp(req)}`, 10, 600);

  const amount = v.amount(body.amount);
  if (body.confirm_amount !== amount) {
    return json(req, 400, { error: { code: "AMOUNT_NOT_CONFIRMED", message: "Please confirm your donation amount." } }, deps.env);
  }
  const accessToken = randomToken();
  const order = await rpc(deps.db, "create_donation_order", {
    p_user_id: user?.id ?? null,
    p_amount: amount,
    p_guest_token_hash: await sha256Hex(accessToken),
  });
  return json(req, 201, { order, access_token: accessToken }, deps.env);
};

