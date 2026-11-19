-- Migration 055 (milestone pings). Run after 001-055 + stub_auth.sql. Each statement commits; cleans up at the end.
\set ON_ERROR_STOP on
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
create function pg_temp.items() returns jsonb language sql as $$ select public.my_notifications() -> 'items' $$;
create function pg_temp.vote(i int) returns void language sql as $$
  insert into public.votes (note_id, user_id) values ('aaaaaaaa-0000-0000-0000-0000000000f1', ('00000000-0000-0000-0000-0000000010' || lpad(i::text, 2, '0'))::uuid) $$;

insert into auth.users (id, email, email_confirmed_at) select ('00000000-0000-0000-0000-0000000010' || lpad(i::text, 2, '0'))::uuid, 'm' || i || '@t.id', now() from generate_series(0, 11) i;
insert into public.notes (id, author_id, body, status, published_at, author_name, publication_amount) values
  ('aaaaaaaa-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-000000001000', 'milestone note', 'published', now(), 'M', 5000);

select pg_temp.must(not has_function_privilege('authenticated', 'public.notify_milestone()', 'execute'), 'trigger fn is not callable');
select pg_temp.vote(i) from generate_series(1, 9) i;
select pg_temp.must((select count(*) from public.notifications where kind = 'milestone') = 0, '9 upvotes: no milestone yet');
insert into public.votes (note_id, user_id) values ('aaaaaaaa-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-000000001000'); -- own vote
select pg_temp.vote(10);
select pg_temp.must((select count(*) from public.notifications where kind = 'milestone' and info = 10) = 1, '10 upvotes: one milestone row (own vote not counted)');
select pg_temp.as_user('00000000-0000-0000-0000-000000001000');
select pg_temp.must((select j from jsonb_array_elements(pg_temp.items()) j where j ->> 'kind' = 'milestone') ->> 'count' = '10', 'list shows count 10');
select pg_temp.must((select j from jsonb_array_elements(pg_temp.items()) j where j ->> 'kind' = 'milestone') -> 'note' ->> 'snippet' = 'milestone note', 'list shows the note');

-- unvote then re-vote crosses 10 again: no second row, even after the first was read
select public.mark_notifications_read(null);
delete from public.votes where note_id = 'aaaaaaaa-0000-0000-0000-0000000000f1' and user_id = '00000000-0000-0000-0000-000000001010';
select pg_temp.vote(10);
select pg_temp.must((select count(*) from public.notifications where kind = 'milestone') = 1, 're-crossing 10 does not fire again');

delete from public.notes where id = 'aaaaaaaa-0000-0000-0000-0000000000f1';
delete from auth.users where id::text like '00000000-0000-0000-0000-0000000010__';
select 'milestones: ok';
