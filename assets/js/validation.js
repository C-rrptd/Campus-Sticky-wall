// Client-side validation for usability. The backend repeats every rule; nothing
// here is a security boundary.

export const MIN_PUBLICATION_PRICE = 5000n;
export const CREDIT_VALUE = 5000n;

/**
 * Parse a rupiah amount typed by a person. Accepts digits with optional "Rp",
 * spaces and "." thousands separators ("25.000"). Rejects decimals, commas,
 * signs and exponents. Returns { ok, digits, value(bigint), error }.
 * There is deliberately NO maximum.
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
  if (parsed.value < MIN_PUBLICATION_PRICE) return { ok: false, error: "The minimum publication price is Rp5.000." };
  return parsed;
}

export function textLength(value) {
  return [...String(value ?? "").trim()].length;
}

export function validateNote({ body, author_name }) {
  const errors = {};
  if (textLength(body) < 1) errors.body = "Write your note.";
  else if (textLength(body) > 500) errors.body = "Notes can be at most 500 characters.";
  if (textLength(author_name) < 1) errors.author_name = "Add the name to show on your note.";
  else if (textLength(author_name) > 40) errors.author_name = "Names can be at most 40 characters.";
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
