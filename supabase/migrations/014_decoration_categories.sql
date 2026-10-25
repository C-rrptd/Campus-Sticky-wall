-- 014 — Decoration categories: Borders, Tapes, Stickers, Stamps & badges, Backgrounds, Themes.
-- Replaces the old category names (Classic, Frames, Corners, ...) and adds three tapes. Idempotent.

update public.decorations set category = case
  when id = 'tape' or id like 'tape-%'                          then 'Tapes'
  when id = 'border' or id like 'frame-%' or id like 'corner-%' then 'Borders'
  when id = 'stickers' or id like 'sticker-%' or id like 'doodle-%' or id like 'nature-%' then 'Stickers'
  when id like 'paper-%' or id like 'retro-%'                   then 'Backgrounds'
  when id like 'campus-%' or id like 'mood-%' or id like 'season-%' then 'Themes'
  else category end
where id in ('tape','border','stickers')
   or id ~ '^(frame|corner|sticker|doodle|nature|paper|retro|campus|mood|season)-';
update public.decorations set category = 'Stamps & badges' where id ~ '^(stamp|badge|label)-';

insert into public.decorations (id, name, description, price, sort_order, render, category) values
  ('tape-washi-pink', 'Pink washi tape', 'A pink striped strip across the top', 1000, 60, '{"class": "deco-tape-washi-pink"}'::jsonb, 'Tapes'),
  ('tape-washi-blue', 'Blue washi tape', 'A blue dotted strip across the top', 1000, 61, '{"class": "deco-tape-washi-blue"}'::jsonb, 'Tapes'),
  ('tape-masking',    'Masking tape',    'A beige masking-tape strip',          0,    62, '{"class": "deco-tape-masking"}'::jsonb,    'Tapes')
on conflict (id) do nothing;
