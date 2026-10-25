# Posting privacy (migration 012)

## What links an account to a note
| Link | Before 012 | After 012 |
|---|---|---|
| `notes.author_id` | stored forever | **never stored** (cleared right after creation) |
| `orders.user_id` | stored forever | cleared when a publication order is fulfilled |
| `credits/referral_credits.redeemed_order_id` | stored | cleared at fulfilment |
| `free_post_claims`, `promo_redemptions` | n/a | `user_id` + hour-rounded time; `order_id` only while the order is pending |
| Public media URL | contained the uploader's user id | moved to a random folder before the order is created; storage owner cleared at fulfilment |
| `notes.order_id` | note → order | kept (receipt, withdrawal, refunds need it) but the order no longer knows the user |

Custom names are plain text (`textContent`, no link, no handler, no data attribute). Names that match a registered display name (case, spacing, look-alike characters and full-width forms folded), reserved words, links, @handles and invisible characters are rejected.

## Cost of the safest option
- No per-account note counts: the **Notes leaderboard is empty** (hide that tab). A public per-account counter that changes when a note appears identifies the author.
- No "my notes" list and no self-vote block. Authors manage a note from the receipt link kept in their browser.
- Referral credits qualify on the first fulfilled post (paid or free), not on publication.

## What stays visible (be honest in the UI)
- Midtrans sees who paid, how much and when.
- Timing: the order's `paid_at` and the note's `published_at` are close. Someone with database access can still guess. Hardening if you need it: round `notes.published_at` to the hour, or publish in batches.
- The optional social link is public and chosen by the poster.
- A late payment on an already-expired order cannot publish (the note is deleted); it is flagged `payment_after_close` for a manual refund.

## Midtrans at Rp2.500 (docs.midtrans.com, "minimum and maximum transaction value")
Accepted at Rp2.500: QRIS, GoPay, ShopeePay, DANA, LinkAja, OVO (min Rp1), Alfamart (min Rp1), BNI/BRI/Permata/CIMB/Danamon VA (min Rp1).
**Not accepted:** cards (min Rp10.000), BCA VA (min Rp10.000), Indomaret (min Rp10.000), Seabank VA (Rp10.000), BSI VA (Rp1.000), Akulaku (Rp5.000).
Fees (published Midtrans rates, excl. VAT; confirm in your dashboard): QRIS 0,7% (~Rp18 on Rp2.500), GoPay/ShopeePay 2% (Rp50), DANA 1,5%. **Eats the payment:** virtual account flat ~Rp4.000 (more than the post), card 2,9% + Rp2.000, OTC (Alfamart/Indomaret) flat fees negotiated with the store. Migration 012 therefore sets `min_amount = 20000` on VA, card and convenience store: only QRIS and e-wallets are offered for small totals.
