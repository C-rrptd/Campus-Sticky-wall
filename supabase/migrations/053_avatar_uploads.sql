-- 053: profile pictures are uploaded files, not links. Idempotent. Builds on 001 (profiles) and the storage pattern of 009.
--   profiles.avatar_url now holds a storage path "<user-id>/<uuid>.<jpg|png|webp|gif>" in the public `avatars` bucket (the column keeps its
--   name so note_json / get_public_profile need no change; the browser builds the URL, see avatarUrl() in supabase-client.js).
--   Old external links were never shown anywhere; they are cleared. A path is only accepted inside the member's own folder.
--   The bucket itself caps files at 1 MB and allows image types only. Browsers shrink JPG/PNG/WebP to 256 px before upload; GIFs are
--   passed through unchanged (an animated GIF cannot be re-drawn on a canvas), which is why the cap is small.

alter table public.profiles drop constraint if exists profiles_avatar_url_check;
update public.profiles set avatar_url = null where avatar_url is not null and avatar_url !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp|gif)$';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_avatar_path_check') then
    alter table public.profiles add constraint profiles_avatar_path_check
      check (avatar_url is null or avatar_url ~ ('^' || id::text || '/[0-9a-f-]{36}\.(jpg|png|webp|gif)$'));
  end if;
end $$;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage') and to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('avatars', 'avatars', true, 1048576, array['image/jpeg','image/png','image/webp','image/gif'])
    on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
    drop policy if exists "avatar upload own folder" on storage.objects;
    drop policy if exists "avatar delete own file" on storage.objects;
    drop policy if exists "avatar read" on storage.objects;
    -- Own folder only, at most 10 new files an hour (changing a picture is rare; this stops a loop filling the bucket).
    execute $p$create policy "avatar upload own folder" on storage.objects for insert to authenticated
      with check (bucket_id = 'avatars'
        and (storage.foldername(name))[1] = (select auth.uid())::text
        and (select count(*) from storage.objects o
              where o.bucket_id = 'avatars' and (storage.foldername(o.name))[1] = (select auth.uid())::text
                and o.created_at > now() - interval '1 hour') < 10)$p$;
    execute $p$create policy "avatar delete own file" on storage.objects for delete to authenticated
      using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)$p$;
    execute $p$create policy "avatar read" on storage.objects for select to anon, authenticated
      using (bucket_id = 'avatars')$p$;
  end if;
end $$;
