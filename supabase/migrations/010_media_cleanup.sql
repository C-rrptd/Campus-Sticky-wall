-- 010_media_cleanup.sql
-- Builds on 009 (notes.media jsonb, public bucket "note-media", uploads into <user-id>/).
--   1. When a note is removed, rejected, withdrawn, refunded, failed or deleted, its files are
--      queued in media_orphans and detached from the note. Edge Functions delete them from Storage.
--   2. Upload rate limit: at most 20 new files per user per hour (storage policy), so one account
--      cannot fill the bucket.
-- Additive and safe to re-run. A restored note does not get its files back.

create table if not exists public.media_orphans (
  path text primary key check (path ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,100}$'),
  created_at timestamptz not null default now()
);
alter table public.media_orphans enable row level security;
revoke all on public.media_orphans from anon, authenticated;

create or replace function public.note_media_paths(p_media jsonb) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(e ->> 'path'), '{}')
    from jsonb_array_elements(case when jsonb_typeof(p_media) = 'array' then p_media else '[]'::jsonb end) e
   where e ->> 'path' is not null
$$;

create or replace function public.notes_release_media() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    insert into public.media_orphans (path)
    select unnest(public.note_media_paths(old.media)) on conflict do nothing;
    return old;
  end if;
  if new.status in ('removed', 'rejected', 'withdrawn', 'refunded', 'payment_failed')
     and old.status is distinct from new.status and old.media is not null then
    insert into public.media_orphans (path)
    select unnest(public.note_media_paths(old.media)) on conflict do nothing;
    new.media := null;
  end if;
  return new;
end $$;

drop trigger if exists notes_release_media_update on public.notes;
create trigger notes_release_media_update before update of status on public.notes
  for each row execute function public.notes_release_media();
drop trigger if exists notes_release_media_delete on public.notes;
create trigger notes_release_media_delete before delete on public.notes
  for each row execute function public.notes_release_media();

-- Paths for the Edge Function to delete from Storage, then forget once deleted.
create or replace function public.media_take_orphans(p_limit int default 50) returns text[]
language sql security definer set search_path = '' as $$
  select coalesce(array_agg(path), '{}') from (
    select path from public.media_orphans order by created_at limit least(greatest(p_limit, 1), 100)) q
$$;
create or replace function public.media_forget_orphans(p_paths text[]) returns void
language sql security definer set search_path = '' as $$
  delete from public.media_orphans where path = any (p_paths)
$$;

revoke execute on function public.note_media_paths(jsonb), public.notes_release_media(),
  public.media_take_orphans(int), public.media_forget_orphans(text[]) from public, anon, authenticated;
grant execute on function public.note_media_paths(jsonb), public.notes_release_media(),
  public.media_take_orphans(int), public.media_forget_orphans(text[]) to service_role;

-- Upload rate limit (replaces the 009 policy; same folder rule plus the hourly cap).
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage') and to_regclass('storage.objects') is not null then
    drop policy if exists "note media upload own folder" on storage.objects;
    execute $p$create policy "note media upload own folder" on storage.objects for insert to authenticated
      with check (bucket_id = 'note-media'
        and (storage.foldername(name))[1] = (select auth.uid())::text
        and (select count(*) from storage.objects o
              where o.bucket_id = 'note-media'
                and (storage.foldername(o.name))[1] = (select auth.uid())::text
                and o.created_at > now() - interval '1 hour') < 20)$p$;
  end if;
end $$;
