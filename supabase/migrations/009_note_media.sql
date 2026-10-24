-- 009: image / video / gif attachments on notes.
-- Files live in the public `note-media` bucket under <user-id>/<file>; the note stores only
-- [{"path": "<user-id>/<file>", "kind": "image|video"}] (max 4). Frontend builds the public URL.
-- Idempotent: safe to re-apply.

alter table public.notes add column if not exists media jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'notes_media_is_array') then
    alter table public.notes add constraint notes_media_is_array
      check (media is null or (jsonb_typeof(media) = 'array' and jsonb_array_length(media) <= 4));
  end if;
end $$;

-- Returns a clean array or null; raises on anything malformed (trust boundary).
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
       or coalesce(v_item ->> 'path', '') !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,100}$' then
      perform public.app_error('CSW40', 'INVALID_MEDIA', 'Invalid media attachment.');
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('path', v_item ->> 'path', 'kind', v_item ->> 'kind'));
  end loop;
  return v_out;
end $$;

-- New trailing parameter changes the signature: drop the old ones so named-arg calls stay unambiguous.
drop function if exists public.create_publication_order_credits(uuid, text, text, text, text, boolean, text, text[], text, uuid, boolean, int);
drop function if exists public.create_publication_order(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid);

create or replace FUNCTION public.create_publication_order(p_user_id uuid, p_author_name text, p_body text, p_color text, p_social_link text, p_show_amount boolean, p_amount text, p_decorations text[], p_use_credit boolean, p_guest_token_hash text, p_campus_id uuid DEFAULT NULL::uuid, p_media jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  v_quote jsonb;
  v_media jsonb := public.validate_note_media(p_media);
  v_order_id uuid;
  v_note_id uuid;
  v_ttl int := coalesce((public.config_value('unpaid_order_ttl_minutes') #>> '{}')::int, 120);
  v_name text := btrim(coalesce(p_author_name, ''));
  v_body text := btrim(coalesce(p_body, ''));
  v_link text := nullif(btrim(coalesce(p_social_link, '')), '');
  r record;
begin
  if p_user_id is not null and public.is_suspended(p_user_id) then
    perform public.app_error('CSW03', 'ACCOUNT_SUSPENDED', 'This account is suspended.');
  end if;
  if p_use_credit and p_user_id is null then
    perform public.app_error('CSW03', 'CREDIT_REQUIRES_ACCOUNT', 'Sign in to use a referral credit.');
  end if;
  if char_length(v_name) not between 1 and 40 or public.has_control_chars(v_name) or v_name ~ '[\n\r\t]' then
    perform public.app_error('CSW40', 'INVALID_AUTHOR_NAME', 'Author name must be 1-40 characters.');
  end if;
  if char_length(v_body) not between 1 and 500 or public.has_control_chars(v_body) then
    perform public.app_error('CSW40', 'INVALID_NOTE_TEXT', 'Note text must be 1-500 characters.');
  end if;
  if coalesce(p_color, '') not in ('yellow','pink','blue','green','orange','purple') then
    perform public.app_error('CSW40', 'INVALID_COLOR', 'Choose one of the available note colours.');
  end if;
  if v_link is not null and not public.is_allowed_social_url(v_link) then
    perform public.app_error('CSW40', 'INVALID_SOCIAL_LINK', 'Social links must be https URLs on supported platforms.');
  end if;
  if p_guest_token_hash is null or p_guest_token_hash !~ '^[0-9a-f]{64}$' then
    perform public.app_error('CSW40', 'INVALID_ACCESS_TOKEN');
  end if;
  if p_campus_id is not null and not exists (select 1 from public.campuses c where c.id = p_campus_id and c.enabled) then
    perform public.app_error('CSW40', 'INVALID_CAMPUS', 'Unknown campus.');
  end if;

  v_quote := public.quote_publication(p_amount, coalesce(p_decorations, '{}'), false);

  insert into public.orders (order_ref, kind, user_id, publication_amount, decorations_amount,
                             subtotal_amount, discount_amount, total_amount, snapshot, guest_token_hash, expires_at)
  values (public.new_order_ref('publication'), 'publication', p_user_id,
          (v_quote->>'publication_amount')::bigint, (v_quote->>'decorations_amount')::bigint,
          (v_quote->>'subtotal_amount')::bigint, 0, (v_quote->>'subtotal_amount')::bigint,
          jsonb_build_object('min_publication_price', public.min_publication_price()::text,
                             'publication_amount', v_quote->>'publication_amount',
                             'decorations', v_quote->'decorations',
                             'decorations_amount', v_quote->>'decorations_amount',
                             'credit_discount', '0',
                             'total_amount', v_quote->>'subtotal_amount',
                             'priced_at', now()),
          p_guest_token_hash, now() + make_interval(mins => v_ttl))
  returning id into v_order_id;

  insert into public.order_items (order_id, item_type, item_ref, name, unit_amount)
  values (v_order_id, 'publication', null, 'Sticky note publication', (v_quote->>'publication_amount')::bigint);
  for r in select * from jsonb_to_recordset(v_quote->'decorations') as x(id text, name text, price text) loop
    insert into public.order_items (order_id, item_type, item_ref, name, unit_amount)
    values (v_order_id, 'decoration', r.id, left(r.name, 50), r.price::bigint);
  end loop;

  insert into public.notes (order_id, author_id, author_name, body, color, social_link, show_amount,
                            publication_amount, campus_id, media)
  values (v_order_id, p_user_id, v_name, v_body, p_color, v_link, coalesce(p_show_amount, true),
          (v_quote->>'publication_amount')::bigint, p_campus_id, v_media)
  returning id into v_note_id;
  insert into public.note_decorations (note_id, decoration_id)
  select v_note_id, unnest(coalesce(p_decorations, '{}'));

  if p_use_credit then
    perform public.attach_credit(v_order_id, p_user_id);
  end if;

  if (select total_amount from public.orders where id = v_order_id) = 0 then
    perform public.complete_free_order(v_order_id);
  else
    perform public.require_payable_total((select total_amount from public.orders where id = v_order_id));
  end if;

  return public.order_summary(v_order_id);
end $$;

create or replace function public.create_publication_order_credits(
  p_user_id uuid, p_author_name text, p_body text, p_color text, p_social_link text, p_show_amount boolean,
  p_amount text, p_decorations text[], p_guest_token_hash text, p_campus_id uuid,
  p_use_post_credit boolean, p_deco_credits int, p_media jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_order jsonb; v_id uuid;
begin
  if p_user_id is null then
    perform public.app_error('CSW03', 'ACCOUNT_REQUIRED', 'Sign in to use referral credits.');
  end if;
  v_order := public.create_publication_order(p_user_id, p_author_name, p_body, p_color, p_social_link, p_show_amount,
                                             p_amount, p_decorations, false, p_guest_token_hash, p_campus_id, p_media);
  select id into v_id from public.orders where order_ref = v_order ->> 'order_ref';
  perform public.apply_referral_credits(v_id, p_user_id, p_use_post_credit, p_deco_credits);
  return public.order_summary(v_id);
end $$;

create or replace FUNCTION public.note_json(n notes, p_viewer uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
  select jsonb_build_object(
    'id', n.id, 'author_name', n.author_name, 'body', n.body, 'color', n.color,
    'social_link', n.social_link,
    'amount', case when n.show_amount then n.publication_amount::text end,
    'vote_count', n.vote_count, 'published_at', n.published_at, 'campus_id', n.campus_id, 'media', n.media,
    'decorations', coalesce((select jsonb_agg(d.decoration_id order by d.decoration_id)
                             from public.note_decorations d where d.note_id = n.id), '[]'::jsonb),
    'voted', p_viewer is not null and exists (select 1 from public.votes v where v.note_id = n.id and v.user_id = p_viewer),
    'bookmarked', p_viewer is not null and exists (select 1 from public.bookmarks b where b.note_id = n.id and b.user_id = p_viewer),
    'is_mine', p_viewer is not null and n.author_id = p_viewer)
$$;

-- admin_list_notes returns jsonb: new key, same signature.
create or replace FUNCTION public.admin_list_notes(p_status text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select n.id, n.author_name, n.body, n.color, n.status, n.publication_amount::text as amount, n.vote_count,
           n.report_count, n.created_at, n.published_at, n.media, n.moderation_reason, o.order_ref, o.status as order_status
      from public.notes n join public.orders o on o.id = n.order_id
     where (p_status is null or n.status = p_status)
     order by n.created_at desc
     limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) x), '[]'::jsonb);
end $$;

revoke execute on function
  public.validate_note_media(jsonb),
  public.create_publication_order(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid, jsonb),
  public.create_publication_order_credits(uuid, text, text, text, text, boolean, text, text[], text, uuid, boolean, int, jsonb)
  from public, anon, authenticated;
grant execute on function
  public.validate_note_media(jsonb),
  public.create_publication_order(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid, jsonb),
  public.create_publication_order_credits(uuid, text, text, text, text, boolean, text, text[], text, uuid, boolean, int, jsonb)
  to service_role;

-- Storage: public-read bucket, upload only into your own folder (same pattern as campaign-creatives in 005).
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'storage' and c.relname = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('note-media', 'note-media', true, 26214400,
            array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm'])
    on conflict (id) do nothing;
    drop policy if exists "note media upload own folder" on storage.objects;
    drop policy if exists "note media read" on storage.objects;
    execute $p$create policy "note media upload own folder" on storage.objects for insert to authenticated
      with check (bucket_id = 'note-media' and (storage.foldername(name))[1] = (select auth.uid())::text)$p$;
    execute $p$create policy "note media read" on storage.objects for select to anon, authenticated
      using (bucket_id = 'note-media')$p$;
  end if;
end $$;
