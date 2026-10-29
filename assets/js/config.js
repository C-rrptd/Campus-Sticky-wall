// Public frontend configuration. ONLY public values belong here:
//   - supabaseUrl:            https://<project-ref>.supabase.co
//   - supabasePublishableKey: the publishable key (sb_publishable_...) or the legacy anon key
//   - siteUrl:                the public URL of this site (used for referral links)
// Never put a secret key, service_role key or Midtrans server key in this file.
// Static hosting does not read .env files; edit these values (or generate this
// file during deployment as described in README.md).

export const config = Object.freeze({
  supabaseUrl: "https://knpdfledhawndelifvqy.supabase.co",
  supabasePublishableKey: "sb_publishable_2XS-29fFMJ8z6p8FQRHcvg_39C8oMtO",
  siteUrl: "https://campusstickywall.app",
  creativeBucket: "campaign-creatives",
});

/** List of human-readable configuration problems (empty when OK). */
export function configProblems(cfg = config) {
  const problems = [];
  if (!/^https:\/\/[a-z0-9.-]+$/i.test(cfg.supabaseUrl) && !/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(cfg.supabaseUrl)) {
    problems.push("supabaseUrl — your Supabase project URL (https://<ref>.supabase.co)");
  }
  const keyKind = classifyKey(cfg.supabasePublishableKey);
  if (keyKind === "missing") {
    problems.push("supabasePublishableKey — the publishable (or legacy anon) key");
  } else if (keyKind === "secret") {
    problems.push("supabasePublishableKey — a SECRET key was configured. Remove it immediately and rotate it.");
  } else if (keyKind === "unknown") {
    problems.push("supabasePublishableKey — not a publishable key (expected sb_publishable_… or the legacy anon JWT)");
  }
  if (!/^https?:\/\//.test(cfg.siteUrl)) problems.push("siteUrl — the public address of this website");
  return problems;
}

/**
 * "public" = sb_publishable_… or a legacy JWT whose role is exactly "anon".
 * "secret" = sb_secret_… or any legacy JWT with another role (e.g. service_role).
 * Anything else is "unknown" and is refused too.
 */
export function classifyKey(key) {
  if (!key) return "missing";
  if (/^sb_publishable_[A-Za-z0-9_-]+$/.test(key)) return "public";
  if (/^sb_secret_/.test(key)) return "secret";
  const parts = String(key).split(".");
  if (parts.length === 3) {
    const role = jwtRole(parts[1]);
    if (role === "anon") return "public";
    if (role !== null) return "secret";
  }
  return "unknown";
}

function jwtRole(segment) {
  try {
    let b64 = segment.replace(/-/g, "+").replace(/_/g, "/");
    b64 += "=".repeat((4 - (b64.length % 4)) % 4);
    const role = JSON.parse(atob(b64))?.role;
    return typeof role === "string" ? role : "";
  } catch {
    return null;
  }
}
