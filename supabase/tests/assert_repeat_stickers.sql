-- Repeated stickers (migration 017). Run after 001-017 and stub_auth.sql.
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
create function pg_temp.note(tag text) returns jsonb language sql as $$
  select public.note_json(n, null) from public.notes n where n.body = tag $$;

-- three copies of one sticker: priced three times, three rows, each copy keeps its own place
select pg_temp.must((public.quote_publication('5000', '{sticker-cat,sticker-cat,sticker-cat}') ->> 'decorations_amount')::bigint
                    = 3 * (select price from public.decorations where id = 'sticker-cat'), 'every copy is priced');
select pg_temp.must(jsonb_array_length(public.quote_publication('5000', '{sticker-cat,sticker-cat}') -> 'decorations') = 2, 'one quote line per copy');
select pg_temp.order_full('three-cats', '{sticker-cat,sticker-cat,sticker-cat,sticker-sun}',
  '[{"id":"sticker-cat","x":10,"y":20,"rot":15},{"id":"sticker-cat","x":50,"y":60},{"id":"sticker-sun","x":90,"y":10},{"id":"sticker-cat","x":70,"y":80,"rot":-30}]');
select pg_temp.must(jsonb_array_length(pg_temp.note('three-cats') -> 'stickers') = 4, 'four stickers stored');
select pg_temp.must((select count(*) from jsonb_array_elements_text(pg_temp.note('three-cats') -> 'decorations') d where d = 'sticker-cat') = 3, 'three cats listed');
select pg_temp.must((select count(distinct (s ->> 'x')) from jsonb_array_elements(pg_temp.note('three-cats') -> 'stickers') s where s ->> 'id' = 'sticker-cat') = 3, 'copies keep different places');
select pg_temp.must((select (s ->> 'rot')::int from jsonb_array_elements(pg_temp.note('three-cats') -> 'stickers') s where s ->> 'id' = 'sticker-cat' and (s ->> 'x')::numeric = 70) = -30, 'rotation follows its copy');
select pg_temp.order_full('items-check', '{sticker-cat,sticker-cat}', null);
select pg_temp.must((select count(*) from public.order_items i join public.notes n on n.order_id = i.order_id
                      where n.body = 'items-check' and i.item_type = 'decoration' and i.item_ref = 'sticker-cat') = 2, 'one order item per copy');

-- the old object form still works: one copy per id
select pg_temp.order_full('legacy', '{sticker-cat,sticker-sun}', '{"sticker-cat":{"x":20,"y":30,"rot":5}}');
select pg_temp.must(jsonb_array_length(pg_temp.note('legacy') -> 'stickers') = 2, 'legacy form stored');
select pg_temp.must((pg_temp.note('legacy') -> 'placements' -> 'sticker-cat' ->> 'x')::numeric = 20, 'legacy placements key still present');

-- whole-note decorations stay one each; stickers cap at 10 decorations in total
select pg_temp.expect_err($$select pg_temp.order_full('dup-frame', '{frame-thick,frame-thick}', null)$$, 'DUPLICATE_DECORATION');
select pg_temp.expect_err($$select pg_temp.order_full('too-many', '{sticker-cat,sticker-cat,sticker-cat,sticker-cat,sticker-cat,sticker-cat,sticker-cat,sticker-cat,sticker-cat,sticker-cat,sticker-cat}', null)$$, 'TOO_MANY_DECORATIONS');

-- positions may not name more copies than the note has, or a sticker that is not on it
select pg_temp.expect_err($$select pg_temp.order_full('extra', '{sticker-cat}', '[{"id":"sticker-cat","x":1,"y":1},{"id":"sticker-cat","x":2,"y":2}]')$$, 'INVALID_POSITION');
select pg_temp.expect_err($$select pg_temp.order_full('absent', '{sticker-cat}', '[{"id":"sticker-sun","x":1,"y":1}]')$$, 'INVALID_POSITION');
select pg_temp.expect_err($$select pg_temp.order_full('offnote', '{sticker-cat}', '[{"id":"sticker-cat","x":101,"y":1}]')$$, 'INVALID_POSITION');
select pg_temp.expect_err($$select pg_temp.order_full('notlist', '{sticker-cat}', '"oops"')$$, 'INVALID_POSITION');

rollback;
select 'repeat sticker assertions passed';
