-- 006_owner_waivers_deletes_decorations.sql
-- Part 1 release. Additive: 001-005 are untouched. Safe to re-run.
--   1. Owner role (owner is a superset of admin, so every is_admin() policy keeps working)
--   2. Payment waivers (status payment_waived; never a Midtrans payment)
--   3. Owner-only permanent deletion + append-only security_events
--   4. News: last-editor attribution + input checks on the existing announcements model
--   5. Decoration catalog expansion (category column + 45 designs)
-- Referral reward changes are NOT in this migration (see release notes: product decision pending).

-- ---------------------------------------------------------------------------
-- 1. Owner role
-- ---------------------------------------------------------------------------
alter table public.user_roles drop constraint if exists user_roles_role_check;
alter table public.user_roles add constraint user_roles_role_check check (role in ('admin', 'owner'));

create or replace function public.is_admin(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user is not null and exists (
    select 1 from public.user_roles r where r.user_id = p_user and r.role in ('admin', 'owner'))
$$;

create or replace function public.is_owner(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user is not null and exists (
    select 1 from public.user_roles r where r.user_id = p_user and r.role = 'owner')
$$;

create or replace function public.require_owner() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if not public.is_owner(v_uid) then
    perform public.app_error('CSW03', 'FORBIDDEN', 'Owner access required.');
  end if;
  return v_uid;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Payment waivers
-- ---------------------------------------------------------------------------
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check check (status in
  ('awaiting_payment','challenge','paid','completed_free','payment_waived','failed','canceled','expired',
   'partially_refunded','refunded','reversed'));

create table if not exists public.payment_waivers (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders (id),
  actor_id uuid not null,
  actor_role text not null check (actor_role in ('admin', 'owner')),
  scope text not null check (scope in ('post', 'post_and_decorations')),
  waived_amount bigint not null check (waived_amount > 0),
  reason text not null check (char_length(reason) between 5 and 500),
  created_at timestamptz not null default now()
);
alter table public.payment_waivers enable row level security;
revoke all on public.payment_waivers from anon, authenticated;

-- Admin: sticky-post orders with no paid decorations. Owner: any first-party
-- publication order (post + decorations). Advertising and donations are never
-- waivable. Only before a Midtrans session exists, so a waived order can never
-- also be paid. No provider reference is created; revenue reports count only
-- paid/refunded statuses, so waived orders never appear as collected revenue.
create or replace function public.admin_waive_order(p_order_ref text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public.require_admin();
  v_owner boolean := public.is_owner(v_uid);
  v_reason text := btrim(coalesce(p_reason, ''));
  o public.orders;
begin
  if char_length(v_reason) not between 5 and 500 then
    perform public.app_error('CSW40', 'REASON_REQUIRED', 'A reason of 5-500 characters is required.');
  end if;
  select * into o from public.orders where order_ref = p_order_ref for update;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  if o.kind <> 'publication' then
    perform public.app_error('CSW09', 'WAIVER_NOT_ALLOWED', 'Payment can be waived for sticky-note publications only.');
  end if;
  if o.status <> 'awaiting_payment' or o.payment_locked_at is not null or o.payment_session_token is not null then
    perform public.app_error('CSW09', 'ORDER_NOT_WAIVABLE', 'Only unpaid orders with no payment session can be waived.');
  end if;
  if o.discount_amount <> 0 then
    perform public.app_error('CSW09', 'ORDER_NOT_WAIVABLE', 'Release the applied credit before waiving.');
  end if;
  if o.decorations_amount > 0 and not v_owner then
    perform public.app_error('CSW03', 'OWNER_REQUIRED', 'Waiving paid decorations requires the Owner.');
  end if;

  update public.orders
     set discount_amount = subtotal_amount, total_amount = 0, status = 'payment_waived', closed_at = now()
   where id = o.id;
  insert into public.payment_waivers (order_id, actor_id, actor_role, scope, waived_amount, reason)
  values (o.id, v_uid, case when v_owner then 'owner' else 'admin' end,
          case when o.decorations_amount > 0 then 'post_and_decorations' else 'post' end,
          o.subtotal_amount, v_reason);
  -- A waived post must not advertise a payment that never happened.
  update public.notes set show_amount = false where order_id = o.id;
  perform public.fulfill_order(o.id);
  perform public.audit('order.waive', 'order', o.order_ref, v_reason,
    jsonb_build_object('status', 'payment_waived', 'role', case when v_owner then 'owner' else 'admin' end,
                       'waived_amount', o.subtotal_amount::text));
  return jsonb_build_object('order_ref', o.order_ref, 'status', 'payment_waived');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Owner-only permanent deletion + append-only security events
-- ---------------------------------------------------------------------------
create table if not exists public.security_events (
  id bigint generated always as identity primary key,
  actor_id uuid not null,
  action text not null,
  target_type text not null,
  target_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.security_events enable row level security;
revoke all on public.security_events from anon, authenticated;

create or replace function public.security_events_append_only() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform public.app_error('CSW09', 'APPEND_ONLY', 'Security events cannot be changed or deleted.');
  return null;
end $$;
drop trigger if exists security_events_no_change on public.security_events;
create trigger security_events_no_change before update or delete on public.security_events
  for each row execute function public.security_events_append_only();
drop trigger if exists security_events_no_truncate on public.security_events;
create trigger security_events_no_truncate before truncate on public.security_events
  for each statement execute function public.security_events_append_only();

-- Kept when a referral entry is deleted: explains already-issued credits.
-- Credits themselves are never touched and credits(source, source_ref) stays
-- unique, so deleting the entry cannot re-issue a reward.
create table if not exists public.referral_tombstones (
  referred_user_id uuid primary key,
  referrer_id uuid,
  code text not null,
  status text not null,
  qualified_at timestamptz,
  deleted_by uuid not null,
  deleted_at timestamptz not null default now()
);
alter table public.referral_tombstones enable row level security;
revoke all on public.referral_tombstones from anon, authenticated;

-- p_kind: report | note | announcement | campaign | referral | audit_entry |
--         country | region | city | campus.  Moderation actions are rows in the
--         audit log (there is no separate table): delete them as audit_entry.
-- Payment, order, credit and entitlement rows are never deleted here.
create or replace function public.owner_delete_record(p_kind text, p_id text, p_confirm text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public.require_owner();
  v_n int := 0;
  v_snap jsonb := '{}'::jsonb;
  v_note uuid;
  v_status text;
  v_row record;
begin
  if p_confirm is distinct from 'DELETE' then
    perform public.app_error('CSW40', 'CONFIRM_REQUIRED', 'Type DELETE to confirm.');
  end if;
  if p_kind not in ('report','note','announcement','campaign','referral','audit_entry','country','region','city','campus') then
    perform public.app_error('CSW40', 'INVALID_KIND');
  end if;
  if p_id is null or char_length(p_id) not between 1 and 40 then
    perform public.app_error('CSW40', 'INVALID_ID');
  end if;
  if p_kind in ('report','note','announcement','campaign','referral','region','city','campus')
     and p_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    perform public.app_error('CSW40', 'INVALID_ID');
  end if;
  if p_kind = 'audit_entry' and p_id !~ '^[0-9]{1,18}$' then
    perform public.app_error('CSW40', 'INVALID_ID');
  end if;

  begin
    if p_kind = 'report' then
      delete from public.reports where id = p_id::uuid returning note_id, status into v_note, v_status;
      get diagnostics v_n = row_count;
      if v_n = 1 then
        update public.notes set report_count = greatest(report_count - 1, 0) where id = v_note;
        v_snap := jsonb_build_object('status', v_status, 'note_id', v_note);
      end if;
    elsif p_kind = 'note' then
      -- The order (and any payment/credit history) stays; only the post and
      -- its votes, bookmarks, reports and decoration links go.
      delete from public.notes where id = p_id::uuid returning status into v_status;
      get diagnostics v_n = row_count;
      v_snap := jsonb_build_object('status', v_status);
    elsif p_kind = 'announcement' then
      delete from public.announcements where id = p_id::uuid returning status into v_status;
      get diagnostics v_n = row_count;
      v_snap := jsonb_build_object('status', v_status);
    elsif p_kind = 'campaign' then
      select status into v_status from public.campaigns where id = p_id::uuid for update;
      if v_status in ('active', 'awaiting_payment') then
        perform public.app_error('CSW09', 'CAMPAIGN_IN_USE', 'Cancel or pause the campaign first; it is live or awaiting payment.');
      end if;
      delete from public.campaigns where id = p_id::uuid;
      get diagnostics v_n = row_count;
      v_snap := jsonb_build_object('status', v_status);
    elsif p_kind = 'referral' then
      select * into v_row from public.referral_attributions where referred_user_id = p_id::uuid for update;
      if found then
        insert into public.referral_tombstones (referred_user_id, referrer_id, code, status, qualified_at, deleted_by)
        values (v_row.referred_user_id, v_row.referrer_id, v_row.code, v_row.status, v_row.qualified_at, v_uid)
        on conflict (referred_user_id) do nothing;
        delete from public.referral_attributions where referred_user_id = p_id::uuid;
        get diagnostics v_n = row_count;
        v_snap := jsonb_build_object('status', v_row.status);
      end if;
    elsif p_kind = 'audit_entry' then
      select * into v_row from public.admin_audit_log where id = p_id::bigint for update;
      if found then
        -- Recorded in security_events below, which this function cannot delete.
        v_snap := jsonb_build_object('entry_action', v_row.action, 'entry_target_type', v_row.target_type,
                                     'entry_target_id', v_row.target_id, 'entry_created_at', v_row.created_at);
        delete from public.admin_audit_log where id = p_id::bigint;
        get diagnostics v_n = row_count;
      end if;
    elsif p_kind = 'country' then
      delete from public.countries where code = upper(p_id); get diagnostics v_n = row_count;
    elsif p_kind = 'region' then
      delete from public.regions where id = p_id::uuid; get diagnostics v_n = row_count;
    elsif p_kind = 'city' then
      delete from public.cities where id = p_id::uuid; get diagnostics v_n = row_count;
    else
      delete from public.campuses where id = p_id::uuid; get diagnostics v_n = row_count;
    end if;
  exception when foreign_key_violation then
    perform public.app_error('CSW09', 'RECORD_IN_USE', 'Other records still depend on this one. Nothing was deleted.');
  end;

  if v_n = 0 then perform public.app_error('CSW04', 'NOT_FOUND', 'Record not found (already deleted?).'); end if;
  insert into public.security_events (actor_id, action, target_type, target_id, details)
  values (v_uid, 'owner.delete', p_kind, p_id, v_snap);
  if p_kind <> 'audit_entry' then
    perform public.audit('owner.delete', p_kind, p_id, null, v_snap);
  end if;
  return jsonb_build_object('deleted', true, 'kind', p_kind, 'id', p_id);
end $$;

create or replace function public.owner_list_security_events(p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_owner();
  return coalesce((select jsonb_agg(to_jsonb(e) order by e.id desc) from (
    select * from public.security_events order by id desc limit least(greatest(p_limit, 1), 500)) e), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 4. News (the existing announcements model; public page is #/announcements)
-- ---------------------------------------------------------------------------
alter table public.announcements add column if not exists updated_by uuid;

create or replace function public.admin_upsert_announcement(p_id uuid, p_title text, p_body text, p_pinned boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_id uuid;
        v_title text := btrim(coalesce(p_title, '')); v_body text := btrim(coalesce(p_body, ''));
begin
  if public.has_control_chars(v_title) or v_title ~ '[\n\r\t]' or public.has_control_chars(v_body) then
    perform public.app_error('CSW40', 'INVALID_NEWS_TEXT', 'News text contains unsupported characters.');
  end if;
  if p_id is null then
    insert into public.announcements (title, body, pinned, created_by, updated_by)
    values (v_title, v_body, coalesce(p_pinned, false), v_admin, v_admin) returning id into v_id;
  else
    update public.announcements set title = v_title, body = v_body, pinned = coalesce(p_pinned, pinned), updated_by = v_admin
     where id = p_id returning id into v_id;
    if v_id is null then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  end if;
  perform public.audit('announcement.upsert', 'announcement', v_id::text);
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.admin_set_announcement_status(p_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin();
begin
  if p_status not in ('draft','published','archived') then perform public.app_error('CSW40', 'INVALID_STATUS'); end if;
  update public.announcements set status = p_status, updated_by = v_admin,
         published_at = case when p_status = 'published' then coalesce(published_at, now()) else published_at end
   where id = p_id;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  perform public.audit('announcement.' || p_status, 'announcement', p_id::text);
  return jsonb_build_object('id', p_id, 'status', p_status);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Decorations: category + 45 new designs (price 0 = free). Existing rows are untouched.
-- ---------------------------------------------------------------------------
alter table public.decorations add column if not exists category text not null default 'Classic';

insert into public.decorations (id, name, description, price, sort_order, render, category) values
  ('sticker-sun', 'Sunny sticker', 'A little sun in the corner', 0, 10, '{"class": "deco-sticker-sun"}'::jsonb, 'Stickers'),
  ('sticker-cat', 'Cat sticker', 'A cat peeking from the corner', 1000, 11, '{"class": "deco-sticker-cat"}'::jsonb, 'Stickers'),
  ('sticker-coffee', 'Coffee break', 'A steaming cup', 1000, 12, '{"class": "deco-sticker-coffee"}'::jsonb, 'Stickers'),
  ('sticker-rocket', 'Rocket sticker', 'Blast off', 1000, 13, '{"class": "deco-sticker-rocket"}'::jsonb, 'Stickers'),
  ('sticker-lightbulb', 'Bright idea', 'A lightbulb moment', 0, 14, '{"class": "deco-sticker-lightbulb"}'::jsonb, 'Stickers'),
  ('stamp-approved', 'Approved stamp', 'A tilted red OK stamp', 1000, 15, '{"class": "deco-stamp-approved"}'::jsonb, 'Stamps & badges'),
  ('stamp-urgent', 'Urgent label', 'A bold URGENT label', 1000, 16, '{"class": "deco-stamp-urgent"}'::jsonb, 'Stamps & badges'),
  ('badge-new', 'New badge', 'A red NEW pill', 1000, 17, '{"class": "deco-badge-new"}'::jsonb, 'Stamps & badges'),
  ('badge-star', 'Gold star badge', 'A round gold star', 2000, 18, '{"class": "deco-badge-star"}'::jsonb, 'Stamps & badges'),
  ('label-nametag', 'Name tag', 'A HELLO name tag', 1000, 19, '{"class": "deco-label-nametag"}'::jsonb, 'Stamps & badges'),
  ('corner-fold', 'Folded corner', 'A turned-down page corner', 0, 20, '{"class": "deco-corner-fold"}'::jsonb, 'Corners'),
  ('corner-photo', 'Photo corners', 'Four album-style corner marks', 1000, 21, '{"class": "deco-corner-photo"}'::jsonb, 'Corners'),
  ('frame-dashed', 'Dashed frame', 'A dashed inner frame', 0, 22, '{"class": "deco-frame-dashed"}'::jsonb, 'Frames'),
  ('frame-thick', 'Bold frame', 'A thick solid border', 1000, 23, '{"class": "deco-frame-thick"}'::jsonb, 'Frames'),
  ('frame-dotted', 'Dotted frame', 'A dotted orange frame', 1000, 24, '{"class": "deco-frame-dotted"}'::jsonb, 'Frames'),
  ('frame-offset', 'Offset shadow', 'A hard comic-style shadow', 2000, 25, '{"class": "deco-frame-offset"}'::jsonb, 'Frames'),
  ('frame-bubble', 'Soft bubble', 'Rounded, pillowy edges', 1000, 26, '{"class": "deco-frame-bubble"}'::jsonb, 'Frames'),
  ('frame-ticket', 'Ticket edge', 'Cut-out notches like a ticket', 2000, 27, '{"class": "deco-frame-ticket"}'::jsonb, 'Frames'),
  ('paper-lined', 'Lined paper', 'Notebook ruling', 0, 28, '{"class": "deco-paper-lined"}'::jsonb, 'Paper & patterns'),
  ('paper-grid', 'Graph paper', 'Light blue grid', 1000, 29, '{"class": "deco-paper-grid"}'::jsonb, 'Paper & patterns'),
  ('paper-dots', 'Dot grid', 'Bullet-journal dots', 0, 30, '{"class": "deco-paper-dots"}'::jsonb, 'Paper & patterns'),
  ('paper-kraft', 'Kraft paper', 'Speckled brown paper', 1000, 31, '{"class": "deco-paper-kraft"}'::jsonb, 'Paper & patterns'),
  ('paper-torn', 'Torn edge', 'A ripped bottom edge', 1000, 32, '{"class": "deco-paper-torn"}'::jsonb, 'Paper & patterns'),
  ('doodle-squiggle', 'Squiggle line', 'A hand-drawn zigzag', 0, 33, '{"class": "deco-doodle-squiggle"}'::jsonb, 'Doodles'),
  ('doodle-stars', 'Scattered stars', 'Tiny stars across the paper', 1000, 34, '{"class": "deco-doodle-stars"}'::jsonb, 'Doodles'),
  ('doodle-heart', 'Heart doodle', 'An outlined heart', 1000, 35, '{"class": "deco-doodle-heart"}'::jsonb, 'Doodles'),
  ('campus-graduation', 'Graduation cap', 'For the grads', 2000, 36, '{"class": "deco-campus-graduation"}'::jsonb, 'Campus life'),
  ('campus-books', 'Book stack', 'Study mode', 0, 37, '{"class": "deco-campus-books"}'::jsonb, 'Campus life'),
  ('campus-grade', 'A+ grade', 'A circled red A+', 1000, 38, '{"class": "deco-campus-grade"}'::jsonb, 'Campus life'),
  ('campus-pencil', 'Pencil edge', 'A pencil along the bottom', 1000, 39, '{"class": "deco-campus-pencil"}'::jsonb, 'Campus life'),
  ('campus-margin', 'Lecture margin', 'A red notebook margin', 1000, 40, '{"class": "deco-campus-margin"}'::jsonb, 'Campus life'),
  ('mood-calm', 'Calm tide', 'A soft blue wash', 1000, 41, '{"class": "deco-mood-calm"}'::jsonb, 'Moods'),
  ('mood-minimal', 'Minimal rule', 'A single clean top line', 0, 42, '{"class": "deco-mood-minimal"}'::jsonb, 'Moods'),
  ('mood-bold', 'Bold bar', 'A thick orange side bar', 1000, 43, '{"class": "deco-mood-bold"}'::jsonb, 'Moods'),
  ('mood-lol', 'LOL pill', 'A funny LOL tag', 1000, 44, '{"class": "deco-mood-lol"}'::jsonb, 'Moods'),
  ('mood-sleepy', 'Sleepy', 'Zzz', 1000, 45, '{"class": "deco-mood-sleepy"}'::jsonb, 'Moods'),
  ('nature-leaf', 'Leaf', 'A fresh leaf', 0, 46, '{"class": "deco-nature-leaf"}'::jsonb, 'Nature'),
  ('nature-flower', 'Blossom', 'A pink blossom', 1000, 47, '{"class": "deco-nature-flower"}'::jsonb, 'Nature'),
  ('nature-grass', 'Grassy edge', 'Green blades along the bottom', 1000, 48, '{"class": "deco-nature-grass"}'::jsonb, 'Nature'),
  ('season-confetti', 'Confetti', 'Party dots around the edges', 1000, 49, '{"class": "deco-season-confetti"}'::jsonb, 'Seasonal'),
  ('season-rain', 'Rainy season', 'Light rain and a cloud', 1000, 50, '{"class": "deco-season-rain"}'::jsonb, 'Seasonal'),
  ('season-merdeka', 'Merdeka stripe', 'A red-and-white top band', 1000, 51, '{"class": "deco-season-merdeka"}'::jsonb, 'Seasonal'),
  ('retro-checker', 'Retro checkers', 'A diner checker strip', 0, 52, '{"class": "deco-retro-checker"}'::jsonb, 'Retro'),
  ('retro-sunset', 'Sunset glow', 'Orange-to-pink gradient', 1000, 53, '{"class": "deco-retro-sunset"}'::jsonb, 'Retro'),
  ('retro-scanlines', 'Scanlines', 'Old-TV lines', 1000, 54, '{"class": "deco-retro-scanlines"}'::jsonb, 'Retro')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Function EXECUTE allowlist (005 pattern): everything is service_role only
-- unless granted here. Each function re-checks the caller's role itself.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.is_owner(uuid), public.require_owner(), public.admin_waive_order(text, text),
  public.owner_delete_record(text, text, text), public.owner_list_security_events(int),
  public.security_events_append_only()
  from public, anon, authenticated;
grant execute on function
  public.is_owner(uuid), public.require_owner(), public.admin_waive_order(text, text),
  public.owner_delete_record(text, text, text), public.owner_list_security_events(int),
  public.security_events_append_only()
  to service_role;
grant execute on function
  public.admin_waive_order(text, text), public.owner_delete_record(text, text, text),
  public.owner_list_security_events(int)
  to authenticated;
