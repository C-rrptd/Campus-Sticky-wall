# Advertising system: launch pricing, slots, auctions

Three phases, each with its own migration, rollback and automated tests. Each was finished and verified before the next one started. Auctions (phase 3) ship **switched off**.

| Phase | Migration | Rollback | SQL assertions |
|---|---|---|---|
| 1. Launch pricing, tracking, trust | `032_launch_pricing_tracking.sql` | `supabase/rollbacks/032_rollback.sql` | `supabase/tests/assert_phase1.sql` |
| 2. Slots, utilization, waitlist pricing | `033_slots_utilization_waitlist.sql` | `supabase/rollbacks/033_rollback.sql` | `supabase/tests/assert_phase2.sql` |
| 3. Auctions (off by default) | `034_auctions.sql` | `supabase/rollbacks/034_rollback.sql` | `supabase/tests/assert_phase3.sql` |

All three migrations are idempotent (safe to run twice). Run a rollback only in reverse order (034, then 033, then 032). A rollback restores the earlier functions exactly and **drops the data in the tables the phase added** (impressions, waitlist rows, bids and so on). Take a backup first.

## Rules that hold everywhere

- Existing orders and campaigns are never repriced. A campaign freezes `price_snapshot` when it is submitted; an order freezes `total_amount` when payment starts. Every change below affects new quotes only. The tests check this after each kind of change (package price, launch mode, multiplier, approved price proposal, auction win).
- All state, deadline and money logic runs in the database on the server clock. The browser only displays.
- Every price change, slot-count change, auction switch and admin override is written to `admin_audit_log` with who, when, old and new values.
- No invented numbers. Without data the pages say "New platform, launch pricing applies" or "Not enough data".
- Settings that used to need a code change are `site_config` keys validated by `config_rules`; `admin_set_config` checks the type and range and audits the old value.

## Phase 1: launch pricing, tracking, trust

**What changed**

- Launch mode (off by default) with a discount percent. When on, new quotes show the struck-through list price, the discounted price and a "Founding advertiser rate" badge. A package can override the percent.
- The 14-day packages are disabled, not deleted. Existing 14-day orders and campaigns are untouched.
- Price lock: the first N paying advertisers (default 10) keep the rate they first paid, per package, when they renew within the grace window (default 7 days) after a campaign ends. The advertiser dashboard and the admin order and campaign lists show "Your rate is locked at Rp X". N and the grace days are settings. Existing paid orders were backfilled.
- Admin package editor: the surcharge column is renamed "% per extra location" with a formula tooltip, a live computed preview, validation (price above 0, surcharge 0 to 100, duration from a fixed list), clear success and error messages, a warning on changes above 50%, and a confirmation when the change affects active campaigns.
- Tracking: one impression per visitor per ad per hour (a salted hash of IP and browser, never stored raw), bots and admin sessions excluded, clicks recorded on the server through the `ad-click` function (which redirects only to the destination stored on the campaign), referrer domain and UTM tags kept.
- Public statistics page (`#/stats`) and advertiser dashboard: views, clicks, click-through rate, daily chart, dates, a CSV download, and an optional end-of-campaign report email.
- Admin "Ad insights": per spot and location, for 7 or 30 days: impressions, unique visitors, clicks, CTR, fill rate, and a suggested weekly price (average weekly views × target CPM ÷ 1,000) with a warning at ±30%. It shows "not enough data" until 14 days of history exist.
- Buyer trust: real recent views per location on the buy form, ad guidelines, and the existing approval queue.
- "Notify me" waitlist for sold-out or hidden packages, with counts for admins.

**Files**: `supabase/migrations/032_*`, `supabase/rollbacks/032_*`, `supabase/tests/assert_phase1.sql`, `supabase/tests/assert_ads_v3.sql` (no longer requires the 14-day tier), `supabase/functions/ad-click/*`, `supabase/functions/ad-maintenance/*`, `supabase/functions/_shared/ad_jobs.ts`, `supabase/functions/admin-api/handler.ts`, `supabase/config.toml`, `assets/js/admin.js`, `assets/js/advertise.js`, `assets/js/ad-tracking.js`, `assets/js/promotions.js`, `assets/js/stats.js`, `assets/js/router.js`, `assets/js/mock-supabase.js`, `assets/css/advertise.css`, `components/admin.html`, `components/advertise.html`, `components/stats.html`, `components/footer.html`.

**Manual test steps**

