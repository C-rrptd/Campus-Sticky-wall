-- 044: "Put my profile on the post", public profile page, achievements, 28 more decorations. Idempotent.
--   1. notes.show_profile (opt-in, per note, default false). Not column-readable by clients; only note_json exposes it.
--      A note without it stays exactly as private as before (author_id is never exposed).
--   2. note_json gains 'profile' {id, name, avatar_url} for linked notes of unsuspended members.
--   3. create_publication_order_v4 = v3 + p_show_profile. A linked note takes the member's display name
--      (the registered-name rule exists to stop impersonation, and this IS the member).
--   4. set_note_profile(note, show): the author can link or unlink later. Unlinking resets the name to Anonymous.
--   5. achievements_for(user, public_only): computed live from existing data, nothing stored.
--      public_only counts only profile-linked notes, so a public badge never reveals how many anonymous notes someone wrote.
--   6. get_public_profile(id): only members with at least one live linked note have a public page; it lists linked notes only.
--   7. 28 new decorations (render classes are in decorations.css).

alter table public.notes add column if not exists show_profile boolean not null default false;
create index if not exists notes_linked_profile_idx on public.notes (author_id, published_at desc) where show_profile and status = 'published';

create or replace function public.note_json(n public.notes, p_viewer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', n.id, 'author_name', n.author_name, 'body', n.body, 'color', n.color,
    'social_link', n.social_link,
    'amount', case when n.show_amount then n.publication_amount::text end,
    'vote_count', n.vote_count, 'published_at', n.published_at, 'campus_id', n.campus_id, 'media', n.media,
    'poll', public.poll_json(n, p_viewer), 'spotify', n.spotify,
    'decorations', coalesce(a.decos, '[]'::jsonb),
    'stickers', coalesce(a.stk, '[]'::jsonb),
    'placements', coalesce(a.plc, '{}'::jsonb),
    'profile', case when n.show_profile then
        (select jsonb_build_object('id', p.id, 'name', p.display_name, 'avatar_url', p.avatar_url)
           from public.profiles p where p.id = n.author_id and p.suspended_at is null) end,
    'voted', p_viewer is not null and exists (select 1 from public.votes v where v.note_id = n.id and v.user_id = p_viewer),
    'bookmarked', p_viewer is not null and exists (select 1 from public.bookmarks b where b.note_id = n.id and b.user_id = p_viewer),
    'is_mine', p_viewer is not null and n.author_id = p_viewer)
  from (
    select jsonb_agg(d.decoration_id order by d.decoration_id, d.id) as decos,
           jsonb_agg(jsonb_build_object('id', d.decoration_id, 'x', coalesce(d.pos_x, c.default_x),
                                        'y', coalesce(d.pos_y, c.default_y), 'rot', d.rot) order by d.id) filter (where c.placeable) as stk,
           jsonb_object_agg(d.decoration_id, jsonb_build_object('x', coalesce(d.pos_x, c.default_x),
                                        'y', coalesce(d.pos_y, c.default_y), 'rot', d.rot)) filter (where c.placeable) as plc
      from public.note_decorations d left join public.decorations c on c.id = d.decoration_id
     where d.note_id = n.id) a
$$;

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

create or replace function public.set_note_profile(p_note uuid, p_show boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_name text;
begin
  select display_name into v_name from public.profiles where id = auth.uid() and suspended_at is null;
  if auth.uid() is null or v_name is null then perform public.app_error('CSW01', 'UNAUTHENTICATED'); end if;
  update public.notes
     set show_profile = coalesce(p_show, false),
         author_name = case when coalesce(p_show, false) then v_name else 'Anonymous' end
   where id = p_note and author_id = auth.uid();
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
end $$;

-- Achievements. Add one by adding a row here and a title in assets/js/profile-view.js.
create or replace function public.achievements_for(p_user uuid, p_public boolean) returns jsonb
language sql stable security definer set search_path = '' as $$
  with s as (
    select (select count(*) from public.notes n where n.author_id = p_user and n.status = 'published' and (not p_public or n.show_profile)) as notes,
           (select coalesce(sum(n.vote_count), 0) from public.notes n where n.author_id = p_user and n.status = 'published' and (not p_public or n.show_profile)) as votes,
           (select count(*) from public.referral_attributions a where a.referrer_id = p_user and a.status = 'qualified') as refs,
           (select coalesce(extract(day from now() - created_at)::int, 0) from public.profiles where id = p_user) as days
  ), d(ord, id, progress, target) as (
    select 1, 'first-note', notes, 1 from s union all
    select 2, 'notes-10', notes, 10 from s union all
    select 3, 'notes-50', notes, 50 from s union all
    select 4, 'votes-10', votes, 10 from s union all
    select 5, 'votes-100', votes, 100 from s union all
    select 6, 'votes-500', votes, 500 from s union all
    select 7, 'referral-1', refs, 1 from s union all
    select 8, 'referral-5', refs, 5 from s union all
    select 9, 'member-30', days, 30 from s union all
    select 10, 'member-365', days, 365 from s
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'progress', least(progress, target), 'target', target,
                            'earned', progress >= target) order by ord), '[]'::jsonb) from d
