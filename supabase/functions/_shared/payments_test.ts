// Run with: deno test supabase/functions/_shared/
// Covers the money and trust-boundary code: DOKU signatures, Checkout body, status mapping, request reader, input validation.
import { createHash, createHmac } from "node:crypto";
import { buildCheckoutBody, dokuConfig, parsePayload, statusToRpcArgs, verifyNotification } from "./payments.ts";
import { HttpError, readJson, timingSafeEqual } from "./security.ts";
import * as v from "./validation.ts";

const SECRET = "SK-TESTKEY";
const CFG = dokuConfig((k) => ({ DOKU_CLIENT_ID: "BRN-0001-TEST", DOKU_SECRET_KEY: SECRET })[k])!;

function eq(actual: unknown, expected: unknown, msg: string) {
  if (actual !== expected) throw new Error(`${msg}: expected ${String(expected)}, got ${String(actual)}`);
}
async function throwsHttp(fn: () => unknown, status: number, code?: string) {
  try {
    await fn();
  } catch (e) {
    if (e instanceof HttpError && e.status === status && (code === undefined || e.code === code)) return;
    throw new Error(`wrong error: ${e instanceof Error ? e.message : String(e)} (wanted ${status} ${code ?? ""})`);
  }
  throw new Error(`expected HttpError ${status} ${code ?? ""}, nothing thrown`);
}
const jsonReq = (body: BodyInit | null, headers: Record<string, string> = { "content-type": "application/json" }) =>
  new Request("http://test.local/", { method: "POST", headers, body, duplex: "half" } as RequestInit);

/** Independent (node:crypto) implementation of DOKU's documented signature, to check ours against. */
function dokuSig(h: { cid: string; rid: string; ts: string; target: string; body: string }) {
  const digest = createHash("sha256").update(h.body).digest("base64");
  const lines = `Client-Id:${h.cid}\nRequest-Id:${h.rid}\nRequest-Timestamp:${h.ts}\nRequest-Target:${h.target}\nDigest:${digest}`;
  return "HMACSHA256=" + createHmac("sha256", SECRET).update(lines).digest("base64");
}

Deno.test("notification signature: matches DOKU's documented algorithm, rejects tampering", async () => {
  const body = JSON.stringify({ order: { invoice_number: "CSW-P-TEST", amount: 20000 }, transaction: { status: "SUCCESS" } });
  const h = { cid: "BRN-0001-TEST", rid: "req-1", ts: "2026-11-14T02:00:00Z", target: "/functions/v1/doku-webhook", body };
  const headers = (over: Record<string, string> = {}) =>
    new Headers({ "client-id": h.cid, "request-id": h.rid, "request-timestamp": h.ts, signature: dokuSig(h), ...over });
  const paths = [h.target];
  eq(await verifyNotification(CFG, headers(), body, paths), true, "valid");
  eq(await verifyNotification(CFG, headers(), body.replace("20000", "1"), paths), false, "changed body rejected");
  eq(await verifyNotification(CFG, headers(), body, ["/other"]), false, "wrong path rejected");
  eq(await verifyNotification(CFG, headers({ "client-id": "BRN-OTHER" }), body, paths), false, "wrong client id rejected");
  eq(await verifyNotification(CFG, headers({ signature: "" }), body, paths), false, "missing signature rejected");
  eq(timingSafeEqual("abc", "abcd"), false, "different length");
  eq(timingSafeEqual("abc", "abc"), true, "equal");
});

