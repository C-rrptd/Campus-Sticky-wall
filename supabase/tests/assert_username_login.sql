-- Migration 037 assertions: username on profiles, availability check, login lookup.
-- Run as a superuser after 001-037 and stub_auth.sql.
\set ON_ERROR_STOP on
begin;
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-0000000000a1', 'alice@real.test', '{"display_name":"Alice","username":"Alice_1"}'),
  ('00000000-0000-4000-8000-0000000000a2', 'bob@real.test',   '{"display_name":"Bob","username":"alice_1"}'),
  ('00000000-0000-4000-8000-0000000000a3', 'cy@real.test',    '{"display_name":"Cy","username":"a b"}'),
  ('00000000-0000-4000-8000-0000000000a4', 'tester1@users.csw.invalid', '{"display_name":"Tester"}');

select pg_temp.must((select username from public.profiles where id = '00000000-0000-4000-8000-0000000000a1') = 'Alice_1', 'signup stores the username');
select pg_temp.must((select username from public.profiles where id = '00000000-0000-4000-8000-0000000000a2') is null, 'taken username (any case) is skipped, signup still works');
select pg_temp.must((select username from public.profiles where id = '00000000-0000-4000-8000-0000000000a3') is null, 'invalid username is skipped');
select pg_temp.must(public.login_email('ALICE_1') = 'alice@real.test', 'login_email is case-insensitive');
select pg_temp.must(public.login_email('nobody') is null, 'unknown username resolves to null');
select pg_temp.must(not public.username_available('alice_1'), 'taken name unavailable');
select pg_temp.must(not public.username_available('tester1'), 'script-account name unavailable');
select pg_temp.must(public.username_available('fresh.name'), 'free name available');
select pg_temp.must(not public.username_available('a@b'), 'invalid name unavailable');
rollback;