1. *Launch mode*: Admin → Prices & settings, turn launch mode on with 50%. Open Advertise: the price shows struck-through list price, the discounted price and the badge. Turn it off: list price only. A campaign submitted while it was on keeps its discounted price.
2. *Price lock on renewal*: pay for a campaign as a first-time advertiser (you become founding advertiser #1). Raise that package's price. Within 7 days after the campaign ends, submit the same package again: the quote equals your original rate and the dashboard shows the locked-rate banner. After the grace window, or for an 11th advertiser, the current price applies.
3. *Tracking dedupe*: open the site as a visitor and reload the Featured spot ten times within an hour: Admin → Ad insights shows 1 view. Open it signed in as admin or with a bot user agent (`curl`): not counted. Click the ad: the click count rises by one and the redirect goes to the stored link.
4. *Formula preview*: Prices & settings → edit a package; change the base fee and the percent per extra location: the preview for 1, 2 and 5 locations updates live and matches `base + base × pct × (n−1)`. Try a price of 0, a surcharge of 150 and a 14-day duration: each is rejected with a message. Change a price by more than 50% and change a package with live campaigns: each asks for confirmation.

## Phase 2: slots, utilization, waitlist pricing

**What changed**

- Slots per location (default 3, range 1 to 10; a location with no row uses the default). Optional **top** and **standard** slot types with price multipliers (defaults 1.5 and 1.0) and a rotation mode, `equal_share` (random order, expected share shown) or `fixed_position` (top slot first, then oldest booking). The buy form shows "1 of 3 slots left", the next free date and the expected share.
- Reducing slots never touches running campaigns. It only lowers the free count, so it blocks new sales. Capacity is enforced twice: an early warning at submit, and the authoritative check inside `create_ad_order` under a per-location advisory lock, so two buyers cannot take the last slot. Error code `SOLD_OUT`.
- Utilization: fill rate over 7, 30 and 90 days, average days to sell out, waitlist size and a status (Underfilled below 50%, Healthy 50 to 85%, Sold out above 85%; both limits are settings). Recommendations are text only.
- Waitlist and escalation without bidding: email, length and an optional maximum budget. When a slot frees, `process_ad_waitlist` offers it to the longest-waiting person whose budget covers the normal price, with a hold (default 24 hours). The hold keeps others from buying that slot; when it lapses, the next person is offered it. An optional price step (default 20%, maximum 30%, off by default) creates a **proposal** for a location that sold out in the last 30 days; an admin approves or rejects each one. Approval changes the package price for future quotes only, and it is refused if the price changed since the proposal. Price history per package shows the 30-day fill before and after each change.
- A small mail queue (`ad_outbox`) sends the waitlist emails; the same queue carries the auction emails in phase 3.

**Files**: `supabase/migrations/033_*`, `supabase/rollbacks/033_*`, `supabase/tests/assert_phase2.sql`, `supabase/functions/_shared/ad_jobs.ts` (+ `ad_jobs_test.ts`), `supabase/functions/admin-api/handler.ts`, `supabase/functions/create-advertiser-campaign/handler.ts`, `assets/js/admin.js` (Slots & utilization tab), `assets/js/advertise.js`, `components/admin.html`, `components/advertise.html`, `assets/css/advertise.css`, `assets/js/mock-supabase.js`.

**Manual test steps**

1. *Reduce slots with active campaigns*: with three live Featured campaigns on one campus, set that campus to 2 slots in Slots & utilization. The three campaigns keep running; the buy form for that campus now says sold out and shows the next free date; the admin sees a note that new sales are blocked.
2. *Sold out → waitlist → hold → expiry*: with the campus full, join the waitlist from the buy form with two different emails (the second with a budget below the price). Cancel one of the campaigns. Run "Run ad jobs now": the first person gets an email and a 24-hour hold; the buy form for anyone else says sold out. Set the hold to expire (or wait), run the jobs again: the hold is released and the next eligible person is offered the slot. The person holding it can submit and the waitlist row becomes "claimed".
3. *Top slot*: set a campus to 3 slots with 1 top slot. A top submission shows 1.5× the price; a second top submission is refused while the top slot is taken; standard submissions still work.
4. *Price proposal*: turn on the price step, make a campus sell out for 30 days, press "Check for proposals now". Approving the proposal changes the price for new submissions only; the old campaigns and orders keep their prices.

## Phase 3: auctions (off by default)

**What changed**

- Global switch (`auctions_enabled`, no admin setting can flip it except the dedicated function, which needs the typed phrase `ENABLE AUCTIONS`), per-location flags, a readiness panel (default: fill above 85% in each of the last 4 weeks and a waitlist of at least 2 × the slot count), an override that needs a written reason and is audited, and a **kill switch** that turns auctions off and cancels every open auction.
- Rules: only the next period of a **full** slot is auctioned (the slot that frees first). Reserve = the current fixed price. Buy now = 1.5 × reserve. Minimum raise Rp10,000 (a setting). Highest valid bid wins; equal amounts go to the earliest bid. Length 72 hours. A bid in the last 5 minutes extends the end by 5 minutes, at most 6 times. Bids need a verified email, are tied to the bidder's own approved Featured ad for that location and package, cannot be withdrawn, and never reveal the bidder. While an auction is open or waiting for payment, that slot is held and cannot be bought at the fixed price.
- Safety: `place_bid` locks the auction row so bids are strictly serial; the bid endpoint is rate-limited per account and per IP at the edge (the limiter keeps counting rejected bids) and again in SQL; several accounts bidding from one network are flagged for admin review; admins can cancel a bid or an auction with a reason and see the full bid log.
- **Payment assumption**: Midtrans Snap here is a one-time charge for e-wallets, virtual accounts and cards. It has no authorization hold, so **no money is taken at bid time**. The winner gets a 24-hour payment window (the campaign price becomes the winning bid, and `create_ad_order` copies it onto the order, where it can never change). If the winner has not paid by the deadline, the offer lapses, the campaign returns to its original price, the winner gets a strike (3 strikes block bidding; an admin can clear them) and the next bidder is offered the slot at their own bid. A payment already started and still open is allowed to finish. Payment capture is the existing idempotent `fulfill_order`.
- Founding price locks lower only the **reserve** (the lowest first bid) for a founding advertiser. A winner always pays exactly their bid.
- Emails: outbid, ending within one hour, won, lost, payment reminder, auction canceled.

**Files**: `supabase/migrations/034_*`, `supabase/rollbacks/034_*`, `supabase/tests/assert_phase3.sql`, `supabase/functions/auction-bid/*`, `supabase/functions/_shared/ad_jobs.ts`, `supabase/functions/admin-api/handler.ts`, `supabase/config.toml`, `assets/js/admin.js` (Auctions tab), `assets/js/advertise.js`, `components/admin.html`, `components/advertise.html`, `assets/css/advertise.css`, `assets/js/mock-supabase.js`.

**Manual test steps** (use a test location; turn on only that one)

1. *Turn on*: Admin → Auctions → "Turn auctions on…", type `ENABLE AUCTIONS`. Enable one full location; an unready location needs a written override reason. Start an auction for it.
2. *Last-minute extension*: with two test accounts holding approved ads for that package and location, bid until the auction has under 5 minutes left (an admin can shorten `ends_at` in the database for the test), then bid again: the end moves out by 5 minutes and the bid log shows the extension count.
3. *Tie handling*: equal top amounts cannot be placed through the app (each bid must beat the last by the minimum raise). To see the rule, the SQL test inserts equal bids directly; the earliest wins. After an admin cancels the leading bid, the next valid bid leads.
4. *Unpaid winner*: end an auction with two bidders; the winner does not pay. After the payment window (shorten `pay_by` for the test) run the ad jobs: the winner gets a strike, the second bidder is offered the slot at their own bid, and the first campaign is back at its original price. Let the second also lapse: the auction ends with no winner and the slot is released for fixed-price sale.
5. *Kill switch*: with an auction open and bids placed, press Kill switch with a reason. Every open auction is canceled, bidding returns `AUCTIONS_OFF`, the public list is empty, and fixed-price buying is unchanged.

## Automated tests

- SQL (`supabase/tests/assert_phase1.sql`, `assert_phase2.sql`, `assert_phase3.sql`, plus all earlier suites): price immutability of existing orders and campaigns, price-lock logic and grace window, impression dedupe, bot and admin exclusion, slot reduction with active campaigns, sold-out → waitlist → hold → expiry → next person, multipliers, utilization status thresholds, price proposals not retroactive, auction reserve enforcement, minimum raise, winner selection, tie-breaking, anti-sniping extension and its cap, identity hiding, buy-now, winning price on the order, unpaid-winner fallback and strikes, kill switch.
- Deno (`supabase/functions/**/*_test.ts`): click redirect and counting, bid handler passes the authenticated user and IP and cannot be given a different bidder, mail rendering.
- Node (`tests/*.test.mjs`): existing front-end tests still pass.
- CI (`.github/workflows/test.yml`) runs all of them, and re-applies the migrations to prove they are idempotent.

## Assumptions and things not done

- "Spot" means the Featured placement or the Random placement (feed and wall-inline ads share the Random rotation). **Slots, multipliers, utilization and auctions apply to Featured only**; Random has no cap.
- Price lock and price proposals work per **package tier** (for example "Featured, campus, 30 days"), not per campus: package prices are tier-wide in this system, so price history is per tier too.
- Launch mode defaults to **off** and the end-of-campaign report email defaults to **on**; both are settings.
- The price-lock backfill for advertisers who paid before this release uses each package's current "% per extra location".
- Waitlist rows with no specific location (for example "any campus") count toward waitlist size but are never offered a slot automatically.
- No same-payment-method check for multi-account detection: no money is taken at bid time, so there is no payment method to compare. Accounts are flagged by shared network (hashed IP) only. Flags are for review; nothing is blocked automatically.
- Auctions are opened by an admin, not automatically. The utilization numbers and readiness panel tell you when to.
- "Fill rate" and "days to sell out" are measured against today's slot count. After changing slots, older weeks are measured against the new count. "Days to sell out" counts from 14 days before a week starts (the farthest-ahead start date a buyer can pick) to the payment that took the last slot of that week.
- A click log older than the impression log is kept (impressions are deleted after 100 days; clicks are not purged yet).
- Email delivery, Midtrans payment and the live scheduler were not run against real services in testing: they are covered by unit tests with fakes and by the SQL suites. Do a sandbox payment and one cron run before turning auctions on.
- Bid rate limits count only accepted bids inside SQL; the edge function adds a limiter that counts rejected bids too.
