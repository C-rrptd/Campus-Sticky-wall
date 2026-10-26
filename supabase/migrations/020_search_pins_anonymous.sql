-- 020: wall search + colour filter, single-note fetch (share links), paid "pin to top",
--      anonymous-by-default names, amount paid is never shown on a note, extra sticker pack.

-- 1. Anonymous names: "Anonymous" is the fallback when the poster types nothing, so it must pass
--    even if a member registered that display name. Everything else is unchanged from 012.
create or replace function public.validate_author_name(p_name text) returns void
language plpgsql stable security definer set search_path = '' as $$
declare v text := btrim(coalesce(p_name, '')); k text;
begin
  if lower(v) = 'anonymous' then return; end if;
  if v ~ '[<>"`{}\\]' then
    perform public.app_error('CSW40', 'INVALID_AUTHOR_NAME', 'Names cannot contain < > " ` { } or backslashes.');
  end if;
  if v ~ '[​-‏‪-‮⁠-⁤⁦-⁩﻿]' then
    perform public.app_error('CSW40', 'INVALID_AUTHOR_NAME', 'That name contains invisible characters.');
  end if;
  if v ~ '@' or v ~* '(https?:|www\.|[a-z0-9-]\.(com|id|net|org|co|me|io|xyz|ly|gl|link)\M)' then
    perform public.app_error('CSW40', 'INVALID_AUTHOR_NAME', 'Names cannot contain links or @handles.');
  end if;
  k := public.name_key(v);
  if k = '' then
    perform public.app_error('CSW40', 'INVALID_AUTHOR_NAME', 'Use letters or numbers in the name.');
  end if;
  if k in ('admin','administrator','moderator','mod','official','staff','support','team','owner')
     or k like '%campusstickywall%'
     or exists (select 1 from public.profiles p where public.name_key(p.display_name) = k) then
    perform public.app_error('CSW40', 'NAME_NOT_AVAILABLE',
      'That name belongs to a registered member or is reserved. Please pick another.');
  end if;
end $$;

-- 2. The amount paid is no longer shown on notes (the opt-in checkbox is gone).
update public.notes set show_amount = false where show_amount;
alter table public.notes alter column show_amount set default false;

-- 3. Pin to top: the "pin-top" decoration keeps a note first on the Newest wall for 7 days after it is published.
create or replace function public.note_is_pinned(p_id uuid, p_published timestamptz) returns boolean
language sql stable set search_path = '' as $$
  select coalesce(p_published > now() - interval '7 days', false)
     and exists (select 1 from public.note_decorations d where d.note_id = p_id and d.decoration_id = 'pin-top')
$$;

-- 4. get_wall gains a text search and a colour filter. The 4-argument version is dropped:
--    two overloads would make named-argument RPC calls ambiguous.
drop function if exists public.get_wall(text, uuid, int, int);
create or replace function public.get_wall(p_sort text default 'newest', p_campus uuid default null,
  p_limit int default 24, p_offset int default 0, p_q text default null, p_color text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_viewer uuid := auth.uid();
  v_limit int := least(greatest(coalesce(p_limit, 24), 1), 50);
  v_offset int := least(greatest(coalesce(p_offset, 0), 0), 5000);
  v_q text := nullif(btrim(left(coalesce(p_q, ''), 60)), '');
  v_like text := case when v_q is null then null
    else '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
begin
  if p_sort not in ('newest','top','contribution') then
    perform public.app_error('CSW40', 'INVALID_SORT');
  end if;
  if p_color is not null and p_color not in ('yellow','pink','blue','green','orange','purple') then
    perform public.app_error('CSW40', 'INVALID_COLOR');
  end if;
  return coalesce((
    select jsonb_agg(public.note_json(n, v_viewer) order by
             (p_sort = 'newest' and public.note_is_pinned(n.id, n.published_at)) desc,
             case when p_sort = 'top' then n.vote_count end desc nulls last,
             case when p_sort = 'contribution' then n.publication_amount end desc nulls last,
             n.published_at desc, n.id)
    from (select * from public.notes n
           where n.status = 'published'
             and (p_campus is null or n.campus_id = p_campus)
             and (p_color is null or n.color = p_color)
             and (v_like is null or n.body ilike v_like escape '\' or n.author_name ilike v_like escape '\')
             and (p_sort <> 'contribution' or n.show_amount)
           order by
             (p_sort = 'newest' and public.note_is_pinned(n.id, n.published_at)) desc,
             case when p_sort = 'top' then n.vote_count end desc nulls last,
             case when p_sort = 'contribution' then n.publication_amount end desc nulls last,
             n.published_at desc, n.id
           limit v_limit offset v_offset) n), '[]'::jsonb);
end $$;

-- 5. One published note by id (share links).
create or replace function public.get_note(p_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select public.note_json(n, auth.uid()) from public.notes n where n.id = p_id and n.status = 'published'
$$;

grant execute on function public.get_wall(text, uuid, int, int, text, text) to anon, authenticated;
grant execute on function public.get_note(uuid) to anon, authenticated;

-- 6. Pin + highlight + a "Food & study" sticker pack (render classes are in decorations.css).
insert into public.decorations (id, name, description, price, sort_order, render, category) values
  ('pin-top',            'Pin to top (7 days)', 'Stays first on the Newest wall for 7 days',    10000, 70, '{"class": "deco-pin-top"}'::jsonb,            'Boosts'),
  ('highlight-glow',     'Highlight glow',      'A warm glow so your note stands out',           3000, 71, '{"class": "deco-highlight-glow"}'::jsonb,     'Boosts'),
  ('sticker-pizza',      'Pizza slice',         'Late-night study fuel',                         1000, 72, '{"class": "deco-sticker-pizza"}'::jsonb,      'Stickers'),
  ('sticker-book',       'Book stack',          'Exam season',                                   1000, 73, '{"class": "deco-sticker-book"}'::jsonb,       'Stickers'),
  ('sticker-music',      'Music note',          'Headphones on',                                 1000, 74, '{"class": "deco-sticker-music"}'::jsonb,      'Stickers'),
  ('sticker-ramen',      'Ramen bowl',          'End-of-month meal',                             1000, 75, '{"class": "deco-sticker-ramen"}'::jsonb,      'Stickers'),
  ('sticker-fire',       'Fire',                'This is hot',                                   1000, 76, '{"class": "deco-sticker-fire"}'::jsonb,       'Stickers'),
  ('sticker-grad',       'Graduation cap',      'Almost there',                                  1000, 77, '{"class": "deco-sticker-grad"}'::jsonb,       'Stickers')
on conflict (id) do nothing;
-- The sticker pack is draggable like the other stickers; the boosts are whole-note effects.
update public.decorations set placeable = true, default_x = 85, default_y = 15
 where id in ('sticker-pizza','sticker-book','sticker-music','sticker-ramen','sticker-fire','sticker-grad') and not placeable;

-- 7. Admin dashboard: notes posted today / last 7 days next to the existing counters.
create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'open_reports', (select count(*) from public.reports where status = 'open'),
    'notes_pending_moderation', (select count(*) from public.notes where status = 'pending_moderation'),
    'campaigns_pending_review', (select count(*) from public.campaigns where status = 'pending_review'),
    'orders_needing_review', (select count(*) from public.orders where review_required),
    'published_notes', (select count(*) from public.notes where status = 'published'),
    'notes_today', (select count(*) from public.notes where status = 'published'
                     and published_at >= date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta'),
    'notes_7d', (select count(*) from public.notes where status = 'published' and published_at >= now() - interval '7 days'),
    'users', (select count(*) from public.profiles));
end $$;
