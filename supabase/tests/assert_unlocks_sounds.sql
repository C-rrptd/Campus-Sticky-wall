-- Locked, seasonal and sound decorations (migration 045). Run after 001-045 + stub_auth.sql.
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
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, true) $$;
create function pg_temp.order_v4(uid uuid, tag text, decos text[]) returns jsonb language sql as $$
  select public.create_publication_order_v4(uid, 'N', tag, 'yellow', null, false, '5000', decos, false, md5(tag) || md5(tag),
    null, null, false, 0, null, null, false, false, null, null, false) $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000b1', 'b1@t.id', now()), ('00000000-0000-0000-0000-0000000000b2', 'b2@t.id', now());
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000b2';

-- 1. achievement lock: guest and member without votes refused; member with 100 votes allowed
select pg_temp.expect_err($$select pg_temp.order_v4(null, 'lock-guest', '{frame-gold}')$$, 'DECORATION_LOCKED');
select pg_temp.expect_err($$select pg_temp.order_v4('00000000-0000-0000-0000-0000000000b1', 'lock-none', '{frame-gold}')$$, 'DECORATION_LOCKED');
select pg_temp.order_v4('00000000-0000-0000-0000-0000000000b1', 'seed-votes', '{}');
update public.notes set status = 'published', published_at = now(), vote_count = 100 where body = 'seed-votes';
select pg_temp.must(pg_temp.order_v4('00000000-0000-0000-0000-0000000000b1', 'lock-ok', '{frame-gold}') is not null, 'earned member can use the locked decoration');
select pg_temp.must(exists (select 1 from public.note_decorations d join public.notes n on n.id = d.note_id where n.body = 'lock-ok' and d.decoration_id = 'frame-gold'), 'locked decoration stored');

-- 2. seasonal window enforced by the server and hidden by RLS
update public.decorations set available_from = now() + interval '1 day', available_until = now() + interval '2 days' where id = 'season-newyear';
select pg_temp.expect_err($$select pg_temp.order_v4('00000000-0000-0000-0000-0000000000b1', 'win-early', '{season-newyear}')$$, 'DECORATION_UNAVAILABLE');
update public.decorations set available_from = now() - interval '2 days', available_until = now() - interval '1 day' where id = 'season-newyear';
select pg_temp.expect_err($$select pg_temp.order_v4('00000000-0000-0000-0000-0000000000b1', 'win-late', '{season-newyear}')$$, 'DECORATION_UNAVAILABLE');
update public.decorations set available_from = now() - interval '1 day', available_until = now() + interval '1 day' where id = 'season-newyear';
select pg_temp.must(pg_temp.order_v4('00000000-0000-0000-0000-0000000000b1', 'win-in', '{season-newyear}') is not null, 'inside the window works');
set local role anon;
select pg_temp.must((select count(*) from public.decorations where id = 'season-newyear') = 1, 'in-window visible to guests');
reset role;
update public.decorations set available_until = now() - interval '1 hour' where id = 'season-newyear';
set local role anon;
select pg_temp.must((select count(*) from public.decorations where id = 'season-newyear') = 0, 'out-of-window hidden from guests');
reset role;

-- 3. sounds: admin only, 5 s cap, id shape, one per note, priced like a decoration
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select pg_temp.expect_err($$select public.admin_add_sound('snd-0123456789ab', 'Pop', '3000', 1000)$$, 'FORBIDDEN');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_err($$select public.admin_add_sound('snd-0123456789ab', 'Long', '3000', 5001)$$, 'SOUND_TOO_LONG');
select pg_temp.expect_err($$select public.admin_add_sound('bad-id', 'Pop', '3000', 1000)$$, 'INVALID_SOUND_ID');
select public.admin_add_sound('snd-0123456789ab', 'Pop', '3000', 1000);
select public.admin_add_sound('snd-ba9876543210', 'Ding', '2000', 5000);
select pg_temp.must((select category from public.decorations where id = 'snd-0123456789ab') = 'Sounds', 'sound category');
select pg_temp.expect_err($$select pg_temp.order_v4('00000000-0000-0000-0000-0000000000b1', 'two-sounds', '{snd-0123456789ab,snd-ba9876543210}')$$, 'TOO_MANY_SOUNDS');
select pg_temp.must(pg_temp.order_v4('00000000-0000-0000-0000-0000000000b1', 'one-sound', '{snd-0123456789ab}') is not null, 'one sound ok');
update public.notes set status = 'published', published_at = now() where body = 'one-sound';
select pg_temp.must((select (public.note_json(n, null) -> 'decorations') ? 'snd-0123456789ab' from public.notes n where body = 'one-sound'), 'sound id reaches the client');
select pg_temp.must((select (decoration_amount)::bigint from (select (public.quote_publication('5000', '{snd-0123456789ab}') ->> 'decorations_amount') as decoration_amount) q) = 3000, 'sound is priced');
rollback;
select 'unlocks+sounds OK';
