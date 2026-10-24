// Request validation for Edge Functions. The database repeats every
// business rule (min price, decorations, targets...), so these checks focus on
// shape, size and type safety before anything reaches SQL.

import { HttpError } from "./security.ts";

const bad = (code: string, message: string) => new HttpError(400, code, message);

export function str(
  v: unknown,
  field: string,
  opts: { min?: number; max: number; optional?: boolean; multiline?: boolean },
): string | null {
  if (v === undefined || v === null || v === "") {
    if (opts.optional) return null;
    throw bad("INVALID_FIELD", `${field} is required.`);
  }
  if (typeof v !== "string") throw bad("INVALID_FIELD", `${field} must be text.`);
  const s = v.trim();
  const len = [...s].length;
  if (len < (opts.min ?? 1) || len > opts.max) {
    throw bad("INVALID_FIELD", `${field} must be ${opts.min ?? 1}-${opts.max} characters.`);
  }
  // deno-lint-ignore no-control-regex
  const ctrl = opts.multiline ? /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/ : /[\u0000-\u001F\u007F]/;
  if (ctrl.test(s)) throw bad("INVALID_FIELD", `${field} contains unsupported characters.`);
  return s;
}

export function bool(v: unknown, field: string, fallback = false): boolean {
  if (v === undefined || v === null) return fallback;
  if (typeof v !== "boolean") throw bad("INVALID_FIELD", `${field} must be true or false.`);
  return v;
}

/**
 * Whole-rupiah amount as an exact decimal string. Strings of digits are
 * accepted as-is (no size cap here: the database decides storage limits and
 * the minimum). JSON numbers are accepted only when they are safe integers,
 * because larger JSON numbers have already lost precision in transit.
 */
export function amount(v: unknown, field = "amount"): string {
  if (typeof v === "number") {
    if (!Number.isSafeInteger(v) || v < 0) {
      throw bad("INVALID_AMOUNT", `${field} must be sent as a string of digits.`);
    }
    return String(v);
  }
  if (typeof v !== "string" || !/^[0-9]{1,30}$/.test(v)) {
    throw bad("INVALID_AMOUNT", "Enter a whole rupiah amount using digits only.");
  }
  return v;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function uuid(v: unknown, field: string, optional = false): string | null {
  if ((v === undefined || v === null || v === "") && optional) return null;
  if (typeof v !== "string" || !UUID.test(v)) throw bad("INVALID_FIELD", `${field} must be a valid id.`);
  return v.toLowerCase();
}

export function oneOf<T extends string>(v: unknown, field: string, allowed: readonly T[]): T {
  if (typeof v !== "string" || !(allowed as readonly string[]).includes(v)) {
    throw bad("INVALID_FIELD", `${field} must be one of: ${allowed.join(", ")}.`);
  }
  return v as T;
}

export function idList(v: unknown, field: string, max: number): string[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v) || v.length > max) throw bad("INVALID_FIELD", `${field} must be a list (max ${max}).`);
  for (const id of v) {
    if (typeof id !== "string" || !/^[a-z0-9-]{2,40}$/.test(id)) throw bad("INVALID_FIELD", `${field} contains an invalid id.`);
  }
  return v as string[];
}

export function mediaList(v: unknown, field: string, max: number): { path: string; kind: "image" | "video" }[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v) || v.length > max) throw bad("INVALID_MEDIA", `${field} must be a list (max ${max}).`);
  return v.map((m) => {
    const o = m as { path?: unknown; kind?: unknown };
    if ((o?.kind !== "image" && o?.kind !== "video") || typeof o.path !== "string" ||
        !/^[0-9a-f-]{36}\/[A-Za-z0-9._-]{1,100}$/.test(o.path)) throw bad("INVALID_MEDIA", `${field} contains an invalid file.`);
    return { path: o.path, kind: o.kind };
  });
}

export function orderRef(v: unknown): string {
  if (typeof v !== "string" || !/^[A-Za-z0-9_.~-]{8,50}$/.test(v)) throw bad("INVALID_ORDER", "Invalid order reference.");
  return v;
}

export function accessToken(v: unknown): string | null {
  if (v === undefined || v === null || v === "") return null;
  if (typeof v !== "string" || !/^[A-Za-z0-9_-]{32,64}$/.test(v)) throw bad("INVALID_ACCESS_TOKEN", "Invalid access token.");
  return v;
}

/** https only, no credentials, no whitespace, bounded length. */
export function httpsUrl(v: unknown, field: string, optional = false): string | null {
  if ((v === undefined || v === null || v === "") && optional) return null;
  if (typeof v !== "string" || v.length > 500) throw bad("INVALID_URL", `${field} must be an https link.`);
  let u: URL;
  try {
    u = new URL(v);
  } catch {
    throw bad("INVALID_URL", `${field} must be an https link.`);
  }
  if (u.protocol !== "https:" || u.username || u.password || /[\s<>"']/.test(v) || !u.hostname.includes(".")) {
    throw bad("INVALID_URL", `${field} must be an https link.`);
  }
  return v;
}

const SOCIAL_HOSTS = new Set([
  "instagram.com", "x.com", "twitter.com", "tiktok.com", "linkedin.com",
  "github.com", "youtube.com", "facebook.com", "threads.net",
]);

export function socialUrl(v: unknown, field: string): string | null {
  const url = httpsUrl(v, field, true);
  if (!url) return null;
  const host = new URL(url).hostname.replace(/^www\./, "");
  if (!SOCIAL_HOSTS.has(host) || url.length > 300) {
    throw bad("INVALID_SOCIAL_LINK", "Social links must point to a supported platform (Instagram, X, TikTok, LinkedIn, GitHub, YouTube, Facebook, Threads).");
  }
  return url;
}

export function isoDate(v: unknown, field: string): string {
  if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(v) || Number.isNaN(Date.parse(v))) {
    throw bad("INVALID_FIELD", `${field} must be a date (YYYY-MM-DD).`);
  }
  return v;
}

export function email(v: unknown, field: string): string {
  const s = str(v, field, { min: 3, max: 200 })!;
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s)) throw bad("INVALID_FIELD", `${field} must be an email address.`);
  return s;
}
