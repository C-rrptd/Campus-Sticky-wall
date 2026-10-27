-- Migration 032 assertions (Phase 1): launch pricing, price immutability, founding price lock, tracking dedupe,
-- validation, stats, waitlist. Run after 001-032 and stub_auth.sql on an EMPTY database.
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
create function pg_temp.submit(u uuid, prod text, start_in int) returns uuid language sql as $$
  select (public.upsert_campaign_draft(u, null, 'Kopi Kita', 'k@t.id', 'Student coffee', 'Cheap coffee for students', 'local_business',
    null, null, prod, (now() at time zone 'Asia/Jakarta')::date + start_in,
    jsonb_build_array(jsonb_build_object('level', 'campus', 'id', (select id from public.campuses where enabled limit 1)))) ->> 'campaign_id')::uuid
$$;
-- submit -> admin approves -> advertiser creates the order -> payment settles (like the webhook)
create function pg_temp.full(u uuid, prod text) returns uuid language plpgsql as $$
declare c uuid := pg_temp.submit(u, prod, 0); o uuid;
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
  perform public.admin_review_campaign(c, 'approve', null);
  perform pg_temp.as_user(u::text);
  perform public.create_ad_order(u, c, repeat('a', 64));
  select order_id into o from public.campaigns where id = c;
  update public.orders set status = 'paid', paid_at = now() where id = o;
  perform public.fulfill_order(o);
  return c;
end $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a0', 'admin@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a1', 'a1@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a2', 'a2@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a3', 'a3@t.id', now());
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000a0', 'admin');
select id as campus from public.campuses where enabled limit 1 \gset

-- ---- 1.2 14-day tier is soft-disabled, rows kept ------------------------------------------------------------
select pg_temp.must(not exists (select 1 from public.ad_products where duration_days = 14 and enabled), '14-day packages disabled');
select pg_temp.must(exists (select 1 from public.ad_products where duration_days = 14), '14-day rows kept');
select pg_temp.expect_err($$select pg_temp.submit('00000000-0000-0000-0000-0000000000a1', 'feed-campus-14d', 0)$$, 'INVALID_PRODUCT');

-- ---- config validation + audit -----------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_err($$select public.admin_set_config('launch_mode_enabled', 'true')$$, 'FORBIDDEN');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select pg_temp.expect_err($$select public.admin_set_config('launch_discount_pct', '95')$$, 'INVALID_CONFIG_VALUE');
select pg_temp.expect_err($$select public.admin_set_config('launch_discount_pct', '"x"')$$, 'INVALID_CONFIG_VALUE');
select pg_temp.expect_err($$select public.admin_set_config('target_cpm', '-1')$$, 'INVALID_CONFIG_VALUE');
select pg_temp.expect_err($$select public.admin_set_config('ad_visitor_salt', '"x"')$$, 'CONFIG_KEY_NOT_EDITABLE');
select public.admin_set_config('founding_advertiser_count', '2');
select pg_temp.must((select details -> 'old' from public.admin_audit_log where action = 'config.set' and target_id = 'founding_advertiser_count'
                      order by created_at desc limit 1) = '10'::jsonb, 'config change audited with old value');

-- ---- 1.1 launch mode off: list price; a campaign submitted now keeps its price whatever happens later ----------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.submit('00000000-0000-0000-0000-0000000000a1', 'feed-campus-7d', 0) as early \gset
select pg_temp.must((select price_snapshot from public.campaigns where id = :'early') = 25000, 'launch off = list price');
select pg_temp.must((select launch_discount_pct from public.campaigns where id = :'early') = 0, 'no discount recorded');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select public.admin_review_campaign(:'early', 'approve', null);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select public.create_ad_order('00000000-0000-0000-0000-0000000000a1', :'early', repeat('a', 64));
select o.total_amount as early_total from public.orders o join public.campaigns c on c.order_id = o.id where c.id = :'early' \gset
select pg_temp.must(:early_total = 25000, 'order total stored');

-- ---- 1.1 launch mode on: discount only for NEW quotes -------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select public.admin_set_config('launch_mode_enabled', 'true');
select pg_temp.must((select (x ->> 'launch')::boolean and x ->> 'price_per_target' = '12500' and x ->> 'list_price_per_target' = '25000'
                       from jsonb_array_elements(public.ad_catalog()) x where x ->> 'id' = 'feed-campus-7d'), 'catalog shows struck list + 50% price');
