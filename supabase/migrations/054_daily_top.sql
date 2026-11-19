-- 054: "top note today" for the wall banner. Idempotent. Builds on 052 (votes_created_at_idx).
--   daily_top(campus): the most upvoted published note of today and of yesterday (Asia/Jakarta days), site-wide or for one campus.
--   Same counting rule as campus_leaderboard: upvotes cast that day, a member's vote on their own note does not count.
--   Ties go to the older note. A day with no upvotes has no top note (null). Returns only id, a short snippet and the count.

create or replace function public.top_note_between(p_from timestamptz, p_to timestamptz, p_campus uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', x.id, 'snippet', left(x.body, 100), 'votes', x.votes)
    from (select n.id, n.body, count(*) as votes
            from public.votes v join public.notes n on n.id = v.note_id and n.status = 'published'
           where v.created_at >= p_from and v.created_at < p_to and v.user_id is distinct from n.author_id
             and (p_campus is null or n.campus_id = p_campus)
           group by n.id, n.body, n.published_at
           order by count(*) desc, n.published_at, n.id limit 1) x
$$;

create or replace function public.daily_top(p_campus uuid default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  with d as (select date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta' as t)
  select jsonb_build_object(
    'today', public.top_note_between(d.t, d.t + interval '1 day', p_campus),
    'yesterday', public.top_note_between(d.t - interval '1 day', d.t, p_campus))
  from d
$$;

revoke execute on function public.top_note_between(timestamptz, timestamptz, uuid), public.daily_top(uuid) from public, anon, authenticated;
grant execute on function public.top_note_between(timestamptz, timestamptz, uuid), public.daily_top(uuid) to service_role;
grant execute on function public.daily_top(uuid) to anon, authenticated;
