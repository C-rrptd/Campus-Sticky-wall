-- Migration 054: daily_top. Run after 001-054 + stub_auth.sql.
\set ON_ERROR_STOP on
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
insert into auth.users (id, email, email_confirmed_at) select ('00000000-0000-0000-0000-0000000000c' || i)::uuid, 'c' || i || '@t.id', now() from generate_series(1, 4) i;

select pg_temp.must(has_function_privilege('anon', 'public.daily_top(uuid)', 'execute') and not has_function_privilege('anon', 'public.top_note_between(timestamptz,timestamptz,uuid)', 'execute'), 'daily_top public, helper not');
select pg_temp.must(public.daily_top() = '{"today": null, "yesterday": null}'::jsonb, 'empty site: no top notes');

insert into public.notes (id, author_id, body, status, published_at, author_name, publication_amount) values
  ('eeeeeeee-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000c1', 'A', 'published', now() - interval '3 days', 'A', 5000),
  ('eeeeeeee-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000c1', 'B', 'published', now() - interval '2 days', 'B', 5000),
  ('eeeeeeee-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000000c1', 'C', 'pending_moderation', null, 'C', 5000);
insert into public.votes (note_id, user_id, created_at) values
  ('eeeeeeee-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000c2', now()),
  ('eeeeeeee-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000c3', now()),
  ('eeeeeeee-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000c2', now()),
  ('eeeeeeee-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000c1', now()),                      -- own vote: ignored
  ('eeeeeeee-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000c3', now() - interval '3 days'),  -- too old
  ('eeeeeeee-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000000c3', now());                      -- unpublished: ignored
select pg_temp.must(public.daily_top() -> 'today' ->> 'id' = 'eeeeeeee-0000-0000-0000-00000000000a' and (public.daily_top() -> 'today' ->> 'votes')::int = 2, 'today: note A with 2 upvotes');
select pg_temp.must((public.daily_top() ->> 'yesterday') is null, 'yesterday: no votes, no winner');
select pg_temp.must((public.daily_top((select id from public.campuses order by name limit 1)) ->> 'today') is null, 'campus filter: notes without that campus do not count');

-- yesterday: tie goes to the older note, snippet is cut at 100 characters, anon may call it
insert into public.notes (id, author_id, body, status, published_at, author_name, publication_amount) values
  ('eeeeeeee-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-0000000000c1', repeat('x', 150), 'published', now() - interval '5 days', 'D', 5000),
  ('eeeeeeee-0000-0000-0000-00000000000e', '00000000-0000-0000-0000-0000000000c1', 'E', 'published', now() - interval '4 days', 'E', 5000);
insert into public.votes (note_id, user_id, created_at)
  select n, '00000000-0000-0000-0000-0000000000c2', (date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta') - interval '12 hours'
    from unnest(array['eeeeeeee-0000-0000-0000-00000000000d', 'eeeeeeee-0000-0000-0000-00000000000e']::uuid[]) n;
select pg_temp.must(public.daily_top() -> 'yesterday' ->> 'id' = 'eeeeeeee-0000-0000-0000-00000000000d' and (public.daily_top() -> 'yesterday' ->> 'votes')::int = 1, 'yesterday: tie goes to the older note');
select pg_temp.must(length(public.daily_top() -> 'yesterday' ->> 'snippet') = 100, 'snippet is 100 chars');
select pg_temp.must(public.daily_top() -> 'today' ->> 'id' = 'eeeeeeee-0000-0000-0000-00000000000a', 'yesterday votes do not leak into today');

select 'daily_top: ok';
delete from public.notes where id::text like 'eeeeeeee-%';
delete from auth.users where id::text like '00000000-0000-0000-0000-0000000000c_';
