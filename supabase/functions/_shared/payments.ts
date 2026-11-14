// DOKU integration (Checkout page, signed notifications, Check Status).
// References (checked 2026-11-14, developers.doku.com):
//   Checkout: POST https://api-sandbox.doku.com/checkout/v1/payment (prod: api.doku.com)
//   Status:   GET  https://api-sandbox.doku.com/orders/v1/status/{invoice_number}
//   Headers:  Client-Id, Request-Id, Request-Timestamp (ISO8601 UTC), Signature
//   Signature: "HMACSHA256=" + base64(HMAC-SHA256(secret, lines joined by \n)), lines =
//     Client-Id:.. / Request-Id:.. / Request-Timestamp:.. / Request-Target:<path> / Digest:<b64 sha256 of body> (body requests only)
// The database function apply_payment_notification still speaks gateway-neutral
// status words (settlement, pending, expire, refund, ...), so DOKU statuses are mapped to those here.

import type { Db } from "./auth.ts";
import { HttpError, rpc, timingSafeEqual } from "./security.ts";

export interface DokuConfig {
  clientId: string;
  secretKey: string;
  production: boolean;
  apiBase: string;
}

export function dokuConfig(env: (k: string) => string | undefined): DokuConfig | null {
  const clientId = env("DOKU_CLIENT_ID");
  const secretKey = env("DOKU_SECRET_KEY");
  if (!clientId || !secretKey) return null;
  const production = env("DOKU_IS_PRODUCTION") === "true";
  return { clientId, secretKey, production, apiBase: production ? "https://api.doku.com" : "https://api-sandbox.doku.com" };
}

const UA = "CampusStickyWall/1.0 (+https://campusstickywall.app)";
const enc = new TextEncoder();

function b64(bytes: ArrayBuffer): string {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s);
}

async function sha256B64(text: string): Promise<string> {
  return b64(await crypto.subtle.digest("SHA-256", enc.encode(text)));
}

