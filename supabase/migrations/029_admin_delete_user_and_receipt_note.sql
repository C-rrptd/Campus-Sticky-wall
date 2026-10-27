-- 029_admin_delete_user_and_receipt_note.sql
-- Admin AND Owner (require_admin() accepts both; members and guests are rejected):
--   1. admin_delete_user_preview / admin_delete_user: delete an account and everything tied to it
--      (profile, votes, bookmarks, reports, referral data, credits, campaigns, and all of its notes with their media).
--      Order and payment rows stay for accounting; they are detached from the account (user_id -> null).
--      Admins and the Owner cannot be deleted here; you cannot delete yourself.
--   2. admin_find_note_by_receipt / admin_delete_note_by_receipt: look a note up by receipt ID (order ref) and delete
--      it, for guest notes (and any other publication order). The order and payment record stay.
-- Additive; safe to re-run.

create or replace function public.admin_delete_user_preview(p_user_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_name text; v_live int;
begin
  perform public.require_admin();
  select display_name into v_name from public.profiles where id = p_user_id;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND', 'Account not found.'); end if;
  select count(*) into v_live from public.campaigns where owner_id = p_user_id and status in ('active', 'awaiting_payment');
  return jsonb_build_object(
    'display_name', v_name,
    'is_admin', public.is_admin(p_user_id),
    'notes', (select count(*) from public.notes where author_id = p_user_id),
    'votes', (select count(*) from public.votes where user_id = p_user_id),
    'bookmarks', (select count(*) from public.bookmarks where user_id = p_user_id),
    'campaigns', (select count(*) from public.campaigns where owner_id = p_user_id),
    'live_campaigns', v_live,
    'orders_kept', (select count(*) from public.orders where user_id = p_user_id));
end $$;

create or replace function public.admin_delete_user(p_user_id uuid, p_confirm text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_name text; v_notes int; v_snap jsonb;
begin
  if p_confirm is distinct from 'DELETE' then
    perform public.app_error('CSW40', 'CONFIRM_REQUIRED', 'Type DELETE to confirm.');
  end if;
  if p_user_id = v_admin then perform public.app_error('CSW40', 'CANNOT_DELETE_SELF', 'You cannot delete your own account here.'); end if;
  if public.is_admin(p_user_id) then
    perform public.app_error('CSW03', 'FORBIDDEN', 'Admin and Owner accounts cannot be deleted here. Remove their role first.');
  end if;
  select display_name into v_name from public.profiles where id = p_user_id for update;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND', 'Account not found.'); end if;
  if exists (select 1 from public.campaigns where owner_id = p_user_id and status in ('active', 'awaiting_payment')) then
    perform public.app_error('CSW09', 'CAMPAIGN_IN_USE', 'This account has a live or unpaid campaign. Cancel it first.');
  end if;
  -- Notes first: the delete trigger queues their media files for Storage cleanup.
  delete from public.notes where author_id = p_user_id;
  get diagnostics v_notes = row_count;
  v_snap := jsonb_build_object('display_name', v_name, 'notes_deleted', v_notes);  -- no email: keep PII out of the log
  -- Everything else (profile, votes, bookmarks, reports, referrals, credits, campaigns, roles) cascades from auth.users.
  delete from auth.users where id = p_user_id;
  insert into public.security_events (actor_id, action, target_type, target_id, details)
  values (v_admin, 'admin.delete_user', 'user', p_user_id::text, v_snap);
  perform public.audit('admin.delete_user', 'user', p_user_id::text, null, v_snap);
  return jsonb_build_object('deleted', true, 'id', p_user_id) || v_snap;
end $$;

create or replace function public.admin_find_note_by_receipt(p_order_ref text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_o public.orders; v_n public.notes;
begin
  perform public.require_admin();
  select * into v_o from public.orders where order_ref = btrim(p_order_ref) and kind = 'publication';
  if not found then perform public.app_error('CSW04', 'NOT_FOUND', 'No note order with that receipt ID.'); end if;
  select * into v_n from public.notes where order_id = v_o.id;
  return jsonb_build_object(
    'order_ref', v_o.order_ref, 'order_status', v_o.status, 'total_amount', v_o.total_amount,
    'is_guest', v_o.user_id is null,
    'note', case when v_n.id is null then null else jsonb_build_object(
      'id', v_n.id, 'status', v_n.status, 'author_name', v_n.author_name, 'body', left(v_n.body, 200), 'created_at', v_n.created_at) end);
end $$;

create or replace function public.admin_delete_note_by_receipt(p_order_ref text, p_confirm text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_o public.orders; v_status text; v_snap jsonb;
begin
  if p_confirm is distinct from 'DELETE' then
    perform public.app_error('CSW40', 'CONFIRM_REQUIRED', 'Type DELETE to confirm.');
  end if;
  select * into v_o from public.orders where order_ref = btrim(p_order_ref) and kind = 'publication';
  if not found then perform public.app_error('CSW04', 'NOT_FOUND', 'No note order with that receipt ID.'); end if;
  delete from public.notes where order_id = v_o.id returning status into v_status;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND', 'This order has no note (already deleted?).'); end if;
  v_snap := jsonb_build_object('order_ref', v_o.order_ref, 'status', v_status, 'guest', v_o.user_id is null);
  insert into public.security_events (actor_id, action, target_type, target_id, details)
  values (v_admin, 'admin.delete_note_by_receipt', 'note', v_o.order_ref, v_snap);
  perform public.audit('admin.delete_note_by_receipt', 'note', v_o.order_ref, null, v_snap);
  return jsonb_build_object('deleted', true) || v_snap;
end $$;

revoke execute on function public.admin_delete_user_preview(uuid), public.admin_delete_user(uuid, text),
  public.admin_find_note_by_receipt(text), public.admin_delete_note_by_receipt(text, text) from public, anon, authenticated;
grant execute on function public.admin_delete_user_preview(uuid), public.admin_delete_user(uuid, text),
  public.admin_find_note_by_receipt(text), public.admin_delete_note_by_receipt(text, text) to authenticated, service_role;
