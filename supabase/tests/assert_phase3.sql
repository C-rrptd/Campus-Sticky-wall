-- Migration 034 assertions (Phase 3): auctions are OFF by default; reserve, minimum raise, tie-break, anti-sniping,
-- identity hiding, buy-now, winner payment at the winning price, unpaid-winner fallback + strikes, kill switch.
-- Run after 001-034 and stub_auth.sql on an EMPTY database.
\set ON_ERROR_STOP on
begin;

create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, true) $$;
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create function pg_temp.expect_err(stmt text, code text) returns void language plpgsql as $$
begin
  begin execute stmt;
  exception when others then
    if sqlerrm like '%' || code || '%' then return; end if;
    raise exception 'expected %, got: %  [%]', code, sqlerrm, stmt;
  end;
  raise exception 'expected % but statement succeeded: %', code, stmt;
end $$;
create function pg_temp.campus(n int) returns uuid language sql as $$ select id from public.campuses where enabled order by id offset n limit 1 $$;
create function pg_temp.key(n int) returns text language sql as $$ select 'campus:' || pg_temp.campus(n) $$;
create function pg_temp.uid(n int) returns uuid language sql as $$ select ('00000000-0000-0000-0000-0000000000' || lpad(to_hex(n), 2, '0'))::uuid $$;
create function pg_temp.sub(u uuid, email text, prod text, campus_n int) returns uuid language sql as $$
  select (public.upsert_campaign_draft(u, null, 'Kopi Kita', email, 'Student coffee', 'Cheap coffee for students', 'local_business',
    null, null, prod, (now() at time zone 'Asia/Jakarta')::date,
    jsonb_build_array(jsonb_build_object('level', 'campus', 'id', pg_temp.campus(campus_n))), 'standard') ->> 'campaign_id')::uuid
$$;
create function pg_temp.approve(c uuid) returns void language plpgsql as $$
declare o uuid := (select owner_id from public.campaigns where id = c);
begin
  perform pg_temp.as_user(pg_temp.uid(160)::text);
  perform public.admin_review_campaign(c, 'approve', null);
  perform pg_temp.as_user(o::text);
end $$;
create function pg_temp.pay(c uuid) returns jsonb language plpgsql as $$
declare o uuid; own uuid := (select owner_id from public.campaigns where id = c); r jsonb;
begin
  r := public.create_ad_order(own, c, repeat('a', 64));
  select order_id into o from public.campaigns where id = c;
  update public.orders set status = 'paid', paid_at = now() where id = o;
  perform public.fulfill_order(o);
  return r;
end $$;
create function pg_temp.full(u uuid, email text, prod text, campus_n int) returns uuid language plpgsql as $$
declare c uuid := pg_temp.sub(u, email, prod, campus_n);
begin perform pg_temp.approve(c); perform pg_temp.pay(c); return c; end $$;
-- bidder's approved ad for the auctioned slot
create function pg_temp.ad(u uuid, campus_n int) returns uuid language plpgsql as $$
declare c uuid := pg_temp.sub(u, 'bid' || u || '@t.id', 'featured-campus-7d', campus_n);
begin perform pg_temp.approve(c); return c; end $$;
create function pg_temp.bid(u uuid, a uuid, c uuid, amt bigint, ip text default null, buy boolean default false) returns jsonb language sql as $$
  select public.place_bid(u, a, c, amt, coalesce(ip, 'ip-' || u), buy)
$$;
create function pg_temp.bid_err(u uuid, a uuid, c uuid, amt bigint, code text, ip text default null, buy boolean default false) returns void language plpgsql as $$
begin
  begin perform pg_temp.bid(u, a, c, amt, ip, buy);
  exception when others then
    if sqlerrm like '%' || code || '%' then return; end if;
    raise exception 'expected %, got: %', code, sqlerrm;
  end;
  raise exception 'expected % but the bid succeeded', code;
end $$;
create function pg_temp.avail(campus_n int, start_in int default 0) returns int language sql as $$
  select (public.ad_capacity(pg_temp.key(campus_n), 'standard', (now() at time zone 'Asia/Jakarta')::date + start_in, 7, null, 'nobody@t.id') ->> 'available')::int
$$;
create function pg_temp.mails(kind text, who uuid default null) returns bigint language sql as $$
  select count(*) from public.ad_outbox where ad_outbox.kind = $1 and (who is null or user_id = who)