Deno.test("parsePayload: status mapping, amount, privacy of stored raw", async () => {
  const base = { order: { invoice_number: "CSW-P-TEST", amount: 20000 }, channel: { id: "QRIS_DOKU" }, customer: { name: "Budi", email: "b@x.id" } };
  const ok = parsePayload({ ...base, transaction: { status: "SUCCESS", original_request_id: "r1" } });
  eq(ok.status, "settlement", "SUCCESS");
  eq(ok.amount, "20000", "amount");
  eq(ok.channel, "qris_doku", "channel");
  eq(JSON.stringify(ok.raw).includes("Budi"), false, "customer data not stored");
  eq(parsePayload({ ...base, transaction: { status: "FAILED" } }).status, "pending", "FAILED is retryable on Checkout");
  eq(parsePayload({ ...base, transaction: { status: "EXPIRED" } }).status, "expire", "EXPIRED");
  eq(parsePayload({ ...base, transaction: { status: "REFUNDED" } }).status, "refund", "REFUNDED");
  const args = statusToRpcArgs(ok);
  eq(args.p_transaction_status, "settlement", "rpc status");
  eq(args.p_gross_amount, "20000", "rpc amount");
  eq(args.p_currency, "IDR", "rpc currency");
  await throwsHttp(() => parsePayload({ order: { invoice_number: "x" } }), 400, "INVALID_NOTIFICATION");
  await throwsHttp(() => parsePayload({}), 400, "INVALID_NOTIFICATION");
});

Deno.test("buildCheckoutBody: integer amount, channels upper-cased, discount lines, totals must match", async () => {
  const base = { orderRef: "CSW-P-TEST", enabledPayments: ["qris", "virtual_account_bca"], finishUrl: "https://example.test/#/checkout" };
  const body = JSON.parse(buildCheckoutBody({ ...base, items: [{ id: "a", name: "Note", price: "25000", quantity: 1 }], grossAmount: "25000", expiryMinutes: 30 }));
  eq(body.order.amount, 25000, "amount");
  eq(body.order.invoice_number, "CSW-P-TEST", "invoice");
  eq(body.payment.payment_due_date, 30, "expiry");
  eq(body.payment.payment_method_types.join(), "QRIS,VIRTUAL_ACCOUNT_BCA", "channels");
  eq("payment_method_types" in JSON.parse(buildCheckoutBody({ ...base, enabledPayments: [], grossAmount: "1500", items: [{ id: "a", name: "n", price: "1500", quantity: 1 }] })).payment, false, "empty = all channels");

  const withDiscount = buildCheckoutBody({
    ...base,
    grossAmount: "1500",
    items: [{ id: "a", name: "Note", price: "2500", quantity: 1 }, { id: "d", name: "Promo", price: "-1000", quantity: 1 }],
  });
  eq(JSON.parse(withDiscount).order.amount, 1500, "discount applied");

  await throwsHttp(() => buildCheckoutBody({ ...base, grossAmount: "2500", items: [{ id: "a", name: "n", price: "2400", quantity: 1 }] }), 500, "ORDER_TOTAL_MISMATCH");
  await throwsHttp(() => buildCheckoutBody({ ...base, grossAmount: "0", items: [] }), 400, "INVALID_AMOUNT");
  await throwsHttp(() => buildCheckoutBody({ ...base, grossAmount: "12.5", items: [] }), 400, "INVALID_AMOUNT");
  await throwsHttp(() => buildCheckoutBody({ ...base, grossAmount: "1" + "0".repeat(12), items: [] }), 400, "INVALID_AMOUNT");
});

Deno.test("dokuConfig: missing credentials, endpoints", () => {
  eq(dokuConfig(() => undefined), null, "no credentials");
  eq(dokuConfig((k) => ({ DOKU_CLIENT_ID: "a" })[k]), null, "no secret");
  eq(CFG.apiBase, "https://api-sandbox.doku.com", "sandbox base");
  eq(dokuConfig((k) => ({ DOKU_CLIENT_ID: "a", DOKU_SECRET_KEY: "b", DOKU_IS_PRODUCTION: "true" })[k])?.apiBase, "https://api.doku.com", "production base");
});

