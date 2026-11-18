// POST /functions/v1/daily-digest   header: x-cron-secret: <CRON_SECRET>
// Call hourly (see OPERATIONS.md). Each member is emailed once per local day, from 8 AM in their university's time zone.

import { type Deps, type Handler } from "../_shared/auth.ts";
import { HttpError, json, timingSafeEqual } from "../_shared/security.ts";
import { sendDigests } from "../_shared/digest.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const secret = deps.env("CRON_SECRET");
  const given = req.headers.get("x-cron-secret") ?? "";
  if (!secret || secret.length < 16 || !timingSafeEqual(given, secret)) throw new HttpError(401, "UNAUTHORIZED");
  return json(req, 200, { data: await sendDigests(deps) }, deps.env);
};
