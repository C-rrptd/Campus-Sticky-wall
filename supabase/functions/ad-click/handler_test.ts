// deno test supabase/functions/ad-click/
import { strictEqual as assertEquals } from "node:assert";
import { handler, hostOf } from "./handler.ts";
import type { Deps } from "../_shared/auth.ts";

const ID = "11111111-2222-3333-4444-555555555555";

function deps(dest: string | null, calls: Array<[string, Record<string, unknown>]>): Deps {
  return {
    db: { rpc: (fn, args) => { calls.push([fn, args]); return Promise.resolve({ data: fn === "ad_click_target" ? dest : fn === "visitor_hash" ? "h" : true, error: null }); } },
    userDb: () => { throw new Error("unused"); }, verifyJwt: () => Promise.resolve(null), fetch,
    env: (k) => (k === "SITE_URL" ? "https://site.test" : undefined),
  };
}
const get = (qs: string, headers: HeadersInit = {}) => new Request(`https://f.test/ad-click?${qs}`, { headers });

Deno.test("hostOf keeps only a clean hostname", () => {
  assertEquals(hostOf("https://www.Instagram.com/p/x?y=1"), "www.instagram.com");
  assertEquals(hostOf("instagram.com"), "instagram.com");
  assertEquals(hostOf("javascript:alert(1)"), null);
  assertEquals(hostOf("<script>"), null);
});

Deno.test("redirects to the stored link and counts the click with referrer + utm", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const res = await handler(get(`c=${ID}&ref=https://instagram.com/x&us=ig&campus=${ID}`, { "user-agent": "Mozilla/5.0 Firefox" }), deps("https://shop.example/promo", calls));
  assertEquals(res.status, 302);
  assertEquals(res.headers.get("location"), "https://shop.example/promo");
  const ev = calls.find(([f]) => f === "record_ad_event")![1];
  assertEquals(ev.p_kind, "click"); assertEquals(ev.p_referrer_host, "instagram.com"); assertEquals(ev.p_utm_source, "ig"); assertEquals(ev.p_campus, ID);
});

Deno.test("destination can never come from the URL; unknown or non-live campaign goes home", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const res = await handler(get(`c=${ID}&to=https://evil.example`), deps(null, calls));
  assertEquals(res.headers.get("location"), "https://site.test");
  assertEquals(calls.some(([f]) => f === "record_ad_event"), false);
  assertEquals((await handler(get("c=nope"), deps("https://x.y", []))).headers.get("location"), "https://site.test");
});

Deno.test("a counting failure still reaches the advertiser", async () => {
  const d = deps("https://shop.example/promo", []);
  d.db.rpc = (fn) => Promise.resolve(fn === "ad_click_target" ? { data: "https://shop.example/promo", error: null } : { data: null, error: { message: "boom" } });
  assertEquals((await handler(get(`c=${ID}`), d)).headers.get("location"), "https://shop.example/promo");
});
