-- 055: "your note reached N upvotes" notification. Idempotent. Builds on 050/051 (notifications, notifications.info).
--   When a published note's upvotes (the author's own vote never counts) reach 10, 50 or 100, its author gets one 'milestone' row (info = N).
--   A milestone that was already reached never fires again, even after unvote/re-vote (any existing row with info >= N blocks it).
--   my_notifications (051) already returns info as `count` and the note snippet for note rows, so nothing else changes. No new table, no new column.

create or replace function public.notify_milestone() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_author uuid; v_n int;
begin
  select author_id into v_author from public.notes where id = new.note_id and status = 'published';
  if v_author is null or v_author = new.user_id or public.is_suspended(v_author) then return null; end if;
  select count(*) into v_n from public.votes where note_id = new.note_id and user_id <> v_author;
  if v_n in (10, 50, 100) and not exists (
    select 1 from public.notifications where user_id = v_author and kind = 'milestone' and note_id = new.note_id and info >= v_n) then
    insert into public.notifications (user_id, kind, note_id, info) values (v_author, 'milestone', new.note_id, v_n)
    on conflict (user_id, kind, note_id) where read_at is null do update set info = excluded.info, updated_at = now();
  end if;
  return null;
end $$;
drop trigger if exists votes_milestone on public.votes;
create trigger votes_milestone after insert on public.votes
  for each row execute function public.notify_milestone();

revoke execute on function public.notify_milestone() from public, anon, authenticated;
grant execute on function public.notify_milestone() to service_role;
