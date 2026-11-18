-- Daily digest + suggestions (migration 046). Run after 001-046 + stub_auth.sql.
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

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000c1', 'c1@t.id', now()), ('00000000-0000-0000-0000-0000000000c2', 'c2@t.id', now());

-- digest: yesterday's top note by votes cast in the previous local day (Asia/Jakarta default)
insert into public.notes (id, body, status, published_at, author_name, publication_amount) values
  ('11111111-1111-1111-1111-111111111111', 'top note', 'published', now() - interval '3 days', 'A', 5000),
  ('22222222-2222-2222-2222-222222222222', 'other note', 'published', now() - interval '3 days', 'B', 5000);
-- fixed clock: 2026-03-10 01:30 UTC = 08:30 WIB; "yesterday" = 2026-03-09 WIB
insert into public.votes (note_id, user_id, created_at) values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-0000000000c1', '2026-03-09 10:00+07'),
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-0000000000c2', '2026-03-09 23:00+07'),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-0000000000c1', '2026-03-09 12:00+07'),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-0000000000c2', '2026-03-10 07:00+07');  -- today: not counted
select pg_temp.must((select count(*) from public.digest_claim(100, '2026-03-10 00:30+00')) = 0, 'before 8 AM local: nobody due');
select pg_temp.must((select count(*) from public.digest_claim(100, '2026-03-10 05:30+00')) = 0, 'after 11 AM local window: nobody due');
select pg_temp.must((select count(*) from public.digest_claim(100, '2026-03-10 01:30+00') c where c.note_id = '11111111-1111-1111-1111-111111111111' and c.votes = 2) >= 2, 'at 8:30 WIB both members get the top note of yesterday');
select pg_temp.must((select count(*) from public.digest_claim(100, '2026-03-10 02:00+00')) = 0, 'claimed once per local day');

-- opt-out
update public.profiles set last_digest_on = null where id in ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c2');
select public.set_digest_for('00000000-0000-0000-0000-0000000000c2', false);
select pg_temp.must((select count(*) from public.digest_claim(100, '2026-03-10 01:30+00') c where c.user_id = '00000000-0000-0000-0000-0000000000c2') = 0, 'opted-out member skipped');


-- suggestions
select pg_temp.expect_err($$select public.submit_suggestion('feature', 'Dark mode', 'Please add a dark mode option.')$$, 'UNAUTHENTICATED');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.expect_err($$select public.submit_suggestion('nope', 'Dark mode', 'Please add a dark mode option.')$$, 'INVALID_KIND');
select pg_temp.expect_err($$select public.submit_suggestion('feature', 'ab', 'Please add a dark mode option.')$$, 'INVALID_TITLE');
select pg_temp.expect_err($$select public.submit_suggestion('feature', 'Dark mode', 'short')$$, 'INVALID_BODY');
select pg_temp.expect_err($$select public.submit_suggestion('feature', 'Dark mode', 'Please add a dark mode option.', '00000000-0000-0000-0000-0000000000c1/00000000-0000-0000-0000-000000000001.png')$$, 'INVALID_ATTACHMENT');
select pg_temp.expect_err($$select public.submit_suggestion('decoration', 'Neon frame', 'A neon frame with glow.', '00000000-0000-0000-0000-0000000000c2/00000000-0000-0000-0000-000000000001.png')$$, 'INVALID_ATTACHMENT');
select public.submit_suggestion('decoration', 'Neon frame', 'A neon frame with glow.', '00000000-0000-0000-0000-0000000000c1/00000000-0000-0000-0000-000000000001.png');
select public.submit_suggestion('feature', 'Dark mode', 'Please add a dark mode option.');
select public.submit_suggestion('bug', 'Broken link', 'The profile link is broken on mobile.');
select public.submit_suggestion('other', 'Hello there', 'Just saying that I like the site.');
select public.submit_suggestion('other', 'Hello again', 'Just saying that I like the site.');
select pg_temp.expect_err($$select public.submit_suggestion('other', 'Sixth one', 'Sixth suggestion in one day.')$$, 'RATE_LIMITED');
select pg_temp.must(jsonb_array_length(public.my_suggestions()) = 5, 'member sees own suggestions');
select pg_temp.expect_err($$select public.admin_list_suggestions(null, 50)$$, 'FORBIDDEN');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c2');
select pg_temp.must(jsonb_array_length(public.my_suggestions()) = 0, 'other member sees none');
reset role;
select pg_temp.must(not has_table_privilege('authenticated', 'public.suggestions', 'select'), 'no direct table read');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000c2';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c2');
select pg_temp.must(jsonb_array_length(public.admin_list_suggestions(null, 50)) = 5, 'admin lists all');
select public.admin_set_suggestion((select id from public.suggestions limit 1), 'planned', 'On the roadmap');
select pg_temp.must(jsonb_array_length(public.admin_list_suggestions('planned', 50)) = 1, 'status filter');

do $$ begin raise notice 'DIGEST + SUGGESTIONS ASSERTIONS PASSED'; end $$;
rollback;