$$;

insert into auth.users (id, email, email_confirmed_at) values
  (pg_temp.uid(160), 'admin@t.id', now()),
  (pg_temp.uid(1), 'a1@t.id', now()), (pg_temp.uid(2), 'a2@t.id', now()), (pg_temp.uid(3), 'a3@t.id', now()),
  (pg_temp.uid(177), 'b1@t.id', now()), (pg_temp.uid(178), 'b2@t.id', now()), (pg_temp.uid(179), 'b3@t.id', now()),
  (pg_temp.uid(180), 'b4@t.id', now()), (pg_temp.uid(181), 'unverified@t.id', null);
insert into public.user_roles (user_id, role) values (pg_temp.uid(160), 'admin');
select pg_temp.uid(160) as admin, pg_temp.uid(1) as a1, pg_temp.uid(2) as a2, pg_temp.uid(3) as a3,
       pg_temp.uid(177) as b1, pg_temp.uid(178) as b2, pg_temp.uid(179) as b3, pg_temp.uid(180) as b4, pg_temp.uid(181) as unv \gset

-- ---- 3.1 shipped OFF ---------------------------------------------------------------------------------------
select pg_temp.must(not public.auctions_on(), 'auctions OFF by default');
select pg_temp.as_user(:'a1');
select pg_temp.full(:'a1', 'k@t.id', 'featured-campus-7d', 0) as f1 \gset
select pg_temp.as_user(:'a2');
select pg_temp.full(:'a2', 'k2@t.id', 'featured-campus-7d', 0) as f2 \gset
select pg_temp.as_user(:'a3');
select pg_temp.full(:'a3', 'k3@t.id', 'featured-campus-7d', 0) as f3 \gset
select pg_temp.must(pg_temp.avail(0) = 0, 'campus 0 is full');
select pg_temp.must(public.list_open_auctions() = '[]'::jsonb, 'nothing listed while OFF');
select pg_temp.as_user(:'admin');
select pg_temp.expect_err($$select public.admin_open_auction(pg_temp.key(0), 'featured-campus-7d')$$, 'AUCTIONS_OFF');
select pg_temp.expect_err($$select public.admin_set_config('auctions_enabled', 'true')$$, 'CONFIG_KEY_NOT_EDITABLE');
select pg_temp.as_user(:'a1');
select pg_temp.expect_err($$select public.admin_set_auctions_enabled(true, 'ENABLE AUCTIONS')$$, 'FORBIDDEN');
select pg_temp.as_user(:'admin');
select pg_temp.expect_err($$select public.admin_set_auctions_enabled(true, 'yes')$$, 'CONFIRM_REQUIRED');
select public.admin_set_auctions_enabled(true, 'ENABLE AUCTIONS');
select pg_temp.must(public.auctions_on(), 'enabled with the confirmation phrase');
select pg_temp.must((select details ->> 'new' from public.admin_audit_log where action = 'auction.global' order by created_at desc limit 1) = 'true', 'global switch audited');

-- ---- 3.1 readiness + override --------------------------------------------------------------------------------
select pg_temp.expect_err($$select public.admin_open_auction(pg_temp.key(0), 'featured-campus-7d')$$, 'LOCATION_OFF');
select pg_temp.must(not (public.auction_readiness(pg_temp.key(0)) ->> 'ready')::boolean, 'new location is not ready');
select pg_temp.expect_err($$select public.admin_set_auction_location(pg_temp.key(0), true)$$, 'NOT_READY');
select pg_temp.expect_err($$select public.admin_set_auction_location(pg_temp.key(0), true, 'no')$$, 'NOT_READY');
select pg_temp.must((public.admin_set_auction_location(pg_temp.key(0), true, 'Pilot with the first campus') ->> 'override')::boolean, 'override accepted with a reason');
select pg_temp.must((select reason from public.admin_audit_log where action = 'auction.location' order by created_at desc limit 1) = 'Pilot with the first campus', 'override reason audited');
-- a location that really qualifies needs no override: 4 weeks > 85% fill and waitlist >= 2 x slots
select pg_temp.as_user(:'a1');
select pg_temp.full(:'a1', 'k@t.id', 'featured-campus-7d', 2) as r1 \gset
select pg_temp.full(:'a2', 'k2@t.id', 'featured-campus-7d', 2) as r2 \gset
select pg_temp.full(:'a3', 'k3@t.id', 'featured-campus-7d', 2) as r3 \gset
update public.campaigns set starts_at = now() - interval '40 days', ends_at = now() + interval '50 days' where id in (:'r1', :'r2', :'r3');
insert into public.ad_waitlist (email, spot, scope_level, target_key, desired_duration)
  select 'w' || i || '@t.id', 'featured', 'campus', pg_temp.key(2), 7 from generate_series(1, 5) i;
