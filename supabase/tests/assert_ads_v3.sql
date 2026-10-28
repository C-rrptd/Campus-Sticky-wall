-- Migration 013 assertions: submit -> approval -> payment -> scheduled/live -> expired, optional link,
-- frozen price, cancel + refund flag, rejection reason. Run after 001-014 and stub_auth.sql on an EMPTY database.
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
-- submit a campaign (no link, no image) for the first enabled campus
create function pg_temp.submit(u uuid, prod text, start_in int) returns uuid language sql as $$
  select (public.upsert_campaign_draft(u, null, 'Kopi Kita', 'k@t.id', 'Student coffee', 'Cheap coffee for students', 'local_business',
    null, null, prod, (now() at time zone 'Asia/Jakarta')::date + start_in,
    jsonb_build_array(jsonb_build_object('level', 'campus', 'id', (select id from public.campuses where enabled limit 1)))) ->> 'campaign_id')::uuid
$$;
-- settle the campaign's payment order the way the webhook does
create function pg_temp.pay(cid uuid) returns void language plpgsql as $$
declare v_o uuid;
begin
  select order_id into v_o from public.campaigns where id = cid;
  update public.orders set status = 'paid', paid_at = now() where id = v_o;
  perform public.fulfill_order(v_o);
end $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000d1', 'adv@t.id', now()),
  ('00000000-0000-0000-0000-0000000000d2', 'admin@t.id', now());
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000d2', 'admin');

select id as campus from public.campuses where enabled limit 1 \gset
-- ---- packages ---------------------------------------------------------------
select pg_temp.must((select count(distinct duration_days) from public.ad_products where placement = 'promotions_feed' and enabled) >= 2, '7/30 day random packages (14-day tier retired in 032)');
select pg_temp.must((select count(distinct duration_days) from public.ad_products where placement = 'featured' and enabled) >= 2, '7/30 day featured packages (14-day tier retired in 032)');

-- ---- submit: link + image optional, price frozen, waits for approval ------------
select pg_temp.submit('00000000-0000-0000-0000-0000000000d1', 'feed-campus-7d', 0) as c1 \gset
select pg_temp.must((select status from public.campaigns where id = :'c1') = 'pending_approval', 'new campaign waits for approval');
select pg_temp.must((select destination_url is null and creative_path is null from public.campaigns where id = :'c1'), 'link and image optional');
select pg_temp.must((select price_snapshot from public.campaigns where id = :'c1') = 25000, 'price frozen at submission');
select pg_temp.expect_err(format('select public.create_ad_order(%L, %L, %L)', '00000000-0000-0000-0000-0000000000d1', :'c1', repeat('a', 64)), 'CAMPAIGN_NOT_APPROVED');
select pg_temp.expect_err($$select pg_temp.submit('00000000-0000-0000-0000-0000000000d1', 'no-such-package', 0)$$, 'INVALID_PRODUCT');
select pg_temp.expect_err($$select pg_temp.submit('00000000-0000-0000-0000-0000000000d1', 'feed-campus-7d', -1)$$, 'INVALID_START_DATE');

-- ---- admin: reason required, approve ------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select pg_temp.expect_err(format('select public.admin_review_campaign(%L, %L, null)', :'c1', 'approve'), 'FORBIDDEN');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select pg_temp.expect_err(format('select public.admin_review_campaign(%L, %L, %L)', :'c1', 'reject', ''), 'REASON_REQUIRED');
select public.admin_review_campaign(:'c1', 'approve', null);
select pg_temp.must((select status from public.campaigns where id = :'c1') = 'approved', 'approved, awaiting payment');
select pg_temp.must((select count(*) from public.get_promotions(null, null, null, :'campus', 'random')) is not null, 'feed query works');
select pg_temp.must(jsonb_array_length(public.get_promotions(null, null, null, :'campus', 'random')) = 0, 'unpaid campaign is never public');

