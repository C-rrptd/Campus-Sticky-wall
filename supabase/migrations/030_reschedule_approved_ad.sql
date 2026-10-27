-- 030_reschedule_approved_ad.sql
-- An approved, unpaid ad whose requested start date has passed lets its owner pick a new start date (today .. +14 days).
-- Content is unchanged, so it stays approved (no re-review). Additive; safe to re-run.
create or replace function public.reschedule_my_campaign(p_campaign_id uuid, p_new_start date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_today date := (now() at time zone 'Asia/Jakarta')::date; v_c public.campaigns;
begin
  if v_uid is null then perform public.app_error('CSW03', 'AUTH_REQUIRED'); end if;
  select * into v_c from public.campaigns where id = p_campaign_id and owner_id = v_uid for update;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  if v_c.status <> 'approved' or v_c.requested_start >= v_today then
    perform public.app_error('CSW09', 'NOT_RESCHEDULABLE', 'Only an approved, unpaid ad whose start date has passed can be given a new date.');
  end if;
  if p_new_start is null or p_new_start < v_today or p_new_start > v_today + 14 then
    perform public.app_error('CSW40', 'INVALID_START', 'Pick a start date within the next 14 days.');
  end if;
  update public.campaigns set requested_start = p_new_start where id = v_c.id;
  return jsonb_build_object('id', v_c.id, 'requested_start', p_new_start);
end $$;
revoke execute on function public.reschedule_my_campaign(uuid, date) from public, anon;
grant execute on function public.reschedule_my_campaign(uuid, date) to authenticated, service_role;