select pg_temp.must(not (public.auction_readiness(pg_temp.key(2)) ->> 'ready')::boolean, '5 waiting < 2 x 3 slots: not ready');
insert into public.ad_waitlist (email, spot, scope_level, target_key, desired_duration) values ('w6@t.id', 'featured', 'campus', pg_temp.key(2), 7);
select pg_temp.must((public.auction_readiness(pg_temp.key(2)) ->> 'ready')::boolean, '4 weeks > 85% + waitlist 6 = ready');
select pg_temp.as_user(:'admin');
select pg_temp.must(not (public.admin_set_auction_location(pg_temp.key(2), true) ->> 'override')::boolean, 'ready location enabled without override');
select public.admin_set_auction_location(pg_temp.key(2), false);

-- ---- 3.2 opening: only a FULL slot, next period, reserve = fixed price, buy-now 1.5x ------------------------------
select pg_temp.expect_err($$select public.admin_open_auction(pg_temp.key(1), 'featured-campus-7d')$$, 'LOCATION_OFF');
select public.admin_set_auction_location(pg_temp.key(1), true, 'Pilot second campus');
select pg_temp.expect_err($$select public.admin_open_auction(pg_temp.key(1), 'featured-campus-7d')$$, 'NOT_FULL');
select public.admin_set_config('auction_hours', '168');
select pg_temp.expect_err($$select public.admin_open_auction(pg_temp.key(0), 'featured-campus-7d')$$, 'AUCTION_TOO_LATE');
select public.admin_set_config('auction_hours', '72');
select pg_temp.expect_err($$select public.admin_open_auction(pg_temp.key(0), 'featured-city-7d')$$, 'INVALID_PRODUCT');
select public.admin_open_auction(pg_temp.key(0), 'featured-campus-7d') ->> 'id' as au \gset
select pg_temp.expect_err($$select public.admin_open_auction(pg_temp.key(0), 'featured-campus-7d')$$, 'AUCTION_EXISTS');
select pg_temp.must((select reserve_amount from public.ad_auctions where id = :'au') = 60000, 'reserve = current fixed price');
select pg_temp.must((select buy_now_amount from public.ad_auctions where id = :'au') = 90000, 'buy-now = 1.5 x reserve');
select pg_temp.must((select period_start from public.ad_auctions where id = :'au') = (now() at time zone 'Asia/Jakarta')::date + 8, 'auction is for the next period (when a slot frees)');
select pg_temp.must((select ends_at - starts_at from public.ad_auctions where id = :'au') = interval '72 hours', 'runs 72h');
select period_start as ps from public.ad_auctions where id = :'au' \gset
-- the raise ladder below is long; lift buy-now for this auction so it does not end it early (buy-now is tested on au3)
update public.ad_auctions set buy_now_amount = 1000000 where id = :'au';
select pg_temp.must(public.ad_active_holds(pg_temp.key(0), 'x', null) = 1 and pg_temp.avail(0, 8) = 2, 'one of the freed slots is reserved for the auction (the others stay sellable at the fixed price)');

