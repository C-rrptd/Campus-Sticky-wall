# Dependencies

The dependency set is intentionally small. There is no frontend framework, bundler, ORM, analytics or state library.

## Runtime

| Dependency | Version | Purpose | Used by | Required | Notes |
|---|---|---|---|---|---|
| `@supabase/supabase-js` (UMD, vendored) | 2.117.0 (MIT) | Auth session (PKCE), REST/RPC, Functions, Storage from the browser | `assets/js/vendor/supabase-2.117.0.umd.js`, loaded by `index.html`, wrapped by `assets/js/supabase-client.js` | Yes | Vendored, so the CSP stays `script-src 'self'`. SHA-256 `7b9e9c64109e15c338fa58c2bc77c32fb1c459bd587e22fc6b72cca80a388645`. |
| `npm:@supabase/supabase-js` | 2.117.0 | Service and user DB clients and Auth admin in Edge Functions | `supabase/functions/_shared/auth.ts`, `scripts/bootstrap-admin.ts` | Yes | Pinned inline (`npm:` specifier) |
| Supabase platform | — | Postgres 15+ (verified on 15, 16 and 17), Auth, Storage, Edge Runtime (Deno 2) | everything | Yes | |
| Midtrans Snap and Core API | Snap v1, API v2 | Payments, Get Status | `_shared/payments.ts` | Yes for payments | Plain `fetch`; no SDK |
| `pg_cron` (Postgres extension) | Supabase-provided | Runs `expire_stale_orders()` | OPERATIONS.md | Recommended | Without it, run the sweeper from the admin panel |

## Development tooling (not shipped to browsers)

| Dependency | Version | Purpose |
|---|---|---|
| Deno | 2.9.x | `deno check`, `deno lint`, `bootstrap-admin.ts` |
| Node.js | 22 | `node --check` syntax pass |
| Python 3 | 3.x | Used by `scripts/build-site.sh` (config generation, CSP narrowing, secret scan) |
| Supabase CLI | latest | Local stack, `db push`, `functions deploy`, `secrets set` |
| Wrangler (Cloudflare) | 4.145.0 (tested) | `pages deploy` |

Test-only tooling (pytest, Playwright, `npm:postgres`) is documented in the development repository.

## Updating safely

1. **supabase-js (browser):**

   ```bash
   npm pack @supabase/supabase-js@<ver>
   tar xzf supabase-supabase-js-<ver>.tgz
   cp package/dist/umd/supabase.js assets/js/vendor/supabase-<ver>.umd.js
   ```

   Then update the `<script>` tag in `index.html`, the import version in `_shared/auth.ts` and `bootstrap-admin.ts`, and this file (including the new SHA-256). Run the development test suite. Delete the old vendored file.
2. **Database:** never edit an applied migration. Add `006_*.sql`. If it creates functions, **repeat the EXECUTE allowlist pattern** from the end of `005`: revoke from `public, anon, authenticated`, then grant explicitly.
3. **Midtrans API changes:** update `_shared/payments.ts` and its tests together. Verify in sandbox.
4. **Deno:** run `deno task check` and the test suite after any upgrade.