-- ---- payment -> live immediately (start today) -------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select public.create_ad_order('00000000-0000-0000-0000-0000000000d1', :'c1', repeat('a', 64));
select pg_temp.must((select status from public.campaigns where id = :'c1') = 'awaiting_payment', 'awaiting payment');
select pg_temp.must(jsonb_array_length(public.get_promotions(null, null, null, :'campus', 'random')) = 0, 'unpaid (order open) still not public');
select pg_temp.pay(:'c1');
select pg_temp.must((select status from public.campaigns where id = :'c1') = 'active', 'paid + start today = active');
select pg_temp.must((select ends_at - starts_at from public.campaigns where id = :'c1') = interval '7 days', '7 day run');
select pg_temp.must(public.campaign_is_live((select c from public.campaigns c where id = :'c1')), 'live');
select pg_temp.must(jsonb_array_length(public.get_promotions(null, null, null, :'campus', 'random')) = 1, 'live campaign in random feed');
select pg_temp.must(jsonb_array_length(public.get_promotions(null, null, null, :'campus', 'featured')) = 0, 'not in featured');
-- cannot self-cancel once started
select pg_temp.expect_err(format('select public.cancel_my_campaign(%L)', :'c1'), 'CANNOT_CANCEL');

-- ---- automatic expiry ---------------------------------------------------------------------
reset role;
update public.campaigns set starts_at = now() - interval '8 days', ends_at = now() - interval '1 day' where id = :'c1';
select pg_temp.must(not public.campaign_is_live((select c from public.campaigns c where id = :'c1')), 'past end date is not live even before the sweeper');
select public.expire_stale_orders();
select pg_temp.must((select status from public.campaigns where id = :'c1') = 'expired', 'sweeper marks expired');

-- ---- scheduled (future start), then cancel -> refund review ---------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select pg_temp.submit('00000000-0000-0000-0000-0000000000d1', 'featured-campus-30d', 5) as c2 \gset
select public.admin_review_campaign(:'c2', 'approve', null);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select public.create_ad_order('00000000-0000-0000-0000-0000000000d1', :'c2', repeat('b', 64));
select pg_temp.pay(:'c2');
select pg_temp.must((select status from public.campaigns where id = :'c2') = 'scheduled', 'future start = scheduled');
select pg_temp.must(jsonb_array_length(public.get_promotions(null, null, null, :'campus', 'featured')) = 0, 'scheduled is not yet public');
select public.cancel_my_campaign(:'c2');
select pg_temp.must((select status from public.campaigns where id = :'c2') = 'canceled', 'advertiser cancelled');
select pg_temp.must((select o.review_required from public.campaigns c join public.orders o on o.id = c.order_id where c.id = :'c2'), 'paid cancel flags refund review');

-- ---- rejection keeps the reason; unpaid cancel is free ---------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select pg_temp.submit('00000000-0000-0000-0000-0000000000d1', 'feed-campus-30d', 0) as c3 \gset
select public.admin_review_campaign(:'c3', 'reject', 'Misleading claim: no free coffee');
select pg_temp.must((select status || moderation_reason from public.campaigns where id = :'c3') = 'rejectedMisleading claim: no free coffee', 'reason stored');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select pg_temp.submit('00000000-0000-0000-0000-0000000000d1', 'feed-campus-7d', 0) as c4 \gset
select public.cancel_my_campaign(:'c4');
select pg_temp.must((select status from public.campaigns where id = :'c4') = 'canceled', 'unpaid cancel');
-- another user cannot cancel it
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select pg_temp.expect_err(format('select public.cancel_my_campaign(%L)', :'c1'), 'NOT_FOUND');

-- ---- failed payment returns to approved --------------------------------------------------------
reset role;
select pg_temp.submit('00000000-0000-0000-0000-0000000000d1', 'feed-campus-7d', 0) as c5 \gset
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select public.admin_review_campaign(:'c5', 'approve', null);
select public.create_ad_order('00000000-0000-0000-0000-0000000000d1', :'c5', repeat('c', 64));
select public.abandon_order((select order_id from public.campaigns where id = :'c5'));
select pg_temp.must((select status || (order_id is null)::text from public.campaigns where id = :'c5') = 'approvedtrue', 'failed payment -> approved, can pay again');

-- ---- decoration categories (014) -----------------------------------------------------------------------
select pg_temp.must((select count(*) from public.decorations where category = 'Tapes') >= 4, 'tapes category');
select pg_temp.must((select category from public.decorations where id = 'frame-thick') = 'Borders', 'frames are borders');
select pg_temp.must((select category from public.decorations where id = 'sticker-cat') = 'Stickers', 'stickers category');

rollback;
select 'ads v3 assertions passed';
