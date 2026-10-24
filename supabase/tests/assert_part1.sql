-- Part 1 assertions (migrations 006-008). Run as a superuser after 001-008 and
-- stub_auth.sql on an EMPTY database. Any failed assertion aborts the run.
\set ON_ERROR_STOP on
begin;

create function pg_temp.as_user(u text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', u, true) $$;
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

-- ---- catalog + grants ------------------------------------------------------
do $$ begin
  assert (select count(*) from public.decorations where enabled) >= 40, 'fewer than 40 decorations';
  assert (select count(*) from public.decorations where enabled and price = 0) >= 5, 'too few free decorations';
  assert not exists (select 1 from public.decorations where category is null or render ->> 'class' is null), 'decoration missing category/class';
  assert not has_function_privilege('anon', 'public.owner_delete_record(text,text,text)', 'execute'), 'anon can delete';
  assert not has_function_privilege('anon', 'public.admin_waive_order(text,text)', 'execute'), 'anon can waive';
  assert not has_function_privilege('anon', 'public.apply_referral_credits(uuid,uuid,boolean,int)', 'execute'), 'anon can apply credits';
  assert not has_function_privilege('authenticated', 'public.apply_referral_credits(uuid,uuid,boolean,int)', 'execute'), 'client can apply credits';
  assert not has_function_privilege('authenticated', 'public.create_publication_order_credits(uuid,text,text,text,text,boolean,text,text[],text,uuid,boolean,int)', 'execute'), 'client can call order+credits directly';
end $$;

-- ---- people ----------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'owner@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a2', 'admin@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a3', 'user@t.id', now()),
  ('00000000-0000-0000-0000-0000000000b1', 'ref@t.id', now());
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'owner'), ('00000000-0000-0000-0000-0000000000a2', 'admin');
select code as rcode from public.referral_codes where user_id = '00000000-0000-0000-0000-0000000000b1' \gset
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000b2', 'inv@t.id', now(), jsonb_build_object('referral_code', :'rcode'));

select (public.create_publication_order('00000000-0000-0000-0000-0000000000a3','U','plain','yellow',null,true,'5000','{}'::text[],false,repeat('a',64)))->>'order_ref' as o1 \gset
select (public.create_publication_order('00000000-0000-0000-0000-0000000000a3','U','decorated','pink',null,true,'7000','{frame-thick,sticker-cat}'::text[],false,repeat('b',64)))->>'order_ref' as o2 \gset

-- ---- roles + waivers -------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select pg_temp.expect_err(format('select public.admin_waive_order(%L, %L)', :'o1', 'a valid reason'), 'FORBIDDEN');
select pg_temp.expect_err($$select public.owner_delete_record('note','00000000-0000-0000-0000-000000000000','DELETE')$$, 'FORBIDDEN');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_err(format('select public.admin_waive_order(%L, %L)', :'o2', 'a valid reason'), 'OWNER_REQUIRED');
select pg_temp.expect_err(format('select public.admin_waive_order(%L, %L)', :'o1', 'x'), 'REASON_REQUIRED');
select public.admin_waive_order(:'o1', 'campus club promo');
select pg_temp.expect_err(format('select public.admin_waive_order(%L, %L)', :'o1', 'campus club promo'), 'ORDER_NOT_WAIVABLE');
select pg_temp.expect_err($$select public.owner_delete_record('announcement','00000000-0000-0000-0000-000000000000','DELETE')$$, 'FORBIDDEN');
select pg_temp.expect_err($$select public.owner_delete_preview('note','00000000-0000-0000-0000-000000000000')$$, 'FORBIDDEN');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select public.admin_waive_order(:'o2', 'sponsor comp');
do $$ begin
  assert (select count(*) from public.orders where status = 'payment_waived') = 2, 'waived orders';
  assert (select count(*) from public.payment_waivers where actor_role = 'admin') = 1, 'admin waiver row';
  assert (select count(*) from public.payment_waivers where actor_role = 'owner') = 1, 'owner waiver row';
  assert not exists (select 1 from public.notes n join public.orders o on o.id = n.order_id
                      where o.status = 'payment_waived' and (n.show_amount or n.status <> 'published')), 'waived notes must publish with amount hidden';
  assert (public.admin_revenue_report(now() - interval '1 day', now() + interval '1 day') ->> 'paid_orders')::int = 0, 'waived orders counted as revenue';
end $$;

-- ---- owner deletes + append-only log --------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select public.admin_upsert_announcement(null, 'Hello', 'Body', false);
do $$ begin
  assert (select count(*) from public.announcements where updated_by = '00000000-0000-0000-0000-0000000000a2') = 1, 'updated_by not stored';
  assert (public.admin_list_announcements() -> 0 ->> 'updated_by_name') is not null, 'last editor name missing';
end $$;
select id::text as ann from public.announcements limit 1 \gset
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_err(format('select public.owner_delete_record(%L,%L,%L)', 'announcement', :'ann', 'no'), 'CONFIRM_REQUIRED');
do $$ begin assert jsonb_array_length(public.owner_delete_preview('note', (select id::text from public.notes limit 1)) -> 'effects') >= 3, 'note preview'; end $$;
select public.owner_delete_record('announcement', :'ann', 'DELETE');
select pg_temp.expect_err(format('select public.owner_delete_record(%L,%L,%L)', 'announcement', :'ann', 'DELETE'), 'NOT_FOUND');
select min(id)::text as aid from public.admin_audit_log \gset
select public.owner_delete_record('audit_entry', :'aid', 'DELETE');
select pg_temp.must(not exists (select 1 from public.admin_audit_log where id = :'aid'::bigint), 'audit entry not deleted');
select pg_temp.must(exists (select 1 from public.security_events where target_type = 'audit_entry'), 'deletion not logged');
select pg_temp.expect_err('delete from public.security_events', 'APPEND_ONLY');
select pg_temp.expect_err($$update public.security_events set action = 'x'$$, 'APPEND_ONLY');
select pg_temp.expect_err('truncate public.security_events', 'APPEND_ONLY');
select pg_temp.expect_err($$select public.owner_delete_record('city',(select id::text from public.cities limit 1),'DELETE')$$, 'RECORD_IN_USE');

