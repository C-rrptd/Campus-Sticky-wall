# Operations

## Routine tasks

| When | Task | How |
|---|---|---|
| Daily | Moderate | Admin → **Moderation** (in `pre` mode, queue for approval) and **Reports**. Removing a note does not refund it. Under the Terms of Use, refunds are not provided for deleted notes or campaigns or for content removed for rule violations, except where applicable law requires; do not promise refunds to users. Any exception is made by the Owner in the DOKU dashboard. |
| Daily | Review campaigns | Admin → **Campaigns** (status `pending_approval`). Approve = the advertiser may now pay; Reject needs a reason the advertiser sees. After payment the campaign is scheduled and goes live on its start date, then ends automatically (migration 013). Paid campaigns you reject or cancel, and paid ones the advertiser cancels before start, appear under Payments → needs review: refund them in the DOKU dashboard (the webhook then marks the campaign cancelled). Set the WhatsApp number and the days-to-pay window under Prices & settings. |
| Daily | Payment exceptions | Admin → **Payments** → tick "needs review". Causes: `amount_or_currency_mismatch`, `fraud_challenge`, `payment_after_close` (money arrived for an expired/cancelled order: refund it in DOKU or fulfil it manually), `partial_refund_amount_unknown`. Use **Reconcile with DOKU** to re-read the status, then **Clear review flag** with a reason (audited). |
| Every 15 min | Expire unpaid orders | `pg_cron` job (see README) or Admin → Overview → "Expire stale unpaid orders". Releases reserved credits. |
| Every hour | Daily digest | Call the `daily-digest` function with header `x-cron-secret: $CRON_SECRET` (see "Daily digest email" below). Emails each member the previous day's most upvoted note once per local day, from 8 AM in their campus time zone. |
| Every 5 min | Advertising jobs | Call the `ad-maintenance` function with header `x-cron-secret: $CRON_SECRET` (see "Advertising jobs" below), or Admin → **Ad insights** → "Run ad jobs now". Sends campaign-end reports, expires waitlist holds and offers freed slots, sends queued ad email, settles auctions. |
| Weekly | Revenue | Admin → **Revenue**. Every figure carries its definition. Processing fees are *not* known to the app; take them from DOKU settlement reports. |
| Monthly | Reconcile payments | Compare Admin → Payments (status `paid` / `refunded`) with the DOKU transaction report for the same period. Investigate any `paid` order missing from DOKU, or the reverse. |
| As needed | Prices | Admin → **Prices & settings**. Decoration and ad-package prices affect **new** orders only; existing orders keep immutable snapshots. The publication price minimum (Rp5.000) and the absence of a maximum are fixed product rules. |
| As needed | Locations | Admin → **Locations**: add a country, then its regions, cities and campuses. Disabling a location removes it from pickers and targeting. |

## Payment state machine (for troubleshooting)

```
awaiting_payment ─settlement / capture+accept─▶ paid ─refund─▶ refunded
      │      └─capture+challenge─▶ challenge ─▶ paid | failed     │
      │                                                 partial_refund ─▶ partially_refunded ─▶ refunded | reversed
      ├─deny / failure / fraud deny─▶ failed       paid ─chargeback─▶ reversed
      ├─cancel─▶ canceled
      └─expire (or sweeper)─▶ expired        (failed/canceled/expired) + success ─▶ review_required (never auto-fulfilled)
credit (total 0) ─▶ completed_free
```

Every notification is logged in `payment_notifications`. The `result` column takes one of these values: `paid`, `duplicate`, `no_change`, `amount_mismatch`, `ignored_regression`, `ignored_terminal`, `needs_review`, `unknown_order`, `unrecognized_status`.

```sql
select order_ref, transaction_status, fraud_status, result, received_at
from payment_notifications order by received_at desc limit 50;
```

## Diagnosing errors

