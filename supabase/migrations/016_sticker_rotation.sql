-- 016 — Sticker rotation. Stickers, stamps and badges can be rotated; placements gain "rot" (degrees, -180..179).
-- Several different stickers/stamps/badges per note were already allowed server-side (the one-per-category rule was UI only).
-- Additive and idempotent.

alter table public.note_decorations add column if not exists rot smallint not null default 0;
alter table public.note_decorations drop constraint if exists note_decorations_rot;
alter table public.note_decorations add constraint note_decorations_rot check (rot between -180 and 180);

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
    'placements', coalesce((select jsonb_object_agg(d.decoration_id, jsonb_build_object('x', coalesce(d.pos_x, c.default_x), 'y', coalesce(d.pos_y, c.default_y), 'rot', d.rot))
                              from public.note_decorations d join public.decorations c on c.id = d.decoration_id
                             where d.note_id = n.id and c.placeable), '{}'::jsonb),
    'voted', p_viewer is not null and exists (select 1 from public.votes v where v.note_id = n.id and v.user_id = p_viewer),
    'bookmarked', p_viewer is not null and exists (select 1 from public.bookmarks b where b.note_id = n.id and b.user_id = p_viewer),
    'is_mine', p_viewer is not null and n.author_id = p_viewer)
$$;

create or replace function public.apply_decoration_positions(p_order_ref text, p_decorations text[], p_positions jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_note uuid; k text; v jsonb; vx numeric; vy numeric; vr numeric;
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
    vr := 0;
    if v ? 'rot' then
      if jsonb_typeof(v -> 'rot') <> 'number' or abs((v ->> 'rot')::numeric) > 360 then
        perform public.app_error('CSW40', 'INVALID_POSITION', 'Invalid sticker rotation.');
      end if;
      vr := (v ->> 'rot')::numeric;
    end if;
    update public.note_decorations
       set pos_x = round(vx, 2), pos_y = round(vy, 2), rot = ((round(vr)::int + 540) % 360) - 180   -- stored as -180..179 degrees
     where note_id = v_note and decoration_id = k;
  end loop;
end $$;
