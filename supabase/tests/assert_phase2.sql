-- Migration 033 assertions (Phase 2): slots, reduction safety, top/standard multipliers, rotation order, sold-out ->
-- waitlist -> hold -> expiry -> next person, utilization status, price proposals (never retroactive).
-- Run after 001-033 and stub_auth.sql on an EMPTY database.
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
create function pg_temp.sub(u uuid, email text, prod text, campus_n int, slot text default 'standard') returns uuid language sql as $$
  select (public.upsert_campaign_draft(u, null, 'Kopi Kita', email, 'Student coffee', 'Cheap coffee for students', 'local_business',
    null, null, prod, (now() at time zone 'Asia/Jakarta')::date,
    jsonb_build_array(jsonb_build_object('level', 'campus', 'id', pg_temp.campus(campus_n))), slot) ->> 'campaign_id')::uuid
$$;
create function pg_temp.approve(c uuid) returns void language plpgsql as $$
declare o uuid := (select owner_id from public.campaigns where id = c);
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
  perform public.admin_review_campaign(c, 'approve', null);
  perform pg_temp.as_user(o::text);
end $$;
create function pg_temp.pay(c uuid) returns void language plpgsql as $$
declare o uuid; own uuid := (select owner_id from public.campaigns where id = c);
begin
  perform public.create_ad_order(own, c, repeat('a', 64));
  select order_id into o from public.campaigns where id = c;
  update public.orders set status = 'paid', paid_at = now() where id = o;
  perform public.fulfill_order(o);
end $$;
create function pg_temp.full(u uuid, email text, prod text, campus_n int, slot text default 'standard') returns uuid language plpgsql as $$
declare c uuid := pg_temp.sub(u, email, prod, campus_n, slot);
begin perform pg_temp.approve(c); perform pg_temp.pay(c); return c; end $$;
create function pg_temp.avail(campus_n int, slot text default 'standard') returns int language sql as $$
  select (public.ad_capacity('campus:' || pg_temp.campus(campus_n), slot, (now() at time zone 'Asia/Jakarta')::date, 7, null, 'nobody@t.id') ->> 'available')::int
$$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a0', 'admin@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a1', 'a1@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a2', 'a2@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a3', 'a3@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a4', 'a4@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a5', 'a5@t.id', now());
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000a0', 'admin');

-- ---- 2.1 defaults + sold out at submit + sold out at order time ---------------------------------------------
select pg_temp.must(pg_temp.avail(0) = 3, 'default 3 free slots');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.full('00000000-0000-0000-0000-0000000000a1', 'k@t.id', 'featured-campus-7d', 0) as c1 \gset
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.full('00000000-0000-0000-0000-0000000000a2', 'k2@t.id', 'featured-campus-7d', 0) as c2 \gset
select pg_temp.must(pg_temp.avail(0) = 1, '1 of 3 slots left');
-- a4 submits and is approved while 1 slot is free ...
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a4');
select pg_temp.sub('00000000-0000-0000-0000-0000000000a4', 'late@t.id', 'featured-campus-7d', 0) as late \gset
select pg_temp.approve(:'late');
-- ... a3 takes the last slot ...
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select pg_temp.full('00000000-0000-0000-0000-0000000000a3', 'k3@t.id', 'featured-campus-7d', 0) as c3 \gset
select pg_temp.must(pg_temp.avail(0) = 0, 'sold out');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a4');
-- ... so a4 cannot start payment (authoritative check) and cannot submit a new one either.
select pg_temp.expect_err($$select public.create_ad_order('00000000-0000-0000-0000-0000000000a4', (select id from public.campaigns where contact_email = 'late@t.id'), repeat('a', 64))$$, 'SOLD_OUT');
select pg_temp.expect_err($$select pg_temp.sub('00000000-0000-0000-0000-0000000000a4', 'x@t.id', 'featured-campus-7d', 0)$$, 'SOLD_OUT');
select pg_temp.must((select next_free from (select (public.ad_capacity('campus:' || pg_temp.campus(0), 'standard', (now() at time zone 'Asia/Jakarta')::date, 7, null, null) ->> 'next_free_date')::date as next_free) x) > (now() at time zone 'Asia/Jakarta')::date,
  'next free date is in the future');
