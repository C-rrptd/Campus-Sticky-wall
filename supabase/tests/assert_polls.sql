-- Migration 021 assertions: polls, quizzes, Spotify link, answer_poll.
-- Run as a superuser after 001-021 and stub_auth.sql.
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
-- Creates, pays and publishes one note with a poll / Spotify id; returns its id.
create function pg_temp.pub(txt text, p jsonb, sp text) returns uuid language plpgsql as $$
declare v jsonb; oid uuid;
begin
  v := public.create_publication_order_v3(null, 'Rani', txt, 'yellow', null, false, '2500', '{}', false,
         encode(sha256(gen_random_uuid()::text::bytea), 'hex'), null, null, false, 0, null, null, false, false, p, sp);
  select id into oid from public.orders where order_ref = v ->> 'order_ref';
  update public.orders set status = 'paid', paid_at = now() where id = oid;
  perform public.fulfill_order(oid);
  return (select id from public.notes where order_id = oid);
end $$;
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, true) $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000e1', 'e1@t.id', now()), ('00000000-0000-0000-0000-0000000000e2', 'e2@t.id', now());

create temp table ids as
  select pg_temp.pub('Best food?', '{"kind":"poll","multi":false,"options":["Bakso"," Soto ","Nasi goreng"]}', null) as single,
         pg_temp.pub('Pick all that apply', '{"kind":"poll","multi":true,"options":["A","B","C"]}', 'track/4uLU6hMCjMI75M1A2tKUQC') as multi,
         pg_temp.pub('2 + 2?', '{"kind":"quiz","multi":false,"options":["3","4","5"],"correct":[1]}', null) as quiz,
         pg_temp.pub('Plain note', null, null) as plain;

-- ---- stored shape ----
select pg_temp.must((select poll -> 'options' ->> 1 from public.notes where id = (select single from ids)) = 'Soto', 'options are trimmed');
select pg_temp.must((select spotify from public.notes where id = (select multi from ids)) = 'track/4uLU6hMCjMI75M1A2tKUQC', 'spotify stored');
select pg_temp.must((select poll is null and poll_answer is null and spotify is null from public.notes where id = (select plain from ids)), 'plain note untouched');
select pg_temp.must((select poll_answer from public.notes where id = (select quiz from ids)) = '{1}', 'quiz answer stored apart from the poll');

-- ---- validation ----
select pg_temp.expect_err($$select pg_temp.pub('x', '{"kind":"poll","options":["only"]}', null)$$, 'INVALID_POLL');
select pg_temp.expect_err($$select pg_temp.pub('x', '{"kind":"poll","options":["a","b","c","d","e","f","g"]}', null)$$, 'INVALID_POLL');
select pg_temp.expect_err($$select pg_temp.pub('x', '{"kind":"poll","options":["a","A"]}', null)$$, 'INVALID_POLL');
select pg_temp.expect_err($$select pg_temp.pub('x', '{"kind":"poll","options":["a",""]}', null)$$, 'INVALID_POLL');
select pg_temp.expect_err($$select pg_temp.pub('x', '{"kind":"vote","options":["a","b"]}', null)$$, 'INVALID_POLL');
select pg_temp.expect_err($$select pg_temp.pub('x', '{"kind":"quiz","options":["a","b"]}', null)$$, 'INVALID_POLL');
select pg_temp.expect_err($$select pg_temp.pub('x', '{"kind":"quiz","multi":false,"options":["a","b"],"correct":[0,1]}', null)$$, 'INVALID_POLL');
select pg_temp.expect_err($$select pg_temp.pub('x', '{"kind":"quiz","options":["a","b"],"correct":[5]}', null)$$, 'INVALID_POLL');
select pg_temp.expect_err($$select pg_temp.pub('x', null, 'https://evil.example/track/4uLU6hMCjMI75M1A2tKUQC')$$, 'INVALID_SPOTIFY');
select pg_temp.expect_err($$select pg_temp.pub('x', null, 'track/short')$$, 'INVALID_SPOTIFY');
select pg_temp.must((select count(*) from public.notes) = 4, 'rejected posts leave no note behind');

-- ---- answering ----
select pg_temp.must(public.get_note((select single from ids)) -> 'poll' -> 'counts' = '[0,0,0]', 'poll shows zero counts before anyone answers');
select pg_temp.expect_err(format($$select public.answer_poll(%L, '{0}')$$, (select single from ids)), 'ACCOUNT_REQUIRED');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select pg_temp.must(public.answer_poll((select single from ids), '{1}') -> 'counts' = '[0,1,0]', 'answer counted');
select pg_temp.must(public.get_note((select single from ids)) -> 'poll' -> 'mine' = '[1]', 'viewer sees own answer');
select pg_temp.expect_err(format($$select public.answer_poll(%L, '{2}')$$, (select single from ids)), 'ALREADY_ANSWERED');
select pg_temp.expect_err(format($$select public.answer_poll(%L, '{0,2}')$$, (select single from ids)), 'INVALID_POLL');
select pg_temp.expect_err(format($$select public.answer_poll(%L, '{9}')$$, (select multi from ids)), 'INVALID_POLL');
select pg_temp.expect_err(format($$select public.answer_poll(%L, '{1,1}')$$, (select multi from ids)), 'INVALID_POLL');
select pg_temp.expect_err(format($$select public.answer_poll(%L, '{0}')$$, (select plain from ids)), 'INVALID_POLL');
select pg_temp.must(public.answer_poll((select multi from ids), '{2,0}') -> 'counts' = '[1,0,1]', 'multiple answers counted per option');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
select pg_temp.must(public.answer_poll((select single from ids), '{1}') -> 'counts' = '[0,2,0]', 'second voter adds up');

-- ---- quiz hides counts and the answer until answered ----
select pg_temp.must(not (public.get_note((select quiz from ids)) -> 'poll' ? 'correct') and not (public.get_note((select quiz from ids)) -> 'poll' ? 'counts'),
                    'unanswered quiz leaks neither counts nor answer');
select pg_temp.must(public.answer_poll((select quiz from ids), '{0}') -> 'correct' = '[1]', 'answering a quiz reveals the answer');
select pg_temp.as_user('');
select pg_temp.must(not (public.get_note((select quiz from ids)) -> 'poll' ? 'correct'), 'anonymous viewer still has no answer');

-- ---- 022 hardening ----
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000e3', 'e3@t.id');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e3');
select pg_temp.expect_err(format($$select public.answer_poll(%L, '{0}')$$, (select plain from ids)), 'EMAIL_NOT_VERIFIED');

-- ---- privileges ----
select pg_temp.must(not has_column_privilege('authenticated', 'public.notes', 'poll_answer', 'select'), 'poll_answer is not readable by clients');
select pg_temp.must(not has_table_privilege('authenticated', 'public.poll_votes', 'select'), 'poll_votes is not readable by clients');
select pg_temp.must(has_function_privilege('authenticated', 'public.answer_poll(uuid,int[])', 'execute'), 'members can answer');
select pg_temp.must(not has_function_privilege('anon', 'public.answer_poll(uuid,int[])', 'execute'), 'anon cannot answer');
select pg_temp.must(not has_function_privilege('authenticated', 'public.create_publication_order_v3(uuid,text,text,text,text,boolean,text,text[],boolean,text,uuid,jsonb,boolean,int,jsonb,text,boolean,boolean,jsonb,text)', 'execute'), 'v3 is service-role only');

rollback;
\echo ALL POLL ASSERTIONS PASSED
