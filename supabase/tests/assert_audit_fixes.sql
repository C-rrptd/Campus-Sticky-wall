-- Migration 024 assertions: pin_until, dead sort removed, offset cap, reserved profile names, referral needs a paid order.
-- Run as a superuser after 001-024 and stub_auth.sql.
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
-- Creates one order (optionally for a member), sets its status, fulfils it; returns the note id.
create function pg_temp.pub(uid uuid, st text, decos text[]) returns uuid language plpgsql as $$
declare v jsonb; oid uuid;
begin
  v := public.create_publication_order_v2(uid, 'Rani', 'audit note ' || gen_random_uuid()::text, 'yellow', null, false, '2500', decos, false,
         encode(sha256(gen_random_uuid()::text::bytea), 'hex'), null, null, false, 0, null, null, false, false);
  select id into oid from public.orders where order_ref = v ->> 'order_ref';
  update public.orders set status = st, paid_at = now() where id = oid;
  perform public.fulfill_order(oid);
  return (select id from public.notes where order_id = oid);
end $$;

-- ---- wall: dead sort gone, offset cap, pin_until ----
select pg_temp.expect_err($$select public.get_wall('contribution')$$, 'INVALID_SORT');
select pg_temp.must(public.get_wall('newest', null, 24, 5001) = '[]'::jsonb, 'offset beyond 5000 returns an empty page');
create temp table n as select pg_temp.pub(null, 'paid', '{pin-top}') as pinned, pg_temp.pub(null, 'paid', '{}') as plain;
select pg_temp.must((select pin_until > now() + interval '6 days' from public.notes where id = (select pinned from n)), 'pin-top note has pin_until ~7 days out');
select pg_temp.must((select pin_until is null from public.notes where id = (select plain from n)), 'plain note has no pin_until');
select pg_temp.must((public.get_wall('newest', null, 1, 0) -> 0 ->> 'id')::uuid = (select pinned from n), 'pinned note is first');

-- ---- reserved profile names ----
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000e1', 'e1@t.id', now());
select pg_temp.expect_err($$update public.profiles set display_name = 'Admin' where id = '00000000-0000-0000-0000-0000000000e1'$$, 'NAME_NOT_AVAILABLE');
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000e2', 'staff@t.id', now());
select pg_temp.must((select display_name from public.profiles where id = '00000000-0000-0000-0000-0000000000e2') = 'Student', 'signup with a reserved email name falls back to Student');

-- ---- referral qualifies only after a PAID order ----
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000f1', 'f1@t.id', now());
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select '00000000-0000-0000-0000-0000000000f2', 'f2@t.id', now(),
         jsonb_build_object('referral_code', (select code from public.referral_codes where user_id = '00000000-0000-0000-0000-0000000000f1'));
select pg_temp.must((select status from public.referral_attributions where referred_user_id = '00000000-0000-0000-0000-0000000000f2') = 'pending_verification', 'attribution starts pending');
select pg_temp.pub('00000000-0000-0000-0000-0000000000f2', 'completed_free', '{}');
select pg_temp.must((select status from public.referral_attributions where referred_user_id = '00000000-0000-0000-0000-0000000000f2') = 'pending_verification', 'a free order does not qualify the referral');
select pg_temp.pub('00000000-0000-0000-0000-0000000000f2', 'paid', '{}');
select pg_temp.must((select status from public.referral_attributions where referred_user_id = '00000000-0000-0000-0000-0000000000f2') = 'qualified', 'a paid order qualifies the referral');

select 'audit fixes OK';
rollback;
