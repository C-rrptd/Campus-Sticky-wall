# Part 1 release notes (migration 006)

Everything else below was run against Postgres 16 with a stubbed `auth` schema; no browser, Deno or Midtrans checks were run.

## Deploy order
1. Review migrations `006`-`009`. The deploy workflow runs `supabase db push` on merge to `main`, so merging deploys them. Open a pull request first: the new `Test` workflow applies and re-applies them on plain Postgres and runs the assertions.
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

## Note media (migration 009)
- Signed-in users can attach up to 4 JPG/PNG/WebP/GIF/MP4/WebM files (25 MB each) to a note. Files go to the public `note-media` bucket under the user's own folder; the note stores `[{path, kind}]` in `notes.media`. Guests cannot attach files (storage upload needs a session).
- Wall: a note with media shows "Contains media" instead of its text; long text is cut with "…". Clicking a note opens a viewer with the full text and media. Moderators see media links in the admin notes list.
- CSP gains `media-src`; `scripts/build-site.sh` now expects 3 `*.supabase.co` wildcards.
- Known limits: attachments are not scanned or moderated before publish (moderators can hide the note); files uploaded for an order that later fails stay in storage; the bucket and its policies are not exercised by the plain-Postgres CI (no `storage` schema).

## Automated checks
`.github/workflows/test.yml` (no deploy): applies all migrations and re-applies 006-009 on Postgres 16 with stubbed Supabase roles, runs `supabase/tests/assert_part1.sql` (about 50 assertions: roles, waivers, deletes, append-only log, referral credits, leaderboard), typechecks every edge function with Deno, and parses the browser JavaScript. Not covered: browsers, Midtrans, real Supabase Auth/RLS as the `authenticated` role.

## Media follow-ups (migration 010, on top of the existing 009)
`main` already had its own media feature (migration 009: signed-in users upload straight into their own Storage folder; `notes.media`). These changes build on it.
- **Removed notes lose their files.** When a note becomes removed, rejected, withdrawn, refunded or payment-failed, or is deleted, its files are queued (`media_orphans`) and detached from the note. `admin-api` (overview, moderate note, owner delete) and `manage-guest-publication` (withdraw) delete the queued files from Storage right after. A restored note does not get its files back. If Storage is down, the queue stays and the next call retries.
- **Video thumbnails:** the enlarged view shows the video's first frame before play (`#t=0.1`). No stored thumbnail files.
- **Upload cleaning (browser):** JPEG/PNG/WebP photos are re-drawn on a canvas so GPS and camera data are not published (a photo that cannot be cleaned is not uploaded; scaled to 4096px; animated WebP becomes a still). MP4 videos get a best-effort overwrite of embedded GPS coordinates; other video metadata stays. **Videos are not re-encoded:** that needs ffmpeg, which Edge Functions and browsers do not have without a large extra download.
- **Upload limit:** the Storage insert policy now allows 20 new files per user per hour.
- **Known gaps:** the server does not check uploaded files' real type (the browser's declared type is trusted, bucket limits apply); files from an order that fails before creation stay in Storage; guests cannot attach media; no alt text.
- Tests: `supabase/tests/assert_media_cleanup.sql`, `supabase/functions/_shared/media_test.ts`, `tests/media-clean.test.mjs`. The upload-limit policy was tested locally against a stubbed Storage schema; it is skipped in CI because plain Postgres has no Storage.

## Draggable stickers and the referral-credits checkbox (migration 011)
- **Stickers:** 18 decorations (stickers, stamps, badges, hearts, emoji) are now "placeable": the author drags them anywhere on the live preview in the composer (mouse, touch or pen), or focuses one and uses the arrow keys (Shift moves 10%). Position is saved as a percentage of the note, so it looks the same at any size. Frames, paper textures, borders and washes stay whole-note decorations. A sticker that was never moved sits at its catalog default spot, which also covers notes created before this release.
- **Server:** `note_decorations.pos_x/pos_y`, `decorations.placeable/default_x/default_y`. `note_json` adds `placements` (decorations is unchanged). `create_publication_order_full` is now the single entry point for order + referral credits + media + positions in one transaction; positions are validated (selected, placeable, numbers within 0-100, at most 10) and a bad request creates nothing.
- **Referral credits:** the compose page now has one optional checkbox "Pay with my referral credits" (shown only when you have credits). Checking it applies a free post and as many free decorations as possible; the two sub-options can be changed and a live line shows what will be used. The old Rp5.000 credit and referral credits still cannot be combined.
- **Limits:** stickers cannot be moved after the note is created; two stickers can overlap; the enlarged view on the wall is a plain text/media viewer and does not show stickers.
- Tests: `supabase/tests/assert_stickers.sql`. A jsdom test of sticker rendering, pointer dragging and keyboard moves passed locally but is not in the repo; the composer checkbox logic was not exercised in a browser.

## Repeated stickers and the decorations dropdowns (migration 017)
- **Repeats:** a sticker, stamp or badge can be added to a note several times. Each copy is priced, charged and credited on its own (`quote_publication` returns one line per copy; `note_decorations` has one row per copy). Frames, tapes, papers and themes stay one each. A note has at most 200 decorations in total (migration 018; a sanity ceiling).
- **Composer:** one dropdown per whole-note category (None or one choice), plus one "Stickers, stamps and badges" dropdown that adds a copy. Added stickers show as rows with a − / + counter. Copies start a step apart so they do not hide each other.
- **API:** `decoration_positions` is now a list `[{id,x,y,rot}]`, one per copy; the old `{ "<id>": {x,y,rot} }` form is still accepted. `note_json` gains `stickers` (one entry per copy); `placements` stays for clients cached from before 017 and can be dropped later.
- **Deploy order:** run `017_repeat_stickers.sql`, deploy `create-publication` (and `check-promo` is unchanged), then the site.
- Tests: `supabase/tests/assert_repeat_stickers.sql` (needs psql like the others). The older `assert_posting_v2.sql`, `assert_sticker_rotation.sql` and, with its `\gset` lines emulated, `assert_stickers.sql` also pass on 017.
