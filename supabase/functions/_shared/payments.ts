// Midtrans integration (Snap transactions, notification signatures, Get Status).
// References (checked 2026-10-21):
//   Snap:   POST https://app.sandbox.midtrans.com/snap/v1/transactions (prod: app.midtrans.com)
//   Status: GET  https://api.sandbox.midtrans.com/v2/{order_id}/status (prod: api.midtrans.com)
//   Auth:   Basic base64("<server key>:")
//   Signature: SHA512(order_id + status_code + gross_amount + server_key), hex.

import { HttpError, sha512Hex, timingSafeEqual } from "./security.ts";

export interface MidtransConfig {
  serverKey: string;
  production: boolean;
  snapUrl: string;
  apiBase: string;
}

export function midtransConfig(env: (k: string) => string | undefined): MidtransConfig | null {
  const serverKey = env("MIDTRANS_SERVER_KEY");
  if (!serverKey) return null;
  const production = env("MIDTRANS_IS_PRODUCTION") === "true";
  // Guard against mixing environments: sandbox keys start with "SB-".
  if (production && serverKey.startsWith("SB-")) {
    throw new Error("MIDTRANS_IS_PRODUCTION=true but MIDTRANS_SERVER_KEY is a sandbox key.");
  }
  return {
    serverKey,
    production,
    snapUrl: production ? "https://app.midtrans.com/snap/v1/transactions" : "https://app.sandbox.midtrans.com/snap/v1/transactions",
    apiBase: production ? "https://api.midtrans.com" : "https://api.sandbox.midtrans.com",
  };
}

export function basicAuth(serverKey: string): string {
  return "Basic " + btoa(`${serverKey}:`);
}

export interface SnapItem {
  id: string;
  name: string;
  /** whole rupiah as decimal string; may be negative for a discount line */
  price: string;
  quantity: number;
}

const INT = /^-?[0-9]{1,19}$/;

/**
 * Build the Snap request body. Amounts are emitted as raw JSON integers taken
 * from decimal strings so values beyond Number.MAX_SAFE_INTEGER keep every
 * digit (JSON.stringify of a JS number would silently round them).
 */
export function buildSnapBody(input: {
  orderRef: string;
  grossAmount: string;
  items: SnapItem[];
  enabledPayments: string[];
  finishUrl: string;
  /** Snap session lifetime in minutes; omitted = Midtrans default (24h). */
  expiryMinutes?: number;
}): string {
  if (!/^[0-9]{1,19}$/.test(input.grossAmount) || BigInt(input.grossAmount) <= 0n) {
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
    // Never send a request Midtrans would reject or, worse, that charges a different amount.
    throw new HttpError(500, "ORDER_TOTAL_MISMATCH", "Order items do not add up to the total.");
  }
  const raws: string[] = [];
  const raw = (digits: string) => {
    raws.push(digits);
    return `__RAW_${raws.length - 1}__`;
  };
  const body = {
    transaction_details: { order_id: input.orderRef, gross_amount: raw(input.grossAmount) },
    item_details: input.items.map((it) => ({
      id: it.id.slice(0, 50),
      name: it.name.slice(0, 50),
      price: raw(it.price),
      quantity: it.quantity,
    })),
    enabled_payments: input.enabledPayments,
    callbacks: { finish: input.finishUrl },
    // Unpaid posts are deleted after 30 minutes, so the Snap session must not outlive them.
    ...(input.expiryMinutes ? { expiry: { unit: "minutes", duration: input.expiryMinutes } } : {}),
  };
  return JSON.stringify(body).replace(/"__RAW_(\d+)__"/g, (_m, i) => raws[Number(i)]);
}

