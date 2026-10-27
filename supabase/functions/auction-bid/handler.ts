// POST /functions/v1/auction-bid  { auction_id, campaign_id, amount?, buy_now? }
// Places a bid for the signed-in user. Every rule (verified email, strikes, reserve, minimum raise, anti-sniping,
// buy-now, flags) lives in the place_bid SQL function; this layer authenticates, rate-limits (a limiter that persists
// even when the bid is rejected) and passes the caller's IP for multi-account detection.

import { type Deps, type Handler, requireUser } from "../_shared/auth.ts";
import { clientIp, json, rateLimit, readJson, rpc } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user } = await requireUser(req, deps);
  const ip = clientIp(req);
  await rateLimit(deps.db, `auction-bid:user:${user.id}`, 30, 60);
  await rateLimit(deps.db, `auction-bid:ip:${ip}`, 90, 60);
  const buyNow = body.buy_now === true;
  // Whole rupiah only. Sent as a string or number; the SQL function enforces the minimum and the buy-now cap.
  const amount = buyNow ? "1" : v.amount(body.amount, "Bid");
  const result = await rpc(deps.db, "place_bid", {
    p_bidder: user.id,
    p_auction: v.uuid(body.auction_id, "Auction"),
    p_campaign: v.uuid(body.campaign_id, "Ad"),
    p_amount: amount,
    p_ip: ip,
    p_buy_now: buyNow,
  });
  return json(req, 200, result, deps.env);
};
