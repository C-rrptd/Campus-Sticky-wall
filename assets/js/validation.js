// Client-side validation for usability. The backend repeats every rule; nothing
// here is a security boundary.

// Pricing comes from public.site_config (min_publication_price, max_publication_price, price_presets,
// confirm_above_amount) via setPricing(). These defaults only apply until it loads; the server decides.
export const pricing = { min: 2500n, max: 1000000n, presets: [2500n, 5000n, 10000n], confirmAbove: 100000n };
export const CREDIT_VALUE = 5000n; // old verify-time credit, no new ones are issued

const fmt = (n) => `Rp${n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")}`;
export { fmt as formatMoney };

/** rows: [{ key, value }] from site_config. Ignores anything malformed. */
export function setPricing(rows) {
  const big = (v) => { try { const n = BigInt(String(v)); return n > 0n ? n : null; } catch { return null; } };
  for (const { key, value } of rows ?? []) {
    if (key === "min_publication_price" && big(value)) pricing.min = big(value);
    if (key === "max_publication_price" && big(value)) pricing.max = big(value);
    if (key === "confirm_above_amount" && big(value)) pricing.confirmAbove = big(value);
    if (key === "price_presets" && Array.isArray(value)) {
      const list = value.map(big).filter(Boolean);
      if (list.length) pricing.presets = list;
    }
  }
}

/**
 * Parse a rupiah amount typed by a person. Accepts digits with optional "Rp",
 * spaces and "." thousands separators ("25.000"). Rejects decimals, commas,
 * signs and exponents. Returns { ok, digits, value(bigint), error }.
 * The maximum here only mirrors the server cap.
 */
export function parseRupiah(input) {
  const raw = String(input ?? "").trim();
  if (raw === "") return { ok: false, error: "Enter an amount." };
  const cleaned = raw.replace(/^rp\.?\s*/i, "").replace(/[\s.]/g, "");
  if (!/^[0-9]+$/.test(cleaned)) {
    return { ok: false, error: "Use whole rupiah, digits only (for example 25000 or 25.000)." };
  }
  const digits = cleaned.replace(/^0+(?=\d)/, "");
  return { ok: true, digits, value: BigInt(digits) };
}

export function validatePublicationAmount(input) {
  const parsed = parseRupiah(input);
  if (!parsed.ok) return parsed;
  if (parsed.value < pricing.min) return { ok: false, error: `The minimum publication price is ${fmt(pricing.min)}.` };
  if (parsed.value > pricing.max) return { ok: false, error: `The maximum publication price is ${fmt(pricing.max)}.` };
  return parsed;
}

export function textLength(value) {
  return [...String(value ?? "").trim()].length;
}

export function validateNote({ body, author_name }) {
  const errors = {};
  if (textLength(body) < 1) errors.body = "Write your note.";
  else if (textLength(body) > 500) errors.body = "Notes can be at most 500 characters.";
  if (textLength(author_name) > 40) errors.author_name = "Names can be at most 40 characters.";
  return errors;
}

const SOCIAL_HOSTS = ["instagram.com", "x.com", "twitter.com", "tiktok.com", "linkedin.com", "github.com", "youtube.com", "facebook.com", "threads.net"];

export function isAllowedSocialUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password &&
      SOCIAL_HOSTS.includes(url.hostname.replace(/^www\./, "")) && value.length <= 300;
  } catch {
    return false;
  }
}

export function isHttpsUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password && url.hostname.includes(".") && !/[\s<>"']/.test(value);
  } catch {
    return false;
  }
}

export function isEmail(value) {
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(value ?? "").trim());
}

export function validatePassword(value) {
  return String(value ?? "").length >= 8 ? null : "Passwords need at least 8 characters.";
}

/** Ad total for n locations: the base fee covers the first, each extra adds pct% of the base. Mirrors public.ad_price(). */
export function adPrice(base, pct, n) {
  const b = BigInt(base);
  return n < 1 ? 0n : b + (b * BigInt(pct) * BigInt(n - 1) + 50n) / 100n;
}

/** Spotify link or URI -> "<type>/<22 char id>", or null. Mirrors spotifyRef() in the create-publication validation. */
export function spotifyRef(input) {
  const m = String(input ?? "").trim().match(/^(?:https:\/\/open\.spotify\.com\/(?:intl-[a-z]{2,3}(?:-[a-z]{2,4})?\/)?|spotify:)(track|album|playlist|episode|show)[/:]([A-Za-z0-9]{22})(?:[?#/].*)?$/);
  return m ? `${m[1]}/${m[2]}` : null;
}

/** Poll option limits, equal to validate_poll() in migration 021. */
export const POLL_MIN_OPTIONS = 2;
export const POLL_MAX_OPTIONS = 6;
export const POLL_OPTION_MAX = 80;

/**
 * Build the poll payload from the composer rows [{ text, correct }].
 * Returns { poll } (null when kind is "none") or { error }.
 */
export function buildPoll(kind, multi, rows) {
  if (kind !== "poll" && kind !== "quiz") return { poll: null };
  const items = rows.map((r) => ({ text: String(r.text ?? "").trim(), correct: Boolean(r.correct) })).filter((r) => r.text);
  if (items.length < POLL_MIN_OPTIONS) return { error: `Add at least ${POLL_MIN_OPTIONS} options.` };
  if (items.some((r) => [...r.text].length > POLL_OPTION_MAX)) return { error: `Options can be at most ${POLL_OPTION_MAX} characters.` };
  if (new Set(items.map((r) => r.text.toLowerCase())).size !== items.length) return { error: "Options must be different from each other." };
  const poll = { kind, multi: Boolean(multi), options: items.map((r) => r.text) };
  if (kind === "quiz") {
    poll.correct = items.flatMap((r, i) => (r.correct ? [i] : []));
    if (poll.correct.length === 0) return { error: "Mark the correct answer." };
    if (!poll.multi && poll.correct.length !== 1) return { error: "Mark exactly one correct answer, or allow multiple answers." };
  }
  return { poll };
}