export async function createSnapTransaction(
  cfg: MidtransConfig,
  body: string,
  fetchFn: typeof fetch,
): Promise<{ token: string; redirect_url: string }> {
  let res: Response;
  try {
    res = await fetchFn(cfg.snapUrl, {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json", Authorization: basicAuth(cfg.serverKey) },
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
  if (res.status === 401) {
    console.error("Midtrans rejected credentials");
    throw new HttpError(502, "PAYMENT_PROVIDER_AUTH", "Payments are temporarily unavailable.");
  }
  if (!res.ok || typeof data.token !== "string" || typeof data.redirect_url !== "string") {
    const messages = Array.isArray(data.error_messages) ? data.error_messages.join("; ").slice(0, 300) : "";
    console.error("Midtrans Snap error", res.status, messages);
    throw new HttpError(
      502,
      "PAYMENT_PROVIDER_REJECTED",
      "The payment provider could not start checkout for this order. The amount was not changed; please try again or contact us.",
    );
  }
  if (!String(data.redirect_url).startsWith("https://")) throw new HttpError(502, "PAYMENT_PROVIDER_REJECTED");
  return { token: data.token as string, redirect_url: data.redirect_url as string };
}

export interface MidtransNotification {
  order_id: string;
  status_code: string;
  gross_amount: string;
  signature_key: string;
  transaction_status: string;
  transaction_id?: string;
  fraud_status?: string;
  payment_type?: string;
  currency?: string;
  refund_amount?: string;
  [k: string]: unknown;
}

export function parseNotification(body: Record<string, unknown>): MidtransNotification {
  const req = ["order_id", "status_code", "gross_amount", "signature_key", "transaction_status"];
  for (const k of req) {
    if (typeof body[k] !== "string" || (body[k] as string).length === 0 || (body[k] as string).length > 200) {
      throw new HttpError(400, "INVALID_NOTIFICATION", `Missing ${k}.`);
    }
  }
  return body as unknown as MidtransNotification;
}

export async function expectedSignature(n: Pick<MidtransNotification, "order_id" | "status_code" | "gross_amount">, serverKey: string) {
  return await sha512Hex(n.order_id + n.status_code + n.gross_amount + serverKey);
}

export async function verifySignature(n: MidtransNotification, serverKey: string): Promise<boolean> {
  const expected = await expectedSignature(n, serverKey);
  return timingSafeEqual(expected, n.signature_key.toLowerCase());
}

/** Authoritative status from Midtrans (used to confirm every notification). */
export async function fetchTransactionStatus(
  cfg: MidtransConfig,
  orderId: string,
  fetchFn: typeof fetch,
): Promise<Record<string, unknown>> {
  let res: Response;
  try {
    res = await fetchFn(`${cfg.apiBase}/v2/${encodeURIComponent(orderId)}/status`, {
      method: "GET",
      headers: { Accept: "application/json", Authorization: basicAuth(cfg.serverKey) },
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    throw new HttpError(503, "STATUS_CHECK_UNAVAILABLE", "Could not confirm the transaction status.");
  }
  if (!res.ok) throw new HttpError(503, "STATUS_CHECK_FAILED", "Could not confirm the transaction status.");
  const data = await res.json().catch(() => null);
  if (!data || typeof data !== "object") throw new HttpError(503, "STATUS_CHECK_FAILED");
  return data as Record<string, unknown>;
}

/** Arguments for public.apply_payment_notification from a verified status payload. */
export function statusToRpcArgs(status: Record<string, unknown>, fallback: MidtransNotification) {
  const s = (k: string) => (typeof status[k] === "string" ? (status[k] as string) : undefined);
  return {
    p_order_ref: s("order_id") ?? fallback.order_id,
    p_transaction_id: s("transaction_id") ?? fallback.transaction_id ?? null,
    p_transaction_status: s("transaction_status") ?? fallback.transaction_status,
    p_fraud_status: s("fraud_status") ?? fallback.fraud_status ?? null,
    p_status_code: s("status_code") ?? fallback.status_code,
    p_gross_amount: s("gross_amount") ?? fallback.gross_amount,
    p_currency: s("currency") ?? fallback.currency ?? null,
    p_payment_type: s("payment_type") ?? fallback.payment_type ?? null,
    p_refund_amount: s("refund_amount") ?? fallback.refund_amount ?? null,
    p_raw: {
      notification: { ...fallback, signature_key: "[redacted]" },
      status: { ...status, signature_key: "[redacted]" },
    },
  };
}