async function sign(secretKey: string, h: { clientId: string; requestId: string; timestamp: string; target: string; body?: string }): Promise<string> {
  const lines = [`Client-Id:${h.clientId}`, `Request-Id:${h.requestId}`, `Request-Timestamp:${h.timestamp}`, `Request-Target:${h.target}`];
  if (h.body) lines.push(`Digest:${await sha256B64(h.body)}`);
  const key = await crypto.subtle.importKey("raw", enc.encode(secretKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return "HMACSHA256=" + b64(await crypto.subtle.sign("HMAC", key, enc.encode(lines.join("\n"))));
}

async function signedHeaders(cfg: DokuConfig, target: string, body?: string): Promise<Record<string, string>> {
  const requestId = crypto.randomUUID();
  const timestamp = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  return {
    Accept: "application/json",
    ...(body ? { "Content-Type": "application/json" } : {}),
    "Client-Id": cfg.clientId,
    "Request-Id": requestId,
    "Request-Timestamp": timestamp,
    Signature: await sign(cfg.secretKey, { clientId: cfg.clientId, requestId, timestamp, target, body }),
    "User-Agent": UA,
  };
}

export interface OrderItem {
  id: string;
  name: string;
  /** whole rupiah as decimal string; may be negative for a discount line */
  price: string;
  quantity: number;
}

const INT = /^-?[0-9]{1,19}$/;

/**
 * Build the Checkout request body. The items only prove the total is consistent
 * (DOKU's line_items cannot carry a negative discount line, so they are not sent).
 * DOKU amounts are plain IDR integers of at most 12 digits, which JS numbers hold exactly.
 */
export function buildCheckoutBody(input: {
  orderRef: string;
  grossAmount: string;
  items: OrderItem[];
  /** DOKU payment_method_types (e.g. QRIS, VIRTUAL_ACCOUNT_BCA). Empty = every channel active on the account. */
  enabledPayments: string[];
  finishUrl: string;
  /** Checkout session lifetime in minutes; default 60. */
  expiryMinutes?: number;
}): string {
  if (!/^[0-9]{1,12}$/.test(input.grossAmount) || BigInt(input.grossAmount) <= 0n) {
    throw new HttpError(400, "INVALID_AMOUNT", "Invalid payable amount.");
  }
  let sum = 0n;
  for (const it of input.items) {
    if (!INT.test(it.price) || !Number.isInteger(it.quantity) || it.quantity < 1) {
      throw new HttpError(500, "INVALID_ORDER_ITEMS");
    }
    sum += BigInt(it.price) * BigInt(it.quantity);
  }
  if (sum !== BigInt(input.grossAmount)) {
    // Never send a request that charges a different amount than the stored order.
    throw new HttpError(500, "ORDER_TOTAL_MISMATCH", "Order items do not add up to the total.");
  }
  return JSON.stringify({
    order: {
      amount: Number(input.grossAmount),
      invoice_number: input.orderRef,
      callback_url: input.finishUrl,
      auto_redirect: true,
    },
    payment: {
      // Unpaid posts are deleted after 30 minutes, so the session must not outlive them.
      payment_due_date: input.expiryMinutes ?? 60,
      ...(input.enabledPayments.length ? { payment_method_types: input.enabledPayments.map((c) => c.toUpperCase()) } : {}),
    },
  });
}

export async function createCheckout(
  cfg: DokuConfig,
  body: string,
  fetchFn: typeof fetch,
): Promise<{ token: string; redirect_url: string }> {
  const target = "/checkout/v1/payment";
  let res: Response;
  try {
    res = await fetchFn(cfg.apiBase + target, {
      method: "POST",
      headers: await signedHeaders(cfg, target, body),
      body,
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    throw new HttpError(502, "PAYMENT_PROVIDER_UNAVAILABLE", "The payment provider could not be reached. Please try again.");
  }
  const text = await res.text();
  let data: Record<string, unknown> = {};
  try {
    data = JSON.parse(text);
  } catch { /* handled below */ }
  if (res.status === 401 || res.status === 403) {
    console.error("DOKU rejected credentials", res.status);
    throw new HttpError(502, "PAYMENT_PROVIDER_AUTH", "Payments are temporarily unavailable.");
  }
  const payment = (data.response as { payment?: { url?: unknown; token_id?: unknown } } | undefined)?.payment;
  if (!res.ok || typeof payment?.url !== "string" || typeof payment?.token_id !== "string") {
    // DOKU answers with error_messages[] (400), message[], or a non-JSON (e.g. proxy) page.
    const list = Array.isArray(data.error_messages) ? data.error_messages : Array.isArray(data.message) ? data.message : null;
    const messages = (list ? list.join("; ") : text.replace(/\s+/g, " ")).slice(0, 300);
    console.error("DOKU Checkout error", res.status, messages);
    // Sandbox only: show DOKU's own reason. Production keeps it generic.
    const detail = !cfg.production && messages ? ` [DOKU sandbox ${res.status}: ${messages}]` : "";
    throw new HttpError(
      502,
      "PAYMENT_PROVIDER_REJECTED",
      "The payment provider could not start checkout for this order. The amount was not changed; please try again or contact us." + detail,
    );
  }
  if (!payment.url.startsWith("https://")) throw new HttpError(502, "PAYMENT_PROVIDER_REJECTED");
  return { token: payment.token_id, redirect_url: payment.url };
}

/** True when a DOKU notification really came from DOKU. `paths` = acceptable Request-Target values. */
export async function verifyNotification(cfg: DokuConfig, headers: Headers, rawBody: string, paths: string[]): Promise<boolean> {
  const clientId = headers.get("client-id") ?? "";
  const requestId = headers.get("request-id") ?? "";
  const timestamp = headers.get("request-timestamp") ?? "";
  const got = headers.get("signature") ?? "";
  if (clientId !== cfg.clientId || !requestId || !timestamp || !got) return false;
  for (const target of paths) {
    const want = await sign(cfg.secretKey, { clientId, requestId, timestamp, target, body: rawBody });
    if (timingSafeEqual(want, got)) return true;
  }
  return false;
}

/** Gateway-neutral view of a DOKU notification or Check Status answer. */
export interface PaymentStatus {
  orderRef: string;
  /** word understood by apply_payment_notification: settlement, pending, expire, refund, partial_refund */
  status: string;
  amount: string;
  channel: string | null;
  txId: string | null;
  raw: Record<string, unknown>;
}

const STATUS_MAP: Record<string, string> = {
  SUCCESS: "settlement",
  EXPIRED: "expire",
  REFUNDED: "refund",
  VOIDED: "refund",
  PARTIAL_REFUNDED: "partial_refund",
  // PENDING, REDIRECT, TIMEOUT: not final. FAILED: on Checkout the customer may retry with another
  // channel, so it is not final either (DOKU best practice). Unpaid orders are expired by the 30-minute rule.
};

/** Same shape for notifications and Check Status: { order: {invoice_number, amount}, transaction: {status, ...}, channel: {id} }. */
export function parsePayload(body: Record<string, unknown>): PaymentStatus {
  const o = (body.order ?? {}) as Record<string, unknown>;
  const t = (body.transaction ?? {}) as Record<string, unknown>;
  const ref = o.invoice_number;
  const st = t.status;
  const amt = o.amount;
  if (typeof ref !== "string" || !ref || ref.length > 200 || typeof st !== "string" || (typeof amt !== "number" && typeof amt !== "string")) {
    throw new HttpError(400, "INVALID_NOTIFICATION", "Missing order or transaction fields.");
  }
  const channel = (body.channel as { id?: unknown } | undefined)?.id;
  const txId = t.original_request_id;
  return {
    orderRef: ref,
    status: STATUS_MAP[st.toUpperCase()] ?? "pending",
    amount: String(amt),
    channel: typeof channel === "string" ? channel.toLowerCase().slice(0, 60) : null,
    txId: typeof txId === "string" ? txId.slice(0, 128) : null,
    // Keep the audit trail but not the customer's name, email or masked card.
    raw: { order: body.order, transaction: body.transaction, service: body.service, acquirer: body.acquirer, channel: body.channel },
  };
}

/** Authoritative status from DOKU. null = DOKU has no payment attempt for this order (404). */
export async function fetchTransactionStatus(cfg: DokuConfig, orderRef: string, fetchFn: typeof fetch): Promise<PaymentStatus | null> {
  const target = `/orders/v1/status/${encodeURIComponent(orderRef)}`;
  let res: Response;
  try {
    res = await fetchFn(cfg.apiBase + target, {
      method: "GET",
      headers: await signedHeaders(cfg, target),
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    throw new HttpError(503, "STATUS_CHECK_UNAVAILABLE", "Could not confirm the transaction status.");
  }
  if (res.status === 404) return null;
  if (!res.ok) throw new HttpError(503, "STATUS_CHECK_FAILED", "Could not confirm the transaction status.");
  const data = await res.json().catch(() => null);
  if (!data || typeof data !== "object") throw new HttpError(503, "STATUS_CHECK_FAILED");
  const s = parsePayload(data as Record<string, unknown>);
  if (s.orderRef !== orderRef) throw new HttpError(409, "STATUS_ORDER_MISMATCH");
  return s;
}

/** Arguments for public.apply_payment_notification from a verified status. */
export function statusToRpcArgs(s: PaymentStatus) {
  return {
    p_order_ref: s.orderRef,
    p_transaction_id: s.txId,
    p_transaction_status: s.status,
    p_fraud_status: null,
    p_status_code: "200",
    p_gross_amount: s.amount,
    p_currency: "IDR",
    p_payment_type: s.channel,
    p_refund_amount: null,
    p_raw: s.raw,
  };
}

/**
 * Pull-based fallback for a missed or delayed webhook: ask DOKU for the
 * transaction status and apply it through the same idempotent, amount-checked RPC.
 * Never throws: the receipt must still load if DOKU is down.
 * (DOKU asks for Check Status at least 60 s after payment; the receipt poll is rate-limited anyway.)
 */
export async function syncOrderStatus(cfg: DokuConfig, db: Db, orderRef: string, fetchFn: typeof fetch): Promise<void> {
  try {
    const status = await fetchTransactionStatus(cfg, orderRef, fetchFn);
    if (status) await rpc(db, "apply_payment_notification", statusToRpcArgs(status));
  } catch (err) {
    console.warn("DOKU status sync skipped", err instanceof Error ? err.message : String(err));
  }
}
