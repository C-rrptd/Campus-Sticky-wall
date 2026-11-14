// deno test supabase/functions/doku-webhook/
import { strictEqual as assertEquals } from "node:assert";
import { createHash, createHmac } from "node:crypto";
import { handler } from "./handler.ts";
import type { Deps } from "../_shared/auth.ts";

const SECRET = "SK-TEST";
const calls: { fn: string; args: Record<string, unknown> }[] = [];
const deps: Deps = {
  db: { rpc: (fn, args) => { calls.push({ fn, args }); return Promise.resolve({ data: fn === "check_rate_limit" ? true : { result: "paid" }, error: null }); } },
  userDb: () => { throw new Error("unused"); }, verifyJwt: () => Promise.resolve(null),
  fetch: (() => { throw new Error("webhook must not call out"); }) as typeof fetch,
  env: (k) => ({ DOKU_CLIENT_ID: "BRN-1", DOKU_SECRET_KEY: SECRET })[k],
};
const body = JSON.stringify({ order: { invoice_number: "CSW-P-0123456789abcdef", amount: 20000 }, transaction: { status: "SUCCESS", original_request_id: "r1" }, channel: { id: "QRIS_DOKU" } });
function req(sigBody = body, target = "/functions/v1/doku-webhook") {
  const lines = `Client-Id:BRN-1\nRequest-Id:abc\nRequest-Timestamp:2026-11-14T02:00:00Z\nRequest-Target:${target}\nDigest:${createHash("sha256").update(sigBody).digest("base64")}`;
  return new Request("https://p.supabase.co/functions/v1/doku-webhook", {
    method: "POST",
    headers: { "content-type": "application/json", "client-id": "BRN-1", "request-id": "abc", "request-timestamp": "2026-11-14T02:00:00Z", signature: "HMACSHA256=" + createHmac("sha256", SECRET).update(lines).digest("base64") },
    body,
  });
}

Deno.test("valid signed SUCCESS notification is applied", async () => {
  calls.length = 0;
  const res = await handler(req(), deps);
  assertEquals(res.status, 200);
  const rpc = calls.find((c) => c.fn === "apply_payment_notification")!;
  assertEquals(rpc.args.p_order_ref, "CSW-P-0123456789abcdef");
  assertEquals(rpc.args.p_transaction_status, "settlement");
  assertEquals(rpc.args.p_gross_amount, "20000");
});

Deno.test("bad signature is rejected and nothing is applied", async () => {
  calls.length = 0;
  let status = 0;
  await handler(req(body.replace("20000", "1")), deps).catch((e) => { status = e.status; });
  assertEquals(status, 401);
  assertEquals(calls.some((c) => c.fn === "apply_payment_notification"), false);
});
