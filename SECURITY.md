# Security

This document covers the threat model, trust boundaries, secrets, permissions and payment security for Campus Sticky Wall. No security claim here replaces a review of the deployed configuration.

## Trust boundaries

| Zone | Trust | Holds |
|---|---|---|
| Browser (HTML/JS) | **Untrusted** | Publishable key only. It collects input and renders server state. |
| Edge Functions (Deno) | Trusted | Midtrans server key and the Supabase secret key (injected by Supabase). They authenticate callers and validate input. |
| PostgreSQL | Authoritative | Prices, orders, credits, roles, moderation state. RLS plus `SECURITY DEFINER` functions. |
| Midtrans | External, verified | Payment status, accepted only after a signature check **and** a Get Status re-read. |

The browser **never** decides any of the following: payment status, amounts, decoration prices, credit eligibility or balance, publication or approval, admin rights, donation totals, campaign status, or leaderboard results.

## Threats and mitigations

| Threat | Mitigation |
|---|---|
| Tampered price or total | The DB computes every amount (`quote_publication`, `create_publication_order`, `create_ad_order`). Client totals are ignored. A `confirm_amount` must equal the submitted amount. |
| Fake "payment success" redirect | The checkout page only displays server status. Return-URL parameters are stripped. |
| Forged or replayed or out-of-order Midtrans notification | SHA-512 signature (constant-time compare), then the Get Status API, then a DB check of order, amount and currency, a deduplication key, and a transition table (no regressions; refunded/reversed are terminal; success after close only sets `review_required`). Fulfilment is guarded by `fulfilled_at` under a row lock. |
| Double credit spend | Credits are reserved with `FOR UPDATE SKIP LOCKED`, with partial unique indexes on reserved/redeemed order. They are consumed only on fulfilment and released on failure. |
| Referral abuse | Attribution is taken only at signup from the immutable insert, rewarded only after email verification, one credit per referred user (`unique(source, source_ref)`). Self-referral via email aliases is rejected. Attribution is immutable. Admins can revoke unredeemed credits (audited). |
| Privilege escalation | Admin role lives in `user_roles` (no client writes). Every admin SQL function calls `require_admin()`; `admin-api` is an explicit allowlist. `is_admin(uuid)` is not exposed to clients. |
| Data leakage via REST | RLS on **every** public table. Column grants hide `orders.guest_token_hash`/session tokens, `notes.author_id`/`order_id`/raw amounts, and referred-user ids. `get_wall` respects `show_amount`. |
| Function abuse | A function EXECUTE allowlist (005): anon may run only read/measurement functions, and order, payment and credit mutations are service-role only. `SECURITY DEFINER` functions pin `search_path = ''`. |
| Guest receipt guessing | 256-bit random tokens; only the SHA-256 is stored. Order refs are not credentials. Failed lookups are rate limited (20 per 10 min per IP). Tokens are removed from the address bar. |
| XSS | All user content goes in via `textContent`. Fragments containing `<script>` or inline handlers are rejected. URLs must be https (and social links must use allowlisted hosts). CSP has `script-src 'self'` with no inline scripts. |
| Malicious campaign content | `https` destination only (DB `CHECK` plus function validation). The creative must be the uploader's own `uid/uuid.ext` object in a bucket limited to images of 1 MB. Campaigns go live only when paid **and** approved **and** in schedule. |
| Mis-targeting | Targets must match the package level exactly (a CHECK constraint per level). Unknown or disabled locations are rejected. Missing locations resolve to *global only*, never broader. |
| Brute force / spam | Postgres-backed fixed-window rate limits shared across instances (`check_rate_limit`). Supabase Auth rate limits apply to login and signup. |
| Secret exposure | Secrets exist only as function secrets. Frontend config is validated (a secret key is detected and refused). The build script refuses `sb_secret_` keys. Webhook raw payloads are stored with `signature_key` redacted. |

## Edge Functions

