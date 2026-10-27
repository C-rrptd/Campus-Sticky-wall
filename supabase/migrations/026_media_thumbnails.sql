-- 026: optional wall thumbnails for note images (idempotent).
-- The first image of a note may have a companion "<name>-t.webp" in the same folder (uploaded by the browser,
-- moved with the file by create-publication). notes.media is unchanged: the companion is derived from the path.
--  1. note_media_paths also returns the companion of every image, so removing a note queues it for deletion
--     and burn_media_owner clears its uploader link too.
--  2. media_sweep_stale_uploads leaves a companion alone while a note still references its image.
--  3. Upload cap per user per hour 20 -> 25 (4 files + 1 thumbnail = 5 objects per note, as before: 5 notes/h).

create or replace function public.note_media_paths(p_media jsonb) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(q.p), '{}') from (
    select e ->> 'path' as p
      from jsonb_array_elements(case when jsonb_typeof(p_media) = 'array' then p_media else '[]'::jsonb end) e
     where e ->> 'path' is not null
    union all
    select regexp_replace(e ->> 'path', '\.[A-Za-z0-9]+$', '-t.webp')
      from jsonb_array_elements(case when jsonb_typeof(p_media) = 'array' then p_media else '[]'::jsonb end) e
     where e ->> 'kind' = 'image' and e ->> 'path' ~ '\.[A-Za-z0-9]+$'
  ) q
$$;

create or replace function public.media_sweep_stale_uploads() returns int
language plpgsql security definer set search_path = '' as $$
declare v_n int := 0;
begin
  if to_regclass('storage.objects') is null then return 0; end if;
  execute $q$
    insert into public.media_orphans (path)
    select o.name from storage.objects o
     where o.bucket_id = 'note-media'
       and o.created_at < now() - interval '24 hours'
       and o.name ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,100}$'
       and not exists (select 1 from public.notes n
                        where n.media @> jsonb_build_array(jsonb_build_object('path', o.name)))
       and not (o.name ~ '-t[.]webp$' and exists (
             select 1 from unnest(array[left(o.name, -7) || '.jpg', left(o.name, -7) || '.png', left(o.name, -7) || '.webp']) c
               join public.notes n on n.media @> jsonb_build_array(jsonb_build_object('path', c))))
     order by o.created_at limit 500
    on conflict do nothing$q$;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke execute on function public.note_media_paths(jsonb), public.media_sweep_stale_uploads() from public, anon, authenticated;
grant execute on function public.note_media_paths(jsonb), public.media_sweep_stale_uploads() to service_role;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage') and to_regclass('storage.objects') is not null then
    drop policy if exists "note media upload own folder" on storage.objects;
    execute $p$create policy "note media upload own folder" on storage.objects for insert to authenticated
      with check (bucket_id = 'note-media'
        and (storage.foldername(name))[1] = (select auth.uid())::text
        and (select count(*) from storage.objects o
              where o.bucket_id = 'note-media'
                and (storage.foldername(o.name))[1] = (select auth.uid())::text
                and o.created_at > now() - interval '1 hour') < 25)$p$;
  end if;
end $$;