$$;

create or replace function public.my_achievements() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null then '[]'::jsonb else public.achievements_for(auth.uid(), false) end
$$;

create or replace function public.get_public_profile(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  p public.profiles;
  v_notes jsonb;
begin
  select * into p from public.profiles where id = p_id and suspended_at is null;
  if not found or not exists (select 1 from public.notes n where n.author_id = p_id and n.show_profile and n.status = 'published') then
    perform public.app_error('CSW04', 'NOT_FOUND');
  end if;
  select coalesce(jsonb_agg(public.note_json(n, auth.uid()) order by n.published_at desc), '[]'::jsonb) into v_notes
    from (select * from public.notes where author_id = p_id and show_profile and status = 'published'
           order by published_at desc limit 24) n;
  return jsonb_build_object('name', p.display_name, 'avatar_url', p.avatar_url, 'social_links', p.social_links,
    'member_since', p.created_at, 'achievements', public.achievements_for(p_id, true), 'notes', v_notes);
end $$;

-- my_notes also reports whether each note is linked to the profile.
create or replace function public.my_notes() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(public.note_json(n, auth.uid()) || jsonb_build_object(
           'status', n.status, 'created_at', n.created_at, 'order_ref', o.order_ref,
           'amount', n.publication_amount::text, 'show_profile', n.show_profile) order by n.created_at desc), '[]'::jsonb)
  from public.notes n join public.orders o on o.id = n.order_id
  where auth.uid() is not null and n.author_id = auth.uid()
$$;

revoke execute on function
  public.create_publication_order_v4(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid, jsonb, boolean, int, jsonb, text, boolean, boolean, jsonb, text, boolean),
  public.achievements_for(uuid, boolean)
  from public, anon, authenticated;
grant execute on function
  public.create_publication_order_v4(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid, jsonb, boolean, int, jsonb, text, boolean, boolean, jsonb, text, boolean),
  public.achievements_for(uuid, boolean)
  to service_role;
revoke execute on function public.set_note_profile(uuid, boolean), public.my_achievements() from public, anon;
grant execute on function public.set_note_profile(uuid, boolean), public.my_achievements() to authenticated;
revoke execute on function public.get_public_profile(uuid) from public;
grant execute on function public.get_public_profile(uuid) to anon, authenticated;

