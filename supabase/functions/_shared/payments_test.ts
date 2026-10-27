// Run with: deno test supabase/functions/_shared/
// Covers the money and trust-boundary code: Midtrans signature, Snap body, request reader, input validation.
import { buildSnapBody, expectedSignature, midtransConfig, parseNotification, statusToRpcArgs, verifySignature } from "./payments.ts";
import { HttpError, readJson, sha512Hex, timingSafeEqual } from "./security.ts";
import * as v from "./validation.ts";

const KEY = "SB-Mid-server-TESTKEY";

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

Deno.test("signature: sha512(order_id + status_code + gross_amount + key), constant-time compare", async () => {
  const n = { order_id: "CSW-P-TEST", status_code: "200", gross_amount: "10000.00" };
  const good = await sha512Hex(n.order_id + n.status_code + n.gross_amount + KEY);
  eq(await expectedSignature(n, KEY), good, "expected signature");
  const note = parseNotification({ ...n, signature_key: good.toUpperCase(), transaction_status: "settlement" });
  eq(await verifySignature(note, KEY), true, "upper-case hex accepted");
  eq(await verifySignature({ ...note, gross_amount: "10001.00" }, KEY), false, "changed amount rejected");
  eq(await verifySignature(note, "SB-Mid-server-OTHER"), false, "wrong key rejected");
  eq(timingSafeEqual("abc", "abcd"), false, "different length");
  eq(timingSafeEqual("abc", "abc"), true, "equal");
});

Deno.test("parseNotification rejects missing or oversized fields", async () => {
  await throwsHttp(() => parseNotification({ order_id: "x" }), 400, "INVALID_NOTIFICATION");
  await throwsHttp(
    () => parseNotification({ order_id: "x".repeat(201), status_code: "200", gross_amount: "1", signature_key: "s", transaction_status: "t" }),
    400,
    "INVALID_NOTIFICATION",
  );
});

Deno.test("statusToRpcArgs prefers the verified status and redacts the signature", () => {
  const fallback = { order_id: "CSW-P-TEST", status_code: "201", gross_amount: "1.00", signature_key: "secret", transaction_status: "pending" };
  const args = statusToRpcArgs({ order_id: "CSW-P-TEST", status_code: "200", gross_amount: "2500.00", transaction_status: "settlement" }, fallback);
  eq(args.p_transaction_status, "settlement", "status wins");
  eq(args.p_gross_amount, "2500.00", "amount from status");
  eq(JSON.stringify(args.p_raw).includes("secret"), false, "signature redacted");
});

Deno.test("buildSnapBody: exact integers, discount lines, totals must match", async () => {
  const base = { orderRef: "CSW-P-TEST", enabledPayments: ["gopay"], finishUrl: "https://example.test/#/checkout" };
  const body = buildSnapBody({
    ...base,
    grossAmount: "9007199254740993", // beyond Number.MAX_SAFE_INTEGER
    items: [{ id: "a", name: "Note", price: "9007199254740993", quantity: 1 }],
  });
  eq(body.includes('"gross_amount":9007199254740993'), true, "no float rounding");

  const withDiscount = buildSnapBody({
    ...base,
    grossAmount: "1500",
    items: [{ id: "a", name: "Note", price: "2500", quantity: 1 }, { id: "d", name: "Promo", price: "-1000", quantity: 1 }],
  });
  eq(JSON.parse(withDiscount).transaction_details.gross_amount, 1500, "discount applied");

  await throwsHttp(() => buildSnapBody({ ...base, grossAmount: "2500", items: [{ id: "a", name: "n", price: "2400", quantity: 1 }] }), 500, "ORDER_TOTAL_MISMATCH");
  await throwsHttp(() => buildSnapBody({ ...base, grossAmount: "0", items: [] }), 400, "INVALID_AMOUNT");
  await throwsHttp(() => buildSnapBody({ ...base, grossAmount: "12.5", items: [] }), 400, "INVALID_AMOUNT");
});

Deno.test("midtransConfig: missing key, sandbox key in production, endpoints", () => {
  eq(midtransConfig(() => undefined), null, "no key");
  let threw = false;
  try {
    midtransConfig((k) => ({ MIDTRANS_SERVER_KEY: KEY, MIDTRANS_IS_PRODUCTION: "true" })[k]);
  } catch {
    threw = true;
  }
  eq(threw, true, "sandbox key refused in production");
  eq(midtransConfig((k) => ({ MIDTRANS_SERVER_KEY: KEY })[k])?.apiBase, "https://api.sandbox.midtrans.com", "sandbox base");
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
