-- 040_roles_on_profiles.sql
-- Moves roles from the separate user_roles table onto public.profiles.role
-- ('member' | 'admin' | 'owner', default 'member'), then drops user_roles.
-- Clients still cannot write the column: profiles only grants UPDATE on named
-- columns (002/004/037) and role is not one of them. Role changes go through
-- admin_set_user_role(), which is owner-only and audited.
-- Safe to re-run.

-- 1. Column + backfill (owner wins over admin; everyone else stays 'member') ---------------------------------
alter table public.profiles add column if not exists role text not null default 'member';
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('member', 'admin', 'owner'));

do $$ begin
  if to_regclass('public.user_roles') is not null then
    update public.profiles p
       set role = case when exists (select 1 from public.user_roles r where r.user_id = p.id and r.role = 'owner')
                       then 'owner' else 'admin' end
     where exists (select 1 from public.user_roles r where r.user_id = p.id);
  end if;
end $$;

-- 2. Role checks read profiles.role (same signatures, so every policy and grant keeps working) ---------------
create or replace function public.is_admin(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user is not null and exists (
    select 1 from public.profiles p where p.id = p_user and p.role in ('admin', 'owner'))
$$;

create or replace function public.is_owner(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user is not null and exists (
    select 1 from public.profiles p where p.id = p_user and p.role = 'owner')
$$;

-- 3. Old table goes away (its RLS policy and grants go with it) ---------------------------------------------
drop table if exists public.user_roles;

-- 4. Admin user list now returns the role -------------------------------------------------------------------
create or replace function public.admin_list_users(p_search text default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select p.id, p.display_name, u.email, u.email_confirmed_at is not null as email_verified, p.suspended_at,
           p.suspension_reason, p.created_at, p.role, public.is_admin(p.id) as is_admin,
           (select count(*) from public.notes n where n.author_id = p.id and n.status = 'published') as published_notes
      from public.profiles p join auth.users u on u.id = p.id
     where p_search is null or p.display_name ilike '%' || p_search || '%' or u.email ilike '%' || p_search || '%'
     order by p.created_at desc
     limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) x), '[]'::jsonb);
end $$;

-- 5. Owner-only role assignment ------------------------------------------------------------------------------
-- An owner cannot change their own role, so the site can never be left without an owner.
create or replace function public.admin_set_user_role(p_user_id uuid, p_role text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_owner uuid := public.require_owner(); v_old text;
begin
  if p_role is null or p_role not in ('member', 'admin', 'owner') then
    perform public.app_error('CSW40', 'INVALID_ROLE', 'Role must be member, admin or owner.');
  end if;
  if p_user_id = v_owner then
    perform public.app_error('CSW40', 'CANNOT_CHANGE_OWN_ROLE', 'You cannot change your own role.');
  end if;
  select role into v_old from public.profiles where id = p_user_id for update;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  update public.profiles set role = p_role where id = p_user_id;
  perform public.audit('user.role', 'user', p_user_id::text, null, jsonb_build_object('from', v_old, 'to', p_role));
  return jsonb_build_object('id', p_user_id, 'role', p_role);
end $$;

revoke execute on function public.admin_set_user_role(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_set_user_role(uuid, text) to service_role, authenticated;
