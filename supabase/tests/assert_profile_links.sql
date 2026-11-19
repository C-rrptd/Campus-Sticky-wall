-- Profile links, public profile, achievements, new decorations (migration 044). Run after 001-044 + stub_auth.sql.
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
create function pg_temp.order_v4(uid uuid, tag text, show boolean) returns jsonb language sql as $$
  select public.create_publication_order_v4(uid, 'Typed Name', tag, 'yellow', null, false, '5000', '{}', false, md5(tag) || md5(tag),
    null, null, false, 0, null, null, false, false, null, null, show) $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@t.id', now()), ('00000000-0000-0000-0000-0000000000a2', 'a2@t.id', now());
update public.profiles set display_name = 'Rina Putri' where id = '00000000-0000-0000-0000-0000000000a1';
update public.profiles set display_name = 'Budi Hidden' where id = '00000000-0000-0000-0000-0000000000a2';

-- 1. linking: name becomes the member's display name, the flag is set; an unlinked note stays anonymous-by-default
select pg_temp.order_v4('00000000-0000-0000-0000-0000000000a1', 'linked-note', true);
select pg_temp.order_v4('00000000-0000-0000-0000-0000000000a1', 'plain-note', false);
select pg_temp.must((select show_profile from public.notes where body = 'linked-note'), 'linked flag stored');
select pg_temp.must((select author_name from public.notes where body = 'linked-note') = 'Rina Putri', 'linked note shows display name');
select pg_temp.must(not (select show_profile from public.notes where body = 'plain-note'), 'plain note not linked');
select pg_temp.must((select author_name from public.notes where body = 'plain-note') = 'Typed Name', 'plain note keeps typed name');
select pg_temp.expect_err($$select pg_temp.order_v4(null, 'guest-link', true)$$, 'PROFILE_NEEDS_ACCOUNT');

-- 2. note_json exposes the profile only for linked notes
update public.notes set status = 'published', published_at = now(), vote_count = 12 where body in ('linked-note', 'plain-note');
select pg_temp.must((select public.note_json(n, null) -> 'profile' ->> 'name' from public.notes n where body = 'linked-note') = 'Rina Putri', 'profile in note_json');
select pg_temp.must((select public.note_json(n, null) -> 'profile' from public.notes n where body = 'plain-note') is null, 'no profile on plain note');
select pg_temp.must(not (select public.note_json(n, null)::text like '%author_id%' from public.notes n where body = 'linked-note'), 'author_id never in note_json');

-- 3. public profile: linked notes only; unlinked member has no page; suspended hides it
select pg_temp.must(jsonb_array_length(public.get_public_profile('00000000-0000-0000-0000-0000000000a1') -> 'notes') = 1, 'only the linked note is listed');
select pg_temp.expect_err($$select public.get_public_profile('00000000-0000-0000-0000-0000000000a2')$$, 'NOT_FOUND');
update public.profiles set suspended_at = now() where id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.expect_err($$select public.get_public_profile('00000000-0000-0000-0000-0000000000a1')$$, 'NOT_FOUND');
select pg_temp.must((select public.note_json(n, null) -> 'profile' from public.notes n where body = 'linked-note') is null, 'suspended member not exposed');
update public.profiles set suspended_at = null where id = '00000000-0000-0000-0000-0000000000a1';

-- 4. achievements: private counts everything, public counts linked notes only
select pg_temp.must((select (a ->> 'earned')::boolean from jsonb_array_elements(public.achievements_for('00000000-0000-0000-0000-0000000000a1', false)) a where a ->> 'id' = 'first-note'), 'first note earned');
select pg_temp.must((select (a ->> 'progress')::int from jsonb_array_elements(public.achievements_for('00000000-0000-0000-0000-0000000000a1', false)) a where a ->> 'id' = 'votes-100') = 24, 'private votes count both notes');
select pg_temp.must((select (a ->> 'progress')::int from jsonb_array_elements(public.achievements_for('00000000-0000-0000-0000-0000000000a1', true)) a where a ->> 'id' = 'votes-100') = 12, 'public votes count the linked note only');
select pg_temp.must(jsonb_array_length(public.achievements_for('00000000-0000-0000-0000-0000000000a1', false)) = 12, 'twelve achievements (10 + 2 streak, migration 051)');
select pg_temp.must(not (select (a ->> 'earned')::boolean from jsonb_array_elements(public.achievements_for('00000000-0000-0000-0000-0000000000a2', false)) a where a ->> 'id' = 'first-note'), 'nothing earned without notes');

-- 5. owner-only link/unlink
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_err($$select public.set_note_profile((select id from public.notes where body = 'plain-note'), true)$$, 'NOT_FOUND');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select public.set_note_profile((select id from public.notes where body = 'plain-note'), true);
select pg_temp.must((select author_name from public.notes where body = 'plain-note') = 'Rina Putri', 'late link sets name');
select public.set_note_profile((select id from public.notes where body = 'plain-note'), false);
select pg_temp.must((select author_name from public.notes where body = 'plain-note') = 'Anonymous', 'unlink resets to Anonymous');
select pg_temp.must(jsonb_array_length(public.my_achievements()) = 12, 'my_achievements works for the member');

-- 6. grants
select pg_temp.must(has_function_privilege('anon', 'public.get_public_profile(uuid)', 'execute'), 'guests can open a public profile');
select pg_temp.must(not has_function_privilege('authenticated', 'public.achievements_for(uuid,boolean)', 'execute'), 'achievements_for is internal');
select pg_temp.must(not has_function_privilege('authenticated', 'public.create_publication_order_v4(uuid,text,text,text,text,boolean,text,text[],boolean,text,uuid,jsonb,boolean,int,jsonb,text,boolean,boolean,jsonb,text,boolean)', 'execute'), 'clients cannot call v4');
select pg_temp.must(not has_function_privilege('anon', 'public.set_note_profile(uuid,boolean)', 'execute'), 'guests cannot link');

-- 7. new decorations: usable in an order, stickers placeable, whole-note ones not
select pg_temp.must((select count(*) from public.decorations where sort_order between 101 and 129) = 28, '28 new decorations');
select pg_temp.must((select placeable from public.decorations where id = 'sticker-boba'), 'boba is a sticker');
select pg_temp.must(not (select placeable from public.decorations where id = 'frame-neon'), 'neon frame is whole-note');
select pg_temp.must((public.quote_publication('5000', '{sticker-boba,frame-neon,tape-gold}') ->> 'decorations_amount')::bigint = 1000 + 2000 + 2000, 'new decorations are priced');
rollback;
select 'profile links OK';
