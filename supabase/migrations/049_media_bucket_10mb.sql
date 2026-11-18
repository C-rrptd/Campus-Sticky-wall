-- 049: note-media bucket ceiling 10 MB (was 25 MB). Client caps video at 10 MB and images/GIFs at 5 MB; this stops hand-made uploads filling the free 1 GB quota.
-- Existing files are untouched. Safe to re-run.
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage') and to_regclass('storage.buckets') is not null then
    update storage.buckets set file_size_limit = 10485760 where id = 'note-media';
  end if;
end $$;
