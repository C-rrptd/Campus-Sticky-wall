-- Streaks, streak achievements, campus leaderboard (migration 051). Run after 001-051 + stub_auth.sql.
-- Statements commit one by one (counts depend on now()); cleans up at the end.
\set ON_ERROR_STOP on
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
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Jakarta')::date $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000e1', 'e1@t.id', now()), ('00000000-0000-0000-0000-0000000000e2', 'e2@t.id', now()),
  ('00000000-0000-0000-0000-0000000000e3', 'e3@t.id', now());

select pg_temp.expect_err($$select public.touch_streak()$$, 'UNAUTHENTICATED');
select pg_temp.must(has_function_privilege('authenticated', 'public.touch_streak()', 'execute') and not has_function_privilege('anon', 'public.touch_streak()', 'execute'), 'touch_streak: members only');
select pg_temp.must(has_function_privilege('anon', 'public.campus_leaderboard(text,int)', 'execute'), 'campus board is public');

-- day 1, and the same day again changes nothing
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select pg_temp.must((public.touch_streak() ->> 'streak')::int = 1, 'first visit = 1');
select pg_temp.must((public.touch_streak() ->> 'streak')::int = 1, 'same day twice = still 1');

-- consecutive days count up; day 3 notifies
update public.profiles set last_visit_on = pg_temp.today() - 1, streak_count = 1 where id = '00000000-0000-0000-0000-0000000000e1';
select pg_temp.must((public.touch_streak() ->> 'streak')::int = 2, 'next day = 2');
select pg_temp.must(not exists (select 1 from public.notifications where kind = 'streak'), 'no notification at 2');
update public.profiles set last_visit_on = pg_temp.today() - 1 where id = '00000000-0000-0000-0000-0000000000e1';
select pg_temp.must((public.touch_streak() ->> 'streak')::int = 3, 'next day = 3');
select pg_temp.must((public.my_notifications() -> 'items' -> 0 ->> 'kind') = 'streak' and (public.my_notifications() -> 'items' -> 0 ->> 'count')::int = 3
  and (public.my_notifications() ->> 'unread')::int = 1, 'streak notification shows 3 days, unread');
select public.touch_streak();
select pg_temp.must((select count(*) from public.notifications where kind = 'streak') = 1, 'no duplicate on same day');

-- a gap resets the streak but keeps the best
update public.profiles set last_visit_on = pg_temp.today() - 3 where id = '00000000-0000-0000-0000-0000000000e1';
select pg_temp.must((public.touch_streak() ->> 'streak')::int = 1 and (public.touch_streak() ->> 'best')::int = 3, 'gap resets to 1, best stays 3');

-- streak achievements follow the best streak
select pg_temp.must((select (a ->> 'earned')::boolean from jsonb_array_elements(public.achievements_for('00000000-0000-0000-0000-0000000000e1', false)) a where a ->> 'id' = 'streak-7') = false, 'streak-7 not earned at best 3');
update public.profiles set streak_best = 7 where id = '00000000-0000-0000-0000-0000000000e1';
select pg_temp.must((select (a ->> 'earned')::boolean from jsonb_array_elements(public.achievements_for('00000000-0000-0000-0000-0000000000e1', false)) a where a ->> 'id' = 'streak-7') = true, 'streak-7 earned at best 7');
select pg_temp.must((select (a ->> 'earned')::boolean from jsonb_array_elements(public.achievements_for('00000000-0000-0000-0000-0000000000e1', false)) a where a ->> 'id' = 'streak-30') = false, 'streak-30 not earned');
select pg_temp.must(jsonb_array_length(public.achievements_for('00000000-0000-0000-0000-0000000000e1', false)) = 12, 'twelve achievements');

-- suspended members do not accrue a streak
update public.profiles set suspended_at = now(), streak_count = 0, last_visit_on = null where id = '00000000-0000-0000-0000-0000000000e2';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
select pg_temp.must((public.touch_streak() ->> 'streak')::int = 0, 'suspended: no streak');

-- campus board
insert into public.notes (id, author_id, body, status, published_at, author_name, publication_amount, campus_id) values
  ('bbbbbbbb-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e1', 'A note', 'published', now(), 'A', 5000, (select id from public.campuses order by name limit 1)),
  ('bbbbbbbb-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000e1', 'B note', 'published', now(), 'A', 5000, (select id from public.campuses order by name desc limit 1)),
  ('bbbbbbbb-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000e1', 'no campus', 'published', now(), 'A', 5000, null);
insert into public.votes (note_id, user_id, created_at) values
  ('bbbbbbbb-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2', now()),
  ('bbbbbbbb-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e3', now()),
  ('bbbbbbbb-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e1', now()),          -- own vote: ignored
  ('bbbbbbbb-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000e2', now() - interval '40 days'),
  ('bbbbbbbb-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000e2', now());          -- no campus: ignored
select pg_temp.must((public.campus_leaderboard('week') -> 'rows' -> 0 ->> 'value')::int = 2 and jsonb_array_length(public.campus_leaderboard('week') -> 'rows') = 1, 'week: one campus, 2 votes, own vote and campus-less note ignored');
select pg_temp.must(jsonb_array_length(public.campus_leaderboard('all') -> 'rows') = 2 and (public.campus_leaderboard('all') -> 'rows' -> 0 ->> 'rank')::int = 1, 'all time: both campuses, ranked');
select pg_temp.expect_err($$select public.campus_leaderboard('year')$$, 'INVALID_LEADERBOARD');

-- cleanup
delete from public.notes where id in ('bbbbbbbb-0000-0000-0000-0000000000e1', 'bbbbbbbb-0000-0000-0000-0000000000e2', 'bbbbbbbb-0000-0000-0000-0000000000e3');
delete from auth.users where id in ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000e3');
select 'streaks: ok';
