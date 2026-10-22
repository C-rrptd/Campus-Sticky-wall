// POST /functions/v1/redeem-referral-credit  { order_ref, apply: boolean }
// Atomically reserves (apply=true) or releases (apply=false) one referral
// credit on the caller's own unpaid publication order. A reserved credit is
// consumed only when the publication succeeds; if the total becomes zero the
// note is published immediately without payment.

import { type Deps, type Handler, requireUser } from "../_shared/auth.ts";
import { json, rateLimit, readJson, rpc } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user } = await requireUser(req, deps);
  await rateLimit(deps.db, `redeem-referral-credit:user:${user.id}`, 30, 600);

  const order = await rpc(deps.db, "set_order_credit", {
    p_order_ref: v.orderRef(body.order_ref),
    p_user_id: user.id,
    p_apply: v.bool(body.apply, "apply", true),
  });
  return json(req, 200, { order }, deps.env);
};

