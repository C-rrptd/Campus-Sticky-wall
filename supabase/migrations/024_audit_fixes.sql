-- 024: audit fixes (idempotent).
--  1. record_campaign_event: bounded per campaign per minute (stat inflation, write load).
--  2. qualify_referral: only a PAID publication order qualifies (stops free-post referral rings).
--  3. get_wall: trigram search indexes, stored pin_until (no per-row EXISTS in the sort),
--     dead "contribution" sort removed, offsets beyond 5000 return an empty page instead of repeating page 5000.
--  4. check_rate_limit cleanup gets an index on window_start.
--  5. lock_order_for_payment: expiry is checked BEFORE a stale payment session is reused.
--  6. admin_check / admin_get_campaign: cheap admin gate and single-campaign read for admin-api.
--  7. media_sweep_stale_uploads: queue uploads that never became part of a note for deletion.
--  8. profiles: reserved display names (admin, official, ...) are not registrable by members.

-- 1 ---------------------------------------------------------------------------------------------
-- shortcut: anon callers cannot be told apart in SQL, so the cap is per campaign, not per viewer; move to an Edge Function with IP limits if exact counts matter.
create or replace function public.record_campaign_event(p_campaign_id uuid, p_kind text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_c public.campaigns;
begin
  if p_kind not in ('impression','click') then
    perform public.app_error('CSW40', 'INVALID_EVENT');
  end if;
  select * into v_c from public.campaigns where id = p_campaign_id;
  if not found or not public.campaign_is_live(v_c) then
    return;
  end if;
  if not public.check_rate_limit('campaign-event:' || p_kind || ':' || p_campaign_id::text,
                                 case p_kind when 'click' then 30 else 300 end, 60) then
    return;
  end if;
  insert into public.campaign_daily_stats (campaign_id, day, impressions, clicks)
  values (p_campaign_id, (now() at time zone 'Asia/Jakarta')::date,
          (p_kind = 'impression')::int, (p_kind = 'click')::int)
  on conflict (campaign_id, day) do update
    set impressions = public.campaign_daily_stats.impressions + excluded.impressions,
        clicks = public.campaign_daily_stats.clicks + excluded.clicks;
  update public.campaigns
     set impressions = impressions + (p_kind = 'impression')::int, clicks = clicks + (p_kind = 'click')::int
   where id = p_campaign_id;
end $$;

-- 2 ---------------------------------------------------------------------------------------------
create or replace function public.qualify_referral(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_referrer uuid; v_slot int; v_kind text;
begin
  if not exists (select 1 from auth.users u where u.id = p_user and u.email_confirmed_at is not null) then return; end if;
  -- 024: free weekly posts, promo-zero and credit-only orders no longer qualify; real money must have moved.
  if not exists (select 1 from public.orders o where o.user_id = p_user and o.kind = 'publication'
                   and o.fulfilled_at is not null and o.status = 'paid' and o.total_amount > 0) then return; end if;
  update public.referral_attributions
     set status = 'qualified', qualified_at = now()
   where referred_user_id = p_user and status = 'pending_verification'
     and referrer_id is not null and not public.is_suspended(referrer_id)
  returning referrer_id into v_referrer;
  if v_referrer is null then return; end if;
  foreach v_kind in array array['post', 'decoration'] loop
    for v_slot in 1..2 loop
      insert into public.referral_credits (user_id, kind, slot, source_ref, recipient)
      values (p_user, v_kind, v_slot, p_user, 'invitee'),
             (v_referrer, v_kind, v_slot, p_user, 'inviter')
      on conflict (source_ref, user_id, kind, slot) do nothing;
    end loop;
  end loop;
  perform public.audit('referral.credits_issued', 'user', p_user::text, null,
    jsonb_build_object('referrer', v_referrer::text));
end $$;

-- 3 ---------------------------------------------------------------------------------------------
alter table public.notes add column if not exists pin_until timestamptz;

create or replace function public.notes_set_pin_until() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.pin_until := case
    when new.status = 'published' and new.published_at is not null
         and exists (select 1 from public.note_decorations d where d.note_id = new.id and d.decoration_id = 'pin-top')
    then new.published_at + interval '7 days' end;
  return new;
end $$;
drop trigger if exists notes_pin_until on public.notes;
create trigger notes_pin_until before insert or update of status, published_at on public.notes
  for each row execute function public.notes_set_pin_until();

create or replace function public.note_decoration_pin() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.decoration_id = 'pin-top' then
    update public.notes set pin_until = published_at + interval '7 days'
     where id = new.note_id and status = 'published' and published_at is not null;
  end if;
  return new;
end $$;
drop trigger if exists note_decorations_pin on public.note_decorations;
create trigger note_decorations_pin after insert on public.note_decorations
  for each row execute function public.note_decoration_pin();

update public.notes n set pin_until = n.published_at + interval '7 days'
 where n.status = 'published' and n.published_at is not null and n.pin_until is null
   and exists (select 1 from public.note_decorations d where d.note_id = n.id and d.decoration_id = 'pin-top');

create index if not exists notes_media_gin on public.notes using gin (media jsonb_path_ops) where media is not null;

do $$ begin
  create schema if not exists extensions;
  create extension if not exists pg_trgm with schema extensions;
exception when others then
  raise notice 'pg_trgm unavailable (%); wall search stays unindexed', sqlerrm;
end $$;

do $$
declare v_schema text;
begin
  select n.nspname into v_schema from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_trgm';
  if v_schema is not null then
    execute format('create index if not exists notes_body_trgm on public.notes using gin (body %I.gin_trgm_ops) where status = %L', v_schema, 'published');
    execute format('create index if not exists notes_author_name_trgm on public.notes using gin (author_name %I.gin_trgm_ops) where status = %L', v_schema, 'published');
  end if;
end $$;

create or replace function public.get_wall(p_sort text default 'newest', p_campus uuid default null,
  p_limit int default 24, p_offset int default 0, p_q text default null, p_color text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_viewer uuid := auth.uid();
  v_limit int := least(greatest(coalesce(p_limit, 24), 1), 50);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_q text := nullif(btrim(left(coalesce(p_q, ''), 60)), '');
  v_like text := case when v_q is null then null
    else '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
begin
  if p_sort not in ('newest','top') then
    perform public.app_error('CSW40', 'INVALID_SORT');
  end if;
  if p_color is not null and p_color not in ('yellow','pink','blue','green','orange','purple') then
    perform public.app_error('CSW40', 'INVALID_COLOR');
  end if;
  if v_offset > 5000 then return '[]'::jsonb; end if;  -- the client stops paging at 5000
  return coalesce((
    select jsonb_agg(public.note_json(n, v_viewer) order by
             coalesce(p_sort = 'newest' and n.pin_until > now(), false) desc,
             case when p_sort = 'top' then n.vote_count end desc nulls last,
             n.published_at desc, n.id)
    from (select * from public.notes n
           where n.status = 'published'
             and (p_campus is null or n.campus_id = p_campus)
             and (p_color is null or n.color = p_color)
             and (v_like is null or n.body ilike v_like escape '\' or n.author_name ilike v_like escape '\')
           order by
             coalesce(p_sort = 'newest' and n.pin_until > now(), false) desc,
             case when p_sort = 'top' then n.vote_count end desc nulls last,
             n.published_at desc, n.id
           limit v_limit offset v_offset) n), '[]'::jsonb);
end $$;

-- 4 ---------------------------------------------------------------------------------------------
create index if not exists rate_limits_window_idx on public.rate_limits (window_start);

-- 5 ---------------------------------------------------------------------------------------------
create or replace function public.lock_order_for_payment(p_order_ref text, p_user_id uuid, p_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_methods jsonb; v_codes text[];
begin
  select * into v_order from public.orders where order_ref = p_order_ref for update;
  if not found or not public.order_access_ok(v_order, p_user_id, p_token_hash) then
    perform public.app_error('CSW04', 'NOT_FOUND', 'Order not found.');
  end if;
  if v_order.status <> 'awaiting_payment' or v_order.total_amount = 0 then
    perform public.app_error('CSW09', 'ORDER_NOT_PAYABLE', 'This order does not need payment.');
  end if;
  -- 024: expiry first, so a lapsed Snap session is never handed out again.
  if v_order.expires_at is not null and v_order.expires_at < now() then
    perform public.app_error('CSW09', 'ORDER_EXPIRED', 'This order expired. Please create it again.');
  end if;
  if v_order.payment_session_token is not null then
    return jsonb_build_object('reused', true, 'order_ref', v_order.order_ref,
      'token', v_order.payment_session_token, 'redirect_url', v_order.payment_redirect_url);
  end if;
  if v_order.payment_locked_at is not null and v_order.payment_locked_at > now() - interval '2 minutes' then
    perform public.app_error('CSW09', 'PAYMENT_IN_PROGRESS', 'Payment is already being prepared. Try again shortly.');
  end if;
  v_methods := public.eligible_payment_methods(v_order.total_amount);
  if jsonb_array_length(v_methods) = 0 then
    perform public.app_error('CSW40', 'NO_ELIGIBLE_PAYMENT_METHOD',
      'No enabled payment method can process this total. The amount was not changed.');
  end if;
  select array_agg(distinct c) into v_codes
    from jsonb_array_elements(v_methods) m, jsonb_array_elements_text(m->'midtrans_codes') c;
  update public.orders set payment_locked_at = now() where id = v_order.id;
  return jsonb_build_object(
    'reused', false,
    'order_ref', v_order.order_ref,
    'kind', v_order.kind,
    'total_amount', v_order.total_amount::text,
    'enabled_payments', to_jsonb(v_codes),
    'items', (select jsonb_agg(jsonb_build_object('id', coalesce(i.item_ref, i.item_type), 'name', i.name,
                                                  'price', i.unit_amount::text, 'quantity', i.quantity) order by i.id)
                from public.order_items i where i.order_id = v_order.id));
end $$;

-- 6 ---------------------------------------------------------------------------------------------
create or replace function public.admin_check() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
end $$;

create or replace function public.admin_get_campaign(p_campaign_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return (select to_jsonb(x) from (
    select c.id, c.title, c.contact_email, c.price_snapshot::text as price, c.moderation_reason
      from public.campaigns c where c.id = p_campaign_id) x);
end $$;

-- 7 ---------------------------------------------------------------------------------------------
-- Uploads older than 24h that no note references (abandoned form, failed order) go to the existing
-- media_orphans queue; the Edge Functions already empty that queue. Schedule hourly with pg_cron (README).
create or replace function public.media_sweep_stale_uploads() returns int
language plpgsql security definer set search_path = '' as $$
declare v_n int := 0;
begin
  if to_regclass('storage.objects') is null then return 0; end if;
  execute $q$
    insert into public.media_orphans (path)
    select o.name from storage.objects o
     where o.bucket_id = 'note-media'
       and o.created_at < now() - interval '24 hours'
       and o.name ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,100}$'
       and not exists (select 1 from public.notes n
                        where n.media @> jsonb_build_array(jsonb_build_object('path', o.name)))
     order by o.created_at limit 500
    on conflict do nothing$q$;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- 8 ---------------------------------------------------------------------------------------------
create or replace function public.profiles_guard_name() returns trigger
language plpgsql security definer set search_path = '' as $$
declare k text := public.name_key(new.display_name);
begin
  if k in ('admin','administrator','moderator','mod','official','staff','support','team','owner')
     or k like '%campusstickywall%' then
    if tg_op = 'INSERT' then
      new.display_name := 'Student';  -- signup trigger derives the name from the email; never fail a signup
    elsif new.display_name is distinct from old.display_name and not public.is_admin(new.id) then
      perform public.app_error('CSW40', 'NAME_NOT_AVAILABLE', 'That name is reserved. Please pick another.');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard_name on public.profiles;
create trigger profiles_guard_name before insert or update of display_name on public.profiles
  for each row execute function public.profiles_guard_name();

-- Grants (005 pattern: everything is service_role only unless listed).
revoke execute on function public.notes_set_pin_until(), public.note_decoration_pin(), public.profiles_guard_name(),
  public.media_sweep_stale_uploads(), public.admin_check(), public.admin_get_campaign(uuid) from public, anon, authenticated;
grant execute on function public.notes_set_pin_until(), public.note_decoration_pin(), public.profiles_guard_name(),
  public.media_sweep_stale_uploads(), public.admin_check(), public.admin_get_campaign(uuid) to service_role;
grant execute on function public.admin_check(), public.admin_get_campaign(uuid) to authenticated;