select pg_temp.must((select price_snapshot from public.campaigns where id = :'early') = 25000, 'existing campaign price unchanged by launch mode');
select pg_temp.must((select total_amount from public.orders o join public.campaigns c on c.order_id = o.id where c.id = :'early') = :early_total, 'existing order price unchanged by launch mode');
-- per-package override beats the global %
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select public.admin_upsert_ad_product('feed-city-7d', 'Promotions feed — one city, 7 days', 'promotions_feed', 'city', 7, '50000', true, 2, 100, 20, false, false);
select pg_temp.must((select x ->> 'price_per_target' = '40000' from jsonb_array_elements(public.ad_catalog()) x where x ->> 'id' = 'feed-city-7d'), 'per-tier discount 20%');
select public.admin_upsert_ad_product('feed-city-7d', 'Promotions feed — one city, 7 days', 'promotions_feed', 'city', 7, '50000', true, 2, 100, null, false, false);

-- ---- 1.4 validation and confirmations -----------------------------------------------------------------------------
select pg_temp.expect_err($$select public.admin_upsert_ad_product('feed-campus-7d','n','promotions_feed','campus',7,'0',true,1,100)$$, 'INVALID_PRICE');
select pg_temp.expect_err($$select public.admin_upsert_ad_product('feed-campus-7d','n','promotions_feed','campus',7,'25000',true,1,101)$$, 'INVALID_SURCHARGE');
select pg_temp.expect_err($$select public.admin_upsert_ad_product('feed-campus-7d','n','promotions_feed','campus',7,'25000',true,1,-1)$$, 'INVALID_SURCHARGE');
select pg_temp.expect_err($$select public.admin_upsert_ad_product('feed-campus-7d','n','promotions_feed','campus',14,'25000',true,1,100)$$, 'INVALID_DURATION');
select pg_temp.expect_err($$select public.admin_upsert_ad_product('feed-campus-7d','n','promotions_feed','campus',7,'25000',true,1,100,95)$$, 'INVALID_DISCOUNT');
-- a retired 14-day row can still be saved while it stays disabled
select public.admin_upsert_ad_product('feed-campus-14d', 'Promotions feed — one campus, 14 days', 'promotions_feed', 'campus', 14, '45000', false, 101, 100);
select pg_temp.expect_err($$select public.admin_upsert_ad_product('feed-campus-14d','n','promotions_feed','campus',14,'45000',true,101,100)$$, 'INVALID_DURATION');
-- >50% change needs confirm; open campaigns need confirm; neither changes existing prices
select pg_temp.expect_err($$select public.admin_upsert_ad_product('feed-campus-7d','n','promotions_feed','campus',7,'40000',true,1,100)$$, 'PRICE_CHANGE_CONFIRM_BIG');
select pg_temp.expect_err($$select public.admin_upsert_ad_product('feed-campus-7d','n','promotions_feed','campus',7,'30000',true,1,100)$$, 'PRICE_CHANGE_CONFIRM_ACTIVE');
select pg_temp.must((public.admin_ad_product_impact('feed-campus-7d') ->> 'open_campaigns')::int >= 1, 'impact counts open campaigns');
select public.admin_upsert_ad_product('feed-campus-7d', 'Promotions feed — one campus, 7 days', 'promotions_feed', 'campus', 7, '30000', true, 1, 100, null, true, false);
select pg_temp.must((select price_snapshot from public.campaigns where id = :'early') = 25000, 'price change is never retroactive (campaign)');
select pg_temp.must((select total_amount from public.orders o join public.campaigns c on c.order_id = o.id where c.id = :'early') = :early_total, 'price change is never retroactive (order)');
select pg_temp.must((select details -> 'old' ->> 'base' = '25000' and details -> 'new' ->> 'base' = '30000' from public.admin_audit_log
                      where action = 'ad_product.change' and target_id = 'feed-campus-7d' order by created_at desc, id desc limit 1), 'price change audited old/new');
select pg_temp.must((select old_base = 25000 and new_base = 30000 from public.ad_price_history where product_id = 'feed-campus-7d' order by id desc limit 1), 'price history row');
select public.admin_upsert_ad_product('feed-campus-7d', 'Promotions feed — one campus, 7 days', 'promotions_feed', 'campus', 7, '25000', true, 1, 100, null, true, false);