-- ---- 3.2 bidding rules -----------------------------------------------------------------------------------------
select pg_temp.as_user(:'a1');
select pg_temp.ad(:'a1', 0) as ca1 \gset
select pg_temp.ad(:'b1', 0) as cb1 \gset
select pg_temp.ad(:'b2', 0) as cb2 \gset
select pg_temp.ad(:'b3', 0) as cb3 \gset
select pg_temp.ad(:'b4', 0) as cb4 \gset
select pg_temp.ad(:'unv', 0) as cun \gset
-- founding price lock applies to the RESERVE only: a1's lock lets a1 open at 40000; everyone else's minimum is 60000
update public.founding_rates set base_fee = 40000 where user_id = :'a1' and product_id = 'featured-campus-7d';
select pg_temp.must(public.auction_reserve_for(:'a1', (select a from public.ad_auctions a where id = :'au')) = 40000, 'founding lock lowers a1 reserve');
select pg_temp.must(public.auction_reserve_for(:'b1', (select a from public.ad_auctions a where id = :'au')) = 60000, 'others pay the public reserve');
select pg_temp.bid_err(:'unv', :'au', :'cun', 60000, 'EMAIL_NOT_VERIFIED');
select pg_temp.bid_err(:'b1', :'au', :'f2', 60000, 'CAMPAIGN_NOT_ELIGIBLE');
select pg_temp.bid_err(:'b2', :'au', :'cb2', 59999, 'BID_TOO_LOW');
select pg_temp.must((pg_temp.bid(:'a1', :'au', :'ca1', 40000) ->> 'amount') = '40000', 'a1 opens at their locked reserve');
select pg_temp.bid_err(:'a1', :'au', :'ca1', 90000, 'ALREADY_HIGHEST');
select pg_temp.bid_err(:'b2', :'au', :'cb2', 49999, 'BID_TOO_LOW');
select pg_temp.bid(:'b2', :'au', :'cb2', 50000);
select pg_temp.must(pg_temp.mails('auction_outbid', :'a1') = 1, 'previous leader got an outbid email');
select pg_temp.bid_err(:'b3', :'au', :'cb3', 50000, 'BID_TOO_LOW');
select pg_temp.bid_err(:'b3', :'au', :'cb3', 59999, 'BID_TOO_LOW');
-- rate limit (the bid endpoints also have an edge-level limiter)
select count(public.check_rate_limit('bid:u:' || :'b4', 20, 60)) from generate_series(1, 20);
select pg_temp.bid_err(:'b4', :'au', :'cb4', 60000, 'RATE_LIMITED');
-- same network, two accounts -> flagged, not blocked
select pg_temp.bid(:'b3', :'au', :'cb3', 60000, 'shared-ip');
select pg_temp.bid(:'b1', :'au', :'cb1', 70000, 'shared-ip');
select pg_temp.must(exists (select 1 from public.ad_auction_flags where auction_id = :'au' and kind = 'same_ip'), 'same-IP multi-account flagged');
-- identity stays hidden; the bidder sees only whether they lead
select pg_temp.as_user(:'b1');
select pg_temp.must((public.list_open_auctions() -> 0 ->> 'leading')::boolean, 'leader sees leading=true');
select pg_temp.must(position(:'b1' in public.list_open_auctions()::text) = 0 and position('b1@t.id' in public.list_open_auctions()::text) = 0, 'public list never reveals bidders');
select pg_temp.as_user(:'b2');
select pg_temp.must(not (public.list_open_auctions() -> 0 ->> 'leading')::boolean and (public.list_open_auctions() -> 0 ->> 'min_next_bid') = '80000', 'others: not leading, next minimum = high + 10000');
select pg_temp.must((select payload::text from public.ad_outbox where kind = 'auction_outbid' order by created_at desc limit 1) not like '%b1%', 'outbid mail does not name the new leader');

-- ---- 3.2 anti-sniping ------------------------------------------------------------------------------------------
select pg_temp.must(public.auction_extended_end('2026-01-01 10:00+00', '2026-01-01 09:56+00', 0) = '2026-01-01 10:05+00', 'bid in last 5 min: +5 min');
select pg_temp.must(public.auction_extended_end('2026-01-01 10:00+00', '2026-01-01 09:50+00', 0) = '2026-01-01 10:00+00', 'earlier bid: no extension');
select pg_temp.must(public.auction_extended_end('2026-01-01 10:00+00', '2026-01-01 09:59+00', 6) = '2026-01-01 10:00+00', 'max 6 extensions');
update public.ad_auctions set ends_at = now() + interval '3 minutes' where id = :'au';
select ends_at as e0 from public.ad_auctions where id = :'au' \gset
select pg_temp.bid(:'b2', :'au', :'cb2', 80000);
select pg_temp.must((select ends_at from public.ad_auctions where id = :'au') = :'e0'::timestamptz + interval '5 minutes' and (select extensions from public.ad_auctions where id = :'au') = 1, 'last-minute bid extends by 5 min');
update public.ad_auctions set ends_at = now() + interval '30 minutes' where id = :'au';
select ends_at as e1 from public.ad_auctions where id = :'au' \gset
select pg_temp.bid(:'b3', :'au', :'cb3', 90000, 'shared-ip');
select pg_temp.must((select ends_at from public.ad_auctions where id = :'au') = :'e1'::timestamptz, 'early bid does not extend');
update public.ad_auctions set ends_at = now() + interval '2 minutes', extensions = 6 where id = :'au';
select ends_at as e2 from public.ad_auctions where id = :'au' \gset
select pg_temp.bid(:'b2', :'au', :'cb2', 100000);
select pg_temp.must((select ends_at from public.ad_auctions where id = :'au') = :'e2'::timestamptz, 'no extension after 6');