| Symptom | Check |
|---|---|
| "not configured" page | `assets/js/config.js` values. Rebuild with `scripts/build-site.sh`. |
| Checkout says "Online payments are not configured" | `supabase secrets list` shows `DOKU_CLIENT_ID`, `DOKU_SECRET_KEY` and `SITE_URL`. |
| Payments stay "Waiting" | DOKU dashboard → notification history (HTTP status from the webhook), then `supabase functions logs doku-webhook`. A 401 means signature failure (wrong secret key for the environment, or the Notification URL path differs from `/functions/v1/doku-webhook`). Use Admin → Reconcile to pull the status directly. |
| "No enabled payment method can process this total" | Payment-method limits in Admin → Prices & settings. This is intended behaviour for totals above every configured limit. |
| Users cannot sign up or sign in | Supabase Auth logs; Site URL and redirect URLs; SMTP settings (Supabase's default mailer is rate-limited, so configure your own SMTP for production). |
| CSP errors in the console | `_headers` `connect-src`/`img-src` must include your Supabase URL. |
| Function returns 403 for an admin | Is `profiles.role` set to `admin` or `owner` for the user? Sign out and in again. |

## Migrations

1. Write a new numbered file (`supabase/migrations/006_*.sql`). Do not edit applied migrations.
2. Run the automated test suites in the development repository. They apply every migration to a fresh database and catch missing RLS, missing `search_path`, and over-broad function grants.
3. Apply with `supabase db push`, then `supabase functions deploy` if any functions changed.
4. Prefer additive changes. For breaking changes, deploy the backend first in a backwards-compatible form, then the frontend, then remove the old paths.

## Backups and restore

- Supabase takes daily backups on paid plans; enable Point-in-Time Recovery if you need it.
- Take an extra logical backup before risky migrations: `supabase db dump -f backup.sql` and `supabase db dump --data-only -f data.sql`.
- Restore into a **new** project first and verify it before switching traffic.
- Storage (campaign images) is not included in database dumps. Copy the bucket separately if needed.

## Secret rotation

See SECURITY.md → Secrets. After rotating `DOKU_SECRET_KEY`, the webhook rejects notifications signed with the old key. Rotate during quiet hours and reconcile pending orders afterwards.

## Cloudflare R2 for note media (optional)

Photos, GIFs and videos attached to notes can be stored in Cloudflare R2 instead of Supabase Storage. Browsers upload straight to R2; nothing is proxied. Old notes keep loading from Supabase, and with no R2 settings everything works as before.

1. Cloudflare → R2 → create a bucket. Connect a custom domain (for example `media.yourdomain`) and turn on public access for it.
2. Bucket → Settings → CORS: allow origin = your site, method `PUT`, header `Content-Type`.
3. Bucket → Settings → Object lifecycle: delete objects with prefix `tmp/` after 1 day (abandoned uploads).
4. R2 → Manage API tokens: create a token with Object Read & Write for this bucket only.
5. Supabase secrets: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, and `MEDIA_TOKEN_SECRET` (random, at least 32 characters, for example `openssl rand -hex 32`).
6. Apply migration `048_r2_media.sql`, then deploy: `supabase functions deploy media-upload create-publication admin-api manage-guest-publication` (the functions that upload or purge media).
7. Build the site with `PUBLIC_MEDIA_BASE=https://media.yourdomain scripts/build-site.sh`. This writes the address into config.js and allows it in the CSP.
8. Optional smaller images: enable Cloudflare Images → Transformations for the domain, then add `PUBLIC_MEDIA_RESIZE=1` to the build. The wall then loads 400 px thumbnails and the viewer 1280 px, in WebP or AVIF, converted by Cloudflare.

How it works: `media-upload` hands out 15-minute upload URLs into `tmp/` plus a signed receipt. `create-publication` checks the receipt, the size and the real file type (first bytes), then copies the file to its final key. Files are never changed after that, so they are cached for a year. Deleting a note removes its R2 files through the normal cleanup queue.

Limits to know: a file copied to its final key stays there even if the order then fails (it is public but unreferenced and is not cleaned up automatically). R2 does not enforce the upload size in the signed URL, so an oversized upload can sit in `tmp/` until the lifecycle rule removes it (it is rejected when the note is created). Cloudflare Images transformations are billed after the free monthly allowance. Videos are served as uploaded; they are already compressed in the browser.

## Advertising jobs

The `ad-maintenance` Edge Function runs every advertising background job and is safe to call as often as you like (each job is idempotent). Set two secrets and schedule it:

```
supabase secrets set CRON_SECRET=<random string of 32+ characters> SITE_URL=https://your-site.example
supabase functions deploy ad-maintenance auction-bid ad-click
```

Schedule with `pg_cron` + `pg_net` (or any external scheduler) every 5 minutes:

```sql
select cron.schedule('ad-maintenance', '*/5 * * * *', $$
  select net.http_post(url := 'https://<project>.functions.supabase.co/ad-maintenance',
                       headers := jsonb_build_object('x-cron-secret', '<CRON_SECRET>')) $$);
```

## Daily digest email

Every member with a verified email gets one email a day at 8 AM in their university's time zone (WIB, WITA or WIT from the region; WIB when none is set) with the note that received the most upvotes the previous local day on their campus, or on the whole site when the campus had none. It is on by default; members turn it off under Profile, or with the link at the bottom of every email.

```bash
supabase functions deploy daily-digest digest-unsubscribe
# needs CRON_SECRET, SITE_URL, RESEND_API_KEY and EMAIL_FROM (already set for ad email)
```
```sql
select cron.schedule('daily-digest', '0 * * * *', $$
  select net.http_post(url := 'https://<project>.functions.supabase.co/daily-digest',
                       headers := jsonb_build_object('x-cron-secret', '<CRON_SECRET>')) $$);
```

Each run sends to members whose local time is between 8:00 and 11:59 and who were not emailed that local day, so one missed hour still delivers the same morning. A member is marked as sent before the email goes out, so a crash can skip a day but never double-sends. Unsubscribe links are signed with CRON_SECRET: rotating that secret invalidates old links.

What it does: emails an advertiser a summary when a campaign ends; expires waitlist holds and offers a freed slot to the next waiting person; queues price proposals when "suggest a price step" is on (you still approve each one); sends queued emails (waitlist offers, auction notices); and, only when auctions are on, settles ended auctions, moves unpaid winners to the next bidder (with a strike) and sends ending-soon and payment-reminder emails. Without this job nothing time-based happens: waitlist holds never expire, auctions never close.

Pricing, slots and auctions are all managed under Admin → **Prices & settings**, **Ad insights**, **Slots & utilization** and **Auctions**. Every price, slot-count and auction change is written to the audit log with old and new values. Auctions ship **off**; see `docs/ADS_PHASES.md` before turning them on.

## Display advertising

Third-party display ads are **off** (`display_ads_enabled = false`) and no provider is integrated. Before enabling:

- Confirm the site is eligible.
- Integrate the provider.
- Add its domains to the CSP.
- Never use incentivised clicks, forced refreshes or bots.

Paid Promotions are separate and always labelled "Sponsored".

## Safe updates checklist

- [ ] The development repository test suite passes.
- [ ] New functions/migrations follow the EXECUTE allowlist pattern.
- [ ] `scripts/build-site.sh dist` with production `PUBLIC_*` values; deploy `dist/` only.
- [ ] Smoke test: wall loads, compose shows prices, sandbox checkout reaches DOKU, admin panel loads.
