// Shared HTTP, CORS, error mapping, hashing and rate-limit helpers.
// Every Edge Function treats the request as untrusted: CORS is a browser
// convenience only, never an authorization mechanism.

import type { Db } from "./auth.ts";

export class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
    message?: string,
  ) {
    super(message ?? code);
  }
}

type Env = (key: string) => string | undefined;

const DEFAULT_ENV: Env = (k) => Deno.env.get(k);

export function allowedOrigins(env: Env = DEFAULT_ENV): string[] {
  return (env("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

export function corsHeaders(req: Request, env: Env = DEFAULT_ENV): Record<string, string> {
  const origin = req.headers.get("origin");
  const headers: Record<string, string> = {
    "Vary": "Origin",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Max-Age": "600",
  };
  if (origin && allowedOrigins(env).includes(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
  }
  return headers;
}

export function json(req: Request, status: number, body: unknown, env: Env = DEFAULT_ENV): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...corsHeaders(req, env),
    },
  });
}

/** PostgREST/Postgres error -> HTTP. Custom SQLSTATEs come from 001_initial_schema.sql. */
const STATE_TO_STATUS: Record<string, number> = {
  CSW40: 400,
  CSW03: 403,
  CSW04: 404,
  CSW09: 409,
  CSW29: 429,
  "42501": 403,
  "23505": 409,
  "23514": 400,
};

export interface DbError {
  code?: string;
  message: string;
  hint?: string | null;
  details?: string | null;
}

export function dbErrorToHttp(err: DbError): HttpError {
  const status = err.code ? STATE_TO_STATUS[err.code] : undefined;
  if (status && err.code?.startsWith("CSW")) {
    return new HttpError(status, err.message, err.hint ?? err.message);
  }
  if (status) {
    return new HttpError(status, status === 403 ? "FORBIDDEN" : "REQUEST_REJECTED", "The request was rejected.");
  }
  console.error("Unexpected database error", { code: err.code, message: err.message });
  return new HttpError(500, "INTERNAL_ERROR", "Something went wrong. Please try again.");
}

/** Call an RPC and unwrap its result, throwing HttpError on failure. */
export async function rpc<T = unknown>(db: Db, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw dbErrorToHttp(error);
  return data as T;
}

export function errorResponse(req: Request, err: unknown, env: Env = DEFAULT_ENV): Response {
  if (err instanceof HttpError) {
    return json(req, err.status, { error: { code: err.code, message: err.message } }, env);
  }
  console.error("Unhandled error", err instanceof Error ? err.message : String(err));
  return json(req, 500, { error: { code: "INTERNAL_ERROR", message: "Something went wrong. Please try again." } }, env);
}

const MAX_BODY_BYTES = 16 * 1024;

/** Read the body but stop once it passes maxBytes: Content-Length can be absent (chunked) or false. */
async function readCapped(req: Request, maxBytes: number): Promise<string> {
  const reader = req.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > maxBytes) {
      await reader.cancel();
      throw new HttpError(413, "PAYLOAD_TOO_LARGE", "Request body too large.");
    }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.length;
  }
  return new TextDecoder().decode(all);
}

/** Enforce POST + JSON + size limit, return the parsed object. */
export async function readJson(req: Request, maxBytes = MAX_BODY_BYTES): Promise<Record<string, unknown>> {
  if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED", "Use POST.");
  const type = req.headers.get("content-type") ?? "";
  if (!type.toLowerCase().startsWith("application/json")) {
    throw new HttpError(415, "UNSUPPORTED_MEDIA_TYPE", "Send JSON.");
  }
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > maxBytes) throw new HttpError(413, "PAYLOAD_TOO_LARGE", "Request body too large.");
  const text = await readCapped(req, maxBytes);
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new HttpError(400, "INVALID_JSON", "Malformed JSON.");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new HttpError(400, "INVALID_JSON", "Expected a JSON object.");
  }
  return parsed as Record<string, unknown>;
}

export function clientIp(req: Request): string {
  // The edge proxy sets cf-connecting-ip itself. The first x-forwarded-for entry is client-supplied
  // (spoofable), so use the last one, which the proxy appended, only as a fallback.
  const direct = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip");
  if (direct) return direct.trim().slice(0, 64);
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) return fwd.split(",").pop()!.trim().slice(0, 64);
  return "unknown";
}

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return toHex(new Uint8Array(digest));
}

export async function sha512Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-512", new TextEncoder().encode(input));
  return toHex(new Uint8Array(digest));
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** 256-bit random token, base64url. Only its SHA-256 hash is stored. */
export function randomToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function timingSafeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  const len = Math.max(ea.length, eb.length);
  for (let i = 0; i < len; i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

/** Postgres-backed fixed-window rate limit (shared across function instances). */
export async function rateLimit(db: Db, key: string, limit: number, windowSeconds: number): Promise<void> {
  const allowed = await rpc<boolean>(db, "check_rate_limit", {
    p_key: key,
    p_limit: limit,
    p_window_seconds: windowSeconds,
  });
  if (!allowed) throw new HttpError(429, "RATE_LIMITED", "Too many requests. Please wait a moment and try again.");
}

/** Standard function wrapper: OPTIONS preflight + error mapping. */
export function withErrors(
  fn: (req: Request) => Promise<Response>,
  env: Env = DEFAULT_ENV,
): (req: Request) => Promise<Response> {
  return async (req) => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req, env) });
    try {
      return await fn(req);
    } catch (err) {
      return errorResponse(req, err, env);
    }
  };
}
