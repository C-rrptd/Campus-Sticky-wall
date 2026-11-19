-- 050: in-app notifications (header bell). Idempotent.
--   public.notifications is written only by triggers; clients have no table access and use three functions:
--   my_notifications(limit), unread_notification_count(), mark_notifications_read(ids).
--   'upvote': one unread row per (author, note). More votes bump updated_at; the count is computed live from votes
--   inside the row's window (created_at .. read_at), never counting the author's own vote, so vote/unvote toggling cannot inflate it and a voter is never exposed.
--   Own votes, guest notes (no author_id), unpublished notes and suspended authors never notify.
--   kind is open (^[a-z_]+$) so streaks, achievements and news can reuse the table later.
--   Read rows older than 30 days are deleted whenever that member marks something read.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind ~ '^[a-z_]{2,30}$'),
  note_id uuid references public.notes (id) on delete cascade,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.notifications enable row level security;
revoke all on public.notifications from anon, authenticated;

create unique index if not exists notifications_open_uq on public.notifications (user_id, kind, note_id) where read_at is null;
create index if not exists notifications_user_idx on public.notifications (user_id, updated_at desc);

create or replace function public.notify_upvote() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_author uuid;
begin
  select author_id into v_author from public.notes where id = new.note_id and status = 'published';
  if v_author is null or v_author = new.user_id or public.is_suspended(v_author) then return null; end if;
  insert into public.notifications (user_id, kind, note_id) values (v_author, 'upvote', new.note_id)
  on conflict (user_id, kind, note_id) where read_at is null do update set updated_at = now();
  return null;
end $$;
drop trigger if exists votes_notify on public.votes;
create trigger votes_notify after insert on public.votes
  for each row execute function public.notify_upvote();

-- An upvote row counts only while at least one vote in its window is still there.
create or replace function public.unread_notification_count() returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications nt
   where nt.user_id = auth.uid() and nt.read_at is null
     and (nt.kind <> 'upvote' or exists (select 1 from public.votes v where v.note_id = nt.note_id and v.user_id <> nt.user_id and v.created_at >= nt.created_at))
$$;

create or replace function public.my_notifications(p_limit int default 20) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'unread', public.unread_notification_count(),
    'items', coalesce((
      select jsonb_agg(s.j order by s.updated_at desc)
        from (
          select nt.updated_at, jsonb_build_object(
            'id', nt.id, 'kind', nt.kind, 'read', nt.read_at is not null, 'at', nt.updated_at,
            'count', case when nt.kind = 'upvote' then c.n end,
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

-- p_ids null = everything unread. The browser passes the ids it showed, so a notification that arrives while the list is open stays unread.
create or replace function public.mark_notifications_read(p_ids uuid[] default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then perform public.app_error('CSW01', 'UNAUTHENTICATED'); end if;
  update public.notifications set read_at = now()
   where user_id = auth.uid() and read_at is null and (p_ids is null or id = any (p_ids));
  delete from public.notifications where user_id = auth.uid() and read_at < now() - interval '30 days';
end $$;

revoke execute on function public.notify_upvote(), public.unread_notification_count(), public.my_notifications(int),
  public.mark_notifications_read(uuid[]) from public, anon, authenticated;
grant execute on function public.notify_upvote(), public.unread_notification_count(), public.my_notifications(int),
  public.mark_notifications_read(uuid[]) to service_role;
grant execute on function public.unread_notification_count(), public.my_notifications(int),
  public.mark_notifications_read(uuid[]) to authenticated;
