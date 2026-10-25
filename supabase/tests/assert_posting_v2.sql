-- Migration 012 assertions: min price, cap, confirmation, free weekly post, promos,
-- author names, failed-order cleanup, and the account<->note unlinking.
-- Run as a superuser after 001-012 and stub_auth.sql on an EMPTY database.
\set ON_ERROR_STOP on
begin;

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
-- v2 call with sensible defaults: (user, name, amount, decorations, promo, use_free, confirmed)
create function pg_temp.post(u uuid, nm text, amt text, decos text[], promo text, free boolean, conf boolean) returns jsonb
language sql as $$
  select public.create_publication_order_v2(u, nm, 'hello world', 'yellow', null, true, amt, decos, false,
    encode(sha256(gen_random_uuid()::text::bytea), 'hex'), null, null, false, 0, null, promo, free, conf)
$$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000c1', 'u1@t.id', now()),
  ('00000000-0000-0000-0000-0000000000c2', 'u2@t.id', now());
update public.profiles set display_name = 'Rani Agro' where id = '00000000-0000-0000-0000-0000000000c1';

-- ---- config / grants -------------------------------------------------------
select pg_temp.must(public.min_publication_price() = 2500, 'min is 2500');
select pg_temp.must(public.max_publication_price() = 1000000, 'cap is 1.000.000');
select pg_temp.must((select value #>> '{}' from public.site_config where key = 'unpaid_order_ttl_minutes') = '30', 'ttl 30 min');
select pg_temp.must(not has_function_privilege('anon', 'public.create_publication_order_v2(uuid,text,text,text,text,boolean,text,text[],boolean,text,uuid,jsonb,boolean,int,jsonb,text,boolean,boolean)', 'execute'), 'anon cannot call v2');
select pg_temp.must(not has_function_privilege('authenticated', 'public.create_publication_order_v2(uuid,text,text,text,text,boolean,text,text[],boolean,text,uuid,jsonb,boolean,int,jsonb,text,boolean,boolean)', 'execute'), 'client cannot call v2');
select pg_temp.must(not has_column_privilege('anon', 'public.notes', 'author_id', 'select'), 'author_id not readable by anon');
select pg_temp.must(not has_column_privilege('authenticated', 'public.notes', 'author_id', 'select'), 'author_id not readable by users');
select pg_temp.must(not has_column_privilege('authenticated', 'public.notes', 'order_id', 'select'), 'order_id not readable by users');

-- ---- amount rules ----------------------------------------------------------
select pg_temp.expect_err($$select public.quote_publication('2499')$$, 'PRICE_BELOW_MINIMUM');
select pg_temp.must((public.quote_publication('2500') ->> 'total_amount') = '2500', 'Rp2.500 accepted');
select pg_temp.expect_err($$select public.quote_publication('1000001')$$, 'PRICE_ABOVE_MAXIMUM');
select pg_temp.must((public.quote_publication('1000000') ->> 'total_amount') = '1000000', 'cap itself accepted');
select pg_temp.expect_err($$select public.quote_publication('25.5')$$, 'INVALID_AMOUNT');
select pg_temp.expect_err($$select public.quote_publication('-3000')$$, 'INVALID_AMOUNT');
select pg_temp.expect_err($$select public.quote_publication('1e5')$$, 'INVALID_AMOUNT');
select pg_temp.expect_err($$select pg_temp.post(null, 'Anon', '100001', '{}', null, false, false)$$, 'AMOUNT_NOT_CONFIRMED');
select pg_temp.must((pg_temp.post(null, 'Anon', '100001', '{}', null, false, true) ->> 'total_amount') = '100001', 'above threshold ok when confirmed');
select pg_temp.must((pg_temp.post(null, 'Anon', '100000', '{}', null, false, false) ->> 'total_amount') = '100000', 'threshold itself needs no confirmation');
select pg_temp.expect_err($$select pg_temp.post(null, 'Anon', '2499', '{}', null, false, false)$$, 'PRICE_BELOW_MINIMUM');
select pg_temp.expect_err($$select pg_temp.post(null, 'Anon', '2500', '{no-such-deco}', null, false, false)$$, 'INVALID_DECORATION');

-- ---- order ref is random, no timestamp, no user data ----------------------
select pg_temp.must(public.new_order_ref('publication') ~ '^CSW-P-[0-9a-f]{40}$', 'random order ref');
select pg_temp.must(public.new_order_ref('publication') <> public.new_order_ref('publication'), 'refs differ');

-- ---- author names ----------------------------------------------------------
select pg_temp.expect_err($$select pg_temp.post(null, '<script>alert(1)</script>', '2500', '{}', null, false, false)$$, 'INVALID_AUTHOR_NAME');
select pg_temp.expect_err($$select pg_temp.post(null, 'rani agro', '2500', '{}', null, false, false)$$, 'NAME_NOT_AVAILABLE');
select pg_temp.expect_err($$select pg_temp.post(null, 'R4ni_Agr0', '2500', '{}', null, false, false)$$, 'NAME_NOT_AVAILABLE');
select pg_temp.expect_err($$select pg_temp.post(null, 'ＲＡＮＩ ＡＧＲＯ', '2500', '{}', null, false, false)$$, 'NAME_NOT_AVAILABLE');
select pg_temp.expect_err($$select pg_temp.post(null, 'Admin', '2500', '{}', null, false, false)$$, 'NAME_NOT_AVAILABLE');
select pg_temp.expect_err($$select pg_temp.post(null, '@rani', '2500', '{}', null, false, false)$$, 'INVALID_AUTHOR_NAME');
select pg_temp.expect_err($$select pg_temp.post(null, 'visit rani.com', '2500', '{}', null, false, false)$$, 'INVALID_AUTHOR_NAME');
select pg_temp.expect_err($$select pg_temp.post(null, E'Ra\u200Bni', '2500', '{}', null, false, false)$$, 'INVALID_AUTHOR_NAME');
select pg_temp.must((pg_temp.post(null, 'Dewi dari Agro', '2500', '{}', null, false, false) ->> 'status') = 'awaiting_payment', 'normal name accepted');

-- ---- free weekly post ------------------------------------------------------
select pg_temp.must(public.jakarta_week_start() = date_trunc('week', now() at time zone 'Asia/Jakarta')::date, 'week start');
select pg_temp.must(extract(isodow from public.jakarta_week_start()) = 1, 'week starts on Monday');
do $$ declare o jsonb; begin
  o := pg_temp.post('00000000-0000-0000-0000-0000000000c1', 'Free One', '2500', '{}', null, true, false);
  perform pg_temp.must(o ->> 'status' = 'completed_free', 'free post completes without payment');
  perform pg_temp.must(o ->> 'total_amount' = '0', 'free post total is 0');
  perform pg_temp.must((select status from public.notes where body = 'hello world' and author_name = 'Free One') = 'published', 'free post goes through the normal release flow');
  perform pg_temp.must((select author_id from public.notes where author_name = 'Free One') is null, 'note has no account');
  perform pg_temp.must((select user_id from public.orders where order_ref = o ->> 'order_ref') is null, 'order unlinked from account after fulfilment');
  perform pg_temp.must((select order_id from public.free_post_claims where user_id = '00000000-0000-0000-0000-0000000000c1') is null, 'claim holds no order after fulfilment');
  perform pg_temp.must((select count(*) from public.free_post_claims) = 1, 'one claim');
  perform pg_temp.must((select claimed_hour from public.free_post_claims) = date_trunc('hour', now()), 'claim time is hour-rounded');
end $$;
select pg_temp.expect_err($$select pg_temp.post('00000000-0000-0000-0000-0000000000c1', 'Free Two', '2500', '{}', null, true, false)$$, 'FREE_POST_USED');
select pg_temp.expect_err($$select pg_temp.post(null, 'Guest Free', '2500', '{}', null, true, false)$$, 'ACCOUNT_REQUIRED');
select pg_temp.must((select count(*) from public.notes where author_name = 'Free Two') = 0, 'failed second free post leaves no note');
select pg_temp.must((select not public.my_free_post_available()) is not null, 'availability function runs');

-- ---- promo codes -----------------------------------------------------------
insert into public.promo_codes (code, kind, value, max_uses, per_user_limit, expires_at) values
  ('HALF50', 'percent', 50, null, 1, null),
  ('FREE100', 'percent', 100, null, 5, null),
  ('FIXED5K', 'fixed', 5000, null, 5, null),
  ('OLDONE', 'percent', 100, null, 1, now() - interval '1 minute'),
  ('ONLYONE', 'percent', 100, 1, 1, null);

do $$ declare o jsonb; u1 uuid := '00000000-0000-0000-0000-0000000000c1'; u2 uuid := '00000000-0000-0000-0000-0000000000c2'; begin
  -- percent applies to the Rp2.500 minimum only: 50% of 2.500 = 1.250, tip untouched
  o := pg_temp.post(u2, 'Promo A', '10000', '{}', 'half50', false, false);
  perform pg_temp.must(o ->> 'discount_amount' = '1250' and o ->> 'total_amount' = '8750', '50% off the minimum only, tip not discounted');
  -- 100% off on a custom amount: the tip is still paid
  o := pg_temp.post(u1, 'Promo B', '10000', '{}', 'FREE100', false, false);
  perform pg_temp.must(o ->> 'total_amount' = '7500', '100% promo on Rp10.000 leaves the Rp7.500 tip to pay');
  -- 100% on the minimum with no extras is a free post
  o := pg_temp.post(u1, 'Promo C', '2500', '{}', 'FREE100', false, false);
  perform pg_temp.must(o ->> 'status' = 'completed_free', '100% promo on the minimum completes free');
  -- fixed discount is capped at the minimum
  o := pg_temp.post(u1, 'Promo D', '2500', '{}', 'FIXED5K', false, false);
  perform pg_temp.must(o ->> 'discount_amount' = '2500', 'fixed discount capped at the minimum');
  -- decorations are never discounted
  o := pg_temp.post(u1, 'Promo E', '2500', '{tape}', 'FREE100', false, false);
  perform pg_temp.must(o ->> 'total_amount' = (select price::text from public.decorations where id = 'tape'), 'decorations stay full price');
end $$;

select pg_temp.expect_err($$select pg_temp.post('00000000-0000-0000-0000-0000000000c1', 'X1', '2500', '{}', 'OLDONE', false, false)$$, 'PROMO_INVALID');
select pg_temp.expect_err($$select pg_temp.post('00000000-0000-0000-0000-0000000000c1', 'X2', '2500', '{}', 'NOPE', false, false)$$, 'PROMO_INVALID');
select pg_temp.expect_err($$select pg_temp.post('00000000-0000-0000-0000-0000000000c2', 'X3', '10000', '{}', 'HALF50', false, false)$$, 'PROMO_INVALID');  -- per-user limit 1
select pg_temp.expect_err($$select pg_temp.post(null, 'X4', '2500', '{}', 'FREE100', false, false)$$, 'ACCOUNT_REQUIRED');
select pg_temp.expect_err($$select pg_temp.post('00000000-0000-0000-0000-0000000000c1', 'X5', '2500', '{}', 'FREE100', true, false)$$, 'DISCOUNT_CONFLICT');
-- max uses: second person cannot redeem a one-use code
select pg_temp.must((pg_temp.post('00000000-0000-0000-0000-0000000000c1', 'Once', '10000', '{}', 'ONLYONE', false, false) ->> 'total_amount') = '7500', 'one-use code works once');
select pg_temp.expect_err($$select pg_temp.post('00000000-0000-0000-0000-0000000000c2', 'Twice', '10000', '{}', 'ONLYONE', false, false)$$, 'PROMO_INVALID');
select pg_temp.must((select uses from public.promo_codes where code = 'ONLYONE') = 1, 'uses never exceeds max_uses');
select pg_temp.must((select max(uses) <= coalesce(min(max_uses), 1000000) from public.promo_codes where code = 'ONLYONE'), 'limit holds');

-- ---- failed / expired orders delete the pending post and return the promo use -
do $$ declare o jsonb; v_id uuid; v_uses int; begin
  select uses into v_uses from public.promo_codes where code = 'HALF50';
  o := pg_temp.post('00000000-0000-0000-0000-0000000000c1', 'Will Fail', '10000', '{}', 'HALF50', false, false);
  select id into v_id from public.orders where order_ref = o ->> 'order_ref';
  perform pg_temp.must((select uses from public.promo_codes where code = 'HALF50') = v_uses + 1, 'use reserved');
  update public.orders set status = 'expired', closed_at = now() where id = v_id;
  perform public.abandon_order(v_id);
  perform pg_temp.must(not exists (select 1 from public.notes where author_name = 'Will Fail'), 'pending post deleted');
  perform pg_temp.must((select uses from public.promo_codes where code = 'HALF50') = v_uses, 'promo use returned');
  perform pg_temp.must(not exists (select 1 from public.promo_redemptions where order_id = v_id), 'reservation removed');
end $$;

-- ---- expiry sweep: unpaid orders vanish after the ttl ----------------------
do $$ declare o jsonb; begin
  o := pg_temp.post(null, 'Stale', '3000', '{}', null, false, false);
  update public.orders set expires_at = now() - interval '1 second' where order_ref = o ->> 'order_ref';
  perform pg_temp.must(public.expire_stale_orders() >= 1, 'sweeper expired the order');
  perform pg_temp.must(not exists (select 1 from public.notes where author_name = 'Stale'), 'stale post deleted');
end $$;

-- ---- paid order: fulfilment unlinks everything -----------------------------
do $$ declare o jsonb; v_id uuid; begin
  o := pg_temp.post('00000000-0000-0000-0000-0000000000c2', 'Paid Note', '5000', '{}', null, false, false);
  select id into v_id from public.orders where order_ref = o ->> 'order_ref';
  perform pg_temp.must((select user_id from public.orders where id = v_id) is not null, 'order knows the user while pending');
  perform pg_temp.must((select author_id from public.notes where order_id = v_id) is null, 'note never knew the user');
  update public.orders set status = 'paid', paid_at = now() where id = v_id;
  perform public.fulfill_order(v_id);
  perform pg_temp.must((select status from public.notes where order_id = v_id) = 'published', 'paid note published');
  perform pg_temp.must((select user_id from public.orders where id = v_id) is null, 'order unlinked after payment');
  perform public.fulfill_order(v_id);  -- repeated fulfilment is a no-op
  perform pg_temp.must((select count(*) from public.notes where author_name = 'Paid Note') = 1, 'idempotent');
end $$;

-- ---- nothing public exposes an account id ----------------------------------
do $$ declare j text; begin
  select public.get_wall('newest', null, 50, 0)::text into j;
  perform pg_temp.must(j !~* '00000000-0000-0000-0000-0000000000c[12]', 'wall JSON contains no user id');
  perform pg_temp.must(j !~ 'author_id|user_id|username|profile', 'wall JSON has no account keys');
  perform pg_temp.must(not exists (select 1 from public.notes where author_id is not null), 'no note stores an account');
  perform pg_temp.must(not exists (select 1 from public.orders where kind = 'publication' and status in ('paid','completed_free') and user_id is not null), 'no fulfilled publication order stores an account');
  perform pg_temp.must(not exists (select 1 from public.promo_redemptions where order_id is not null and not exists (select 1 from public.orders o where o.id = order_id and o.status = 'awaiting_payment')), 'redemptions only reference pending orders');
end $$;

rollback;
\echo ALL POSTING V2 ASSERTIONS PASSED
