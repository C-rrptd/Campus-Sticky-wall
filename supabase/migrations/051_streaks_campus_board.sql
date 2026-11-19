-- 051: daily visit streak, streak achievements, campus leaderboard. Idempotent. Builds on 050 (notifications).
--   Streak days are Asia/Jakarta calendar days. touch_streak() is called by the signed-in browser once per day; calling it again the same day changes nothing.
--   Reaching 3, 7, 30 or 100 days in a row adds a 'streak' notification (notifications.info holds the day count).
--   Reward = achievements 'streak-7' and 'streak-30' (best streak ever). They plug into the existing decorations.unlock_achievement gate,
--   so a sticker can be made visible-for-purchase only to people who earned it. No free credits are issued.
--   campus_leaderboard(): upvotes received by published notes per campus; a member's vote on their own note does not count.

alter table public.profiles add column if not exists streak_count int not null default 0 check (streak_count >= 0);
alter table public.profiles add column if not exists streak_best int not null default 0 check (streak_best >= 0);
alter table public.profiles add column if not exists last_visit_on date;
alter table public.notifications add column if not exists info int;

create or replace function public.touch_streak() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  p public.profiles;
  v_next int;
begin
  if v_uid is null then perform public.app_error('CSW01', 'UNAUTHENTICATED'); end if;
  select * into p from public.profiles where id = v_uid for update;
  if not found or p.suspended_at is not null then return jsonb_build_object('streak', 0, 'best', 0); end if;
  if p.last_visit_on is distinct from v_today then
    v_next := case when p.last_visit_on = v_today - 1 then p.streak_count + 1 else 1 end;
    update public.profiles set streak_count = v_next, streak_best = greatest(p.streak_best, v_next), last_visit_on = v_today
     where id = v_uid returning * into p;
    if v_next in (3, 7, 30, 100) then
      insert into public.notifications (user_id, kind, info) values (v_uid, 'streak', v_next);
    end if;
  end if;
  return jsonb_build_object('streak', p.streak_count, 'best', p.streak_best);
end $$;

-- 050's list, now also returning streak rows (count comes from info).
create or replace function public.my_notifications(p_limit int default 20) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'unread', public.unread_notification_count(),
    'items', coalesce((
      select jsonb_agg(s.j order by s.updated_at desc)
        from (
          select nt.updated_at, jsonb_build_object(
            'id', nt.id, 'kind', nt.kind, 'read', nt.read_at is not null, 'at', nt.updated_at,
            'count', case when nt.kind = 'upvote' then c.n else nt.info end,
            'note', case when n.status = 'published' then jsonb_build_object('id', n.id, 'snippet', left(n.body, 80)) end) as j
            from public.notifications nt
            left join public.notes n on n.id = nt.note_id
            left join lateral (
              select count(*) as n from public.votes v
               where v.note_id = nt.note_id and v.user_id <> nt.user_id and v.created_at >= nt.created_at and v.created_at < coalesce(nt.read_at, 'infinity')
            ) c on true
           where nt.user_id = auth.uid() and (nt.kind <> 'upvote' or c.n > 0)
           order by nt.updated_at desc
           limit least(greatest(coalesce(p_limit, 20), 1), 50)
        ) s), '[]'::jsonb))
$$;

-- 044's achievements + two streak rows. Same signature and grants.
create or replace function public.achievements_for(p_user uuid, p_public boolean) returns jsonb
language sql stable security definer set search_path = '' as $$
  with s as (
    select (select count(*) from public.notes n where n.author_id = p_user and n.status = 'published' and (not p_public or n.show_profile)) as notes,
           (select coalesce(sum(n.vote_count), 0) from public.notes n where n.author_id = p_user and n.status = 'published' and (not p_public or n.show_profile)) as votes,
           (select count(*) from public.referral_attributions a where a.referrer_id = p_user and a.status = 'qualified') as refs,
           (select coalesce(extract(day from now() - created_at)::int, 0) from public.profiles where id = p_user) as days,
           (select coalesce(streak_best, 0) from public.profiles where id = p_user) as streak
  ), d(ord, id, progress, target) as (
    select 1, 'first-note', notes, 1 from s union all
    select 2, 'notes-10', notes, 10 from s union all
    select 3, 'notes-50', notes, 50 from s union all
    select 4, 'votes-10', votes, 10 from s union all
    select 5, 'votes-100', votes, 100 from s union all
    select 6, 'votes-500', votes, 500 from s union all
    select 7, 'referral-1', refs, 1 from s union all
    select 8, 'referral-5', refs, 5 from s union all
    select 9, 'member-30', days, 30 from s union all
    select 10, 'member-365', days, 365 from s union all
    select 11, 'streak-7', streak, 7 from s union all
    select 12, 'streak-30', streak, 30 from s
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'progress', least(progress, target), 'target', target,
                            'earned', progress >= target) order by ord), '[]'::jsonb) from d
$$;

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
  select coalesce(jsonb_agg(jsonb_build_object('rank', r.rank, 'display_name', r.name, 'value', r.votes::text, 'is_me', false)
                            order by r.rank, r.name), '[]'::jsonb)
    into v_rows
    from (select c.name, count(*) as votes, rank() over (order by count(*) desc) as rank
            from public.votes v
            join public.notes n on n.id = v.note_id and n.status = 'published'
            join public.campuses c on c.id = n.campus_id
           where v.created_at >= v_since and v.user_id is distinct from n.author_id
           group by c.id, c.name
           order by count(*) desc, c.name
           limit least(greatest(coalesce(p_limit, 25), 1), 100)) r;
  return jsonb_build_object('period', p_period, 'timezone', 'Asia/Jakarta', 'rows', v_rows);
end $$;

revoke execute on function public.touch_streak(), public.campus_leaderboard(text, int) from public, anon, authenticated;
grant execute on function public.touch_streak(), public.campus_leaderboard(text, int) to service_role;
grant execute on function public.touch_streak() to authenticated;
grant execute on function public.campus_leaderboard(text, int) to anon, authenticated;
