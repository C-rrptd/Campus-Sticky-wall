-- 052: return hooks for the wall. Idempotent. Builds on 051.
--   touch_streak() also returns 'lost': the streak a member just broke (3+ days), else 0. Only the first call of the day sees it.
--   campus_leaderboard() rows gain campus_id so the wall can say "your campus is 14 votes behind #1".
--   today_pulse(): public counts for today (Asia/Jakarta): notes published, upvotes cast. Counts only, no names.
--   my_week(): the signed-in member's week so far (Monday 00:00 WIB): notes published, upvotes received, current streak.
--   Two indexes so the day/week range scans do not read whole tables.

create index if not exists votes_created_at_idx on public.votes (created_at);
create index if not exists notes_published_at_idx on public.notes (published_at) where status = 'published';

-- 051's touch_streak plus v_lost.
create or replace function public.touch_streak() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  p public.profiles;
  v_next int;
  v_lost int := 0;
begin
  if v_uid is null then perform public.app_error('CSW01', 'UNAUTHENTICATED'); end if;
  select * into p from public.profiles where id = v_uid for update;
  if not found or p.suspended_at is not null then return jsonb_build_object('streak', 0, 'best', 0); end if;
  if p.last_visit_on is distinct from v_today then
    v_next := case when p.last_visit_on = v_today - 1 then p.streak_count + 1 else 1 end;
    if v_next = 1 and p.streak_count >= 3 then v_lost := p.streak_count; end if;
    update public.profiles set streak_count = v_next, streak_best = greatest(p.streak_best, v_next), last_visit_on = v_today
     where id = v_uid returning * into p;
    if v_next in (3, 7, 30, 100) then
      insert into public.notifications (user_id, kind, info) values (v_uid, 'streak', v_next);
    end if;
  end if;
  return jsonb_build_object('streak', p.streak_count, 'best', p.streak_best, 'lost', v_lost);
end $$;

-- 051's board plus campus_id in each row.
create or replace function public.campus_leaderboard(p_period text default 'week', p_limit int default 25) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_since timestamptz;
  v_rows jsonb;
begin
  if p_period not in ('all', 'week', 'month') then perform public.app_error('CSW40', 'INVALID_LEADERBOARD'); end if;
  v_since := case p_period
               when 'week' then date_trunc('week', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta'
               when 'month' then date_trunc('month', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta'
               else '-infinity'::timestamptz end;
  select coalesce(jsonb_agg(jsonb_build_object('rank', r.rank, 'campus_id', r.id, 'display_name', r.name, 'value', r.votes::text, 'is_me', false)
                            order by r.rank, r.name), '[]'::jsonb)
    into v_rows
    from (select c.id, c.name, count(*) as votes, rank() over (order by count(*) desc) as rank
            from public.votes v
            join public.notes n on n.id = v.note_id and n.status = 'published'
            join public.campuses c on c.id = n.campus_id
           where v.created_at >= v_since and v.user_id is distinct from n.author_id
           group by c.id, c.name
           order by count(*) desc, c.name
           limit least(greatest(coalesce(p_limit, 25), 1), 100)) r;
  return jsonb_build_object('period', p_period, 'timezone', 'Asia/Jakarta', 'rows', v_rows);
end $$;

create or replace function public.today_pulse() returns jsonb
language sql stable security definer set search_path = '' as $$
  with d as (select date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta' as since)
  select jsonb_build_object(
    'notes', (select count(*) from public.notes n where n.status = 'published' and n.published_at >= d.since),
    'votes', (select count(*) from public.votes v join public.notes n on n.id = v.note_id and n.status = 'published'
               where v.created_at >= d.since and v.user_id is distinct from n.author_id))
  from d
$$;

create or replace function public.my_week() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_since timestamptz := date_trunc('week', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
begin
  if v_uid is null then perform public.app_error('CSW01', 'UNAUTHENTICATED'); end if;
  return jsonb_build_object(
    'notes', (select count(*) from public.notes n where n.author_id = v_uid and n.status = 'published' and n.published_at >= v_since),
    'votes', (select count(*) from public.votes v join public.notes n on n.id = v.note_id and n.status = 'published'
               where n.author_id = v_uid and v.user_id is distinct from v_uid and v.created_at >= v_since),
    'streak', coalesce((select streak_count from public.profiles where id = v_uid), 0));
end $$;

revoke execute on function public.today_pulse(), public.my_week() from public, anon, authenticated;
grant execute on function public.today_pulse(), public.my_week() to service_role;
grant execute on function public.today_pulse() to anon, authenticated;
grant execute on function public.my_week() to authenticated;
