-- Migration 029: admin/owner delete account + delete note by receipt ID. Run after 001-029 + stub_auth.sql on an EMPTY database.
\set ON_ERROR_STOP on
begin;
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, true) $$;
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
  ('00000000-0000-0000-0000-0000000000a1', 'owner@t.id', now()), ('00000000-0000-0000-0000-0000000000a2', 'admin@t.id', now()),
  ('00000000-0000-0000-0000-0000000000a3', 'user@t.id', now()), ('00000000-0000-0000-0000-0000000000a4', 'other@t.id', now());
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'owner'), ('00000000-0000-0000-0000-0000000000a2', 'admin');
select (public.create_publication_order('00000000-0000-0000-0000-0000000000a3','U','member note','yellow',null,true,'5000','{}'::text[],false,repeat('a',64)))->>'order_ref' as o1 \gset
select (public.create_publication_order(null,'G','guest note','pink',null,true,'5000','{}'::text[],false,repeat('b',64)))->>'order_ref' as o2 \gset

-- members cannot use any of it
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a4');
select pg_temp.expect_err($$select public.admin_delete_user('00000000-0000-0000-0000-0000000000a3','DELETE')$$, 'FORBIDDEN');
select pg_temp.expect_err(format('select public.admin_find_note_by_receipt(%L)', :'o2'), 'FORBIDDEN');
select pg_temp.expect_err(format('select public.admin_delete_note_by_receipt(%L,%L)', :'o2', 'DELETE'), 'FORBIDDEN');

-- admin: guest note by receipt ID
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
do $$ begin assert (select (public.admin_find_note_by_receipt((select order_ref from public.orders where user_id is null limit 1)) ->> 'is_guest')::boolean), 'guest flag'; end $$;
select pg_temp.expect_err(format('select public.admin_delete_note_by_receipt(%L,%L)', :'o2', 'no'), 'CONFIRM_REQUIRED');
select public.admin_delete_note_by_receipt(:'o2', 'DELETE');
do $$ begin assert (select count(*) from public.notes where body = 'guest note') = 0, 'guest note gone'; assert (select count(*) from public.orders where user_id is null) = 1, 'order kept'; end $$;
select pg_temp.expect_err(format('select public.admin_delete_note_by_receipt(%L,%L)', :'o2', 'DELETE'), 'NOT_FOUND');

-- admin: delete account; cannot delete admin/owner/self
select pg_temp.expect_err($$select public.admin_delete_user('00000000-0000-0000-0000-0000000000a1','DELETE')$$, 'FORBIDDEN');
select pg_temp.expect_err($$select public.admin_delete_user('00000000-0000-0000-0000-0000000000a2','DELETE')$$, 'CANNOT_DELETE_SELF');
select public.admin_delete_user('00000000-0000-0000-0000-0000000000a3', 'DELETE');
do $$ begin
  assert not exists (select 1 from auth.users where id = '00000000-0000-0000-0000-0000000000a3'), 'user gone';
  assert not exists (select 1 from public.profiles where id = '00000000-0000-0000-0000-0000000000a3'), 'profile gone';
  assert (select count(*) from public.notes where body = 'member note') = 0, 'member note gone';
  assert (select count(*) from public.orders where order_ref = (select 'x')) = 0 and (select count(*) from public.orders) = 2, 'orders kept';
  assert (select count(*) from public.admin_audit_log where action in ('admin.delete_user','admin.delete_note_by_receipt')) = 2, 'audited';
end $$;
select pg_temp.expect_err($$select public.admin_delete_user('00000000-0000-0000-0000-0000000000a3','DELETE')$$, 'NOT_FOUND');
rollback;
select 'ok';