-- another campus is unaffected
select pg_temp.must(pg_temp.avail(2) = 3, 'other location still open');

-- ---- 2.1 reducing slots never touches running campaigns -----------------------------------------------------
select c.price_snapshot as p1 from public.campaigns c where id = :'c1' \gset
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select pg_temp.must((public.admin_set_slot_config('campus:' || pg_temp.campus(0), 2, 0, 1.5, 1.0, 'equal_share') ->> 'blocks_new_sales')::boolean, 'reduction reports it blocks new sales');
select pg_temp.must((select count(*) from public.campaigns where id in (:'c1', :'c2', :'c3') and status in ('active','scheduled')) = 3, 'all 3 running campaigns kept after reducing to 2');
select pg_temp.must((select price_snapshot from public.campaigns where id = :'c1') = :p1, 'running campaign price unchanged');
select pg_temp.must(pg_temp.avail(0) = 0, 'over capacity => zero free, never negative');
select pg_temp.must((select details -> 'old' ->> 'slots' from public.admin_audit_log where action = 'ad_slots.change' order by created_at desc limit 1) = '3', 'slot change audited (old)');
select pg_temp.must((select details -> 'new' ->> 'slots' from public.admin_audit_log where action = 'ad_slots.change' order by created_at desc limit 1) = '2', 'slot change audited (new)');
select pg_temp.expect_err($$select public.admin_set_slot_config('campus:x', 2, 0, 1.5, 1.0, 'equal_share')$$, 'INVALID_LOCATION');
select pg_temp.expect_err($$select public.admin_set_slot_config('global:*', 11, 0, 1.5, 1.0, 'equal_share')$$, 'INVALID_SLOTS');
select pg_temp.expect_err($$select public.admin_set_slot_config('global:*', 3, 4, 1.5, 1.0, 'equal_share')$$, 'INVALID_TOP_SLOTS');
select pg_temp.expect_err($$select public.admin_set_slot_config('global:*', 3, 1, 9, 1.0, 'equal_share')$$, 'INVALID_MULTIPLIER');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_err($$select public.admin_set_slot_config('global:*', 3, 0, 1.5, 1.0, 'equal_share')$$, 'FORBIDDEN');

-- ---- 2.3 sold out -> waitlist -> hold -> expiry -> next person ----------------------------------------------
-- A campaign ends (simulated), then slots go back to 3: exactly one slot is free.
update public.campaigns set status = 'canceled' where id = :'c3';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select public.admin_set_slot_config('campus:' || pg_temp.campus(0), 3, 0, 1.5, 1.0, 'equal_share');
select pg_temp.must(pg_temp.avail(0) = 1, 'one slot free again');
-- three people waiting, FCFS. w1 budget is below the price, so is skipped.
insert into public.ad_waitlist (email, spot, scope_level, target_key, desired_duration, max_budget, created_at) values
  ('w1@t.id', 'featured', 'campus', 'campus:' || pg_temp.campus(0), 7, 1000,  now() - interval '3 hours'),
  ('k4@t.id', 'featured', 'campus', 'campus:' || pg_temp.campus(0), 7, null,  now() - interval '2 hours'),
  ('w3@t.id', 'featured', 'campus', 'campus:' || pg_temp.campus(0), 7, 99999999, now() - interval '1 hour');
