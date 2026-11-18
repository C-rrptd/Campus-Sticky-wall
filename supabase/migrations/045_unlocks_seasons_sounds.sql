-- 045: achievement-locked decorations, seasonal windows, animated decorations, paid upvote sounds. Idempotent.
--   unlock_achievement: only members who earned that achievement (see achievements_for) may buy it.
--   available_from/until: hidden from clients (RLS) and refused by the order function outside the window.
--   Sounds are decorations in category 'Sounds' (id snd-<12 hex>, mp3 in the sound-effects bucket, at most 5 s),
--   so price, credits, order items and refunds reuse the decoration pipeline. A note may carry one sound;
--   it plays for a member who upvotes the note (the client cuts playback at 5 s whatever the file says).

alter table public.decorations add column if not exists unlock_achievement text
  check (unlock_achievement is null or unlock_achievement ~ '^[a-z0-9-]{2,30}$');
alter table public.decorations add column if not exists available_from timestamptz;
alter table public.decorations add column if not exists available_until timestamptz;

drop policy if exists decorations_public_read on public.decorations;
create policy decorations_public_read on public.decorations for select to anon, authenticated
  using (enabled and (available_from is null or available_from <= now()) and (available_until is null or available_until > now()));

-- Server-side gate for window, unlock and one-sound-per-note. Called by the order function below.
create or replace function public.check_decorations_allowed(p_user uuid, p_decos text[]) returns void
language plpgsql stable security definer set search_path = '' as $$
declare
  d record;
  v_earned jsonb;
begin
  if (select count(*) from public.decorations where id = any (p_decos) and category = 'Sounds') > 1 then
    perform public.app_error('CSW40', 'TOO_MANY_SOUNDS', 'A note can have only one sound.');
  end if;
  for d in select id, unlock_achievement, available_from, available_until from public.decorations where id = any (p_decos) loop
    if (d.available_from is not null and now() < d.available_from) or (d.available_until is not null and now() >= d.available_until) then
      perform public.app_error('CSW40', 'DECORATION_UNAVAILABLE', 'That decoration is not available right now.');
    end if;
    if d.unlock_achievement is not null then
      if p_user is null then perform public.app_error('CSW40', 'DECORATION_LOCKED', 'Sign in and earn this decoration first.'); end if;
      v_earned := coalesce(v_earned, public.achievements_for(p_user, false));
      if not exists (select 1 from jsonb_array_elements(v_earned) a where a ->> 'id' = d.unlock_achievement and (a ->> 'earned')::boolean) then
        perform public.app_error('CSW40', 'DECORATION_LOCKED', 'Earn the achievement to unlock this decoration.');
      end if;
    end if;
  end loop;
end $$;
revoke execute on function public.check_decorations_allowed(uuid, text[]) from public, anon, authenticated;
grant execute on function public.check_decorations_allowed(uuid, text[]) to service_role;

