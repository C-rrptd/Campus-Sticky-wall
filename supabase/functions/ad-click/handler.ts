// GET /functions/v1/ad-click?c=<campaign id>&country=..&region=..&city=..&campus=..&ref=<host>&us=..&um=..&uc=..&adm=1
// Counts the click on the server (an ad blocker cannot hide a redirect), then sends the visitor to the campaign's own
// https link read from the database. The destination is NEVER taken from the URL, so this is not an open redirect.
// Counting never blocks the visitor: if it fails they still reach the advertiser.

import { type Deps, type Handler } from "../_shared/auth.ts";
import { clientIp, rateLimit, rpc } from "../_shared/security.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HOST = /^[a-z0-9]([a-z0-9.-]{0,98}[a-z0-9])?$/i;

const uuidOrNull = (v: string | null) => (v && UUID.test(v) ? v : null);
const clip = (v: string | null, n: number) => (v ? v.trim().slice(0, n) || null : null);

/** "https://www.instagram.com/x?y" -> "www.instagram.com"; bare hosts pass; anything else -> null. */
export function hostOf(v: string | null): string | null {
  if (!v) return null;
  try {
    const h = v.includes("/") ? new URL(v).hostname : v;
    return HOST.test(h) ? h.toLowerCase() : null;
  } catch {
    return null;
  }
}

const go = (to: string) =>
  new Response(null, { status: 302, headers: { location: to, "cache-control": "no-store", "referrer-policy": "no-referrer" } });

export const handler: Handler = async (req: Request, deps: Deps) => {
  const q = new URL(req.url).searchParams;
  const site = (deps.env("SITE_URL") ?? "").replace(/\/$/, "") || "/";
  const id = q.get("c") ?? "";
  if (!UUID.test(id)) return go(site);

  const dest = await rpc<string | null>(deps.db, "ad_click_target", { p_campaign_id: id });
  if (!dest || !dest.startsWith("https://")) return go(site);

  try {
    const ua = req.headers.get("user-agent") ?? "";
    await rateLimit(deps.db, `ad-click:ip:${clientIp(req)}`, 60, 60); // over the limit: skip counting, still redirect
    const hash = await rpc<string>(deps.db, "visitor_hash", { p_ip: clientIp(req), p_ua: ua });
    const country = q.get("country");
    await rpc(deps.db, "record_ad_event", {
      p_campaign_id: id, p_kind: "click", p_visitor_hash: hash, p_ua: ua,
      p_is_admin: q.get("adm") === "1",     // set by the page for a signed-in admin; only ever REDUCES counts
      p_country: country && /^[A-Za-z]{2}$/.test(country) ? country : null,
      p_region: uuidOrNull(q.get("region")), p_city: uuidOrNull(q.get("city")), p_campus: uuidOrNull(q.get("campus")),
      p_referrer_host: hostOf(q.get("ref")) ?? hostOf(req.headers.get("referer")),
      p_utm_source: clip(q.get("us"), 60), p_utm_medium: clip(q.get("um"), 60), p_utm_campaign: clip(q.get("uc"), 80),
    });
  } catch (err) {
    console.error("ad-click count failed", err instanceof Error ? err.message : String(err));
  }
  return go(dest);
};