select pg_temp.must((public.process_ad_waitlist() ->> 'notified')::int = 1, 'one slot => exactly one person notified');
select pg_temp.must((select status from public.ad_waitlist where email = 'k4@t.id') = 'notified', 'oldest person whose budget covers the price is notified');
select pg_temp.must((select status from public.ad_waitlist where email = 'w1@t.id') = 'waiting', 'budget below price: skipped, still waiting');
select pg_temp.must((select status from public.ad_waitlist where email = 'w3@t.id') = 'waiting', 'next person waits while slot is held');
select pg_temp.must((select hold_expires_at - notified_at from public.ad_waitlist where email = 'k4@t.id') = interval '24 hours', 'default hold = 24h');
select pg_temp.must((select count(*) from public.ad_outbox where kind = 'waitlist_slot_free' and to_email = 'k4@t.id') = 1, 'notification queued');
select pg_temp.must((public.process_ad_waitlist() ->> 'notified')::int = 0, 'second run: no double notify');
select pg_temp.must((select count(*) from public.ad_outbox where kind = 'waitlist_slot_free') = 1, 'outbox deduped');
-- the held slot is not sellable to a stranger ...
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a4');
select pg_temp.expect_err($$select pg_temp.sub('00000000-0000-0000-0000-0000000000a4', 'other@t.id', 'featured-campus-7d', 0)$$, 'SOLD_OUT');
-- ... the hold lapses -> next person is offered it; the first one lost the hold.
update public.ad_waitlist set hold_expires_at = now() - interval '1 minute' where email = 'k4@t.id';
select pg_temp.must((public.process_ad_waitlist() ->> 'expired')::int = 1, 'expired hold released');
select pg_temp.must((select status from public.ad_waitlist where email = 'k4@t.id') = 'expired', 'first person expired');
select pg_temp.must((select status from public.ad_waitlist where email = 'w3@t.id') = 'notified', 'next person in line is offered the slot');
select pg_temp.expect_err($$select pg_temp.sub('00000000-0000-0000-0000-0000000000a4', 'k4@t.id', 'featured-campus-7d', 0)$$, 'SOLD_OUT');
-- the holder can buy it, and the entry is claimed.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a5');
select pg_temp.sub('00000000-0000-0000-0000-0000000000a5', 'w3@t.id', 'featured-campus-7d', 0) as w3c \gset
select pg_temp.must((select status from public.ad_waitlist where email = 'w3@t.id') = 'claimed', 'holder claims the slot');
select pg_temp.approve(:'w3c');
select pg_temp.pay(:'w3c');
select pg_temp.must(pg_temp.avail(0) = 0, 'sold out again after the waitlist buyer paid');
select pg_temp.must((select price_snapshot from public.campaigns where id = :'w3c') = 60000, 'waitlist buyer pays the normal price, no bidding');

-- waitlist join: validation + budget
select pg_temp.expect_err($$select public.join_ad_waitlist('a@b.co', 'featured', 'campus', null, 7, 0)$$, 'INVALID_BUDGET');
select pg_temp.must((public.join_ad_waitlist('Budget@T.id', 'featured', 'campus', 'campus:' || pg_temp.campus(0), 7, 80000) ->> 'ok')::boolean, 'join with budget');
select pg_temp.must((select max_budget from public.ad_waitlist where email = 'budget@t.id') = 80000, 'max budget stored');

