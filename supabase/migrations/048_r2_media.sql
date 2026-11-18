-- 048 — Note attachments can live in Cloudflare R2. Items stay {path, kind}; R2 items also carry "s":"r2".
-- Older notes keep working from Supabase Storage. Idempotent.

create or replace function public.validate_note_media(p_media jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare v_item jsonb; v_out jsonb := '[]'::jsonb;
begin
  if p_media is null or p_media = 'null'::jsonb or p_media = '[]'::jsonb then return null; end if;
  if jsonb_typeof(p_media) <> 'array' or jsonb_array_length(p_media) > 4 then
    perform public.app_error('CSW40', 'INVALID_MEDIA', 'Attach at most 4 files.');
  end if;
  for v_item in select * from jsonb_array_elements(p_media) loop
    if jsonb_typeof(v_item) <> 'object'
       or coalesce(v_item ->> 'kind', '') not in ('image', 'video')
       or coalesce(v_item ->> 'path', '') !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,100}$'
       or coalesce(v_item ->> 's', 'sb') not in ('sb', 'r2') then
      perform public.app_error('CSW40', 'INVALID_MEDIA', 'Invalid media attachment.');
    end if;
    v_out := v_out || jsonb_build_array(
      jsonb_build_object('path', v_item ->> 'path', 'kind', v_item ->> 'kind')
      || case when v_item ->> 's' = 'r2' then jsonb_build_object('s', 'r2') else '{}'::jsonb end);
  end loop;
  return v_out;
end $$;

-- Cleanup queue: R2 files are queued as "r2:<path>" (the purge job deletes their thumbnail too); Supabase files keep
-- the 026 behaviour (the file plus its "-t.webp" thumbnail for images).
create or replace function public.note_media_paths(p_media jsonb) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(q.p), '{}') from (
    select case when e ->> 's' = 'r2' then 'r2:' || (e ->> 'path') else e ->> 'path' end as p
      from jsonb_array_elements(case when jsonb_typeof(p_media) = 'array' then p_media else '[]'::jsonb end) e
     where e ->> 'path' is not null
    union all
    select regexp_replace(e ->> 'path', '\.[A-Za-z0-9]+$', '-t.webp')
      from jsonb_array_elements(case when jsonb_typeof(p_media) = 'array' then p_media else '[]'::jsonb end) e
     where e ->> 'kind' = 'image' and coalesce(e ->> 's', 'sb') <> 'r2'
       and e ->> 'path' ~ '\.[A-Za-z0-9]+$' and e ->> 'path' !~* '\.gif$'
  ) q
$$;