create or replace function public.create_publication_order_v4(
  p_user_id uuid, p_author_name text, p_body text, p_color text, p_social_link text, p_show_amount boolean,
  p_amount text, p_decorations text[], p_use_credit boolean, p_guest_token_hash text, p_campus_id uuid,
  p_media jsonb, p_use_post_credit boolean, p_deco_credits int, p_positions jsonb,
  p_promo text, p_use_free_post boolean, p_confirmed boolean,
  p_poll jsonb, p_spotify text, p_show_profile boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_name text;
  v jsonb;
begin
  perform public.check_decorations_allowed(p_user_id, p_decorations);
  if not coalesce(p_show_profile, false) then
    return public.create_publication_order_v3(p_user_id, p_author_name, p_body, p_color, p_social_link, p_show_amount,
      p_amount, p_decorations, p_use_credit, p_guest_token_hash, p_campus_id, p_media, p_use_post_credit, p_deco_credits,
      p_positions, p_promo, p_use_free_post, p_confirmed, p_poll, p_spotify);
  end if;
  if p_user_id is null then
    perform public.app_error('CSW40', 'PROFILE_NEEDS_ACCOUNT', 'Sign in to put your profile on a note.');
  end if;
  select display_name into v_name from public.profiles where id = p_user_id and suspended_at is null;
  if v_name is null then
    perform public.app_error('CSW40', 'PROFILE_NEEDS_ACCOUNT', 'Your profile is not available.');
  end if;
  v := public.create_publication_order_v3(p_user_id, 'Anonymous', p_body, p_color, p_social_link, p_show_amount,
    p_amount, p_decorations, p_use_credit, p_guest_token_hash, p_campus_id, p_media, p_use_post_credit, p_deco_credits,
    p_positions, p_promo, p_use_free_post, p_confirmed, p_poll, p_spotify);
  update public.notes set show_profile = true, author_name = v_name
   where order_id = (select id from public.orders where order_ref = v ->> 'order_ref');
  return v;
end $$;

-- Admin decoration editor gains the window and the unlock. New signature replaces the old one.
drop function if exists public.admin_upsert_decoration(text, text, text, text, boolean, int);
create or replace function public.admin_upsert_decoration(p_id text, p_name text, p_description text,
  p_price text, p_enabled boolean, p_sort int default 0,
  p_available_from timestamptz default null, p_available_until timestamptz default null, p_unlock text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_price bigint := public.parse_amount(p_price);
begin
  perform public.require_admin();
  insert into public.decorations (id, name, description, price, enabled, sort_order, render, available_from, available_until, unlock_achievement)
  values (p_id, p_name, p_description, v_price, coalesce(p_enabled, true), coalesce(p_sort, 0),
          jsonb_build_object('class', 'deco-' || p_id), p_available_from, p_available_until, nullif(p_unlock, ''))
  on conflict (id) do update set name = excluded.name, description = excluded.description, price = excluded.price,
          enabled = excluded.enabled, sort_order = excluded.sort_order, available_from = excluded.available_from,
          available_until = excluded.available_until, unlock_achievement = excluded.unlock_achievement;
  perform public.audit('decoration.upsert', 'decoration', p_id, null, jsonb_build_object('price', v_price::text, 'enabled', p_enabled));
  return (select to_jsonb(d) || jsonb_build_object('price', d.price::text) from public.decorations d where d.id = p_id);
end $$;
revoke execute on function public.admin_upsert_decoration(text, text, text, text, boolean, int, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.admin_upsert_decoration(text, text, text, text, boolean, int, timestamptz, timestamptz, text) to authenticated, service_role;

-- Admin adds a sound after uploading sound-effects/<id>.mp3. Duration is declared by the admin's browser and capped here.
create or replace function public.admin_add_sound(p_id text, p_name text, p_price text, p_duration_ms int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_price bigint := public.parse_amount(p_price);
begin
  perform public.require_admin();
  if p_id !~ '^snd-[0-9a-f]{12}$' then perform public.app_error('CSW40', 'INVALID_SOUND_ID'); end if;
  if length(trim(p_name)) not between 2 and 50 then perform public.app_error('CSW40', 'INVALID_NAME'); end if;
  if p_duration_ms is null or p_duration_ms not between 200 and 5000 then
    perform public.app_error('CSW40', 'SOUND_TOO_LONG', 'A sound can be 5 seconds at most.');
  end if;
  insert into public.decorations (id, name, description, price, enabled, sort_order, render, category, placeable)
  values (p_id, trim(p_name), 'Plays when someone upvotes the note', v_price, true, 950,
          jsonb_build_object('class', 'deco-' || p_id, 'duration_ms', p_duration_ms), 'Sounds', false);
  perform public.audit('sound.add', 'decoration', p_id, null, jsonb_build_object('price', v_price::text, 'duration_ms', p_duration_ms));
  return jsonb_build_object('id', p_id);
end $$;
revoke execute on function public.admin_add_sound(text, text, text, int) from public, anon;
grant execute on function public.admin_add_sound(text, text, text, int) to authenticated;

-- Storage: public-read bucket, admin-only upload/delete, "snd-<12 hex>.mp3" only, 160 KB max.
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'storage' and c.relname = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('sound-effects', 'sound-effects', true, 163840, array['audio/mpeg'])
    on conflict (id) do nothing;
    drop policy if exists "sound effects admin upload" on storage.objects;
    drop policy if exists "sound effects read" on storage.objects;
    drop policy if exists "sound effects admin delete" on storage.objects;
    execute $p$create policy "sound effects admin upload" on storage.objects for insert to authenticated
      with check (bucket_id = 'sound-effects' and name ~ '^snd-[0-9a-f]{12}\.mp3$' and public.is_admin((select auth.uid())))$p$;
    execute $p$create policy "sound effects read" on storage.objects for select to anon, authenticated
      using (bucket_id = 'sound-effects')$p$;
    execute $p$create policy "sound effects admin delete" on storage.objects for delete to authenticated
      using (bucket_id = 'sound-effects' and public.is_admin((select auth.uid())))$p$;
  end if;
end $$;

insert into public.decorations (id, name, description, price, sort_order, render, category, placeable, default_x, default_y,
                                unlock_achievement, available_from, available_until) values
  ('frame-gold', 'Gold frame', 'Unlocked at 100 votes', 0, 201, '{"class": "deco-frame-gold"}'::jsonb, 'Frames', false, null, null, 'votes-100', null, null),
  ('sticker-crown', 'Crown', 'Unlocked at 500 votes', 0, 202, '{"class": "deco-sticker-crown"}'::jsonb, 'Stickers', true, 50, 10, 'votes-500', null, null),
  ('badge-wall-legend', 'Wall legend badge', 'Unlocked at 50 notes', 0, 203, '{"class": "deco-badge-wall-legend"}'::jsonb, 'Stamps & badges', true, 12, 12, 'notes-50', null, null),
  ('badge-og', 'OG member badge', 'Unlocked after one year', 0, 204, '{"class": "deco-badge-og"}'::jsonb, 'Stamps & badges', true, 88, 12, 'member-365', null, null),
  ('season-newyear', 'New Year glow', 'Gold sparks, until 8 Jan', 1000, 205, '{"class": "deco-season-newyear"}'::jsonb, 'Seasonal', false, null, null, null, '2026-12-20 00:00+07', '2027-01-09 00:00+07'),
  ('sticker-fireworks', 'Fireworks', 'Pop, until 8 Jan', 1000, 206, '{"class": "deco-sticker-fireworks"}'::jsonb, 'Seasonal', true, 88, 12, null, '2026-12-20 00:00+07', '2027-01-09 00:00+07'),
  ('anim-rainbow-frame', 'Rainbow frame', 'A frame that cycles colours', 3000, 207, '{"class": "deco-anim-rainbow-frame"}'::jsonb, 'Animated', false, null, null, null, null, null),
  ('anim-shimmer', 'Shimmer', 'A light sweeps across the note', 3000, 208, '{"class": "deco-anim-shimmer"}'::jsonb, 'Animated', false, null, null, null, null, null),
  ('anim-glow-pulse', 'Glow pulse', 'A gold glow that breathes', 3000, 209, '{"class": "deco-anim-glow-pulse"}'::jsonb, 'Animated', false, null, null, null, null, null),
  ('anim-star-twinkle', 'Twinkling star', 'A star that twinkles', 2000, 210, '{"class": "deco-anim-star-twinkle"}'::jsonb, 'Animated', true, 88, 12, null, null, null),
  ('anim-heart-beat', 'Heartbeat', 'A beating heart', 2000, 211, '{"class": "deco-anim-heart-beat"}'::jsonb, 'Animated', true, 12, 12, null, null, null),
  ('anim-ball-bounce', 'Bouncing ball', 'Bounce bounce', 2000, 212, '{"class": "deco-anim-ball-bounce"}'::jsonb, 'Animated', true, 88, 84, null, null, null),
  ('anim-record-spin', 'Spinning record', 'Spin it', 2000, 213, '{"class": "deco-anim-record-spin"}'::jsonb, 'Animated', true, 12, 84, null, null, null)
on conflict (id) do nothing;
