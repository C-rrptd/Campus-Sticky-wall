// POST /functions/v1/leaderboard-data  { kind: "referrals"|"donations", period: "all"|"week" }
// Account-only rankings. Runs the SQL function as the caller (their JWT), so
// the database itself refuses guests and applies donor-privacy opt-ins.

import { type Deps, type Handler, requireUser } from "../_shared/auth.ts";
import { json, rateLimit, readJson, rpc } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user, jwt } = await requireUser(req, deps);
  await rateLimit(deps.db, `leaderboard:user:${user.id}`, 60, 60);

  const data = await rpc(deps.userDb(jwt), "leaderboard", {
    p_kind: v.oneOf(body.kind, "kind", ["referrals", "donations"] as const),
    p_period: v.oneOf(body.period ?? "all", "period", ["all", "week"] as const),
    p_limit: 25,
  });
  const res = json(req, 200, data, deps.env);
  res.headers.set("Cache-Control", "private, no-store");
  return res;
};

