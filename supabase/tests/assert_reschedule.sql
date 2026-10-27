-- Migration 030: reschedule an approved, unpaid ad whose start date passed. Run after 001-030 + stub_auth.sql on an EMPTY database.
\set ON_ERROR_STOP on
begin;
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, true) $$;
create function pg_temp.expect_err(stmt text, code text) returns void language plpgsql as $$
begin
  begin execute stmt;
  exception when others then
    if sqlerrm like '%' || code || '%' then return; end if;
    raise exception 'expected %, got: %  [%]', code, sqlerrm, stmt;
  end;
  raise exception 'expected % but statement succeeded: %', code, stmt;
end $$;
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000d1', 'adv@t.id', now()), ('00000000-0000-0000-0000-0000000000d2', 'admin@t.id', now()),
  ('00000000-0000-0000-0000-0000000000d3', 'other@t.id', now());
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000d2', 'admin');
select c.id as campus from public.campuses c where c.enabled limit 1 \gset
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select (public.upsert_campaign_draft('00000000-0000-0000-0000-0000000000d1', null, 'Kopi', 'k@t.id', 'Coffee ad', 'text', 'local_business',
  null, null, 'feed-campus-7d', (now() at time zone 'Asia/Jakarta')::date,
  jsonb_build_array(jsonb_build_object('level', 'campus', 'id', :'campus'))) ->> 'campaign_id') as c1 \gset
select pg_temp.expect_err(format($$select public.upsert_campaign_draft('00000000-0000-0000-0000-0000000000d1', null, 'Kopi', 'k@t.id', 'Far ad', 'text', 'local_business',
  null, null, 'feed-campus-7d', (now() at time zone 'Asia/Jakarta')::date + 15, jsonb_build_array(jsonb_build_object('level', 'campus', 'id', %L)))$$, :'campus'), 'INVALID_START_DATE');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select public.admin_review_campaign(:'c1', 'approve', null);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
-- start date not passed yet -> refused
select pg_temp.expect_err(format('select public.reschedule_my_campaign(%L, current_date + 3)', :'c1'), 'NOT_RESCHEDULABLE');
update public.campaigns set requested_start = (now() at time zone 'Asia/Jakarta')::date - 2 where id = :'c1';
select pg_temp.expect_err(format('select public.reschedule_my_campaign(%L, current_date - 1)', :'c1'), 'INVALID_START');
select pg_temp.expect_err(format('select public.reschedule_my_campaign(%L, (now() at time zone ''Asia/Jakarta'')::date + 15)', :'c1'), 'INVALID_START');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d3');
select pg_temp.expect_err(format('select public.reschedule_my_campaign(%L, current_date + 3)', :'c1'), 'NOT_FOUND');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select public.reschedule_my_campaign(:'c1', (now() at time zone 'Asia/Jakarta')::date + 14);
do $$ begin assert (select status from public.campaigns where title = 'Coffee ad') = 'approved', 'still approved';
  assert (select requested_start from public.campaigns where title = 'Coffee ad') = (now() at time zone 'Asia/Jakarta')::date + 14, 'date moved'; end $$;
rollback;
select 'ok';
