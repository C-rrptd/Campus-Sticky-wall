// GET  /functions/v1/digest-unsubscribe?u=<user id>&t=<hmac>  -> confirmation page (mail scanners that open links change nothing)
// POST same URL (button on that page, or the mail app's one-click List-Unsubscribe-Post) -> unsubscribes
import { type Deps, type Handler } from "../_shared/auth.ts";
import { HttpError, rpc, timingSafeEqual } from "../_shared/security.ts";
import { unsubToken } from "../_shared/digest.ts";

const page = (body: string) => new Response(
  `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Daily email</title><main style="font:16px system-ui;margin:3rem auto;max-width:30rem;padding:0 1rem">${body}</main>`,
  { status: 200, headers: { "content-type": "text/html; charset=utf-8", "x-content-type-options": "nosniff", "cache-control": "no-store" } },
);

export const handler: Handler = async (req: Request, deps: Deps) => {
  const url = new URL(req.url);
  const u = url.searchParams.get("u") ?? "", t = url.searchParams.get("t") ?? "";
  const secret = deps.env("CRON_SECRET") ?? "";
  if (!/^[0-9a-f-]{36}$/.test(u) || secret.length < 16 || !timingSafeEqual(t, await unsubToken(secret, u))) throw new HttpError(400, "BAD_LINK");
  if (req.method === "POST") {
    await rpc(deps.db, "set_digest_for", { p_user: u, p_on: false });
    return page("<p>You will no longer get the daily top-note email. You can turn it back on in your profile.</p>");
  }
  return page(`<p>Stop the daily top-note email?</p><form method=post><button style="font:inherit;padding:.5rem 1rem">Yes, unsubscribe</button></form>`);
};
