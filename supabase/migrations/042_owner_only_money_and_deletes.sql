-- 042_owner_only_money_and_deletes.sql
-- Admins keep content/people work. These money-setting and irreversible actions become owner-only.
-- The functions are rewritten in place (require_admin() -> require_owner()), so bodies, signatures and grants stay.
-- Safe to re-run: a function already owner-only is skipped.
do $$
declare r record; v_def text;
begin
  for r in
    select p.oid::regprocedure as fn, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('admin_delete_user', 'admin_set_config', 'admin_upsert_ad_product',
                         'admin_upsert_payment_method', 'admin_set_slot_config', 'admin_decide_price_proposal')
  loop
    v_def := pg_get_functiondef(r.fn);
    if position('public.require_admin()' in v_def) = 0 then
      if position('public.require_owner()' in v_def) = 0 then
        raise exception 'no role check found in %', r.fn;
      end if;
      continue;
    end if;
    execute replace(v_def, 'public.require_admin()', 'public.require_owner()');
  end loop;
end $$;

-- Owner gate for edge-function actions that touch the payment provider / ad jobs (like admin_check, for owners).
create or replace function public.owner_check() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_owner();
end $$;
revoke execute on function public.owner_check() from public, anon;
grant execute on function public.owner_check() to authenticated, service_role;