-- ---- 2.1 top / standard slot types: multiplier, capacity, immutability, rotation ------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select public.admin_set_slot_config('campus:' || pg_temp.campus(1), 3, 1, 1.5, 1.0, 'fixed_position');
select pg_temp.must(pg_temp.avail(1, 'top') = 1 and pg_temp.avail(1, 'standard') = 2, '1 top + 2 standard slots');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.full('00000000-0000-0000-0000-0000000000a1', 'k@t.id', 'featured-campus-7d', 1, 'standard') as s1 \gset
select pg_temp.full('00000000-0000-0000-0000-0000000000a1', 'k@t.id', 'featured-campus-7d', 1, 'top') as t1 \gset
select pg_temp.must((select price_snapshot from public.campaigns where id = :'s1') = 60000, 'standard multiplier 1x');
select pg_temp.must((select price_snapshot from public.campaigns where id = :'t1') = 90000, 'top multiplier 1.5x');
select pg_temp.must((select o.total_amount from public.orders o join public.campaigns c on c.order_id = o.id where c.id = :'t1') = 90000, 'final price stored on the order');
select pg_temp.must(pg_temp.avail(1, 'top') = 0, 'top slot taken');
select pg_temp.expect_err($$select pg_temp.sub('00000000-0000-0000-0000-0000000000a2', 'k2@t.id', 'featured-campus-7d', 1, 'top')$$, 'SOLD_OUT');
select pg_temp.must(pg_temp.avail(1, 'standard') = 1, 'standard slot still free');
-- multiplier change is not retroactive
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select public.admin_set_slot_config('campus:' || pg_temp.campus(1), 3, 1, 3.0, 1.0, 'fixed_position');
select pg_temp.must((select price_snapshot from public.campaigns where id = :'t1') = 90000, 'old campaign keeps its price after multiplier change');
select pg_temp.must((select o.total_amount from public.orders o join public.campaigns c on c.order_id = o.id where c.id = :'t1') = 90000, 'old order keeps its price');
-- fixed_position: top first even though it started later
update public.campaigns set starts_at = now() - interval '2 hours' where id = :'s1';
select pg_temp.must((public.get_promotions(null, null, null, pg_temp.campus(1), 'featured', null, 10) -> 0 ->> 'id')::uuid = :'t1', 'fixed position: top slot listed first');
select pg_temp.must((public.get_ad_availability(array['campus:' || pg_temp.campus(1)], 'standard', (now() at time zone 'Asia/Jakarta')::date, 7) -> 0 ->> 'rotation_mode') = 'fixed_position', 'availability shows rotation mode');
select pg_temp.must((public.ad_capacity('campus:' || pg_temp.campus(0), 'standard', (now() at time zone 'Asia/Jakarta')::date, 7, null, null) ->> 'expected_share_pct')::numeric = 33.3, 'equal share shown as 33.3%');

-- ---- 2.2 utilization -----------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select pg_temp.must(not (public.admin_utilization() ->> 'enough_data')::boolean, 'no verdicts before 14 days of history');
select pg_temp.must((select r ->> 'status' from jsonb_array_elements(public.admin_utilization() -> 'rows') r where r ->> 'key' = 'campus:' || pg_temp.campus(0)) = 'no_data', 'status no_data early');
-- one underfilled location (1 of 3 slots) and the sold-out one, with 40 days of history
select pg_temp.full('00000000-0000-0000-0000-0000000000a2', 'k2@t.id', 'featured-campus-7d', 2) as u1 \gset
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
update public.campaigns c set starts_at = now() - interval '40 days', ends_at = now() + interval '50 days'
 where c.id in (select c2.id from public.campaigns c2 join public.campaign_targets t on t.campaign_id = c2.id
                 where c2.placement = 'featured' and c2.status in ('active','scheduled') and t.target_key in ('campus:' || pg_temp.campus(0), 'campus:' || pg_temp.campus(2)));
