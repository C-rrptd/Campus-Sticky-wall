-- Migration 039 assertions: submit_decoration limits, admin review, approval lands in the catalog as a placeable sticker.
-- Run as a superuser after 001-039 and stub_auth.sql.
\set ON_ERROR_STOP on
begin;
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-0000000000c1', 'maker@real.test', '{"display_name":"Maker"}'),
  ('00000000-0000-4000-8000-0000000000c2', 'boss@real.test',  '{"display_name":"Boss"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000000c2', 'admin');

-- a normal user cannot upload
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', true);
do $$ begin
  perform public.submit_decoration('Sneaky');
  raise exception 'ASSERT FAILED: non-admin upload should fail';
exception when sqlstate 'CSW03' then null; end $$;

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c2', true);
create temp table ids as select public.submit_decoration('  Happy cat ') as id;
select pg_temp.must((select id ~ '^u-[0-9a-f]{12}$' from ids), 'id has the u-<12 hex> shape');
select pg_temp.must((select name from public.decoration_submissions) = 'Happy cat', 'name is trimmed');

-- a normal user cannot review
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', true);
do $$ begin
  perform public.admin_review_decoration((select id from ids), true, null, '0', null);
  raise exception 'ASSERT FAILED: non-admin review should fail';
exception when sqlstate 'CSW03' then null; end $$;

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c2', true);
select public.admin_review_decoration((select id from ids), true, 'Happy cat', '1500', null);
select pg_temp.must((select placeable and category = 'Community' and price = 1500 and enabled from public.decorations where id = (select id from ids)), 'approved upload is a priced, placeable Community sticker');
select pg_temp.must((select status from public.decoration_submissions where id = (select id from ids)) = 'approved', 'submission marked approved');
do $$ begin
  perform public.admin_review_decoration((select id from ids), false, null, null, 'x');
  raise exception 'ASSERT FAILED: reviewing twice should fail';
exception when sqlstate 'CSW07' then null; end $$;
rollback;