-- ---- 1.3 founding advertisers: first 2 (configured) paying advertisers; price lock on renewal in the grace period --
-- early campaign (a1) is already approved with an order: pay it. Launch mode is ON, so a1's NEW campaigns are discounted.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
update public.orders set status = 'paid', paid_at = now() where id = (select order_id from public.campaigns where id = :'early');
select public.fulfill_order((select order_id from public.campaigns where id = :'early'));
select pg_temp.must((select rank from public.founding_advertisers where user_id = '00000000-0000-0000-0000-0000000000a1') = 1, 'first payer is founding #1');
select pg_temp.must((select base_fee from public.founding_rates where user_id = '00000000-0000-0000-0000-0000000000a1' and product_id = 'feed-campus-7d') = 25000,
  'locked rate = base the first campaign was quoted at');
select pg_temp.full('00000000-0000-0000-0000-0000000000a2', 'feed-campus-7d') as c2 \gset
select pg_temp.must((select price_snapshot from public.campaigns where id = :'c2') = 12500, 'a2 gets the launch price 12500');
select pg_temp.must((select rank from public.founding_advertisers where user_id = '00000000-0000-0000-0000-0000000000a2') = 2, 'second payer is founding #2');
select pg_temp.full('00000000-0000-0000-0000-0000000000a3', 'feed-campus-7d') as c3 \gset
select pg_temp.must(not exists (select 1 from public.founding_advertisers where user_id = '00000000-0000-0000-0000-0000000000a3'), 'third payer is NOT founding (limit 2)');
-- launch mode ends and the list price goes up
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select public.admin_set_config('launch_mode_enabled', 'false');
select public.admin_upsert_ad_product('feed-campus-7d', 'Promotions feed — one campus, 7 days', 'promotions_feed', 'campus', 7, '40000', true, 1, 100, null, true, true);
-- a2 locked at 12500; their campaign ended 3 days ago -> renews inside the 7 day grace period at the locked rate
update public.campaigns set starts_at = now() - interval '10 days', ends_at = now() - interval '3 days', status = 'expired' where id = :'c2';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.submit('00000000-0000-0000-0000-0000000000a2', 'feed-campus-7d', 0) as r2 \gset
select pg_temp.must((select price_snapshot = 12500 and price_locked from public.campaigns where id = :'r2'), 'founding renewal inside grace keeps the locked rate');
select pg_temp.must((select list_price_snapshot from public.campaigns where id = :'r2') = 40000, 'list price recorded next to it');
-- 8 days after expiry: no lock
update public.campaigns set ends_at = now() - interval '8 days', starts_at = now() - interval '15 days' where id = :'c2';
select pg_temp.submit('00000000-0000-0000-0000-0000000000a2', 'feed-campus-7d', 0) as r2b \gset
select pg_temp.must((select price_snapshot = 40000 and not price_locked from public.campaigns where id = :'r2b'), 'renewal after the grace period pays the current price');
-- non-founding advertiser never gets a lock
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
update public.campaigns set starts_at = now() - interval '10 days', ends_at = now() - interval '3 days', status = 'expired' where id = :'c3';
select pg_temp.submit('00000000-0000-0000-0000-0000000000a3', 'feed-campus-7d', 0) as r3 \gset
select pg_temp.must((select price_snapshot = 40000 and not price_locked from public.campaigns where id = :'r3'), 'non-founding pays current price');
-- grace period is configurable; a locked rate that is higher than the current price is never used
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select public.admin_set_config('price_lock_grace_days', '2');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
update public.campaigns set starts_at = now() - interval '10 days', ends_at = now() - interval '3 days' where id = :'c2';
select (public.upsert_campaign_draft('00000000-0000-0000-0000-0000000000a2', null, 'Kopi Kita', 'k@t.id', 'Student coffee', 'Cheap', 'local_business', null, null,
  'feed-campus-7d', (now() at time zone 'Asia/Jakarta')::date, jsonb_build_array(jsonb_build_object('level','campus','id',:'campus'))) ->> 'campaign_id')::uuid as g2 \gset
