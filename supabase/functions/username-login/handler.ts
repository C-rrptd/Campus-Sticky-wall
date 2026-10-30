// POST /functions/v1/username-login  { username, password } -> { access_token, refresh_token, ... }
// Resolves the username to its email server-side and signs in, so emails never reach the browser.
// Every failure is the same 401, so it never reveals whether a username exists.

import { type Deps, type Handler, publishableKey } from "../_shared/auth.ts";
import { clientIp, HttpError, json, rateLimit, readJson, rpc } from "../_shared/security.ts";

const USERNAME = /^[A-Za-z0-9_.-]{3,30}$/;

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const username = typeof body.username === "string" ? body.username.trim() : "";
  const password = typeof body.password === "string" ? body.password : "";
  if (!USERNAME.test(username) || !password || password.length > 200) throw new HttpError(401, "INVALID_LOGIN", "Username or password is incorrect.");
  await rateLimit(deps.db, `username-login:ip:${clientIp(req)}`, 20, 60);
  await rateLimit(deps.db, `username-login:user:${username.toLowerCase()}`, 10, 300);

  // Script-made accounts (no profile username) sign in with the placeholder address.
  const email = (await rpc<string | null>(deps.db, "login_email", { p_username: username })) ?? `${username.toLowerCase()}@users.csw.invalid`;
  const key = publishableKey(deps.env);
  const res = await deps.fetch(`${deps.env("SUPABASE_URL")}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: key ?? "", "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const session = await res.json().catch(() => ({}));
  if (!res.ok || !session.access_token) {
    if (session?.error_code === "email_not_confirmed") throw new HttpError(401, "EMAIL_NOT_CONFIRMED", "Please verify your email first — check your inbox for the confirmation link.");
    throw new HttpError(401, "INVALID_LOGIN", "Username or password is incorrect.");
  }
  const out = json(req, 200, { access_token: session.access_token, refresh_token: session.refresh_token }, deps.env);
  out.headers.set("Cache-Control", "no-store");
  return out;
};