-- ---- 3.2 winner selection + tie-break -----------------------------------------------------------------------------
-- Equal top amounts can only arise from admin cancellations / data repair; the rule is still earliest bid first.
insert into public.ad_bids (auction_id, bidder_id, campaign_id, amount, created_at) values
  (:'au', :'b3', :'cb3', 200000, now() - interval '2 minutes'),
  (:'au', :'b1', :'cb1', 200000, now() - interval '1 minute'),
  (:'au', :'b2', :'cb2', 200000, now() - interval '30 seconds');
select pg_temp.must((select bidder_id from public.auction_pick_winner(:'au')) = :'b3', 'tie on amount: the earliest bid wins');
select pg_temp.must((select amount from public.auction_pick_winner(:'au')) = 200000, 'highest valid bid wins');
select pg_temp.as_user(:'admin');
select pg_temp.expect_err($$select public.admin_cancel_bid((select id from public.ad_bids where amount = 200000 and bidder_id = pg_temp.uid(179)), '')$$, 'REASON_REQUIRED');
select public.admin_cancel_bid((select id from public.ad_bids where amount = 200000 and bidder_id = pg_temp.uid(179)), 'Bid placed by a duplicate account');
select pg_temp.must((select bidder_id from public.auction_pick_winner(:'au')) = :'b1', 'after cancelling the leader the next earliest tied bid leads');
select pg_temp.must((public.admin_auction_bids(:'au') -> 'bids' -> 0 ->> 'email') is not null, 'admin sees the bid log with identities');
select pg_temp.must(exists (select 1 from public.admin_audit_log where action = 'auction.cancel_bid' and reason = 'Bid placed by a duplicate account'), 'bid cancellation audited with reason');
select pg_temp.must(jsonb_array_length(public.admin_auction_bids(:'au') -> 'flags') = 1, 'admin sees the same-IP flag');
-- a blocked (3 strikes) bidder is skipped when picking a winner
insert into public.ad_auction_strikes (user_id) select :'b1' from generate_series(1, 3);
select pg_temp.must((select bidder_id from public.auction_pick_winner(:'au')) = :'b2', 'blocked bidder skipped; next valid bid wins');
select public.admin_clear_strikes(:'b1', 'Support resolved the dispute');
select pg_temp.must((select bidder_id from public.auction_pick_winner(:'au')) = :'b1', 'strikes cleared');

-- ---- 3.3 settle: winner pays EXACTLY the winning bid; fixed prices untouched -----------------------------------------
update public.ad_auctions set ends_at = now() - interval '1 second' where id = :'au';
select pg_temp.must((public.run_auction_jobs() ->> 'settled')::int = 1, 'ended auction settled');
select pg_temp.must((select status from public.ad_auctions where id = :'au') = 'awaiting_payment', 'awaiting payment');
select pg_temp.must((select bidder_id from public.ad_auction_offers where auction_id = :'au' and status = 'pending') = :'b1', 'offer to the winner');
select pg_temp.must((select pay_by - offered_at from public.ad_auction_offers where auction_id = :'au' and status = 'pending') = interval '24 hours', '24h payment window');
select pg_temp.must((select price_snapshot from public.campaigns where id = :'cb1') = 200000, 'campaign price = winning bid');
select pg_temp.must((select requested_start from public.campaigns where id = :'cb1') = :'ps', 'campaign starts at the auctioned period');
select pg_temp.must(pg_temp.mails('auction_won', :'b1') = 1 and pg_temp.mails('auction_lost') >= 2, 'won + lost emails queued');
select pg_temp.must((select price_per_target from public.ad_products where id = 'featured-campus-7d') = 60000, 'fixed package price untouched by the auction');
select pg_temp.must((select price_snapshot from public.campaigns where id = :'cb2') = 60000, 'losing campaign price untouched');
select pg_temp.as_user(:'b1');
select pg_temp.must(jsonb_array_length(public.my_auction_offers()) = 1, 'winner sees the offer');
select pg_temp.pay(:'cb1') as ord \gset
select pg_temp.must((select total_amount from public.orders o join public.campaigns c on c.order_id = o.id where c.id = :'cb1') = 200000, 'order stores the winning price');
select pg_temp.must((select status from public.campaigns where id = :'cb1') = 'scheduled', 'paid winner scheduled for the period');
select (public.run_auction_jobs() ->> 'paid')::int as paid_n \gset
select pg_temp.must(:paid_n = 1 and (select status from public.ad_auctions where id = :'au') = 'settled', 'auction settled once paid');
-- "capture" is idempotent: paying/fulfilling again changes nothing
select public.fulfill_order((select order_id from public.campaigns where id = :'cb1'));
select pg_temp.must((select count(*) from public.orders o join public.campaigns c on c.order_id = o.id where c.id = :'cb1' and o.total_amount = 200000) = 1, 'second fulfil is a no-op');
select pg_temp.as_user(:'admin');
update public.ad_products set price_per_target = 99000 where id = 'featured-campus-7d';
select pg_temp.must((select total_amount from public.orders o join public.campaigns c on c.order_id = o.id where c.id = :'cb1') = 200000, 'later price change cannot touch the paid order');
update public.ad_products set price_per_target = 60000 where id = 'featured-campus-7d';

