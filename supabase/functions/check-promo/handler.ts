// POST /functions/v1/check-promo
//   { amount, decorations?, promo_code?, use_free_post? }
// Read-only price preview for the compose page: shows the discounted total before
// the customer pays. Nothing is reserved here; the real check happens again,
// atomically, in create_publication_order_v2. Requires an account (the per-user
// limit needs an identity) and is rate limited because it can be used to guess codes.

import { type Deps, type Handler, requireUser } from "../_shared/auth.ts";
import { clientIp, json, rateLimit, readJson, rpc } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user } = await requireUser(req, deps);
  await rateLimit(deps.db, `promo:ip:${clientIp(req)}`, 15, 600);
  await rateLimit(deps.db, `promo:user:${user.id}`, 15, 600);
  const quote = await rpc(deps.db, "quote_post_discount", {
    p_user_id: user.id,
    p_amount: v.amount(body.amount),
    p_decorations: v.idList(body.decorations, "Decorations", 10),
    p_code: v.promoCode(body.promo_code),
    p_use_free: v.bool(body.use_free_post, "use_free_post", false),
  });
  return json(req, 200, { quote }, deps.env);
};