select pg_temp.must((select price_snapshot = 40000 and not price_locked from public.campaigns where id = :'g2'), 'grace period setting is honoured (3 days > 2)');
select pg_temp.must(((public.my_price_locks() -> 'locks') -> 0 ->> 'base_fee') = '12500', 'dashboard shows the locked rate');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select public.admin_set_config('price_lock_grace_days', '7');
select pg_temp.must((select founding_rank = 2 and price_locked is not null from jsonb_to_recordset(public.admin_list_campaigns('pending_approval')) as t(id uuid, founding_rank int, price_locked boolean) where id = :'r2'), 'admin list shows founding rank');
select pg_temp.must(exists (select 1 from jsonb_array_elements(public.admin_list_orders('advertising')) x where x ->> 'founding_rank' = '2'), 'admin order list shows founding rank');

-- ---- 1.5 tracking: dedupe per visitor per ad per hour, bots + admin excluded, clicks server-side -------------------------
reset role;
select set_config('request.jwt.claim.sub', '', true);
select :'c2'::uuid as live \gset
update public.campaigns set starts_at = now() - interval '1 day', ends_at = now() + interval '6 days', status = 'active' where id = :'live';
select pg_temp.must(public.record_ad_event(:'live', 'impression', 'v1', 'Mozilla/5.0 (X11) Firefox/120', false, null, null, null, :'campus'), 'first impression counts');
select pg_temp.must(not public.record_ad_event(:'live', 'impression', 'v1', 'Mozilla/5.0 (X11) Firefox/120', false, null, null, null, :'campus'), 'same visitor same hour does not count');
select pg_temp.must(public.record_ad_event(:'live', 'impression', 'v2', 'Mozilla/5.0 (X11) Firefox/120', false, null, null, null, :'campus'), 'another visitor counts');
select pg_temp.must(not public.record_ad_event(:'live', 'impression', 'v3', 'Googlebot/2.1 (+http://www.google.com/bot.html)', false, null, null, null, :'campus'), 'bot excluded');
select pg_temp.must(not public.record_ad_event(:'live', 'impression', 'v3', null, false, null, null, null, :'campus'), 'empty user agent excluded');
select pg_temp.must(not public.record_ad_event(:'live', 'impression', 'v4', 'Mozilla/5.0 (X11) Firefox/120', true, null, null, null, :'campus'), 'admin session excluded');
-- next hour: counts again
update public.ad_impression_log set hour_bucket = hour_bucket - interval '1 hour' where campaign_id = :'live' and visitor_hash = 'v1';
select pg_temp.must(public.record_ad_event(:'live', 'impression', 'v1', 'Mozilla/5.0 (X11) Firefox/120', false, null, null, null, :'campus'), 'same visitor next hour counts');
select pg_temp.must((select sum(impressions) from public.campaign_daily_stats where campaign_id = :'live') = 3, 'daily total = 3 counted impressions');
select pg_temp.must((select impressions from public.ad_location_daily where target_key = 'campus:' || :'campus' and spot = 'random') = 3, 'per-location total = 3');
select pg_temp.must(public.record_ad_event(:'live', 'click', 'v1', 'Mozilla/5.0 (X11) Firefox/120', false, null, null, null, :'campus', 'instagram.com', 'ig', 'social', 'launch'), 'click counts');
select pg_temp.must(not public.record_ad_event(:'live', 'click', 'v9', 'curl/8.0.1', false, null, null, null, :'campus'), 'bot click excluded');
select pg_temp.must((select utm_source = 'ig' and referrer_host = 'instagram.com' from public.ad_click_log where campaign_id = :'live'), 'click records referrer + utm source');
-- the old rpc name still works for impressions and ignores clicks
select set_config('request.headers', '{"x-forwarded-for":"1.2.3.4","user-agent":"Mozilla/5.0 Safari/605"}', true);
select public.record_campaign_event(:'live', 'impression', null, null, null, :'campus');
select public.record_campaign_event(:'live', 'impression', null, null, null, :'campus');
select public.record_campaign_event(:'live', 'click', null, null, null, :'campus');
select pg_temp.must((select sum(impressions) from public.campaign_daily_stats where campaign_id = :'live') = 4, 'wrapper dedupes (3 + 1)');
select pg_temp.must((select sum(clicks) from public.campaign_daily_stats where campaign_id = :'live') = 1, 'wrapper ignores clicks');
-- not live -> nothing counted
update public.campaigns set status = 'paused' where id = :'live';
select pg_temp.must(not public.record_ad_event(:'live', 'impression', 'v7', 'Mozilla/5.0 (X11) Firefox/120', false, null, null, null, :'campus'), 'paused campaign counts nothing');
update public.campaigns set status = 'active' where id = :'live';
select pg_temp.must(public.ad_click_target(:'live') is null, 'no destination link -> no redirect target');
update public.campaigns set destination_url = 'https://example.com/promo' where id = :'live';
select pg_temp.must(public.ad_click_target(:'live') = 'https://example.com/promo', 'redirect target comes from the database');

