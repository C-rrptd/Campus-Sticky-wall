-- Migration 053 (avatar paths). Run after 001-053 + stub_auth.sql.
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

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000e1', 'e1@t.id', now()), ('00000000-0000-0000-0000-0000000000e2', 'e2@t.id', now());

-- 053: avatar must be a path inside the member's own folder
update public.profiles set avatar_url = '00000000-0000-0000-0000-0000000000e1/11111111-1111-1111-1111-111111111111.gif' where id = '00000000-0000-0000-0000-0000000000e1';
select pg_temp.expect_err($$update public.profiles set avatar_url = 'https://evil.example/a.png' where id = '00000000-0000-0000-0000-0000000000e1'$$, 'profiles_avatar_path_check');
select pg_temp.expect_err($$update public.profiles set avatar_url = '00000000-0000-0000-0000-0000000000e2/11111111-1111-1111-1111-111111111111.png' where id = '00000000-0000-0000-0000-0000000000e1'$$, 'profiles_avatar_path_check');
select pg_temp.expect_err($$update public.profiles set avatar_url = '00000000-0000-0000-0000-0000000000e1/11111111-1111-1111-1111-111111111111.svg' where id = '00000000-0000-0000-0000-0000000000e1'$$, 'profiles_avatar_path_check');
update public.profiles set avatar_url = null where id = '00000000-0000-0000-0000-0000000000e1';

select 'avatars: ok';
delete from auth.users where id::text like '00000000-0000-0000-0000-0000000000e%';
