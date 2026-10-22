# Operations

## Routine tasks

| When | Task | How |
|---|---|---|
| Daily | Moderate | Admin → **Moderation** (in `pre` mode, queue for approval) and **Reports**. Removing a note does not refund it; decide refunds case by case in the Midtrans dashboard. |
| Daily | Review campaigns | Admin → **Campaigns** (status `pending_review`). Approve only paid campaigns. The schedule starts at approval or at the requested date, whichever is later. |
| Daily | Payment exceptions | Admin → **Payments** → tick "needs review". Causes: `amount_or_currency_mismatch`, `fraud_challenge`, `payment_after_close` (money arrived for an expired/cancelled order: refund it in Midtrans or fulfil it manually), `partial_refund_amount_unknown`. Use **Reconcile with Midtrans** to re-read the status, then **Clear review flag** with a reason (audited). |
| Every 15 min | Expire unpaid orders | `pg_cron` job (see README) or Admin → Overview → "Expire stale unpaid orders". Releases reserved credits. |
| Weekly | Revenue | Admin → **Revenue**. Every figure carries its definition. Processing fees are *not* known to the app; take them from Midtrans settlement reports. |
| Monthly | Reconcile payments | Compare Admin → Payments (status `paid` / `refunded`) with the Midtrans transaction report for the same period. Investigate any `paid` order missing from Midtrans, or the reverse. |
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
| Checkout says "Online payments are not configured" | `supabase secrets list` shows `MIDTRANS_SERVER_KEY` and `SITE_URL`. |
| Payments stay "Waiting" | Midtrans dashboard → notification history (HTTP status from the webhook), then `supabase functions logs midtrans-webhook`. A 401 means signature failure (wrong server key for the environment). A 503 means the status API was unreachable; Midtrans retries. |
| "No enabled payment method can process this total" | Payment-method limits in Admin → Prices & settings. This is intended behaviour for totals above every configured limit. |
| Users cannot sign up or sign in | Supabase Auth logs; Site URL and redirect URLs; SMTP settings (Supabase's default mailer is rate-limited, so configure your own SMTP for production). |
| CSP errors in the console | `_headers` `connect-src`/`img-src` must include your Supabase URL. |
| Function returns 403 for an admin | Is the user in `user_roles`? Sign out and in again. |

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

See SECURITY.md → Secrets. After rotating `MIDTRANS_SERVER_KEY`, the webhook rejects notifications signed with the old key. Rotate during quiet hours and reconcile pending orders afterwards.

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
- [ ] Smoke test: wall loads, compose shows prices, sandbox checkout reaches Midtrans, admin panel loads.