-- ---- 3.3 unpaid winner -> strike -> next bidder -> no winner --------------------------------------------------------
select pg_temp.as_user(:'a1');
select pg_temp.full(:'a1', 'k@t.id', 'featured-campus-7d', 1) as g1 \gset
select pg_temp.full(:'a2', 'k2@t.id', 'featured-campus-7d', 1) as g2 \gset
select pg_temp.full(:'a3', 'k3@t.id', 'featured-campus-7d', 1) as g3 \gset
select pg_temp.as_user(:'admin');
select public.admin_open_auction(pg_temp.key(1), 'featured-campus-7d') ->> 'id' as au2 \gset
select pg_temp.ad(:'b1', 1) as db1 \gset
select pg_temp.ad(:'b2', 1) as db2 \gset
select pg_temp.bid(:'b2', :'au2', :'db2', 60000);
select pg_temp.bid(:'b1', :'au2', :'db1', 70000);
update public.ad_auctions set ends_at = now() - interval '1 second' where id = :'au2';
select public.run_auction_jobs();
select pg_temp.must((select bidder_id from public.ad_auction_offers where auction_id = :'au2' and status = 'pending') = :'b1', 'b1 offered first');
-- b1 is offered but the offer lapses unpaid
update public.ad_auction_offers set pay_by = now() - interval '1 minute' where auction_id = :'au2' and status = 'pending';
select pg_temp.must((public.run_auction_jobs() ->> 'expired_offers')::int = 1, 'unpaid offer expired');
select pg_temp.must((select count(*) from public.ad_auction_strikes where user_id = :'b1' and cleared_at is null) = 1, 'non-payer gets a strike');
select pg_temp.must((select bidder_id from public.ad_auction_offers where auction_id = :'au2' and status = 'pending') = :'b2', 'next bidder is offered the slot');
select pg_temp.must((select amount from public.ad_auction_offers where auction_id = :'au2' and status = 'pending') = 60000, 'next bidder pays THEIR bid');
select pg_temp.must((select price_snapshot from public.campaigns where id = :'db1') = 60000, 'non-payer campaign restored to its original price');
select pg_temp.as_user(:'b1');
select pg_temp.expect_err($$select public.create_ad_order(pg_temp.uid(177), (select id from public.campaigns where owner_id = pg_temp.uid(177) and status = 'approved' and requested_start = (now() at time zone 'Asia/Jakarta')::date limit 1), repeat('a', 64))$$, 'SOLD_OUT');
update public.ad_auction_offers set pay_by = now() - interval '1 minute' where auction_id = :'au2' and status = 'pending';
select public.run_auction_jobs();
select pg_temp.must((select status from public.ad_auctions where id = :'au2') = 'no_winner', 'nobody left: no winner');
select pg_temp.must(pg_temp.avail(1, 8) = 3, 'slot reservation released: fixed-price sale possible again');
select pg_temp.must((select count(*) from public.ad_auction_strikes where user_id = :'b2' and cleared_at is null) = 1, 'second non-payer struck too');
-- 3 strikes block bidding
select pg_temp.as_user(:'admin');
select public.admin_open_auction(pg_temp.key(1), 'featured-campus-7d') ->> 'id' as au3 \gset
insert into public.ad_auction_strikes (user_id) select :'b1' from generate_series(1, 2);
select pg_temp.ad(:'b1', 1) as db1b \gset
select pg_temp.bid_err(:'b1', :'au3', :'db1b', 60000, 'BIDDING_BLOCKED');
select pg_temp.as_user(:'admin');
select public.admin_clear_strikes(:'b1', 'Appeal accepted by support');
select pg_temp.bid(:'b1', :'au3', :'db1b', 60000);

