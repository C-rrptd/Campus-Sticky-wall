-- Migration 040 assertions: roles live in profiles.role, default 'member', only an owner can change them.
-- Run as a superuser after 001-040 and stub_auth.sql.
\set ON_ERROR_STOP on
begin;
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, true) $$;
create function pg_temp.fails(stmt text, code text) returns void language plpgsql as $$
begin
  begin execute stmt; exception when others then
    if sqlerrm like '%' || code || '%' then return; end if;
    raise exception 'expected %, got: %  [%]', code, sqlerrm, stmt;
  end;
  raise exception 'expected % but statement succeeded: %', code, stmt;
end $$;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000e1', 'owner@t.id', now()),
  ('00000000-0000-0000-0000-0000000000e2', 'admin@t.id', now()),
  ('00000000-0000-0000-0000-0000000000e3', 'member@t.id', now());
update public.profiles set role = 'owner' where id = '00000000-0000-0000-0000-0000000000e1';
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000e2';

select pg_temp.must(to_regclass('public.user_roles') is null, 'user_roles still exists');
select pg_temp.must((select role from public.profiles where id = '00000000-0000-0000-0000-0000000000e3') = 'member', 'new profile is not member by default');
select pg_temp.must(public.is_owner('00000000-0000-0000-0000-0000000000e1') and public.is_admin('00000000-0000-0000-0000-0000000000e1'), 'owner is not owner+admin');
select pg_temp.must(public.is_admin('00000000-0000-0000-0000-0000000000e2') and not public.is_owner('00000000-0000-0000-0000-0000000000e2'), 'admin role wrong');
select pg_temp.must(not public.is_admin('00000000-0000-0000-0000-0000000000e3'), 'member counts as admin');

-- a signed-in client cannot grant itself a role
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e3');
select pg_temp.fails($$update public.profiles set role = 'owner' where id = '00000000-0000-0000-0000-0000000000e3'$$, 'permission denied');
select pg_temp.fails($$select public.admin_set_user_role('00000000-0000-0000-0000-0000000000e3', 'admin')$$, 'FORBIDDEN');
-- ...and can read its own role
select pg_temp.must((select role from public.profiles where id = '00000000-0000-0000-0000-0000000000e3') = 'member', 'member cannot read own role');

-- an admin is not enough
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
select pg_temp.fails($$select public.admin_set_user_role('00000000-0000-0000-0000-0000000000e3', 'admin')$$, 'FORBIDDEN');

-- the owner assigns roles (state is checked as superuser: is_admin() is not client-callable)
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select public.admin_set_user_role('00000000-0000-0000-0000-0000000000e3', 'admin');
select pg_temp.must(exists (select 1 from jsonb_array_elements(public.admin_list_users()) u
                             where u->>'id' = '00000000-0000-0000-0000-0000000000e3' and u->>'role' = 'admin'), 'admin_list_users hides role');
reset role;
select pg_temp.must(public.is_admin('00000000-0000-0000-0000-0000000000e3'), 'role not assigned');
set local role authenticated;
select public.admin_set_user_role('00000000-0000-0000-0000-0000000000e3', 'member');
select pg_temp.fails($$select public.admin_set_user_role('00000000-0000-0000-0000-0000000000e3', 'root')$$, 'INVALID_ROLE');
select pg_temp.fails($$select public.admin_set_user_role('00000000-0000-0000-0000-0000000000e1', 'member')$$, 'CANNOT_CHANGE_OWN_ROLE');
select pg_temp.fails($$select public.admin_set_user_role(gen_random_uuid(), 'admin')$$, 'NOT_FOUND');
reset role;
select pg_temp.must(not public.is_admin('00000000-0000-0000-0000-0000000000e3'), 'role not removed');
select pg_temp.must((select count(*) from public.admin_audit_log where action = 'user.role') = 2, 'role changes not audited');

rollback;
select 'assert_roles_on_profiles OK';
