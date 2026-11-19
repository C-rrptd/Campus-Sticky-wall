-- Notifications (migration 050). Run after 001-050 + stub_auth.sql.
-- No wrapping transaction: counts depend on now() differing between statements, so each statement commits. Cleans up at the end.
\set ON_ERROR_STOP on
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
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
create function pg_temp.unread() returns int language sql as $$ select (public.my_notifications() ->> 'unread')::int $$;
create function pg_temp.items() returns jsonb language sql as $$ select public.my_notifications() -> 'items' $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000d1', 'd1@t.id', now()), ('00000000-0000-0000-0000-0000000000d2', 'd2@t.id', now()),
  ('00000000-0000-0000-0000-0000000000d3', 'd3@t.id', now());
insert into public.notes (id, author_id, body, status, published_at, author_name, publication_amount) values
  ('aaaaaaaa-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d1', 'author note', 'published', now(), 'A', 5000),
  ('aaaaaaaa-0000-0000-0000-0000000000d2', null, 'guest note', 'published', now(), 'G', 5000),
  ('aaaaaaaa-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000d1', 'hidden note', 'pending_moderation', null, 'A', 5000);

-- grants: no table access, functions only for signed-in members
select pg_temp.must(not has_table_privilege('authenticated', 'public.notifications', 'select'), 'no table select for members');
select pg_temp.must(not has_table_privilege('anon', 'public.notifications', 'select'), 'no table select for anon');
select pg_temp.must(has_function_privilege('authenticated', 'public.my_notifications(int)', 'execute'), 'members may list');
select pg_temp.must(not has_function_privilege('anon', 'public.my_notifications(int)', 'execute'), 'anon may not list');
select pg_temp.must(not has_function_privilege('authenticated', 'public.notify_upvote()', 'execute'), 'trigger fn is not callable');

-- first upvote notifies the author; no voter identity in the payload
insert into public.votes (note_id, user_id) values ('aaaaaaaa-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select pg_temp.must(pg_temp.unread() = 1, 'one unread after first upvote');
select pg_temp.must((pg_temp.items() -> 0 ->> 'count')::int = 1 and pg_temp.items() -> 0 -> 'note' ->> 'snippet' = 'author note', 'item shows count and snippet');
select pg_temp.must(pg_temp.items()::text !~ '0000000000d2', 'voter is not exposed');
select pg_temp.must(public.unread_notification_count() = 1, 'badge count matches');

-- more votes fold into the same row
insert into public.votes (note_id, user_id) values ('aaaaaaaa-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d3');
select pg_temp.must(pg_temp.unread() = 1 and (pg_temp.items() -> 0 ->> 'count')::int = 2, 'still one row, count 2');

-- self votes, guest notes and unpublished notes never notify
insert into public.votes (note_id, user_id) values ('aaaaaaaa-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d1');
insert into public.votes (note_id, user_id) values ('aaaaaaaa-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d2');
insert into public.votes (note_id, user_id) values ('aaaaaaaa-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000d2');
select pg_temp.must((select count(*) from public.notifications) = 1, 'only the first upvote made a row');
select pg_temp.must((pg_temp.items() -> 0 ->> 'count')::int = 2, 'the author''s own vote is not counted');

-- unvotes lower the count; a row with no votes left disappears
delete from public.votes where note_id = 'aaaaaaaa-0000-0000-0000-0000000000d1' and user_id = '00000000-0000-0000-0000-0000000000d2';
select pg_temp.must((pg_temp.items() -> 0 ->> 'count')::int = 1, 'unvote lowers the count');
delete from public.votes where note_id = 'aaaaaaaa-0000-0000-0000-0000000000d1' and user_id = '00000000-0000-0000-0000-0000000000d3';
select pg_temp.must(pg_temp.unread() = 0 and jsonb_array_length(pg_temp.items()) = 0, 'no votes left: no badge, no item');

-- a re-vote brings the same unread row back
insert into public.votes (note_id, user_id) values ('aaaaaaaa-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2');
select pg_temp.must(pg_temp.unread() = 1 and (pg_temp.items() -> 0 ->> 'count')::int = 1, 're-vote shows one upvote');

-- mark read by id
select pg_sleep(0.02);
select public.mark_notifications_read(array[(pg_temp.items() -> 0 ->> 'id')::uuid]);
select pg_temp.must(pg_temp.unread() = 0 and (pg_temp.items() -> 0 ->> 'read')::boolean and (pg_temp.items() -> 0 ->> 'count')::int = 1, 'read row stays, count frozen by read_at');

-- a vote after reading opens a new row; the read row keeps its own count
select pg_sleep(0.02);
insert into public.votes (note_id, user_id) values ('aaaaaaaa-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d3');
select pg_temp.must(pg_temp.unread() = 1 and jsonb_array_length(pg_temp.items()) = 2, 'new unread row beside the read one');
select pg_temp.must((pg_temp.items() -> 0 ->> 'count')::int = 1 and not (pg_temp.items() -> 0 ->> 'read')::boolean and (pg_temp.items() -> 1 ->> 'count')::int = 1, 'each row counts only its own window');

-- other members see nothing of it and cannot clear it
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
select pg_temp.must(pg_temp.unread() = 0 and jsonb_array_length(pg_temp.items()) = 0, 'other member sees nothing');
select public.mark_notifications_read();
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select pg_temp.must(pg_temp.unread() = 1, 'another member cannot mark mine read');

-- signed out
select pg_temp.as_user('');
select pg_temp.expect_err($$select public.mark_notifications_read()$$, 'UNAUTHENTICATED');
select pg_temp.must(pg_temp.unread() = 0 and jsonb_array_length(pg_temp.items()) = 0, 'signed out sees nothing');

-- a removed note keeps the row but loses its snippet and link
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
update public.notes set status = 'removed' where id = 'aaaaaaaa-0000-0000-0000-0000000000d1';
select pg_temp.must(pg_temp.items() -> 0 -> 'note' = 'null'::jsonb or pg_temp.items() -> 0 -> 'note' is null, 'removed note: no snippet');
update public.notes set status = 'published' where id = 'aaaaaaaa-0000-0000-0000-0000000000d1';

-- read rows older than 30 days are pruned on the next mark
update public.notifications set read_at = now() - interval '40 days' where read_at is not null;
select public.mark_notifications_read();
select pg_temp.must((select count(*) from public.notifications where read_at < now() - interval '30 days') = 0, 'old read rows pruned');
select pg_temp.must(pg_temp.unread() = 0, 'mark all read');

-- cleanup
delete from public.notes where id in ('aaaaaaaa-0000-0000-0000-0000000000d1', 'aaaaaaaa-0000-0000-0000-0000000000d2', 'aaaaaaaa-0000-0000-0000-0000000000d3');
delete from auth.users where id in ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d3');
select 'notifications: ok';
