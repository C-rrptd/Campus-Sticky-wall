-- Migration 020 assertions: wall search + colour filter, pin to top, get_note, "Anonymous" names, no shown amounts.
-- Run as a superuser after 001-020 and stub_auth.sql.
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
-- Creates, pays and publishes one note; returns its id.
create function pg_temp.pub(nm text, txt text, col text, decos text[]) returns uuid language plpgsql as $$
declare v jsonb; oid uuid;
begin
  v := public.create_publication_order_v2(null, nm, txt, col, null, false, '2500', decos, false,
         encode(sha256(gen_random_uuid()::text::bytea), 'hex'), null, null, false, 0, null, null, false, false);
  select id into oid from public.orders where order_ref = v ->> 'order_ref';
  update public.orders set status = 'paid', paid_at = now() where id = oid;
  perform public.fulfill_order(oid);
  return (select id from public.notes where order_id = oid);
end $$;

-- ---- names: empty becomes "Anonymous", even if a member took that display name ----
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000d1', 'd1@t.id', now());
update public.profiles set display_name = 'Anonymous' where id = '00000000-0000-0000-0000-0000000000d1';
select pg_temp.must(pg_temp.pub('Anonymous', 'who am i', 'yellow', '{}') is not null, 'Anonymous allowed');
select pg_temp.expect_err($$select pg_temp.pub('admin', 'x', 'yellow', '{}')$$, 'NAME_NOT_AVAILABLE');

-- ---- the amount paid is never shown ----
select pg_temp.must((select column_default from information_schema.columns where table_schema = 'public' and table_name = 'notes' and column_name = 'show_amount') = 'false', 'show_amount defaults to false');
select pg_temp.must(not exists (select 1 from public.notes where show_amount), 'no note shows its amount');

-- ---- search + colour + pin ----
create temp table ids as
  select pg_temp.pub('Rani', 'Bakso kantin enak', 'pink', '{}') as bakso,
         pg_temp.pub('Dito', 'Kelas pagi jam 7', 'blue', '{pin-top}') as pinned,
         pg_temp.pub('Sari', 'Diskon 100% hari ini', 'yellow', '{}') as pct;
update public.notes set published_at = now() - interval '1 day' where id = (select pinned from ids);

select pg_temp.must(jsonb_array_length(public.get_wall('newest', null, 50, 0, 'BAKSO', null)) = 1, 'search is case-insensitive');
select pg_temp.must(jsonb_array_length(public.get_wall('newest', null, 50, 0, 'Dito', null)) = 1, 'search matches the name too');
select pg_temp.must(jsonb_array_length(public.get_wall('newest', null, 50, 0, '100%', null)) = 1, 'percent sign is literal, not a wildcard');
select pg_temp.must(jsonb_array_length(public.get_wall('newest', null, 50, 0, '%', null)) = 1, 'a lone percent matches only notes containing it');
select pg_temp.must(jsonb_array_length(public.get_wall('newest', null, 50, 0, null, 'pink')) = 1, 'colour filter');
select pg_temp.must(jsonb_array_length(public.get_wall('newest', null, 50, 0, 'bakso', 'blue')) = 0, 'search and colour combine');
select pg_temp.expect_err($$select public.get_wall('newest', null, 50, 0, null, 'red')$$, 'INVALID_COLOR');
select pg_temp.must(public.get_wall('newest', null, 50, 0) -> 0 ->> 'id' = (select pinned::text from ids), 'pinned note is first on Newest even though older');
update public.notes set published_at = now() - interval '8 days' where id = (select pinned from ids);
select pg_temp.must(public.get_wall('newest', null, 50, 0) -> 0 ->> 'id' <> (select pinned::text from ids), 'pin expires after 7 days');

-- ---- single note for share links ----
select pg_temp.must(public.get_note((select bakso from ids)) ->> 'body' = 'Bakso kantin enak', 'get_note returns a published note');
update public.notes set status = 'removed' where id = (select bakso from ids);
select pg_temp.must(public.get_note((select bakso from ids)) is null, 'removed notes are not shared');
select pg_temp.must(has_function_privilege('anon', 'public.get_note(uuid)', 'execute'), 'anon can open a share link');
select pg_temp.must(has_function_privilege('anon', 'public.get_wall(text,uuid,int,int,text,text)', 'execute'), 'anon can read the wall');
select pg_temp.must(not exists (select 1 from pg_proc where proname = 'get_wall' and pronargs = 4), 'old 4-argument get_wall is gone (no ambiguous overload)');

rollback;
\echo ALL WALL SEARCH ASSERTIONS PASSED
