-- Sticker rotation + several stickers per note (migration 016). Run after 001-016 and stub_auth.sql.
\set ON_ERROR_STOP on
begin;
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create function pg_temp.expect_err(stmt text, code text) returns void language plpgsql as $$
begin
  begin execute stmt;
  exception when others then
    if sqlerrm like '%' || code || '%' then return; end if;
    raise exception 'expected %, got: %  [%]', code, sqlerrm, stmt;
  end;
  raise exception 'expected % but statement succeeded: %', code, stmt;
end $$;
create function pg_temp.order_full(tag text, decos text[], pos jsonb) returns jsonb language sql as $$
  select public.create_publication_order_full(null, 'G', tag, 'yellow', null, true, '5000', decos, false, md5(tag) || md5(tag), null, null, false, 0, pos) $$;
create function pg_temp.placements(tag text) returns jsonb language sql as $$
  select public.note_json(n, null) -> 'placements' from public.notes n where n.body = tag $$;

-- several different stickers, stamps and badges on one note; each keeps its own position and rotation
select pg_temp.order_full('multi', '{sticker-cat,sticker-sun,stamp-approved,badge-star}',
  '{"sticker-cat":{"x":20,"y":70,"rot":45},"stamp-approved":{"x":50,"y":50,"rot":-12.4},"badge-star":{"x":80,"y":20,"rot":270}}');
select pg_temp.must((select count(*) from jsonb_object_keys(pg_temp.placements('multi'))) = 4, 'four placeable decorations stored');
select pg_temp.must((pg_temp.placements('multi') -> 'sticker-cat' ->> 'rot')::int = 45, 'rotation stored');
select pg_temp.must((pg_temp.placements('multi') -> 'stamp-approved' ->> 'rot')::int = -12, 'rotation rounded to whole degrees');
select pg_temp.must((pg_temp.placements('multi') -> 'badge-star' ->> 'rot')::int = -90, '270 degrees is stored as -90');
select pg_temp.must((pg_temp.placements('multi') -> 'sticker-sun' ->> 'rot')::int = 0, 'never rotated: 0');

-- no rot given: 0 (old clients keep working)
select pg_temp.order_full('norot', '{sticker-cat}', '{"sticker-cat":{"x":10,"y":10}}');
select pg_temp.must((pg_temp.placements('norot') -> 'sticker-cat' ->> 'rot')::int = 0, 'rot defaults to 0');

-- bad rotations are refused
select pg_temp.expect_err($$select pg_temp.order_full('bad1', '{sticker-cat}', '{"sticker-cat":{"x":10,"y":10,"rot":400}}')$$, 'INVALID_POSITION');
select pg_temp.expect_err($$select pg_temp.order_full('bad2', '{sticker-cat}', '{"sticker-cat":{"x":10,"y":10,"rot":"90"}}')$$, 'INVALID_POSITION');

rollback;
select 'sticker rotation assertions passed';
