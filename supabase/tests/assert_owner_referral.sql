-- Owner referrals (migration 056): no requirements, usage limits, custom credit amounts, no cap interference.
\set ON_ERROR_STOP on
begin;
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create function pg_temp.as_user(u uuid) returns void language sql as $$ select set_config('request.jwt.claim.sub', u::text, true) $$;
create function pg_temp.credits(u uuid, k text) returns bigint language sql as $$
  select count(*) from public.referral_credits where user_id = u and kind = k and origin = 'owner' and status = 'available' $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a0', 'owner@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a1', 'admin@t.id', now());
update public.profiles set role = 'owner' where id = '00000000-0000-0000-0000-0000000000a0';
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000a1';

-- 1. The owner's personal code: a verified friend gets 3 posts + 10 decorations with nobody having paid.
select pg_temp.must(public.has_paid_publication('00000000-0000-0000-0000-0000000000a0'), 'owner code is always active');
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select '00000000-0000-0000-0000-0000000000b1', 'f1@t.id', now(),
       jsonb_build_object('referral_code', code) from public.referral_codes where user_id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.must((select status from public.referral_attributions where referred_user_id = '00000000-0000-0000-0000-0000000000b1') = 'qualified', 'personal owner code qualifies on verification');
select pg_temp.must(pg_temp.credits('00000000-0000-0000-0000-0000000000b1', 'post') = 3, 'friend gets 3 free posts');
select pg_temp.must(pg_temp.credits('00000000-0000-0000-0000-0000000000b1', 'decoration') = 10, 'friend gets 10 free decorations');

-- 2. Only the owner makes custom codes.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
do $$ begin
  perform public.owner_create_referral_code('ADMINTRY', 1, 1, null, null);
  raise exception 'ASSERT FAILED: admin created an owner code';
exception when others then if sqlerrm like 'ASSERT FAILED%' then raise; end if; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a0');
select public.owner_create_referral_code('kampus2026', 5, 20, 2, 'campus launch');
select pg_temp.must((select max_uses = 2 and post_credits = 5 and deco_credits = 20 from public.owner_referral_codes where code = 'KAMPUS2026'), 'custom code saved upper-cased with its limits');
do $$ begin
  perform public.owner_create_referral_code('ab', 1, 1, null, null);
  raise exception 'ASSERT FAILED: 2-letter code accepted';
exception when others then if sqlerrm like 'ASSERT FAILED%' then raise; end if; end $$;
do $$ declare c text; begin
  select code into c from public.referral_codes limit 1;
  perform public.owner_create_referral_code(c, 1, 1, null, null);
  raise exception 'ASSERT FAILED: code clashing with a personal code accepted';
exception when others then if sqlerrm like 'ASSERT FAILED%' then raise; end if; end $$;

-- 3. Usage limit 2: two verified signups get 5 + 20, the third is rejected and gets nothing.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c1', 'c1@t.id', now(), '{"referral_code":"kampus2026"}'),
  ('00000000-0000-0000-0000-0000000000c2', 'c2@t.id', now(), '{"referral_code":"KAMPUS2026"}'),
  ('00000000-0000-0000-0000-0000000000c3', 'c3@t.id', now(), '{"referral_code":"KAMPUS2026"}');
select pg_temp.must(pg_temp.credits('00000000-0000-0000-0000-0000000000c1', 'post') = 5 and pg_temp.credits('00000000-0000-0000-0000-0000000000c1', 'decoration') = 20, 'custom amounts granted');
select pg_temp.must(pg_temp.credits('00000000-0000-0000-0000-0000000000c2', 'decoration') = 20, 'second use works');
select pg_temp.must((select status || '/' || reject_reason from public.referral_attributions where referred_user_id = '00000000-0000-0000-0000-0000000000c3') = 'rejected/code_full', 'third use refused: code_full');
select pg_temp.must(pg_temp.credits('00000000-0000-0000-0000-0000000000c3', 'post') = 0, 'refused signup gets no credits');
select pg_temp.must((select uses from public.owner_referral_codes where code = 'KAMPUS2026') = 2, 'uses counted');

-- 4. Unverified email: nothing until verification, then credits. Raising the limit reopens the code.
select public.owner_update_referral_code('KAMPUS2026', true, 5);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c4', 'c4@t.id', null, '{"referral_code":"KAMPUS2026"}');
select pg_temp.must(pg_temp.credits('00000000-0000-0000-0000-0000000000c4', 'post') = 0, 'no credits before email verification');
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-0000000000c4';
select pg_temp.must(pg_temp.credits('00000000-0000-0000-0000-0000000000c4', 'post') = 5, 'credits arrive on verification');

-- 5. Disabled code: later signups are not attributed at all.
select public.owner_update_referral_code('KAMPUS2026', false, 5);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c5', 'c5@t.id', now(), '{"referral_code":"KAMPUS2026"}');
select pg_temp.must(not exists (select 1 from public.referral_attributions where referred_user_id = '00000000-0000-0000-0000-0000000000c5'), 'disabled code is ignored');

-- 6. Owner credits never expire and never block friend-to-friend credits (the 3+3 cap only counts friend credits).
select pg_temp.must(not exists (select 1 from information_schema.columns where table_name in ('owner_referral_codes', 'referral_credits') and column_name like '%expire%'), 'no expiry column');
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000d1', 'r@t.id', now()), ('00000000-0000-0000-0000-0000000000d2', 'd@t.id', now());
update public.profiles set first_paid_at = now() where id in ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2');
insert into public.referral_credits (user_id, kind, slot, source_ref, recipient, origin)
select '00000000-0000-0000-0000-0000000000d1', 'decoration', s, '00000000-0000-0000-0000-0000000000d1', 'invitee', 'owner' from generate_series(1, 10) s;
insert into public.referral_attributions (referred_user_id, referrer_id, code, status)
values ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d1', 'FRIENDCD', 'pending_verification');
select public.qualify_referral('00000000-0000-0000-0000-0000000000d2');
select pg_temp.must((select count(*) from public.referral_credits where user_id = '00000000-0000-0000-0000-0000000000d1' and kind = 'decoration') = 11, '10 owner credits + 1 friend credit');
rollback;
\echo OWNER REFERRAL ASSERTIONS PASSED
