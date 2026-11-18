// GET/POST /functions/v1/digest-unsubscribe?u=<user id>&t=<hmac>   (link in every digest email; POST = one-click)
import { type Deps, type Handler } from "../_shared/auth.ts";
import { HttpError, rpc, timingSafeEqual } from "../_shared/security.ts";
import { unsubToken } from "../_shared/digest.ts";

export const handler: Handler = async (req: Request, deps: Deps) => {
  const url = new URL(req.url);
  const u = url.searchParams.get("u") ?? "", t = url.searchParams.get("t") ?? "";
  const secret = deps.env("CRON_SECRET") ?? "";
  if (!/^[0-9a-f-]{36}$/.test(u) || secret.length < 16 || !timingSafeEqual(t, await unsubToken(secret, u))) throw new HttpError(400, "BAD_LINK");
  await rpc(deps.db, "set_digest_for", { p_user: u, p_on: false });
  return new Response("<!doctype html><meta charset=utf-8><title>Unsubscribed</title><p style=\"font:16px system-ui;margin:3rem auto;max-width:30rem\">You will no longer get the daily top-note email. You can turn it back on in your profile.</p>",
    { status: 200, headers: { "content-type": "text/html; charset=utf-8", "x-content-type-options": "nosniff" } });
};
