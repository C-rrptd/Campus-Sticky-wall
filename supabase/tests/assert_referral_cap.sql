-- Referral credits are capped at 3 posts and 3 decorations per person (migration 046).
\set ON_ERROR_STOP on
begin;
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000d0', 'r@t.id', now()),
  ('00000000-0000-0000-0000-0000000000d1', 'f1@t.id', now()), ('00000000-0000-0000-0000-0000000000d2', 'f2@t.id', now()),
  ('00000000-0000-0000-0000-0000000000d3', 'f3@t.id', now()), ('00000000-0000-0000-0000-0000000000d4', 'f4@t.id', now());
update public.profiles set first_paid_at = now() where id::text like '00000000-0000-0000-0000-0000000000d%';
insert into public.referral_attributions (referred_user_id, referrer_id, code, status)
  select id, '00000000-0000-0000-0000-0000000000d0', 'CAPTEST1', 'pending_verification' from public.profiles where id in
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000d4');
select public.qualify_referral(id) from public.profiles where id in
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000d4') order by id;
select pg_temp.must((select count(*) from public.referral_credits where user_id = '00000000-0000-0000-0000-0000000000d0' and kind = 'post') = 3, 'referrer capped at 3 post credits');
select pg_temp.must((select count(*) from public.referral_credits where user_id = '00000000-0000-0000-0000-0000000000d0' and kind = 'decoration') = 3, 'referrer capped at 3 decoration credits');
select pg_temp.must((select count(*) from public.referral_credits where user_id = '00000000-0000-0000-0000-0000000000d4') = 2, 'the 4th friend still gets their own 1 post + 1 decoration');
select pg_temp.must((select count(*) from public.referral_attributions where status = 'qualified' and referrer_id = '00000000-0000-0000-0000-0000000000d0') = 4, 'all four referrals still qualify');

-- Grandfathering: a member with a published note priced >= 5000 becomes active when 046 is (re-)applied; a 2500 note does not.
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000e1', 'old1@t.id', now()), ('00000000-0000-0000-0000-0000000000e2', 'old2@t.id', now());
insert into public.notes (id, body, status, published_at, author_name, publication_amount, author_id) values
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee1', 'old paid', 'published', now() - interval '5 days', 'A', 6000, '00000000-0000-0000-0000-0000000000e1'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee2', 'old small', 'published', now() - interval '5 days', 'B', 2500, '00000000-0000-0000-0000-0000000000e2');
\i supabase/migrations/046_referral_activation_digest_suggestions.sql
select pg_temp.must((select first_paid_at is not null and paid_total = 6000 from public.profiles where id = '00000000-0000-0000-0000-0000000000e1'), 'earlier payer is grandfathered');
select pg_temp.must((select first_paid_at is null and paid_total = 0 from public.profiles where id = '00000000-0000-0000-0000-0000000000e2'), 'a 2500 note does not activate');
rollback;
\echo REFERRAL CAP ASSERTIONS PASSED
