// POST /functions/v1/leaderboard-data  { kind: "referrals"|"donations", period: "all"|"week" }
// Public rankings. Signed-in callers run the SQL as themselves (so is_me works);
// guests run it with auth.uid() = null. Donor-privacy opt-ins apply either way.

import { type Deps, type Handler, optionalUser } from "../_shared/auth.ts";
import { clientIp, json, rateLimit, readJson, rpc } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user, jwt } = await optionalUser(req, deps);
  await rateLimit(deps.db, user ? `leaderboard:user:${user.id}` : `leaderboard:ip:${clientIp(req)}`, 60, 60);

  const data = await rpc(jwt ? deps.userDb(jwt) : deps.db, "leaderboard", {
    p_kind: v.oneOf(body.kind, "kind", ["referrals", "donations"] as const),
    p_period: v.oneOf(body.period ?? "all", "period", ["all", "week"] as const),
    p_limit: 25,
  });
  const res = json(req, 200, data, deps.env);
  res.headers.set("Cache-Control", "private, no-store");
  return res;
};

