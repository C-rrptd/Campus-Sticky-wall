// deno test supabase/functions/username-login/
import { strictEqual as assertEquals } from "node:assert";
import { handler } from "./handler.ts";
import type { Deps } from "../_shared/auth.ts";

function deps(email: string | null, upstream: { status: number; body: unknown }, sent: string[]): Deps {
  return {
    db: { rpc: (fn) => Promise.resolve({ data: fn === "login_email" ? email : true, error: null }) },
    userDb: () => { throw new Error("unused"); }, verifyJwt: () => Promise.resolve(null),
    fetch: ((_u: string, init: RequestInit) => { sent.push(String(init.body)); return Promise.resolve(new Response(JSON.stringify(upstream.body), { status: upstream.status })); }) as typeof fetch,
    env: (k) => (k === "SUPABASE_URL" ? "https://p.supabase.co" : k === "SUPABASE_PUBLISHABLE_KEY" ? "pk" : undefined),
  };
}
const post = (b: unknown) => new Request("https://f.test/username-login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(b) });

Deno.test("signs in with the email stored for the username", async () => {
  const sent: string[] = [];
  const res = await handler(post({ username: "Alice", password: "pw" }), deps("a@real.com", { status: 200, body: { access_token: "t", refresh_token: "r" } }, sent));
  assertEquals(res.status, 200);
  assertEquals(JSON.parse(sent[0]).email, "a@real.com");
});

Deno.test("unknown username falls back to the placeholder address", async () => {
  const sent: string[] = [];
  await handler(post({ username: "Tester1", password: "pw" }), deps(null, { status: 400, body: { error_code: "invalid_credentials" } }, sent)).catch(() => {});
  assertEquals(JSON.parse(sent[0]).email, "tester1@users.csw.invalid");
});

Deno.test("bad credentials and bad input are one generic 401", async () => {
  for (const b of [{ username: "alice", password: "bad" }, { username: "a b", password: "x" }]) {
    let status = 0;
    await handler(post(b), deps("a@real.com", { status: 400, body: { error_code: "invalid_credentials" } }, [])).catch((e) => { status = e.status; });
    assertEquals(status, 401);
  }
});
