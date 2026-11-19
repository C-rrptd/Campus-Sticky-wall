-- Return hooks (migration 052): lost streak, campus_id on the board, today_pulse, my_week. Run after 001-052 + stub_auth.sql.
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
  ('00000000-0000-0000-0000-0000000000f1', 'f1@t.id', now()), ('00000000-0000-0000-0000-0000000000f2', 'f2@t.id', now()),
  ('00000000-0000-0000-0000-0000000000f3', 'f3@t.id', now());

-- grants
select pg_temp.must(has_function_privilege('anon', 'public.today_pulse()', 'execute'), 'pulse is public');
select pg_temp.must(has_function_privilege('authenticated', 'public.my_week()', 'execute') and not has_function_privilege('anon', 'public.my_week()', 'execute'), 'my_week: members only');
select pg_temp.expect_err($$select public.my_week()$$, 'UNAUTHENTICATED');

-- lost streak: only a broken streak of 3+ reports it, only on the day it breaks
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select pg_temp.must((public.touch_streak() ->> 'lost')::int = 0, 'first visit: nothing lost');
update public.profiles set streak_count = 5, streak_best = 5, last_visit_on = pg_temp.today() - 3 where id = '00000000-0000-0000-0000-0000000000f1';
select pg_temp.must((public.touch_streak() ->> 'lost')::int = 5 and (public.touch_streak() ->> 'streak')::int = 1, 'gap after 5 days: lost 5, restarts at 1');
select pg_temp.must((public.touch_streak() ->> 'lost')::int = 0, 'second call the same day: lost is 0');
update public.profiles set streak_count = 2, last_visit_on = pg_temp.today() - 3 where id = '00000000-0000-0000-0000-0000000000f1';
select pg_temp.must((public.touch_streak() ->> 'lost')::int = 0, 'a 2-day streak is not worth a loss message');
update public.profiles set streak_count = 4, last_visit_on = pg_temp.today() - 1 where id = '00000000-0000-0000-0000-0000000000f1';
select pg_temp.must((public.touch_streak() ->> 'lost')::int = 0 and (public.touch_streak() ->> 'streak')::int = 5, 'consecutive day: nothing lost');

-- board rows carry campus_id; pulse and my_week count what they say
insert into public.notes (id, author_id, body, status, published_at, author_name, publication_amount, campus_id) values
  ('cccccccc-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f1', 'A', 'published', now(), 'A', 5000, (select id from public.campuses order by name limit 1)),
  ('cccccccc-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000f1', 'B', 'published', now() - interval '9 days', 'A', 5000, (select id from public.campuses order by name limit 1)),
  ('cccccccc-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000f1', 'C', 'pending_moderation', null, 'A', 5000, null);
insert into public.votes (note_id, user_id, created_at) values
  ('cccccccc-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f2', now()),
  ('cccccccc-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f3', now()),
  ('cccccccc-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f1', now()),          -- own vote: ignored
  ('cccccccc-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000f2', now() - interval '9 days');  -- old: ignored
select pg_temp.must((public.campus_leaderboard('week') -> 'rows' -> 0 ->> 'campus_id')::uuid = (select id from public.campuses order by name limit 1), 'board row has campus_id');
select pg_temp.must((public.today_pulse() ->> 'notes')::int = 1 and (public.today_pulse() ->> 'votes')::int = 2, 'pulse: 1 note today, 2 votes (own and old ignored)');
select pg_temp.must((public.my_week() ->> 'notes')::int = 1 and (public.my_week() ->> 'votes')::int = 2 and (public.my_week() ->> 'streak')::int = 5, 'my_week: 1 note, 2 votes, streak 5');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
select pg_temp.must((public.my_week() ->> 'notes')::int = 0 and (public.my_week() ->> 'votes')::int = 0, 'my_week is per member');

-- cleanup
delete from public.notes where id in ('cccccccc-0000-0000-0000-0000000000f1', 'cccccccc-0000-0000-0000-0000000000f2', 'cccccccc-0000-0000-0000-0000000000f3');
delete from auth.users where id in ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000f3');
select 'fomo: ok';
