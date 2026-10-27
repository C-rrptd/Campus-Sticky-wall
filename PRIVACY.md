# Privacy

This is an operator-facing description of the data Campus Sticky Wall processes. **It is not legal advice and does not by itself make the service compliant** with Indonesia's PDP Law (UU 27/2022) or any other law. Review it with a qualified adviser before launch, and publish a user-facing notice. A starter notice is in `components/legal.html`.

## Data collected

| Data | Purpose | Visibility | Where |
|---|---|---|---|
| Note text, display name, colour, decorations, optional social link, optional campus | Publish the note | **Public** once published | `notes`, `note_decorations` |
| Chosen publication amount | Pricing, receipts, optional display | Public only if "show amount" is on; otherwise visible to the author and admins only | `notes.publication_amount`, `orders` |
| Account email, password (hashed by Supabase Auth) | Sign-in | Private; admins can see email | `auth.users` |
| Profile: display name, avatar URL, social links, location preference, donor recognition flag | Account features | Private to the user. The display name appears on leaderboards. | `profiles` |
| Votes, bookmarks | Features | Private to the user (vote counts are public) | `votes`, `bookmarks` |
| Reports | Moderation | Reporter and admins | `reports` |
| Orders, order items, payment status, payment type | Payments, reconciliation | User (own orders) and admins | `orders`, `order_items` |
| Midtrans notification payloads (signature redacted) | Audit, dispute handling | Admins (via the database) | `payment_notifications.raw` |
| Guest receipt token **hash** | Guest receipt access | Never exposed | `orders.guest_token_hash` |
| Referral code, attribution, credits | Referral programme | User; admins | `referral_codes`, `referral_attributions`, `credits` |
| Advertiser name, contact email, campaign content, targeting | Advertising | Campaign content is public when live; contact data is for admins and the owner | `campaigns`, `campaign_targets` |
| Aggregate impressions and clicks per campaign per day | Reporting | Owner, admins | `campaign_daily_stats` |
| Ad views and clicks: a one-way hash of IP address + browser string (salted with a server secret, so it cannot be reversed or linked across sites), the hour, the ad, and the location. For clicks also the referring site's domain and any `utm_*` tags on the landing link. Bots and admin sessions are not counted. | Counting unique visitors, advertiser statistics, pricing analytics | Aggregates are shown to the advertiser and (anonymised) on the public statistics page; the hashed rows are admins only | `ad_impression_log` (deleted after 100 days), `ad_click_log`, `ad_location_daily` |
| Ad waitlist: email, wanted placement, length and optional maximum budget | Tell you when a slot opens | Admins (counts only on the admin dashboard) | `ad_waitlist` |
| Auction bids: bidder account, amount, a one-way hash of the IP address | Run auctions, detect several accounts on one network | Admins only. Other bidders and the public never see who bid. | `ad_bids`, `ad_auction_flags` |
| Outgoing ad email queue (address, notice type) | Send waitlist, report and auction emails | Admins (via the database) | `ad_outbox` |
| IP-based rate-limit counters (key only, no payload) | Abuse prevention | Never exposed; windows purged after about 1 day | `rate_limits` |

Not collected:

- Card or wallet credentials. Midtrans hosts the payment page.
- Precise location (no GPS).
- Analytics or advertising cookies (no third-party scripts).

Browser storage holds the Supabase session, guest receipt tokens for this device, the location preference and UI preferences.

## Donor recognition

Donor recognition is **off by default**. A donor appears on the donor leaderboard (public, visible to guests too) only after they opt in through Profile, or the checkbox on the donation form. Opting out removes them immediately, because leaderboards are computed live and nothing is cached. Guest donations are never linked to any identity.

## Processors

- **Supabase:** database, authentication, storage, functions. Choose a region near your users.
- **Midtrans:** payment processing.
- **Static host** (e.g. Cloudflare Pages): standard request logs.

## Retention and deletion

- Account deletion is handled by request (Profile → "Request account deletion"). An admin deletes the user in the Supabase dashboard. Database rules then apply:
  - Profile, votes, bookmarks, referral code and credits cascade.
  - Notes and orders keep their records with `author_id`/`user_id` set to null, for financial reconciliation.
  - Campaigns owned by the user are deleted.
- Payment records (orders, items, notifications) are kept for accounting. Decide and document your retention period with your adviser.
- Guests can take down their own note with their receipt link. This hides it from the wall; it is not a refund.

## Media uploaded to notes
Images, GIFs and videos you attach to a note are stored in public Storage and visible to anyone once the note is published. Photos are re-saved in your browser without camera metadata (such as GPS location). In MP4 videos embedded GPS coordinates are overwritten, but other video metadata is kept, so check videos yourself. Files are deleted when a note is removed, rejected, withdrawn or deleted.
