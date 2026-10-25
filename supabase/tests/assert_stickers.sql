-- Sticker placement assertions (migration 011). Run on a fresh DB after migrations 001-011 + stub_auth.sql.
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

select pg_temp.must((select count(*) from public.decorations where placeable) >= 15, 'at least 15 placeable stickers');
select pg_temp.must(not exists (select 1 from public.decorations where placeable and (default_x not between 0 and 100 or default_y not between 0 and 100 or default_x is null)), 'sticker defaults on the note');
select pg_temp.must(not (select placeable from public.decorations where id = 'frame-thick'), 'frames are not placeable');
select pg_temp.must(not has_function_privilege('authenticated', 'public.create_publication_order_full(uuid,text,text,text,text,boolean,text,text[],boolean,text,uuid,jsonb,boolean,int,jsonb)', 'execute'), 'clients cannot call the full order function');

create function pg_temp.order_full(tag text, decos text[], pos jsonb, use_credit boolean default false, use_post boolean default false) returns jsonb language sql as $$
  select public.create_publication_order_full(null, 'G', tag, 'yellow', null, true, '5000', decos, use_credit, md5(tag) || md5(tag), null, null, use_post, 0, pos) $$;
create function pg_temp.placements(tag text) returns jsonb language sql as $$
  select public.note_json(n, null) -> 'placements' from public.notes n where n.body = tag $$;

-- dragged position is stored (rounded) and returned; frames never appear in placements
select pg_temp.order_full('moved', '{sticker-cat,frame-thick}', '{"sticker-cat":{"x":20.456,"y":70}}');
select pg_temp.must((pg_temp.placements('moved') -> 'sticker-cat' ->> 'x')::numeric = 20.46, 'x stored and rounded');
select pg_temp.must((pg_temp.placements('moved') -> 'sticker-cat' ->> 'y')::numeric = 70, 'y stored');
select pg_temp.must(not (pg_temp.placements('moved') ? 'frame-thick'), 'frames are not in placements');

-- never moved: catalog default
select pg_temp.order_full('default', '{sticker-sun}', null);
select pg_temp.must((pg_temp.placements('default') -> 'sticker-sun' ->> 'x')::numeric = (select default_x from public.decorations where id = 'sticker-sun'), 'default x');

-- positions are validated; a bad request leaves nothing behind
select count(*) as before_n from public.orders \gset
select pg_temp.expect_err($$select pg_temp.order_full('bad1', '{sticker-cat}', '{"sticker-sun":{"x":10,"y":10}}')$$, 'INVALID_POSITION');
select pg_temp.expect_err($$select pg_temp.order_full('bad2', '{frame-thick}', '{"frame-thick":{"x":10,"y":10}}')$$, 'INVALID_POSITION');
select pg_temp.expect_err($$select pg_temp.order_full('bad3', '{sticker-cat}', '{"sticker-cat":{"x":101,"y":10}}')$$, 'INVALID_POSITION');
select pg_temp.expect_err($$select pg_temp.order_full('bad4', '{sticker-cat}', '{"sticker-cat":{"x":-1,"y":10}}')$$, 'INVALID_POSITION');
select pg_temp.expect_err($$select pg_temp.order_full('bad5', '{sticker-cat}', '{"sticker-cat":{"x":"5","y":10}}')$$, 'INVALID_POSITION');
select pg_temp.expect_err($$select pg_temp.order_full('bad6', '{sticker-cat}', '[1,2]')$$, 'INVALID_POSITION');
select pg_temp.must((select count(*) from public.orders) = :before_n, 'invalid positions must not create an order');

-- credit rules still enforced through the single entry point
select pg_temp.expect_err($$select pg_temp.order_full('conflict', '{}', null, true, true)$$, 'CREDIT_CONFLICT');
select pg_temp.expect_err($$select pg_temp.order_full('guest', '{}', null, false, true)$$, 'ACCOUNT_REQUIRED');
rollback;
\echo ALL STICKER ASSERTIONS PASSED
