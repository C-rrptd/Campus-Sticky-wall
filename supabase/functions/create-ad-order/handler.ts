// POST /functions/v1/create-ad-order  { campaign_id }
// Prices a draft campaign from trusted ad_products x validated targets and
// creates its payment order. The campaign stays inactive until payment is
// verified AND an administrator approves it.

import { type Deps, type Handler, requireUser } from "../_shared/auth.ts";
import { json, randomToken, rateLimit, readJson, rpc, sha256Hex } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user } = await requireUser(req, deps);
  await rateLimit(deps.db, `create-ad-order:user:${user.id}`, 10, 600);

  const accessToken = randomToken();
  const order = await rpc(deps.db, "create_ad_order", {
    p_owner: user.id,
    p_campaign_id: v.uuid(body.campaign_id, "Campaign"),
    p_guest_token_hash: await sha256Hex(accessToken),
  });
  return json(req, 201, { order, access_token: accessToken }, deps.env);
};

