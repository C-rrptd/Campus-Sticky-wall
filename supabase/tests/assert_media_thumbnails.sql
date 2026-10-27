-- Media thumbnail assertions (migration 026): the sweep keeps the thumbnail of a live note's image and queues abandoned ones.
-- Plain Postgres has no Storage, so a minimal storage.objects is created inside the transaction and rolled back.
\set ON_ERROR_STOP on
begin;
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

create schema if not exists storage;
create table storage.objects (id bigserial primary key, bucket_id text, name text, created_at timestamptz default now());

insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000e1', 't@t.id', now());
create function pg_temp.make_note(tag text, media jsonb) returns uuid language plpgsql as $$
declare ref text; nid uuid;
begin
  ref := (public.create_publication_order(p_user_id => '00000000-0000-0000-0000-0000000000e1', p_author_name => 'T', p_body => tag,
            p_color => 'yellow', p_social_link => null, p_show_amount => true, p_amount => '5000', p_decorations => '{}'::text[],
            p_use_credit => false, p_guest_token_hash => repeat('b', 64), p_media => media))->>'order_ref';
  select n.id into nid from public.notes n join public.orders o on o.id = n.order_id where o.order_ref = ref;
  return nid;
end $$;
select pg_temp.make_note('live', '[{"path":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/pic.png","kind":"image"}]') as n1 \gset

select pg_temp.must(public.note_media_paths('[{"path":"x/p.jpg","kind":"image"}]'::jsonb) = array['x/p.jpg','x/p-t.webp'], 'image path list includes its thumbnail');
select pg_temp.must(public.note_media_paths('[{"path":"x/v.mp4","kind":"video"},{"path":"x/g.gif","kind":"image"}]'::jsonb) = array['x/v.mp4','x/g.gif'], 'video and gif have no thumbnail path');
select pg_temp.must(public.note_media_paths(null) = '{}' and public.note_media_paths('[]'::jsonb) = '{}', 'empty media gives an empty list');

insert into storage.objects (bucket_id, name, created_at) values
  ('note-media', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/pic.png',    now() - interval '3 days'),
  ('note-media', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/pic-t.webp', now() - interval '3 days'),
  ('note-media', 'cccccccc-cccc-cccc-cccc-cccccccccccc/lost.jpg',    now() - interval '3 days'),
  ('note-media', 'cccccccc-cccc-cccc-cccc-cccccccccccc/lost-t.webp', now() - interval '3 days'),
  ('note-media', 'dddddddd-dddd-dddd-dddd-dddddddddddd/new-t.webp',  now() - interval '1 hour');

select public.media_sweep_stale_uploads() as swept \gset
select pg_temp.must(:swept = 2, 'sweep queues exactly the abandoned file and its thumbnail');
select pg_temp.must((select array_agg(path order by path collate "C") from public.media_orphans) =
  array['cccccccc-cccc-cccc-cccc-cccccccccccc/lost-t.webp', 'cccccccc-cccc-cccc-cccc-cccccccccccc/lost.jpg'],
  'a live note keeps its thumbnail and a fresh upload is left alone');
rollback;
\echo ALL MEDIA THUMBNAIL ASSERTIONS PASSED