select pg_temp.must((public.admin_utilization() ->> 'enough_data')::boolean, 'verdicts after 14 days');
select pg_temp.must((select r ->> 'status' from jsonb_array_elements(public.admin_utilization() -> 'rows') r where r ->> 'key' = 'campus:' || pg_temp.campus(0)) = 'sold_out', 'fill > 85% = sold out');
select pg_temp.must((select r ->> 'status' from jsonb_array_elements(public.admin_utilization() -> 'rows') r where r ->> 'key' = 'campus:' || pg_temp.campus(2)) = 'underfilled', 'fill < 50% = underfilled');
select pg_temp.must((select (r ->> 'fill_30')::numeric from jsonb_array_elements(public.admin_utilization() -> 'rows') r where r ->> 'key' = 'campus:' || pg_temp.campus(2)) = 33.3, 'fill 30d = 1 of 3 slots');
select pg_temp.must((select r ->> 'recommendation' from jsonb_array_elements(public.admin_utilization() -> 'rows') r where r ->> 'key' = 'campus:' || pg_temp.campus(0)) like 'Sold out%', 'recommendation text, no automatic action');
-- thresholds are configurable and validated
select public.admin_set_config('slot_soldout_pct', '100');
select pg_temp.expect_err($$select public.admin_set_config('slot_underfilled_pct', '100')$$, 'INVALID_CONFIG_VALUE');
select pg_temp.must((select r ->> 'status' from jsonb_array_elements(public.admin_utilization() -> 'rows') r where r ->> 'key' = 'campus:' || pg_temp.campus(0)) = 'healthy', 'threshold change moves status (100% is not > 100%)');
select public.admin_set_config('slot_soldout_pct', '85');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_err($$select public.admin_utilization()$$, 'FORBIDDEN');

-- ---- 2.3 price proposals: suggestion only, one click, never retroactive --------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select pg_temp.expect_err($$select public.admin_generate_price_proposals()$$, 'AUTO_STEP_OFF');
select pg_temp.must(public.generate_price_proposals() = 0, 'step off => nothing proposed');
select pg_temp.expect_err($$select public.admin_set_config('ad_auto_price_step_pct', '31')$$, 'INVALID_CONFIG_VALUE');
select public.admin_set_config('ad_auto_price_step_enabled', 'true');
select pg_temp.must((public.admin_generate_price_proposals() ->> 'created')::int >= 1, 'proposal created for sold-out location');
select pg_temp.must((select new_base from public.ad_price_proposals where product_id = 'featured-campus-7d' and status = 'pending') = 72000, '60000 + 20% rounded to 72000');
select pg_temp.must((select price_per_target from public.ad_products where id = 'featured-campus-7d') = 60000, 'proposing changes nothing');
select pg_temp.must((public.admin_generate_price_proposals() ->> 'created')::int = 0, 'one pending proposal per package');
select id as prop from public.ad_price_proposals where product_id = 'featured-campus-7d' and status = 'pending' \gset
select public.admin_decide_price_proposal(:'prop', true);
select pg_temp.must((select price_per_target from public.ad_products where id = 'featured-campus-7d') = 72000, 'approved price applied to new quotes');
select pg_temp.must((select price_snapshot from public.campaigns where id = :'c1') = :p1, 'existing campaign price untouched by approval');
select pg_temp.must((select total_amount from public.orders o join public.campaigns c on c.order_id = o.id where c.id = :'c1') = :p1, 'existing order price untouched by approval');
select pg_temp.must(exists (select 1 from public.ad_price_history where product_id = 'featured-campus-7d' and old_base = 60000 and new_base = 72000), 'price history row');
select pg_temp.must(exists (select 1 from public.admin_audit_log where action = 'price_proposal.decide' and target_id = 'featured-campus-7d'), 'decision audited');
select pg_temp.expect_err($$select public.admin_decide_price_proposal((select id from public.ad_price_proposals where status = 'approved' limit 1), true)$$, 'NOT_FOUND');
-- stale proposal: price edited by hand after the proposal was made
select id as prop2 from public.ad_price_proposals where product_id = 'featured-campus-30d' and status = 'pending' \gset
update public.ad_products set price_per_target = 210000 where id = 'featured-campus-30d';
select format('select public.admin_decide_price_proposal(%L::uuid, true)', :'prop2') as stale_stmt \gset
select pg_temp.expect_err(:'stale_stmt', 'PROPOSAL_STALE');
select pg_temp.must(jsonb_array_length(public.admin_price_history('featured-campus-7d')) >= 1, 'price history readable');

rollback;
select 'phase2 ok';
