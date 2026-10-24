# Part 1 release notes (migration 006)

Everything else below was run against Postgres 16 with a stubbed `auth` schema; no browser, Deno or Midtrans checks were run.

## Deploy order
1. Review migrations `006`, `007` and `008`. The deploy workflow runs `supabase db push` on merge to `main`, so merging deploys them. Open a pull request first: the new `Test` workflow applies and re-applies them on plain Postgres and runs the assertions.
2. Grant yourself Owner: `ADMIN_EMAIL=you@example.com deno run --allow-env --allow-net scripts/bootstrap-admin.ts --owner` (add `--dry-run` first), or SQL: `insert into public.user_roles (user_id, role, granted_by) select id, 'owner', 'sql' from auth.users where email = 'you@example.com' on conflict do nothing;`
3. Deploy functions (`admin-api` changed) and the static site (`decorations.css` is new).
4. Sign out and in again to see the Owner controls.

## What changed
| Area | Change |
|---|---|
| Roles | `owner` added. Owner passes every `is_admin()` check, so existing Admin policies keep working. No function edits roles. |
| Waivers | `admin_waive_order`. Status `payment_waived`, row in `payment_waivers`, audit entry. No Midtrans call, never in revenue totals. Admin: post-only orders. Owner: post and paid decorations. Advertising and donations are never waivable. Only before a payment session exists. Waived notes hide the amount badge. |
| Owner deletes | `owner_delete_record` for report, note, announcement, campaign, referral, audit entry, country, region, city, campus. Typed `DELETE` confirm in the UI and enforced in SQL. Orders, payments and credits are never deleted. Campaigns that are `active` or `awaiting_payment` are refused. Locations in use are refused. Referral delete keeps a tombstone; credits are untouched. |
| Security log | `security_events` is append-only (update, delete and truncate blocked by trigger). Every Owner delete is recorded there, including audit-entry deletes. Owner-only tab "Security log". |
| News | Existing announcements model reused. Admin tab and public page are labelled News (route stays `#/announcements`). Added Preview, last-editor column, text checks. Drafts stay private through existing RLS. |
| Terms | Fifth-bullet wording replaced in `components/legal.html` (the only copy in the frontend). |
| Decorations | 45 new designs (48 total, 11 new ones free), `category` column, swatch preview and Free label in the composer. CSS-only, no assets. |

## Known limits
- "Moderation records/actions" have no table. They are audit-log rows; delete them as audit entries.
- A database superuser can still disable the `security_events` triggers.
- Several decorations selected together can override each other's border or background.
- Pinned news is listed first, then newest first (existing behaviour).

## Referral credits (migration 007)
Both the inviter and the invited friend get **2 free posts + 2 free decorations**, shown as "Referral credits" with separate counters (free posts left, free decorations left).
- **When:** the friend's email is verified AND their first sticky post is published. One-time per invited account (atomic status flip plus unique key).
- **Free post:** the publication price is free; the note shows no amount. **Free decoration:** covers one paid decoration, most expensive first. Free decorations (price 0) never use a credit.
- **Mixing:** free decoration on a paid post and paid decoration on a free post both work; any combination is reserved in the same transaction as the order, and released if the order expires or is abandoned.
- **Not allowed:** ads, donations, cash-out, combining with the old Rp5.000 credit on one order.
- **Behaviour change:** the old verify-time Rp5.000 credit is **no longer issued**. Credits already issued still work. The referrer used to get nothing and now gets credits.
- **Admin:** `admin_revoke_referral_credits` (unused credits only, reason required, audited), with a button in the admin Referrals tab, which also shows each referral's credit count.
- **Limits:** credits are chosen on the compose page. To change them after the order exists, write a new note (the unpaid order expires and releases them). The checkout page hides the old credit toggle on such orders.
- Migration `008`: the Owner delete dialog now lists what else a delete removes (`owner_delete_preview`), countries can be deleted, News shows the last editor, and the referral leaderboard keeps counting a referral whose entry the Owner deleted.

## Automated checks
`.github/workflows/test.yml` (no deploy): applies all migrations and re-applies 006-008 on Postgres 16 with stubbed Supabase roles, runs `supabase/tests/assert_part1.sql` (about 50 assertions: roles, waivers, deletes, append-only log, referral credits, leaderboard), typechecks every edge function with Deno, and parses the browser JavaScript. Not covered: browsers, Midtrans, real Supabase Auth/RLS as the `authenticated` role.
