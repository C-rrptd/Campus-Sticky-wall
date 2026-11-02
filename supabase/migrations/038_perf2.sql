-- 038: wall read performance (idempotent). Output of note_json is unchanged.
--  1. note_json read note_decorations three times per note (decorations, stickers, placements);
--     now one pass feeds all three, so a 24-note page does 24 index scans instead of 72.
--  2. Indexes for the pinned lookup in get_wall and for "Most voted" inside one campus.

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

create index if not exists notes_pinned_idx on public.notes (pin_until) where status = 'published' and pin_until is not null;
create index if not exists notes_campus_top_idx on public.notes (campus_id, vote_count desc, published_at desc) where status = 'published';
