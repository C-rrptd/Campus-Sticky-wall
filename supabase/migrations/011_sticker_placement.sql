-- 011_sticker_placement.sql
-- Stickers (decorations flagged placeable) can be dragged anywhere on a note.
-- Position is stored per note as a percentage of the note's width/height (0-100).
-- Frames, textures and other whole-note decorations are not placeable.
-- Also adds create_publication_order_full: one transaction for order + referral
-- credits + media + sticker positions. Additive; safe to re-run.

alter table public.decorations add column if not exists placeable boolean not null default false;
alter table public.decorations add column if not exists default_x numeric(5,2);
alter table public.decorations add column if not exists default_y numeric(5,2);
alter table public.decorations drop constraint if exists decorations_placeable_pos;
alter table public.decorations add constraint decorations_placeable_pos check (
  not placeable or (default_x between 0 and 100 and default_y between 0 and 100));

alter table public.note_decorations add column if not exists pos_x numeric(5,2);
alter table public.note_decorations add column if not exists pos_y numeric(5,2);
alter table public.note_decorations drop constraint if exists note_decorations_pos;
alter table public.note_decorations add constraint note_decorations_pos check (
  (pos_x is null) = (pos_y is null) and (pos_x is null or (pos_x between 0 and 100 and pos_y between 0 and 100)));

update public.decorations set placeable = true, default_x = 88, default_y = 12 where id = 'sticker-sun';
update public.decorations set placeable = true, default_x = 88, default_y = 84 where id = 'sticker-cat';
update public.decorations set placeable = true, default_x = 12, default_y = 12 where id = 'sticker-coffee';
update public.decorations set placeable = true, default_x = 12, default_y = 86 where id = 'sticker-rocket';
update public.decorations set placeable = true, default_x = 50, default_y = 10 where id = 'sticker-lightbulb';
update public.decorations set placeable = true, default_x = 50, default_y = 88 where id = 'stamp-approved';
update public.decorations set placeable = true, default_x = 88, default_y = 48 where id = 'stamp-urgent';
update public.decorations set placeable = true, default_x = 12, default_y = 48 where id = 'badge-new';
update public.decorations set placeable = true, default_x = 70, default_y = 12 where id = 'badge-star';
update public.decorations set placeable = true, default_x = 70, default_y = 88 where id = 'label-nametag';
update public.decorations set placeable = true, default_x = 30, default_y = 12 where id = 'doodle-heart';
update public.decorations set placeable = true, default_x = 30, default_y = 88 where id = 'campus-graduation';
update public.decorations set placeable = true, default_x = 88, default_y = 28 where id = 'campus-books';
update public.decorations set placeable = true, default_x = 88, default_y = 68 where id = 'campus-grade';
update public.decorations set placeable = true, default_x = 12, default_y = 28 where id = 'mood-lol';
update public.decorations set placeable = true, default_x = 12, default_y = 68 where id = 'mood-sleepy';
update public.decorations set placeable = true, default_x = 60, default_y = 50 where id = 'nature-leaf';
update public.decorations set placeable = true, default_x = 40, default_y = 50 where id = 'nature-flower';

-- note_json gains "placements": { "<decoration id>": {"x": 0-100, "y": 0-100} } for placeable
-- decorations (the catalog default when the author never moved it). "decorations" is unchanged.
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
    'placements', coalesce((select jsonb_object_agg(d.decoration_id, jsonb_build_object('x', coalesce(d.pos_x, c.default_x), 'y', coalesce(d.pos_y, c.default_y)))
                              from public.note_decorations d join public.decorations c on c.id = d.decoration_id
                             where d.note_id = n.id and c.placeable), '{}'::jsonb),
    'voted', p_viewer is not null and exists (select 1 from public.votes v where v.note_id = n.id and v.user_id = p_viewer),
    'bookmarked', p_viewer is not null and exists (select 1 from public.bookmarks b where b.note_id = n.id and b.user_id = p_viewer),
    'is_mine', p_viewer is not null and n.author_id = p_viewer)
$$;

-- Validate and store positions for a just-created order's note (same transaction as the order).
create or replace function public.apply_decoration_positions(p_order_ref text, p_decorations text[], p_positions jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_note uuid; k text; v jsonb; vx numeric; vy numeric;
begin
  if p_positions is null or p_positions = 'null'::jsonb or p_positions = '{}'::jsonb then return; end if;
  if jsonb_typeof(p_positions) <> 'object' or (select count(*) from jsonb_object_keys(p_positions)) > 10 then
    perform public.app_error('CSW40', 'INVALID_POSITION', 'Invalid sticker positions.');
  end if;
  select n.id into v_note from public.notes n join public.orders o on o.id = n.order_id where o.order_ref = p_order_ref;
  if v_note is null then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  for k, v in select * from jsonb_each(p_positions) loop
    if not (k = any (coalesce(p_decorations, '{}'))) or not exists (select 1 from public.decorations c where c.id = k and c.placeable) then
      perform public.app_error('CSW40', 'INVALID_POSITION', 'That decoration cannot be placed.');
    end if;
    if jsonb_typeof(v) <> 'object' or jsonb_typeof(v -> 'x') <> 'number' or jsonb_typeof(v -> 'y') <> 'number' then
      perform public.app_error('CSW40', 'INVALID_POSITION', 'Invalid sticker positions.');
    end if;
    vx := (v ->> 'x')::numeric; vy := (v ->> 'y')::numeric;
    if vx < 0 or vx > 100 or vy < 0 or vy > 100 then
      perform public.app_error('CSW40', 'INVALID_POSITION', 'Stickers must stay on the note.');
    end if;
    update public.note_decorations set pos_x = round(vx, 2), pos_y = round(vy, 2) where note_id = v_note and decoration_id = k;
  end loop;
end $$;

create or replace function public.create_publication_order_full(
  p_user_id uuid, p_author_name text, p_body text, p_color text, p_social_link text, p_show_amount boolean,
  p_amount text, p_decorations text[], p_use_credit boolean, p_guest_token_hash text, p_campus_id uuid,
  p_media jsonb, p_use_post_credit boolean, p_deco_credits int, p_positions jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  if coalesce(p_use_post_credit, false) or coalesce(p_deco_credits, 0) > 0 then
    if p_use_credit then
      perform public.app_error('CSW40', 'CREDIT_CONFLICT', 'Choose either the old Rp5.000 credit or referral credits, not both.');
    end if;
    v := public.create_publication_order_credits(p_user_id, p_author_name, p_body, p_color, p_social_link, p_show_amount,
           p_amount, p_decorations, p_guest_token_hash, p_campus_id, p_use_post_credit, p_deco_credits, p_media);
  else
    v := public.create_publication_order(p_user_id, p_author_name, p_body, p_color, p_social_link, p_show_amount,
           p_amount, p_decorations, p_use_credit, p_guest_token_hash, p_campus_id, p_media);
  end if;
  perform public.apply_decoration_positions(v ->> 'order_ref', p_decorations, p_positions);
  return v;
end $$;

revoke execute on function public.apply_decoration_positions(text, text[], jsonb),
  public.create_publication_order_full(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid, jsonb, boolean, int, jsonb)
  from public, anon, authenticated;
grant execute on function public.apply_decoration_positions(text, text[], jsonb),
  public.create_publication_order_full(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid, jsonb, boolean, int, jsonb)
  to service_role;