-- ---- referral credits ------------------------------------------------------
select (public.create_publication_order('00000000-0000-0000-0000-0000000000b2','I','first note','yellow',null,true,'5000','{}'::text[],false,repeat('d',64)))->>'order_ref' as o0 \gset
do $$ begin assert (select status from public.referral_attributions) = 'pending_verification', 'must wait for first post'; end $$;
update public.orders set status = 'paid', paid_at = now() where order_ref = :'o0';
select public.fulfill_order(id) from public.orders where order_ref = :'o0';
select public.qualify_referral('00000000-0000-0000-0000-0000000000b2');   -- replay must not re-issue
do $$ begin
  assert (select status from public.referral_attributions) = 'qualified', 'not qualified after first post';
  assert (select count(*) from public.referral_credits) = 8, 'expected 8 credits (2 posts + 2 decorations x 2 people)';
  assert (select count(*) from public.referral_credits where user_id = '00000000-0000-0000-0000-0000000000b2' and kind = 'post') = 2, 'invitee posts';
  assert (select count(*) from public.referral_credits where user_id = '00000000-0000-0000-0000-0000000000b1' and kind = 'decoration') = 2, 'inviter decorations';
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
do $$ begin
  assert (public.my_referral_summary() ->> 'free_posts_left') = '2' and (public.my_referral_summary() ->> 'free_decorations_left') = '2', 'summary counters';
end $$;
-- free post + one free decoration, the other decoration stays paid
select public.create_publication_order_credits('00000000-0000-0000-0000-0000000000b2','I','mix a','pink',null,true,'8000','{frame-thick,sticker-cat}'::text[],repeat('e',64),null,true,1) ->> 'total_amount' as ta \gset
select pg_temp.must(:'ta' = '1000', 'free post + 1 free decoration should leave Rp1.000');
do $$ begin
  assert (select count(*) from public.referral_credits where user_id = '00000000-0000-0000-0000-0000000000b2' and status = 'reserved') = 2, 'two credits reserved';
  assert (select show_amount from public.notes where body = 'mix a') = false, 'free post must not show an amount';
end $$;
-- paid post + free decoration (uses the last decoration credit)
select public.create_publication_order_credits('00000000-0000-0000-0000-0000000000b2','I','mix b','pink',null,true,'6000','{frame-thick,sticker-cat}'::text[],repeat('f',64),null,false,1) ->> 'total_amount' as tb \gset
select pg_temp.must(:'tb' = '7000', 'paid post + 1 free decoration');
select pg_temp.expect_err($$select public.create_publication_order_credits('00000000-0000-0000-0000-0000000000b2','I','x','pink',null,true,'6000','{frame-thick}'::text[],repeat('9',64),null,false,1)$$, 'NO_CREDIT_AVAILABLE');
select pg_temp.expect_err($$select public.create_publication_order_credits('00000000-0000-0000-0000-0000000000b2','I','x','pink',null,true,'6000','{}'::text[],repeat('8',64),null,false,1)$$, 'TOO_MANY_DECORATION_CREDITS');
select pg_temp.expect_err($$select public.create_publication_order_credits(null,'I','x','pink',null,true,'6000','{}'::text[],repeat('7',64),null,true,0)$$, 'ACCOUNT_REQUIRED');
do $$ begin assert not exists (select 1 from public.notes where body = 'x'), 'failed credit call must not leave an order/note behind'; end $$;
-- abandoning releases the reservation
select id as oid from public.orders where status = 'awaiting_payment' and discount_amount > 0 order by created_at limit 1 \gset
select public.abandon_order(:'oid');
do $$ begin assert (select count(*) from public.referral_credits where user_id = '00000000-0000-0000-0000-0000000000b2' and status = 'available') >= 1, 'abandon must release credits'; end $$;
-- a fully covered order completes with no payment
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select public.create_publication_order_credits('00000000-0000-0000-0000-0000000000b1','R','free all','pink',null,true,'5000','{frame-thick}'::text[],repeat('6',64),null,true,1) ->> 'status' as sg \gset
select pg_temp.must(:'sg' = 'completed_free', 'fully covered order must complete free');
do $$ begin
  assert (select status from public.notes where body = 'free all') = 'published', 'free order must publish';
  assert (select count(*) from public.referral_credits where user_id = '00000000-0000-0000-0000-0000000000b1' and status = 'redeemed') = 2, 'credits redeemed';
end $$;
-- leaderboard counts the referral, and still does after the Owner deletes the entry
do $$ begin assert (public.leaderboard('referrals','all',5) -> 'rows' -> 0 ->> 'value') = '1', 'leaderboard before delete'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select public.owner_delete_record('referral', '00000000-0000-0000-0000-0000000000b2', 'DELETE');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
do $$ begin
  assert (public.leaderboard('referrals','all',5) -> 'rows' -> 0 ->> 'value') = '1', 'leaderboard after delete';
  assert (select count(*) from public.referral_credits) = 8, 'credits must survive entry deletion';
end $$;

rollback;
\echo ALL PART 1 ASSERTIONS PASSED