-- ---- 1.6 public stats + report --------------------------------------------------------------------------------------
select pg_temp.must((public.get_public_stats() ->> 'views_total')::int = 4 and (public.get_public_stats() ->> 'clicks_total')::int = 1, 'public totals');
select pg_temp.must(jsonb_array_length(public.get_public_stats() -> 'locations') >= 1, 'public per-location rows');
select pg_temp.must((public.get_locations_recent_views('random', array['campus:' || :'campus', 'bad key']) -> 0 ->> 'views_7d')::int = 4, 'recent views for the buyer page (bad keys ignored)');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.must((public.campaign_report(:'live') -> 'totals' ->> 'impressions')::int = 4 and (public.campaign_report(:'live') -> 'totals' ->> 'unique_visitors')::int = 3, 'owner report totals');
select pg_temp.must((public.campaign_report(:'live') -> 'referrers' -> 0 ->> 'host') = 'instagram.com', 'report referrers');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select pg_temp.expect_err(format('select public.campaign_report(%L)', :'live'), 'NOT_FOUND');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select pg_temp.must(public.campaign_report(:'live') is not null, 'admin can read any report');

-- ---- 1.7 pricing analytics: not enough data until 14 days --------------------------------------------------------------
select public.admin_set_config('target_cpm', '10000');
select pg_temp.must((select not (x ->> 'enough')::boolean and x -> 'suggested_weekly_price' = 'null'::jsonb from jsonb_array_elements(public.admin_pricing_analytics(30) -> 'rows') x
                      where x ->> 'key' = 'campus:' || :'campus' and x ->> 'spot' = 'random'), 'under 14 days: no suggested price');
reset role;
update public.ad_location_daily set day = day - 20 where target_key = 'campus:' || :'campus' and spot = 'random';
update public.ad_location_daily set impressions = 14000 where target_key = 'campus:' || :'campus' and spot = 'random';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
-- 14000 views over 21 observed days (>=14) in a 30 day window => capped at observed days: 14000/21*7 = 4666.67 weekly; x10000/1000 = 46667
select pg_temp.must((select (x ->> 'enough')::boolean and (x ->> 'suggested_weekly_price')::int = 46667
                      from jsonb_array_elements(public.admin_pricing_analytics(30) -> 'rows') x
                      where x ->> 'key' = 'campus:' || :'campus' and x ->> 'spot' = 'random'), 'suggested = weekly views x CPM / 1000');
-- current weekly price 25000 is >30% below 46667 -> warning
select pg_temp.must((select x ->> 'price_warning' = 'below' from jsonb_array_elements(public.admin_pricing_analytics(30) -> 'rows') x
                      where x ->> 'key' = 'campus:' || :'campus' and x ->> 'spot' = 'random'), 'price more than 30% off suggestion is flagged');

-- ---- 1.9 waitlist ---------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '', true);
select public.join_ad_waitlist('Wait@T.id', 'featured', 'country', 'country:ID', 30);
select public.join_ad_waitlist('wait@t.id', 'featured', 'country', 'country:ID', 30);
select pg_temp.must((select count(*) from public.ad_waitlist) = 1, 'duplicate waitlist signup collapses to one row');
select pg_temp.expect_err($$select public.join_ad_waitlist('nope', 'featured', 'country', null, 30)$$, 'INVALID_EMAIL');
select pg_temp.expect_err($$select public.join_ad_waitlist('x@t.id', 'featured', 'moon', null, 30)$$, 'INVALID_WAITLIST');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select pg_temp.must((public.admin_waitlist_counts() ->> 'total_waiting')::int = 1, 'admin sees waitlist count');

rollback;
select 'phase 1 assertions passed';
