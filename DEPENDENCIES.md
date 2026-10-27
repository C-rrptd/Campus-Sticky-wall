# Dependencies

The dependency set is intentionally small. There is no frontend framework, bundler, ORM, analytics or state library.

## Runtime

| Dependency | Version | Purpose | Used by | Required | Notes |
|---|---|---|---|---|---|
| `@supabase/supabase-js` (UMD, vendored) | 2.117.0 (MIT) | Auth session (PKCE), REST/RPC, Functions, Storage from the browser | `assets/vendor/supabase-2.117.0.umd.js`, loaded by `index.html`, wrapped by `assets/js/supabase-client.js` | Yes | Vendored, so the CSP stays `script-src 'self'`. SHA-256 `7b9e9c64109e15c338fa58c2bc77c32fb1c459bd587e22fc6b72cca80a388645`. |
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
   cp package/dist/umd/supabase.js assets/vendor/supabase-<ver>.umd.js
   ```

   Then update the `<script>` tag in `index.html`, the import version in `_shared/auth.ts` and `bootstrap-admin.ts`, and this file (including the new SHA-256). Run the development test suite. Delete the old vendored file.
2. **Database:** never edit an applied migration. Add `006_*.sql`. If it creates functions, **repeat the EXECUTE allowlist pattern** from the end of `005`: revoke from `public, anon, authenticated`, then grant explicitly.
3. **Midtrans API changes:** update `_shared/payments.ts` and its tests together. Verify in sandbox.
4. **Deno:** run `deno task check` and the test suite after any upgrade.

## Added: video compression (browser, lazy-loaded)

| Dependency | Version | Purpose | Used by | Required | Notes |
|---|---|---|---|---|---|
| `mediabunny` (vendored, esbuild bundle of Input/Output/Conversion, MP4 + WebM) | 1.62.1 (MPL-2.0) | Re-encodes attached videos to ~800 kbps H.264 MP4 before upload | `assets/vendor/mediabunny-1.62.1.min.js`, loaded by `assets/js/video-compress.js` only when a video is attached | No | Unmodified library code. MPL-2.0 is file-level: keep its license notice if you redistribute the bundle. Needs WebCodecs; otherwise the original file is uploaded (10 MB cap). Rebuild: `npm i mediabunny esbuild`, then `esbuild entry.js --bundle --minify --format=esm --outfile=mediabunny-<ver>.min.js` with `entry.js` exporting `Input, Output, Conversion, BlobSource, BufferTarget, Mp4OutputFormat, MP4, WEBM, canEncodeVideo, canEncodeAudio`. |

## Changed: vendored supabase-js is now a build without Realtime

`assets/vendor/supabase-2.117.0.umd.js` was replaced by `assets/vendor/supabase-2.117.0.lite.js` (same 2.117.0, MIT; 217 KB to 169 KB, 55 KB to 43 KB gzipped). It is an esbuild IIFE bundle (global `supabase`) of `@supabase/supabase-js@2.117.0` with `@supabase/realtime-js` replaced by a no-op stub, because the app never uses Realtime. Do not call `.channel()` on this client. SHA-256 `51e6350a5327701d3c754efc7ac880129d4834e788fdecf968f77e87c99b9156`.
Rebuild: `npm i @supabase/supabase-js@<ver> esbuild`, entry `export * from "@supabase/supabase-js"`, `esbuild entry.js --bundle --minify --format=iife --global-name=supabase --target=es2020 --alias:@supabase/realtime-js=./rt-stub.js`, where `rt-stub.js` exports no-op `RealtimeClient` (`setAuth`, `channel`, `getChannels`, `removeChannel`, `removeAllChannels`, `disconnect`) and an empty `RealtimeChannel`. For this file, use this recipe instead of the `npm pack` UMD copy in step 1 of "Updating safely".
