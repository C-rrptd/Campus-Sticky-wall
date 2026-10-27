# Business rules

The authoritative implementation of each rule is the SQL in `supabase/migrations/`. The browser only *estimates*. Each section names the function that enforces the rule.

## 1. Customer-defined publication price

- The customer chooses the publication price. **Minimum Rp2.500, hard cap Rp1.000.000** (migration 012). Both, the presets (Rp2.500 preselected, Rp5.000, Rp10.000) and the confirmation threshold (above Rp100.000) live in `site_config`: `min_publication_price`, `max_publication_price`, `price_presets`, `confirm_above_amount`. `public.min_publication_price()` / `max_publication_price()` read them; the browser reads the same rows.
- Amounts travel as **decimal strings of digits**. They are parsed exactly by `parse_amount`, which rejects signs, decimals, exponents and whitespace, and are stored as `BIGINT` whole rupiah.
- The only ceiling is technical: BIGINT holds up to 9.223.372.036.854.775.807. Larger values are rejected with `AMOUNT_EXCEEDS_STORAGE_LIMIT`, and nothing is ever rounded or capped.
- The browser parses with `BigInt`. The UI accepts "25.000" or "Rp 25.000" and has no `max` attribute. The customer must tick a confirmation of the exact total, and the server requires `confirm_amount == amount`.
- **Payment-method limits are not pricing limits.** `payment_methods.min_amount/max_amount` decide which channels are offered (`eligible_payment_methods`). If none fits, order creation fails with `NO_ELIGIBLE_PAYMENT_METHOD`, and the message says the amount was not changed.
- Snap receives the exact digits through a raw-JSON integer emitter, so values beyond `Number.MAX_SAFE_INTEGER` are not corrupted.


## 2. Totals

```
publication: total = chosen amount + Σ selected decoration prices − credit discount
credit discount  = least(Rp5.000, chosen amount) = Rp5.000   (chosen amount ≥ Rp5.000)
```

| Chosen | Decorations | Credit | Due |
|---:|---:|---:|---:|
| 5.000 | 0 | yes | **0** (completed without payment: `completed_free`) |
| 10.000 | 1.000 | yes | 6.000 |
| 50.000 | 4.000 | yes | 49.000 |
| 1.000.000 | 0 | yes | 995.000 |

- Decoration prices come from `decorations` at order time.
- Every order stores immutable `order_items` and a `snapshot`. A trigger forbids changes once a payment session exists or the order has left `awaiting_payment`.
- No surcharge or fee is ever added.

## 3. Publication lifecycle

1. `create_publication_order` validates the note, prices it, and creates the order, its items and the note (`awaiting_payment`). It reserves a credit if one is requested.
2. If the total is 0, `complete_free_order` runs. Otherwise, `create-payment` → `lock_order_for_payment` creates the Snap session once; later calls reuse it.
3. A verified `settlement`, or `capture` with fraud `accept`, triggers `fulfill_order`, exactly once. That step consumes the credit and publishes the note. In `pre` moderation mode the note goes to `pending_moderation` instead.
4. Failed, cancelled or expired orders run `abandon_order`, which releases the credit and sets the note to `payment_failed`.
5. A full refund or chargeback runs `reverse_order_effects`, which unpublishes the note. A partial refund keeps the note and records `refunded_amount`.
6. Unpaid orders with no session expire after `unpaid_order_ttl_minutes` (default 120). Sessions expire after 24 hours on Midtrans' side and 25 hours on ours.

## 4. Referral programme

- Every account gets an 8-character code (`A–Z`, `2–9` without look-alikes). The link is `SITE/?ref=CODE#/auth?mode=register`.
- At signup, the `referral_code` in user metadata is read **once**, by the `handle_new_user` trigger on `auth.users` insert. Later metadata edits change nothing.
- A referral is rejected for:
  - an invalid code (no attribution);
  - self-referral, detected by normalised email: case-insensitive, `+tag` stripped, Gmail dots and `googlemail.com` folded;
  - a suspended referrer.
- **The referred friend** gets one credit worth exactly Rp5.000 when their email is verified (`handle_user_confirmed` → `qualify_referral`). The referrer receives nothing except leaderboard credit.
- One credit per referred user (`unique(source, source_ref)`). Repeated verification events cannot issue another.
- Credit states: `available → reserved → redeemed`, or `revoked`. Admins can revoke only `available` credits, and must give an audited reason.
- A refund does not restore a redeemed credit.

## 5. Leaderboards (signed-in accounts only)

| Board | Counts | Excludes |
|---|---|---|
| Referrals | Qualified attributions whose credit is not revoked | pending, rejected, revoked |
| Donations | `kind = donation`, status `paid`/`partially_refunded` (minus refunded part), **only donors with `donor_recognition = true`** | purchases, ads, pending/failed/refunded/reversed, guests |
| Notes | Published notes with an author account | drafts, unpaid, rejected, removed, withdrawn, refunded |