Deno.test("readJson: size cap holds without Content-Length, type and shape are enforced", async () => {
  const stream = new ReadableStream<Uint8Array>({
    start(c) {
      c.enqueue(new TextEncoder().encode(`{"a":"${"x".repeat(20000)}"}`)); // 20 KB > 16 KB, sent chunked (no Content-Length)
      c.close();
    },
  });
  await throwsHttp(() => readJson(jsonReq(stream)), 413, "PAYLOAD_TOO_LARGE");
  eq((await readJson(jsonReq('{"ok":true}'))).ok, true, "small body parses");
  await throwsHttp(() => readJson(jsonReq("{}", { "content-type": "text/plain" })), 415);
  await throwsHttp(() => readJson(jsonReq("[1]")), 400, "INVALID_JSON");
  await throwsHttp(() => readJson(jsonReq("not json")), 400, "INVALID_JSON");
  await throwsHttp(() => readJson(new Request("http://test.local/", { method: "GET" })), 405);
});

Deno.test("validation: amounts", async () => {
  eq(v.amount("2500"), "2500", "digit string");
  eq(v.amount(2500), "2500", "safe integer");
  await throwsHttp(() => v.amount(-1), 400);
  await throwsHttp(() => v.amount(12.5), 400);
  await throwsHttp(() => v.amount("12.5"), 400);
  await throwsHttp(() => v.amount(Number.MAX_SAFE_INTEGER + 2), 400);
  await throwsHttp(() => v.amount("1".repeat(31)), 400);
});

Deno.test("validation: ids, tokens, order refs", async () => {
  eq(v.orderRef("CSW-P-0123456789abcdef"), "CSW-P-0123456789abcdef", "order ref");
  await throwsHttp(() => v.orderRef("short"), 400);
  await throwsHttp(() => v.orderRef("CSW P 0123456789"), 400);
  eq(v.accessToken(undefined), null, "token optional");
  await throwsHttp(() => v.accessToken("too short"), 400);
  eq(v.uuid("0F8FAD5B-D9CB-469F-A165-70867728950E", "id"), "0f8fad5b-d9cb-469f-a165-70867728950e", "uuid lower-cased");
  await throwsHttp(() => v.uuid("not-a-uuid", "id"), 400);
});

Deno.test("validation: links", async () => {
  eq(v.httpsUrl("https://example.com/a?b=1", "Link"), "https://example.com/a?b=1", "https link");
  for (const bad of ["http://example.com", "javascript:alert(1)", "https://user:pw@example.com", "https://localhost/", 'https://a.com/"x']) {
    await throwsHttp(() => v.httpsUrl(bad, "Link"), 400);
  }
  eq(v.socialUrl("https://www.instagram.com/someone", "Social"), "https://www.instagram.com/someone", "supported host");
  await throwsHttp(() => v.socialUrl("https://evil.example/instagram.com", "Social"), 400);
});

Deno.test("validation: media paths, Spotify refs, strings", async () => {
  const id = "0f8fad5b-d9cb-469f-a165-70867728950e";
  eq(v.mediaList([{ path: `${id}/photo.jpg`, kind: "image" }], "Media", 4).length, 1, "valid media");
  await throwsHttp(() => v.mediaList([{ path: "../etc/passwd", kind: "image" }], "Media", 4), 400, "INVALID_MEDIA");
  await throwsHttp(() => v.mediaList([{ path: `${id}/a.jpg`, kind: "script" }], "Media", 4), 400, "INVALID_MEDIA");
  eq(v.spotifyRef("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc"), "track/4uLU6hMCjMI75M1A2tKUQC", "spotify link");
  await throwsHttp(() => v.spotifyRef("https://evil.example/track/4uLU6hMCjMI75M1A2tKUQC"), 400, "INVALID_SPOTIFY");
  eq(v.str("  hi  ", "Name", { max: 10 }), "hi", "trimmed");
  await throwsHttp(() => v.str("a\u0000b", "Name", { max: 10 }), 400);
  await throwsHttp(() => v.str("x".repeat(11), "Name", { max: 10 }), 400);
});
