// POST /functions/v1/ad-maintenance   header: x-cron-secret: <CRON_SECRET>
// Runs the advertising background jobs (report emails, waitlist holds, auctions). Call it every 5 minutes from a
// scheduler (see OPERATIONS.md). verify_jwt is off; the shared secret is the only way in.

import { type Deps, type Handler } from "../_shared/auth.ts";
import { HttpError, json, timingSafeEqual } from "../_shared/security.ts";
import { runAdJobs } from "../_shared/ad_jobs.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const secret = deps.env("CRON_SECRET");
  const given = req.headers.get("x-cron-secret") ?? "";
  if (!secret || secret.length < 16 || !timingSafeEqual(given, secret)) throw new HttpError(401, "UNAUTHORIZED");
  return json(req, 200, { data: await runAdJobs(deps) }, deps.env);
};