-- ---- 3.3 buy-now ----------------------------------------------------------------------------------------------------
select pg_temp.ad(:'b3', 1) as db3 \gset
select pg_temp.must((pg_temp.bid(:'b3', :'au3', :'db3', 5000000) ->> 'amount') = '90000', 'a bid above buy-now pays only the buy-now price');
select pg_temp.must((select status from public.ad_auctions where id = :'au3') = 'awaiting_payment' and (select bidder_id from public.ad_auction_offers where auction_id = :'au3' and status = 'pending') = :'b3', 'buy-now ends the auction at once');
select pg_temp.bid_err(:'b2', :'au3', :'db2', 100000, 'AUCTION_CLOSED');

-- ---- 3.1 kill switch -----------------------------------------------------------------------------------------------
select pg_temp.as_user(:'admin');
select public.admin_cancel_auction(:'au3', 'Reset for the kill switch test');
select public.admin_open_auction(pg_temp.key(1), 'featured-campus-7d') ->> 'id' as au4 \gset
select pg_temp.bid(:'b2', :'au4', :'db2', 60000);
select pg_temp.as_user(:'a1');
select pg_temp.expect_err($$select public.admin_auction_kill_switch('Testing the switch')$$, 'FORBIDDEN');
select pg_temp.as_user(:'admin');
select pg_temp.expect_err($$select public.admin_auction_kill_switch('x')$$, 'REASON_REQUIRED');
select pg_temp.must((public.admin_auction_kill_switch('Suspicious bidding pattern') ->> 'canceled')::int = 1, 'kill switch cancels open auctions');
select pg_temp.must(not public.auctions_on(), 'global flag off');
select pg_temp.must((select status from public.ad_auctions where id = :'au4') = 'canceled', 'auction canceled');
select pg_temp.must(public.list_open_auctions() = '[]'::jsonb, 'nothing listed after the kill switch');
select pg_temp.bid_err(:'b1', :'au4', :'db1b', 70000, 'AUCTIONS_OFF');
select pg_temp.must(exists (select 1 from public.admin_audit_log where action = 'auction.kill_switch' and reason = 'Suspicious bidding pattern'), 'kill switch audited');
-- fixed pricing carries on exactly as before
select pg_temp.must(pg_temp.avail(3) = 3, 'fixed-price sales unaffected');
select pg_temp.as_user(:'b4');
select pg_temp.must((public.upsert_campaign_draft(:'b4', null, 'Kopi Kita', 'k@t.id', 'Student coffee', 'Cheap coffee', 'local_business', null, null,
  'featured-campus-7d', (now() at time zone 'Asia/Jakarta')::date, jsonb_build_array(jsonb_build_object('level', 'campus', 'id', pg_temp.campus(3))), 'standard') ->> 'price') = '60000', 'fixed price quote unchanged');

rollback;
select 'phase3 ok';

-- ACL: server-only functions must not be callable by client roles
do $$ begin
  assert not has_function_privilege('anon','public.place_bid(uuid,uuid,uuid,bigint,text,boolean)','execute'), 'anon place_bid';
  assert not has_function_privilege('authenticated','public.place_bid(uuid,uuid,uuid,bigint,text,boolean)','execute'), 'auth place_bid';
  assert not has_function_privilege('anon','public.process_ad_waitlist()','execute'), 'anon process_ad_waitlist';
  assert not has_function_privilege('authenticated','public.run_auction_jobs()','execute'), 'auth run_auction_jobs';
  assert not has_function_privilege('anon','public.admin_auction_kill_switch(text)','execute'), 'anon kill switch';
  assert has_function_privilege('anon','public.list_open_auctions()','execute'), 'anon list_open_auctions';
end $$;