All functions run with `verify_jwt = false` (set in `supabase/config.toml`), because guests call them with only the publishable key and Midtrans calls the webhook without a JWT. Each function therefore authenticates the caller itself:

- `optionalUser` / `requireUser` (`_shared/auth.ts`) verify bearer JWTs with `auth.getUser`. A legacy anon-key JWT is treated as a guest. An invalid session returns **401**; it is never silently downgraded to guest.
- Requests must be POST with JSON and a body of at most 16 KB (64 KB for the webhook). Each field is shape-validated in `_shared/validation.ts`, and the DB re-validates the business rules.
- CORS echoes only origins listed in `ALLOWED_ORIGINS`. **CORS is not authorization**: every function is safe to call from outside a browser.
- Errors map custom SQLSTATEs (`CSW40/03/04/09/29`) to HTTP codes. Unexpected errors return a generic 500. SQL text and stack traces are never returned.

| Function | Caller | DB access |
|---|---|---|
| create-publication, create-donation | guest or user | service role → trusted SQL with verified `p_user_id` |
| create-payment | owner (JWT) or receipt token | service role; Snap call with the server key |
| midtrans-webhook | Midtrans (signature + status API) | service role |
| redeem-referral-credit, create-ad-order, create-advertiser-campaign | user | service role with verified user id |
| manage-guest-publication | receipt token or owner | service role |
| leaderboard-data, admin-api | user | **user-scoped** client (JWT), so SQL checks `auth.uid()` itself |

## Secrets

| Secret | Where | Rotation |
|---|---|---|
| `MIDTRANS_SERVER_KEY` | `supabase secrets set` only | Regenerate in the Midtrans dashboard → `supabase secrets set` → old key stops working |
| Supabase secret key (`sb_secret_…`) | Injected into functions; used locally only for `bootstrap-admin.ts` | Dashboard → API Keys → create new, then delete old |
| Publishable key | `assets/js/config.js` (public by design) | Rotate if abused; redeploy the site |

Never commit `.env` (it is gitignored). If a secret is ever committed, **rotate it immediately**: removing it from git history is not enough.

## Browser hardening

`_headers` sets the following:

- CSP: `default-src 'self'`, `script-src 'self'`, `style-src 'self'`, Supabase-only `connect-src`/`img-src`, `frame-ancestors 'none'`, `object-src 'none'`.
- HSTS.
- `X-Content-Type-Options: nosniff`.
- `Referrer-Policy: strict-origin-when-cross-origin`.
- A restrictive `Permissions-Policy`.
- `X-Frame-Options: DENY`.

`scripts/build-site.sh` narrows `connect-src`/`img-src` to the exact Supabase project URL and removes `wss:`. The Midtrans redirect is a top-level navigation, validated against the `app.midtrans.com` / `app.sandbox.midtrans.com` hosts, so it needs no CSP allowance. `upgrade-insecure-requests` is deliberately omitted: every subresource is same-origin or an explicit `https://` origin, and the directive breaks local `wrangler pages dev` previews. The headers were checked in Cloudflare's local Pages runtime, but not yet on a real deployment.

### Keeping secret keys out of the browser

Only `sb_publishable_…` keys, or legacy JWT keys whose role is exactly `anon`, may appear in frontend files. `sb_secret_…` keys and legacy `service_role` JWTs bypass RLS. They are blocked in two places:

1. `classifyKey()` in `assets/js/config.js`: the site refuses to start and tells the operator to rotate the key.
2. `scripts/build-site.sh`: refuses the key, and also scans all of `dist/` for secret-looking values and non-anon JWTs.

## Known limitations

- Campaign impressions and clicks are client-reported and approximate (documented in reports).
- Guest reports are not supported: reporting requires an account, so that the open report endpoint does not become a spam vector. Guests can email the contact address.
- Rate limiting by IP depends on `x-forwarded-for` as set by the Supabase gateway.
- Refunds do not restore a redeemed referral credit automatically.

## Reporting a vulnerability

Email the contact address configured in the admin settings. Do not file a public issue.