insert into public.decorations (id, name, description, price, sort_order, render, category, placeable, default_x, default_y) values
  ('sticker-sparkles', 'Sparkles', 'A little shine', 0, 101, '{"class": "deco-sticker-sparkles"}'::jsonb, 'Stickers', true, 88, 12),
  ('sticker-rainbow', 'Rainbow', 'After the rain', 1000, 102, '{"class": "deco-sticker-rainbow"}'::jsonb, 'Stickers', true, 12, 12),
  ('sticker-boba', 'Boba time', 'Brown sugar, extra pearls', 1000, 103, '{"class": "deco-sticker-boba"}'::jsonb, 'Stickers', true, 88, 84),
  ('sticker-game', 'Game on', 'Controller ready', 1000, 104, '{"class": "deco-sticker-game"}'::jsonb, 'Stickers', true, 12, 86),
  ('sticker-camera', 'Say cheese', 'Photo dump', 1000, 105, '{"class": "deco-sticker-camera"}'::jsonb, 'Stickers', true, 50, 10),
  ('sticker-ghost', 'Boo', 'Ghosted', 1000, 106, '{"class": "deco-sticker-ghost"}'::jsonb, 'Stickers', true, 70, 12),
  ('sticker-balloon', 'Balloon', 'Party up', 1000, 107, '{"class": "deco-sticker-balloon"}'::jsonb, 'Stickers', true, 30, 12),
  ('sticker-trophy', 'Trophy', 'You won', 2000, 108, '{"class": "deco-sticker-trophy"}'::jsonb, 'Stickers', true, 88, 48),
  ('sticker-moon', 'Midnight oil', 'Up all night', 1000, 109, '{"class": "deco-sticker-moon"}'::jsonb, 'Stickers', true, 12, 48),
  ('sticker-ojek', 'Ojek ride', 'Ride to campus', 1000, 110, '{"class": "deco-sticker-ojek"}'::jsonb, 'Stickers', true, 70, 88),
  ('label-lost', 'LOST label', 'Lost something? Say so', 0, 111, '{"class": "deco-label-lost"}'::jsonb, 'Stamps & badges', true, 12, 48),
  ('label-found', 'FOUND label', 'Found something? Say so', 0, 112, '{"class": "deco-label-found"}'::jsonb, 'Stamps & badges', true, 30, 88),
  ('label-forsale', 'FOR SALE label', 'Selling to the campus', 1000, 113, '{"class": "deco-label-forsale"}'::jsonb, 'Stamps & badges', true, 88, 28),
  ('label-wanted', 'WANTED label', 'Looking for something', 1000, 114, '{"class": "deco-label-wanted"}'::jsonb, 'Stamps & badges', true, 12, 88),
  ('badge-hot', 'HOT badge', 'A flaming orange pill', 1000, 115, '{"class": "deco-badge-hot"}'::jsonb, 'Stamps & badges', true, 50, 88),
  ('stamp-verified', 'Verified stamp', 'A tilted blue check stamp', 1000, 116, '{"class": "deco-stamp-verified"}'::jsonb, 'Stamps & badges', true, 88, 68),
  ('frame-double', 'Double line frame', 'Two thin lines', 1000, 117, '{"class": "deco-frame-double"}'::jsonb, 'Frames', false, null, null),
  ('frame-neon', 'Neon glow frame', 'A glowing violet edge', 2000, 118, '{"class": "deco-frame-neon"}'::jsonb, 'Frames', false, null, null),
  ('frame-sketch', 'Sketch frame', 'A rough hand-drawn box', 1000, 119, '{"class": "deco-frame-sketch"}'::jsonb, 'Frames', false, null, null),
  ('paper-blueprint', 'Blueprint', 'Engineer grid paper', 1000, 120, '{"class": "deco-paper-blueprint"}'::jsonb, 'Paper & patterns', false, null, null),
  ('paper-stripes', 'Pinstripes', 'Fine diagonal stripes', 0, 121, '{"class": "deco-paper-stripes"}'::jsonb, 'Paper & patterns', false, null, null),
  ('paper-polka', 'Polka dots', 'Big soft dots', 1000, 122, '{"class": "deco-paper-polka"}'::jsonb, 'Paper & patterns', false, null, null),
  ('mood-love', 'Lovestruck', 'Hearts floating around', 1000, 123, '{"class": "deco-mood-love"}'::jsonb, 'Moods', false, null, null),
  ('mood-night', 'Night sky', 'A deep blue edge glow', 1000, 124, '{"class": "deco-mood-night"}'::jsonb, 'Moods', false, null, null),
  ('mood-sunny', 'Sunny day', 'A warm light from the corner', 0, 125, '{"class": "deco-mood-sunny"}'::jsonb, 'Moods', false, null, null),
  ('campus-batik', 'Batik pattern', 'Parang-style diamonds', 2000, 126, '{"class": "deco-campus-batik"}'::jsonb, 'Campus life', false, null, null),
  ('tape-gold', 'Gold tape', 'A shiny gold strip', 2000, 128, '{"class": "deco-tape-gold"}'::jsonb, 'Tapes', false, null, null),
  ('tape-checker', 'Checker tape', 'A black and white strip', 1000, 129, '{"class": "deco-tape-checker"}'::jsonb, 'Tapes', false, null, null)
on conflict (id) do nothing;
-- Ramadan band was dropped before release; hide it if an earlier draft of this migration was already applied.
update public.decorations set enabled = false where id = 'season-ramadan';
