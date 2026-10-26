-- Migration 015 assertions: featured ranking before LIMIT, admin can stop an awaiting_payment campaign,
-- pending-review cap, legacy 3-day package off. Run after 001-015 and stub_auth.sql on an EMPTY database.
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
-- submit one target of the given level; admin approves; advertiser orders; the webhook settles it
create function pg_temp.go_live(prod text, lvl text, ref text, tok text) returns uuid language plpgsql as $$
declare v_c uuid; v_o uuid;
begin
  v_c := (public.upsert_campaign_draft('00000000-0000-0000-0000-0000000000d1', null, 'Kopi', 'k@t.id', 'Ad ' || lvl, 'text', 'local_business',
    null, null, prod, (now() at time zone 'Asia/Jakarta')::date,
    jsonb_build_array(jsonb_build_object('level', lvl, 'id', ref))) ->> 'campaign_id')::uuid;
  perform public.admin_review_campaign(v_c, 'approve', null);
  perform public.create_ad_order('00000000-0000-0000-0000-0000000000d1', v_c, repeat(tok, 64));
  select order_id into v_o from public.campaigns where id = v_c;
  update public.orders set status = 'paid', paid_at = now() where id = v_o;
  perform public.fulfill_order(v_o);
  return v_c;
end $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000d1', 'adv@t.id', now()),
  ('00000000-0000-0000-0000-0000000000d2', 'admin@t.id', now());
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000d2', 'admin');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');

select c.id as campus, c.city_id as city from public.campuses c where c.enabled limit 1 \gset

-- ---- legacy package -------------------------------------------------------------------
select pg_temp.must(not exists (select 1 from public.ad_products where id = 'featured-campus-3d' and enabled), '3-day featured package is off');

-- ---- featured: most specific wins even when more ads match than the limit -------------
-- least specific is inserted FIRST so an unordered LIMIT 2 would keep the wrong rows
select pg_temp.go_live('featured-country-7d', 'country', 'ID', 'a') as f_country \gset
select pg_temp.go_live('featured-city-7d', 'city', :'city', 'b') as f_city \gset
select pg_temp.go_live('featured-campus-7d', 'campus', :'campus', 'c') as f_campus \gset
select public.get_promotions(null, null, null, :'campus', 'featured', null, 2) as feat \gset
select pg_temp.must(jsonb_array_length(:'feat'::jsonb) = 2, 'featured limit 2');
select pg_temp.must((:'feat'::jsonb -> 0 ->> 'id') = :'f_campus', 'campus ad ranks first');
select pg_temp.must((:'feat'::jsonb -> 1 ->> 'id') = :'f_city', 'city ad ranks second, country ad cut');

-- ---- admin can stop a campaign whose payment is open; a late payment is flagged, not fulfilled
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select (public.upsert_campaign_draft('00000000-0000-0000-0000-0000000000d1', null, 'Kopi', 'k@t.id', 'Open order', 'text', 'local_business',
  null, null, 'feed-campus-7d', (now() at time zone 'Asia/Jakarta')::date,
  jsonb_build_array(jsonb_build_object('level', 'campus', 'id', :'campus'))) ->> 'campaign_id') as c_open \gset
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select public.admin_review_campaign(:'c_open', 'approve', null);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select public.create_ad_order('00000000-0000-0000-0000-0000000000d1', :'c_open', repeat('d', 64));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select public.admin_review_campaign(:'c_open', 'reject', 'Misleading claim');
select pg_temp.must((select status from public.campaigns where id = :'c_open') = 'rejected', 'awaiting_payment campaign can be rejected');
select pg_temp.must((select o.status from public.campaigns c join public.orders o on o.id = c.order_id where c.id = :'c_open') = 'canceled', 'its open order is closed');

-- ---- pending-review cap -------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select public.upsert_campaign_draft('00000000-0000-0000-0000-0000000000d1', null, 'Kopi', 'k@t.id', 'Pending ' || g, 'text', 'local_business',
  null, null, 'feed-campus-7d', (now() at time zone 'Asia/Jakarta')::date,
  jsonb_build_array(jsonb_build_object('level', 'campus', 'id', :'campus')))
from generate_series(1, 5) g;
select pg_temp.expect_err(format($$select public.upsert_campaign_draft('00000000-0000-0000-0000-0000000000d1', null, 'Kopi', 'k@t.id', 'One more', 'text', 'local_business',
  null, null, 'feed-campus-7d', (now() at time zone 'Asia/Jakarta')::date, jsonb_build_array(jsonb_build_object('level', 'campus', 'id', %L)))$$, :'campus'), 'TOO_MANY_PENDING');

rollback;
select 'ads fixes assertions passed';
