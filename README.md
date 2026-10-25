# Campus Sticky Wall

A public sticky-note wall for college students. Anyone can post a note and **choose what they pay to publish it (minimum Rp2.500, server cap Rp1.000.000)**. The site also has optional paid decorations, accounts with votes and bookmarks, referral credits, three member leaderboards, voluntary donations, a location-targeted Promotions section with paid campaigns, official announcements and an admin console.

- **Frontend:** static HTML, CSS and vanilla ES modules. There is no framework, no bundler and no build step. Supabase JS 2.117.0 is vendored.
- **Backend:** Supabase. It uses Auth, PostgreSQL with Row Level Security, Storage, and 10 Deno Edge Functions.
- **Payments:** Midtrans Snap (redirect). Every notification is checked with its signature and again with the Midtrans Get Status API.

> **Before going live:** work through the [First-deploy checklist](#first-deploy-checklist). The external integrations (hosted Supabase, Midtrans, Cloudflare) are confirmed there, on your accounts.

---

## Contents

1. [Project layout](#project-layout)
2. [Run locally](#run-locally)
3. [Configure Supabase](#configure-supabase)
4. [Configure Midtrans](#configure-midtrans)
5. [Configure and deploy the frontend](#configure-and-deploy-the-frontend)
6. [Bootstrap the first administrator](#bootstrap-the-first-administrator)
7. [First-deploy checklist](#first-deploy-checklist)
8. [Going live (production payments)](#going-live)

Related documents:

- [docs/BUSINESS_RULES.md](docs/BUSINESS_RULES.md): pricing, credits, referrals, targeting and revenue definitions.
- [SECURITY.md](SECURITY.md)
- [PRIVACY.md](PRIVACY.md)
- [OPERATIONS.md](OPERATIONS.md)
- [DEPENDENCIES.md](DEPENDENCIES.md)

---

## Project layout

| Path | Responsibility |
|---|---|
| `index.html` | Small shell: mount points, stylesheets, module entry. |
| `components/*.html` | `<template>`-only fragments. Each view has one: `core`, `wall`, `note-card`, `note-composer`, `promotions`, `promotion-card`, `announcements`, `auth`, `account`, `profile`, `referrals`, `leaderboard`, `checkout`, `donations`, `admin`, `footer`, `legal`. |
| `assets/css/` | `base.css` holds tokens and reset. `components.css`, `pages.css` and `responsive.css` hold the rest. |
| `assets/js/app.js` | Boots the app. It checks config, handles URL callbacks (PKCE, `?ref=`, Midtrans return), restores the session, renders the shell and starts the router. |
| `assets/js/router.js` | Hash router. It lazy-loads views, aborts listeners and requests on navigation, and ignores stale renders. |
| `assets/js/component-loader.js` | Loads trusted fragments and rejects scripts and inline handlers. |
| `assets/js/supabase-client.js` | Browser client (publishable key only), plus `rpc`/`query`/`invoke` wrappers with normalised errors. |
| `assets/js/{wall,notes,promotions,checkout,donations,account,referrals,leaderboard,announcements,admin,auth,location}.js` | Feature views. |
| `assets/js/{validation,utils,config}.js` | Client-side validation for usability only, safe DOM helpers, and public configuration. |
| `supabase/migrations/006…007` | Owner role, payment waivers, Owner-only deletion + security log, News attribution, 45 decorations (006); referral credits (007). |
| `supabase/migrations/001…005` | Schema, RLS, payments and referrals, promotions and locations, indexes, admin functions, and the function-execute allowlist. |
| `supabase/functions/*` | Edge Functions (see [SECURITY.md](SECURITY.md#edge-functions)). Each has `handler.ts` (logic) and a small `index.ts` entry point that serves it. `_shared/` holds auth, validation, Midtrans and security helpers. |
| `scripts/bootstrap-admin.ts` | Grants admin to an existing verified account (run from a trusted machine). |
| `scripts/build-site.sh` | Copies only the public files to `dist/`, writes `config.js` from `PUBLIC_*` variables, narrows the CSP to your Supabase project, and refuses to build if any secret key would ship. |
| `wrangler.toml` | Cloudflare Pages project settings (`pages_build_output_dir = "dist"`). |
| `_headers` | CSP, HSTS and other security headers (Cloudflare Pages / Netlify format). |

---

## Preview locally

Fragments and ES modules must be served over HTTP. Opening `index.html` as a `file://` URL does not work.

```bash
python3 -m http.server 8080        # from the project root
# open http://localhost:8080
```

If `assets/js/config.js` is not filled in, the page shows a "not configured" message that lists what is missing.

For a full local backend, use the Supabase CLI (requires Docker):

```bash
supabase start                      # local Postgres/Auth/Storage/Functions
supabase db reset                   # applies supabase/migrations/*
cp .env.example supabase/functions/.env   # then edit: Midtrans sandbox key etc.
supabase functions serve --env-file supabase/functions/.env
```

Put the printed local API URL and publishable/anon key into `assets/js/config.js`.

---

## Configure Supabase

1. **Create a project** at supabase.com, then link it: `supabase link --project-ref <ref>`.
2. **Apply the migrations**: `supabase db push`. This runs `001` → `005` in order.
3. **Configure Auth** (Dashboard → Authentication):
   - Turn on email confirmations. Referral credits are issued only after an account verifies its email.
   - Set **Site URL** to your deployed URL, and add it to **Redirect URLs**. The app uses the PKCE flow, so links come back as `?code=…` and the app exchanges the code itself.
   - Set the minimum password length to 8 or more, and keep the auth rate limits turned on.
4. **Storage**: migration 005 creates the public `campaign-creatives` bucket. Limits are 1 MB and png/jpeg/webp only. Uploads are allowed only into the uploader's own folder. Check that the bucket and its policies exist after `db push`.
5. **Deploy the functions**:

   ```bash
   supabase secrets set --env-file .env          # MIDTRANS_SERVER_KEY, MIDTRANS_IS_PRODUCTION, SITE_URL, ALLOWED_ORIGINS
   supabase functions deploy                     # all functions; verify_jwt=false is set per function in config.toml
   ```

   Every function verifies the caller itself, and the webhook verifies Midtrans itself. This is why `verify_jwt` is off. See [SECURITY.md](SECURITY.md).
6. **Schedule the expiry sweeper.** Enable `pg_cron` and run this in the SQL editor:

   ```sql
   select cron.schedule('expire-stale-orders', '*/5 * * * *', $$select public.expire_stale_orders()$$);
   ```

---

## Deploy everything from one GitHub repository

1. Push the release folder to a **private** GitHub repo. It contains no secrets; `.env` and `dist/` are gitignored.
2. **Backend (Supabase):** `.github/workflows/deploy-supabase.yml` runs on every push to `main` that changes `supabase/`. It applies migrations and deploys all Edge Functions. Add three repository secrets (GitHub → Settings → Secrets and variables → Actions):
   - `SUPABASE_ACCESS_TOKEN`, from supabase.com → Account → Access Tokens.
   - `SUPABASE_DB_PASSWORD`, the password you chose when you created the project.
   - `SUPABASE_PROJECT_ID`, your project ref.

   Then run the workflow once from the Actions tab (**Run workflow**).
3. **Function secrets:** set these once in Supabase → Edge Functions → Secrets, not in GitHub: `MIDTRANS_SERVER_KEY`, `MIDTRANS_IS_PRODUCTION=false`, `SITE_URL`, `ALLOWED_ORIGINS`.
4. **Website (Cloudflare Pages):** connect the same repo as described in [Configure and deploy the frontend](#configure-and-deploy-the-frontend). Cloudflare rebuilds the site on every push.

Some steps are still manual and done only once: the Auth URL settings and email confirmation, the `pg_cron` schedule, the Midtrans Notification URL, and the first admin.

---

## Configure Midtrans

1. Create a Midtrans account and use **Sandbox** first. Copy the sandbox **Server Key**, which starts with `SB-Mid-server-`, into the `MIDTRANS_SERVER_KEY` function secret. The client key is not needed, because checkout uses the Snap redirect URL.
2. In **Settings → Configuration**, set the **Payment Notification URL** to
   `https://<project-ref>.supabase.co/functions/v1/midtrans-webhook`.
3. Turn on the payment channels you want. Then, in **Admin → Prices & settings → Payment methods**, set each method's **min/max** from your merchant agreement. **The seeded limits are empty (unknown) on purpose.** A method is offered only when the order total fits its limits. Totals are never reduced to fit: if no method fits, the customer is told so.
4. Make a sandbox test payment end to end (see the [First-deploy checklist](#first-deploy-checklist)).

How it works:

- `create-payment` builds the Snap request from the database order, not from the browser. Amounts are sent as exact integers, and `enabled_payments` lists only the eligible channels.
- `midtrans-webhook` checks `SHA512(order_id+status_code+gross_amount+server_key)`, re-reads the transaction from the Get Status API, and passes only verified values to `apply_payment_notification`.
- That SQL function checks the amount and currency against the order, removes duplicate notifications, and applies only allowed state transitions.

---

## Configure and deploy the frontend

The chosen host is **Cloudflare Pages**: static files, `_headers` support, free TLS. Netlify works the same way.

```bash
PUBLIC_SUPABASE_URL=https://<ref>.supabase.co \
PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_... \
PUBLIC_SITE_URL=https://campus-sticky-wall.pages.dev \
scripts/build-site.sh dist

npx wrangler pages deploy dist --project-name campus-sticky-wall
```

- The script accepts only `sb_publishable_…` or a legacy JWT whose role is `anon`. It refuses `sb_secret_…`, legacy `service_role` JWTs and unknown formats. It also scans `dist/` and refuses to finish if any secret-looking value is present.
- It narrows the CSP in `dist/_headers` from `https://*.supabase.co` to your exact project URL, and drops `wss:` (realtime is not used).
- **Git integration instead of wrangler:** in Cloudflare Pages, set the build command to `bash scripts/build-site.sh dist`, the output directory to `dist`, and the three `PUBLIC_*` values as environment variables.
- In the Cloudflare dashboard for the domain, turn off features that inject scripts (Rocket Loader, Email Address Obfuscation, automatic Web Analytics). The CSP blocks injected scripts, and Rocket Loader breaks ES modules.
- Cloudflare Pages redirects `components/x.html` to `components/x` (308). The app follows the redirect; this is expected.
- Add the custom domain in Cloudflare Pages if you have one. Then update the Supabase Site URL, `SITE_URL` and `ALLOWED_ORIGINS` to match.
- After deploying, open the site and check that the wall loads, that `#/compose` shows decorations, and that the browser console has no CSP errors.

---

## Bootstrap the first administrator

1. Sign up on the site and verify your email.
2. On a trusted machine, run:

```bash
SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SECRET_KEY=sb_secret_... ADMIN_EMAIL=you@example.com \
  deno run --allow-env --allow-net scripts/bootstrap-admin.ts --dry-run   # then without --dry-run
```

To do the same with SQL instead, run this in the dashboard SQL editor:

`insert into public.user_roles (user_id, role, granted_by) select id, 'admin', 'sql' from auth.users where email = 'you@example.com';`

Admin status lives only in `public.user_roles`. No client role can write to it.

---

## First-deploy checklist

Confirm each item on your own accounts before taking real payments:

| Check | How |
|---|---|
| Migrations applied on hosted Supabase | `supabase db push` succeeds; Table Editor shows RLS enabled on every `public` table |
| Storage bucket and policies | Storage shows `campaign-creatives` (public, 1 MB, images only) |
| Edge Functions respond | On the site, post a note: the checkout page appears with the server-calculated total |
| Sign-up, email confirmation, password reset | Do all three on the deployed site |
| Midtrans sandbox payment | Pay a sandbox order. Then in SQL: `select result from payment_notifications order by received_at desc limit 1` returns `paid`, and the note is on the wall |
| Payment confirmed by the backend only | Before the notification arrives, the return page says "Waiting for payment" |
| Campaign image upload | Create a campaign with an image |
| Security headers | `curl -sI https://<your-site>/` shows the CSP with your exact Supabase URL; the browser console has no CSP errors |
| No secrets in the browser | DevTools → Sources: `config.js` contains only the URL and the publishable key |
| Payment-method limits | Set min/max per method in Admin → Prices & settings |
| Desktop and mobile layout | Check the wall, compose and checkout at phone width |

---

## Going live

Live payments are **not** turned on by default. Do not switch until you have explicit authorization and a successful sandbox run:

1. Get production approval from Midtrans and set the payment-method limits.
2. Run `supabase secrets set MIDTRANS_SERVER_KEY=Mid-server-... MIDTRANS_IS_PRODUCTION=true`. Payment functions refuse to run (HTTP 500, logged) if production mode is combined with a sandbox key.
3. Change the Notification URL in the **production** Midtrans dashboard.
4. Place one small real order. Then check the order, the notification log and the note.