Rows from suspended accounts are hidden. Periods are all time, or the current week starting **Monday 00:00 Asia/Jakarta**. Results are computed live, so opt-outs apply immediately.

## 6. Promotions and targeting

- Packages (`ad_products`) are defined by placement (`promotions_feed`, `wall_inline`, `featured`), scope level (`global`/`country`/`region`/`city`/`campus`), duration and a **base fee** (`price_per_target`, covers the first target) plus **extra_location_pct** (each added target costs that % of the base fee; default 100). The total is `public.ad_price(base, pct, targets)`, snapshotted on the campaign and charged as one order line.
- Every target must match the package's scope level, enforced by a CHECK constraint per level. Unknown or disabled locations are rejected.
- **Live** means status `active`, order `paid`, and now within `[starts_at, ends_at)`. Approval sets `starts_at = max(now, requested start)` and `ends_at = starts_at + duration`.
- **Matching** (`get_promotions`): the viewer's selection is resolved upwards (campus → city → region → country). A campaign matches if any target is global, or equals the resolved country, region, city or campus. Results are grouped per campaign (no duplicates) and sorted most specific first. Campus-targeted campaigns are shown only to that campus audience. A missing or invalid selection yields global campaigns only.
- Impressions (once per browser session per campaign, at 50% visible) and clicks are client-reported and approximate.

## 7. Donations

These are separate `kind = donation` orders with their own confirmation. The default limits are Rp1.000 to Rp100.000.000 (admin-editable; they apply to donations only). Donations never buy votes, placement or credits.

## 8. Revenue definitions (`admin_revenue_report`)

| Metric | Definition |
|---|---|
| publication_revenue | Σ(chosen amount − credit discount) for publication orders paid in the period |
| decoration_revenue | Σ decoration amounts of those orders |
| donations / advertising_revenue | Σ totals of donation / advertising orders paid in the period |
| gross_payment_volume | Σ totals of all orders paid through Midtrans in the period |
| refunds_and_reversals | Σ refunded amounts of those orders |
| net_collected | Gross minus refunds. **Not profit**: fees and costs are not deducted. |
| processing_fees | Not available from notifications; reported as `null` |
| average_order_value | Gross ÷ paid orders |
| checkout_completion_rate | Paid ÷ (sessions created in the period that reached a final state) |
| decoration_attachment_rate | Completed publications with any decoration ÷ completed publications |
| credits_issued / credits_redeemed | Referral-to-publication conversion inputs |
| campaign_impressions / clicks | Approximate, client-reported |
| campaign_renewals | Paid ad orders whose owner had an earlier paid ad order |


## Referral credits (Part 1, migration 007) — supersedes the reward in section 4
- Inviter and invited friend each receive 2 free post credits and 2 free decoration credits.
- Qualifies once, when the friend has a verified email and their first PAID sticky post (a paid order with a total above zero) is published. Free weekly posts, promo-zero and credit-only orders do not qualify (migration 024). Self-referrals, suspended referrers and unverified accounts do not qualify.
- A post credit makes the note's publication price free (no amount is shown on the note). A decoration credit makes one paid decoration free (highest price first). Free decorations never consume a credit.
- Post and decoration credits are independent and can be mixed with paid items. They cannot be used for ads or donations, have no cash value and cannot be combined with the old Rp5.000 credit on the same order.
- The old Rp5.000 verify-time credit is no longer issued; already-issued ones remain valid.

## Migration 012 — free weekly post, promo codes (supersedes the figures above where they differ)
- Free weekly post: one per account per week (Monday 00:00 Asia/Jakarta), claimed in `free_post_claims(user_id, week_start)`. It waives the minimum price only. Decorations are still paid.
- Promo codes (`promo_codes`, admin-created): percent (100 = free post) or fixed rupiah off, `max_uses`, `per_user_limit`, `expires_at`. They discount **the minimum price only**; the rest of the amount is a tip and is never discounted. Decorations are never discounted. A free weekly post, a promo code and credits cannot be combined. Promo and free post need an account.
- Race safety: `apply_post_discount` locks the code row (`FOR UPDATE`), so `uses` and the per-user count cannot be exceeded.
- Unpaid orders (and their post) are deleted after 30 minutes; a Snap session lasts 30 minutes from the moment payment starts. Failed, denied, cancelled and expired orders delete the pending post and return the promo use and the free post.
- Anonymity: see `docs/PRIVACY_POSTING.md`.

## Boosts and anonymity (migration 020)
- **Pin to top** (`pin-top`, Rp10.000) keeps a note first on the Newest wall for 7 days after it is published. **Highlight glow** (`highlight-glow`, Rp3.000) is cosmetic. Both are ordinary paid decorations, so pricing, credits and refunds work as for any decoration. Prices live in the `decorations` table.
- The amount paid is never shown on a note. The server always stores `show_amount = false`; the "Highest contribution" sort is removed from the wall.
- A note posted without a name is shown as **Anonymous**.
