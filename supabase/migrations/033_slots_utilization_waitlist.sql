-- 033 — Phase 2: per-location slots, top/standard slot types, utilization metrics, waitlist with time-limited
-- holds, price proposals (never automatic). Idempotent: safe to re-run. Rollback: supabase/rollbacks/033_rollback.sql.
--
-- Rules this migration keeps:
--   * Reducing slots NEVER removes or edits a running/paid campaign. It only lowers `free`, which blocks new sales.
--   * Existing orders and campaign prices are never touched. A slot multiplier or an approved price proposal only
--     changes the price of campaigns submitted AFTER it.
--   * Slots apply to the `featured` spot only (the `random` spot is a shared rotation with no cap).

-- ---------------------------------------------------------------------------
-- 1. Settings (rules live in config_rules, so admin_set_config validates and audits them)
-- ---------------------------------------------------------------------------
insert into public.site_config (key, value, is_public, description) values
  ('slot_underfilled_pct',       '50',    false, 'Fill rate (30 days) below this % = Underfilled'),
  ('slot_soldout_pct',           '85',    false, 'Fill rate (30 days) above this % = Sold out'),
  ('waitlist_hold_hours',        '24',    false, 'How long a notified waitlist person can reserve a freed slot'),
  ('ad_auto_price_step_enabled', 'false', false, 'Allow price PROPOSALS (never automatic) for locations that sold out'),
  ('ad_auto_price_step_pct',     '20',    false, 'Proposed price step % when a location sold out last cycle (max 30)')
on conflict (key) do nothing;

insert into public.config_rules (key, kind, min_v, max_v) values
  ('slot_underfilled_pct','int',1,99), ('slot_soldout_pct','int',2,100), ('waitlist_hold_hours','int',1,168),
  ('ad_auto_price_step_enabled','bool',null,null), ('ad_auto_price_step_pct','int',0,30)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Schema
-- ---------------------------------------------------------------------------
-- No row = defaults (ad_default_slots, no top slot, equal share, multipliers 1.5 / 1.0).
create table if not exists public.ad_slot_settings (
  target_key text primary key check (target_key ~ '^(global:\*|country:[A-Z]{2}|(region|city|campus):[0-9a-f-]{36})$'),
  slots int not null default 3 check (slots between 1 and 10),
  top_slots int not null default 0 check (top_slots between 0 and 10),
  top_multiplier numeric(4,2) not null default 1.5 check (top_multiplier between 1 and 5),
  standard_multiplier numeric(4,2) not null default 1.0 check (standard_multiplier between 0.5 and 5),
  rotation_mode text not null default 'equal_share' check (rotation_mode in ('equal_share','fixed_position')),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.ad_slot_settings enable row level security;
revoke all on public.ad_slot_settings from anon, authenticated;

alter table public.campaigns add column if not exists slot_type text not null default 'standard'
  check (slot_type in ('top','standard'));

alter table public.ad_waitlist
  add column if not exists max_budget bigint check (max_budget is null or max_budget > 0),
  add column if not exists notified_at timestamptz,
  add column if not exists hold_expires_at timestamptz,
  add column if not exists claimed_campaign_id uuid references public.campaigns (id) on delete set null;
create index if not exists ad_waitlist_key_status on public.ad_waitlist (target_key, status, created_at);

-- Outgoing mail queue (text only, same as _shared/email.ts). dedupe_key makes enqueue idempotent.
create table if not exists public.ad_outbox (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  to_email text not null,
  user_id uuid,
  payload jsonb not null default '{}'::jsonb,
  dedupe_key text not null unique,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts int not null default 0
);
create index if not exists ad_outbox_pending on public.ad_outbox (created_at) where sent_at is null;
alter table public.ad_outbox enable row level security;
revoke all on public.ad_outbox from anon, authenticated;

create table if not exists public.ad_price_proposals (
  id uuid primary key default gen_random_uuid(),
  product_id text not null references public.ad_products (id) on delete cascade,
  old_base bigint not null,
  new_base bigint not null check (new_base > 0),
  step_pct int not null,
  reason text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid
);
create unique index if not exists ad_price_proposals_one_pending on public.ad_price_proposals (product_id) where status = 'pending';
alter table public.ad_price_proposals enable row level security;
revoke all on public.ad_price_proposals from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Capacity
-- ---------------------------------------------------------------------------
-- Effective slot settings for a location.
create or replace function public.ad_slot_cfg(p_key text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'slots', coalesce(s.slots, (public.config_value('ad_default_slots') #>> '{}')::int, 3),
    'top_slots', least(coalesce(s.top_slots, 0), coalesce(s.slots, (public.config_value('ad_default_slots') #>> '{}')::int, 3)),
    'top_multiplier', coalesce(s.top_multiplier, 1.5),
    'standard_multiplier', coalesce(s.standard_multiplier, 1.0),
    'rotation_mode', coalesce(s.rotation_mode, 'equal_share'))
  from (select 1) d left join public.ad_slot_settings s on s.target_key = p_key
$$;

-- Replaces the Phase 1 stub: slots per location, used by the pricing analytics.
create or replace function public.ad_slots_for(p_spot text, p_key text) returns int
language sql stable security definer set search_path = '' as $$
  select (public.ad_slot_cfg(p_key) ->> 'slots')::int
$$;

-- First and exclusive-last Jakarta day a campaign occupies a slot. Unpaid ones count from the requested start.
create or replace function public.campaign_start_day(c public.campaigns) returns date
language sql stable set search_path = '' as $$
  select coalesce((c.starts_at at time zone 'Asia/Jakarta')::date,
                  greatest(c.requested_start, (now() at time zone 'Asia/Jakarta')::date))
$$;
create or replace function public.campaign_end_day(c public.campaigns) returns date
language sql stable set search_path = '' as $$
  select case when c.ends_at is not null then ((c.ends_at at time zone 'Asia/Jakarta') - interval '1 microsecond')::date + 1
              else public.campaign_start_day(c) + c.duration_days end
$$;

-- Slot-holding campaigns per day on one location: total and top. Paid-but-unreviewed and unpaid orders hold a slot.
create or replace function public.ad_day_usage(p_key text, p_from date, p_days int, p_exclude uuid)
returns table (day date, total int, top int) language sql stable security definer set search_path = '' as $$
  select (p_from + g.i)::date, count(c.id)::int, (count(c.id) filter (where c.slot_type = 'top'))::int
    from generate_series(0, greatest(p_days, 1) - 1) g(i)
    left join public.campaigns c
      on c.placement = 'featured' and c.id is distinct from p_exclude
     and c.status in ('awaiting_payment','pending_review','scheduled','active','paused')
     and exists (select 1 from public.campaign_targets t where t.campaign_id = c.id and t.target_key = p_key)
     and public.campaign_start_day(c) <= p_from + g.i and public.campaign_end_day(c) > p_from + g.i
   group by g.i order by g.i
$$;

-- Slots reserved for waitlist people: a notified person inside the hold window, or a claimed entry whose campaign
-- is still waiting for review / payment. The buyer's own hold and their own campaign never count against them.
create or replace function public.ad_active_holds(p_key text, p_email text, p_exclude uuid) returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.ad_waitlist w
   where w.spot = 'featured' and w.target_key = p_key
     and lower(w.email) is distinct from lower(coalesce(p_email, ''))
     and (p_exclude is null or w.claimed_campaign_id is distinct from p_exclude)
     and ((w.status = 'notified' and w.hold_expires_at > now())
       or (w.status = 'claimed' and exists (select 1 from public.campaigns c
            where c.id = w.claimed_campaign_id and c.status in ('pending_approval','approved'))))
$$;

-- What a buyer can book: free slots for the window, the next day with space, and the expected rotation share.
create or replace function public.ad_capacity(p_key text, p_slot_type text, p_start date, p_days int, p_exclude uuid, p_email text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_cfg jsonb := public.ad_slot_cfg(p_key);
  v_slots int := (v_cfg ->> 'slots')::int;
  v_top int := (v_cfg ->> 'top_slots')::int;
  v_cap int;
  v_max int;
  v_free int;
  v_avail int;
  v_next date;
  v_std int := v_slots - v_top;
begin
  v_cap := case when p_slot_type = 'top' then v_top else v_std end;
  select coalesce(max(case when p_slot_type = 'top' then u.top else u.total - u.top end), 0) into v_max
    from public.ad_day_usage(p_key, p_start, p_days, p_exclude) u;
  v_free := greatest(v_cap - v_max, 0); -- floored: a reduced slot count blocks new sales, it never goes negative
  v_avail := greatest(v_free - public.ad_active_holds(p_key, p_email, p_exclude), 0);
  if v_avail = 0 then
    select min(u.day) into v_next from public.ad_day_usage(p_key, p_start, 180, p_exclude) u
     where (case when p_slot_type = 'top' then u.top else u.total - u.top end) < v_cap;
  end if;
  return jsonb_build_object('key', p_key, 'slot_type', p_slot_type, 'total', v_cap, 'free', v_free, 'available', v_avail,
    'next_free_date', v_next, 'rotation_mode', v_cfg ->> 'rotation_mode',
    'expected_share_pct', case when v_cfg ->> 'rotation_mode' = 'equal_share' then round(100.0 / v_slots, 1)
                               when p_slot_type = 'top' then 100 else round(100.0 / greatest(v_std, 1), 1) end,
    'top_multiplier', (v_cfg ->> 'top_multiplier')::numeric, 'standard_multiplier', (v_cfg ->> 'standard_multiplier')::numeric,
    'top_slots', v_top, 'slots', v_slots);
end $$;

-- Highest slot-type multiplier across the chosen locations (a bundle is priced at its dearest location).
create or replace function public.ad_slot_multiplier(p_keys text[], p_slot_type text) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(max((public.ad_slot_cfg(k) ->> case when p_slot_type = 'top' then 'top_multiplier' else 'standard_multiplier' end)::numeric), 1)
    from unnest(p_keys) k
$$;

-- Public availability for the buy form. Only featured locations have slots.
create or replace function public.get_ad_availability(p_keys text[], p_slot_type text, p_start date, p_days int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_email text := (select email from auth.users where id = (select auth.uid()));
begin
  if p_keys is null or cardinality(p_keys) not between 1 and 20 or p_slot_type not in ('top','standard')
     or p_start is null or p_days is null or p_days not between 1 and 365 then
    perform public.app_error('CSW40', 'INVALID_AVAILABILITY', 'Choose locations, a slot type, a start date and a length.');
  end if;
  return coalesce((select jsonb_agg(public.ad_capacity(k, p_slot_type, p_start, p_days, null, v_email)) from unnest(p_keys) k), '[]'::jsonb);
end $$;

-- Raise SOLD_OUT unless every target has a free slot for the window. Callers hold the per-location advisory locks.
create or replace function public.assert_ad_capacity(p_campaign public.campaigns, p_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_key text; v_start date; v_cap jsonb;
begin
  if p_campaign.placement <> 'featured' then return; end if;
  v_start := greatest(p_campaign.requested_start, (now() at time zone 'Asia/Jakarta')::date);
  for v_key in select t.target_key from public.campaign_targets t where t.campaign_id = p_campaign.id order by t.target_key loop
    v_cap := public.ad_capacity(v_key, p_campaign.slot_type, v_start, p_campaign.duration_days, p_campaign.id, p_email);
    if (v_cap ->> 'available')::int < 1 then
      perform public.app_error('CSW09', 'SOLD_OUT', 'No ' || p_campaign.slot_type || ' slot is free for ' || public.target_label(v_key) ||
        ' in that period. Join the waitlist or pick another start date.');
    end if;
  end loop;
end $$;
drop function if exists public.upsert_campaign_draft(uuid, uuid, text, text, text, text, text, text, text, text, date, jsonb);
create or replace function public.upsert_campaign_draft(
  p_owner uuid, p_campaign_id uuid, p_advertiser_name text, p_contact_email text, p_title text,
  p_description text, p_category text, p_creative_path text, p_destination_url text,
  p_product_id text, p_requested_start date, p_targets jsonb, p_slot_type text default 'standard'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_product public.ad_products;
  v_id uuid;
  v_target jsonb;
  v_level text;
  v_ref text;
  v_count int := 0;
  v_price bigint;
  v_q jsonb;
  v_keys text[];
  v_mult numeric := 1;
  v_slot text := case when p_slot_type = 'top' then 'top' else 'standard' end;
  v_camp public.campaigns;
begin
  if p_owner is null then
    perform public.app_error('CSW03', 'AUTH_REQUIRED', 'Sign in to create a campaign.');
  end if;
  if public.is_suspended(p_owner) then
    perform public.app_error('CSW03', 'ACCOUNT_SUSPENDED', 'This account is suspended.');
  end if;
  -- Keep the review queue usable: at most 5 new submissions waiting for a decision per advertiser.
  if p_campaign_id is null and (select count(*) from public.campaigns where owner_id = p_owner and status = 'pending_approval') >= 5 then
    perform public.app_error('CSW09', 'TOO_MANY_PENDING', 'You already have 5 campaigns waiting for review. Wait for a decision or cancel one first.');
  end if;
  select * into v_product from public.ad_products where id = p_product_id and enabled;
  if not found then
    perform public.app_error('CSW40', 'INVALID_PRODUCT', 'Choose an available advertising package.');
  end if;
  if p_requested_start is null or p_requested_start < (now() at time zone 'Asia/Jakarta')::date
     or p_requested_start > (now() at time zone 'Asia/Jakarta')::date + 14 then
    perform public.app_error('CSW40', 'INVALID_START_DATE', 'Start date must be within the next 14 days.');
  end if;
  if p_targets is null or jsonb_typeof(p_targets) <> 'array' or jsonb_array_length(p_targets) not between 1 and 20 then
    perform public.app_error('CSW40', 'INVALID_TARGETS', 'Choose between 1 and 20 target locations.');
  end if;
  if v_product.scope_level = 'global' and jsonb_array_length(p_targets) <> 1 then
    perform public.app_error('CSW40', 'INVALID_TARGETS', 'Global packages take exactly one global target.');
  end if;

  if p_campaign_id is null then
    insert into public.campaigns (owner_id, advertiser_name, contact_email, title, description, category,
      creative_path, destination_url, product_id, placement, scope_level, duration_days, requested_start, status, slot_type)
    values (p_owner, btrim(p_advertiser_name), btrim(p_contact_email), btrim(p_title), btrim(p_description), p_category,
      p_creative_path, nullif(btrim(coalesce(p_destination_url, '')), ''), v_product.id, v_product.placement,
      v_product.scope_level, v_product.duration_days, p_requested_start, 'pending_approval',
      case when v_product.placement = 'featured' then v_slot else 'standard' end)
    returning id into v_id;
  else
    update public.campaigns set advertiser_name = btrim(p_advertiser_name), contact_email = btrim(p_contact_email),
           title = btrim(p_title), description = btrim(p_description), category = p_category,
           creative_path = p_creative_path, destination_url = nullif(btrim(coalesce(p_destination_url, '')), ''),
           product_id = v_product.id, placement = v_product.placement, scope_level = v_product.scope_level,
           duration_days = v_product.duration_days, requested_start = p_requested_start, status = 'pending_approval',
           slot_type = case when v_product.placement = 'featured' then v_slot else 'standard' end,
           moderation_reason = null
     where id = p_campaign_id and owner_id = p_owner and status in ('draft','rejected')
    returning id into v_id;
    if v_id is null then
      perform public.app_error('CSW04', 'NOT_FOUND', 'Campaign not found or it can no longer be edited.');
    end if;
    delete from public.campaign_targets where campaign_id = v_id;
  end if;

  for v_target in select * from jsonb_array_elements(p_targets) loop
    v_level := v_target ->> 'level';
    v_ref := v_target ->> 'id';
    if v_level is distinct from v_product.scope_level then
      perform public.app_error('CSW40', 'INVALID_TARGETS', 'All targets must match the package scope.');
    end if;
    begin
      if v_level = 'global' then
        insert into public.campaign_targets (campaign_id, level) values (v_id, 'global');
      elsif v_level = 'country' then
        insert into public.campaign_targets (campaign_id, level, country_code)
        select v_id, 'country', code from public.countries where code = upper(v_ref) and enabled;
      elsif v_level = 'region' then
        insert into public.campaign_targets (campaign_id, level, region_id)
        select v_id, 'region', id from public.regions where id = v_ref::uuid and enabled;
      elsif v_level = 'city' then
        insert into public.campaign_targets (campaign_id, level, city_id)
        select v_id, 'city', id from public.cities where id = v_ref::uuid and enabled;
      elsif v_level = 'campus' then
        insert into public.campaign_targets (campaign_id, level, campus_id)
        select v_id, 'campus', id from public.campuses where id = v_ref::uuid and enabled;
      end if;
    exception
      when invalid_text_representation then
        perform public.app_error('CSW40', 'INVALID_TARGETS', 'A target location is invalid.');
      when unique_violation then
        perform public.app_error('CSW40', 'DUPLICATE_TARGET', 'Each location can be targeted once.');
    end;
    if not found then
      perform public.app_error('CSW40', 'INVALID_TARGETS', 'A target location is unknown or disabled.');
    end if;
    v_count := v_count + 1;
  end loop;

  select array_agg(t.target_key) into v_keys from public.campaign_targets t where t.campaign_id = v_id;
  if v_product.placement = 'featured' then
    v_mult := public.ad_slot_multiplier(v_keys, v_slot);
  end if;
  v_q := public.ad_quote(p_owner, v_product, v_count);
  v_price := round((v_q ->> 'total')::numeric * v_mult)::bigint;
  perform public.require_payable_total(v_price);
  -- Early warning only; create_ad_order re-checks under a lock before any money is requested.
  select * into v_camp from public.campaigns where id = v_id;
  perform public.assert_ad_capacity(v_camp, p_contact_email);
  update public.ad_waitlist set status = 'claimed', claimed_campaign_id = v_id
   where status = 'notified' and hold_expires_at > now() and spot = 'featured' and target_key = any (v_keys)
     and lower(email) = lower(btrim(p_contact_email));
  update public.campaigns set price_snapshot = v_price, list_price_snapshot = round((v_q ->> 'list_total')::numeric * v_mult)::bigint,
         launch_discount_pct = (v_q ->> 'discount_pct')::int, price_locked = (v_q ->> 'locked')::boolean,
         price_base_used = (v_q ->> 'base_used')::bigint, price_extra_pct_used = (v_q ->> 'extra_pct_used')::int
   where id = v_id;
  return jsonb_build_object('campaign_id', v_id, 'target_count', v_count, 'price', v_price::text,
    'list_price', round((v_q ->> 'list_total')::numeric * v_mult)::text, 'slot_type', v_camp.slot_type, 'slot_multiplier', v_mult, 'discount_pct', (v_q ->> 'discount_pct')::int,
    'price_locked', (v_q ->> 'locked')::boolean, 'duration_days', v_product.duration_days);
end $$;
create or replace function public.create_ad_order(p_owner uuid, p_campaign_id uuid, p_guest_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_c public.campaigns;
  v_product public.ad_products;
  v_targets int;
  v_price bigint;
  v_order_id uuid;
  v_key text;
begin
  select * into v_c from public.campaigns where id = p_campaign_id for update;
  if not found or v_c.owner_id is distinct from p_owner then
    perform public.app_error('CSW04', 'NOT_FOUND', 'Campaign not found.');
  end if;
  if v_c.status <> 'approved' then
    perform public.app_error('CSW09', 'CAMPAIGN_NOT_APPROVED', 'Only campaigns approved by an administrator can be paid.');
  end if;
  if p_guest_token_hash is null or p_guest_token_hash !~ '^[0-9a-f]{64}$' then
    perform public.app_error('CSW40', 'INVALID_ACCESS_TOKEN');
  end if;
  select * into v_product from public.ad_products where id = v_c.product_id and enabled;
  if not found then
    perform public.app_error('CSW40', 'INVALID_PRODUCT', 'This advertising package is no longer available.');
  end if;
  select count(*) into v_targets from public.campaign_targets where campaign_id = v_c.id and level = v_product.scope_level;
  if v_targets = 0 then
    perform public.app_error('CSW40', 'INVALID_TARGETS', 'The campaign has no valid targets.');
  end if;
  -- Serialise buyers per location, in a fixed order so two multi-location orders cannot deadlock.
  for v_key in select t.target_key from public.campaign_targets t where t.campaign_id = v_c.id order by t.target_key loop
    perform pg_advisory_xact_lock(hashtext('slots:' || v_key));
  end loop;
  perform public.assert_ad_capacity(v_c, v_c.contact_email);
  v_price := coalesce(v_c.price_snapshot, public.ad_price(v_product.price_per_target, v_product.extra_location_pct, v_targets));
  perform public.require_payable_total(v_price);
  insert into public.orders (order_ref, kind, user_id, subtotal_amount, total_amount, snapshot, guest_token_hash, expires_at)
  values (public.new_order_ref('advertising'), 'advertising', p_owner, v_price, v_price,
          jsonb_build_object('product_id', v_product.id, 'product_name', v_product.name,
                             'price_per_target', v_product.price_per_target::text, 'target_count', v_targets,
                             'duration_days', v_c.duration_days, 'priced_at', now(),
                             'list_price', coalesce(v_c.list_price_snapshot, v_price)::text,
                             'launch_discount_pct', coalesce(v_c.launch_discount_pct, 0),
                             'price_locked', v_c.price_locked, 'base_fee_used', v_c.price_base_used::text),
          p_guest_token_hash,
          now() + make_interval(mins => coalesce((public.config_value('unpaid_order_ttl_minutes') #>> '{}')::int, 120)))
  returning id into v_order_id;
  insert into public.order_items (order_id, item_type, item_ref, name, unit_amount, quantity)
  values (v_order_id, 'advertising', v_product.id, left(v_product.name, 44) || ' ×' || v_targets, v_price, 1);
  update public.campaigns set status = 'awaiting_payment', order_id = v_order_id, price_snapshot = v_price
   where id = v_c.id;
  return public.order_summary(v_order_id);
end $$;
-- ---------------------------------------------------------------------------
-- 4. Admin: slot configuration (audited; never removes a running campaign)
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_slot_config(
  p_key text, p_slots int, p_top_slots int, p_top_multiplier numeric, p_standard_multiplier numeric, p_rotation_mode text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_admin uuid := public.require_admin();
  v_old jsonb := public.ad_slot_cfg(p_key);
  v_peak_total int; v_peak_top int; v_new jsonb;
begin
  if p_key is null or p_key !~ '^(global:\*|country:[A-Z]{2}|(region|city|campus):[0-9a-f-]{36})$' then
    perform public.app_error('CSW40', 'INVALID_LOCATION', 'Unknown location key.');
  end if;
  if p_slots is null or p_slots not between 1 and 10 then
    perform public.app_error('CSW40', 'INVALID_SLOTS', 'Slots must be between 1 and 10.');
  end if;
  if p_top_slots is null or p_top_slots not between 0 and p_slots then
    perform public.app_error('CSW40', 'INVALID_TOP_SLOTS', 'Top slots must be between 0 and the slot count.');
  end if;
  if p_top_multiplier is null or p_top_multiplier not between 1 and 5 or p_standard_multiplier is null or p_standard_multiplier not between 0.5 and 5 then
    perform public.app_error('CSW40', 'INVALID_MULTIPLIER', 'Top multiplier must be 1-5 and standard 0.5-5.');
  end if;
  if p_rotation_mode not in ('equal_share','fixed_position') then
    perform public.app_error('CSW40', 'INVALID_ROTATION', 'Choose equal share or fixed position.');
  end if;
  insert into public.ad_slot_settings (target_key, slots, top_slots, top_multiplier, standard_multiplier, rotation_mode, updated_by)
  values (p_key, p_slots, p_top_slots, p_top_multiplier, p_standard_multiplier, p_rotation_mode, v_admin)
  on conflict (target_key) do update set slots = excluded.slots, top_slots = excluded.top_slots,
    top_multiplier = excluded.top_multiplier, standard_multiplier = excluded.standard_multiplier,
    rotation_mode = excluded.rotation_mode, updated_at = now(), updated_by = excluded.updated_by;
  v_new := public.ad_slot_cfg(p_key);
  perform public.audit('ad_slots.change', 'ad_location', p_key, null, jsonb_build_object('old', v_old, 'new', v_new));
  select coalesce(max(u.total), 0), coalesce(max(u.top), 0) into v_peak_total, v_peak_top
    from public.ad_day_usage(p_key, (now() at time zone 'Asia/Jakarta')::date, 180, null) u;
  -- Information only: campaigns above the new limit keep running to their end date; only new sales are blocked.
  return jsonb_build_object('ok', true, 'config', v_new, 'running_peak', v_peak_total,
    'blocks_new_sales', v_peak_total >= p_slots or v_peak_top >= p_top_slots and p_top_slots > 0);
end $$;

create or replace function public.admin_list_slot_configs() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return jsonb_build_object('default_slots', coalesce((public.config_value('ad_default_slots') #>> '{}')::int, 3),
    'rows', coalesce((select jsonb_agg(x order by x.label) from (
      select k.key, public.target_label(k.key) as label, public.ad_slot_cfg(k.key) as cfg,
             (select coalesce(max(u.total), 0) from public.ad_day_usage(k.key, (now() at time zone 'Asia/Jakarta')::date, 30, null) u) as in_use_peak_30d
        from (select target_key as key from public.ad_slot_settings
              union select t.target_key from public.campaign_targets t join public.campaigns c on c.id = t.campaign_id where c.placement = 'featured'
              union select target_key from public.ad_waitlist where target_key is not null and spot = 'featured') k) x), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Public rotation: fixed_position locations list the top slot first, then the oldest booking (stable order).
--    Everything else is unchanged from 015: most specific location first, then random (equal share).
-- ---------------------------------------------------------------------------
create or replace function public.get_promotions(
  p_country text default null, p_region uuid default null, p_city uuid default null, p_campus uuid default null,
  p_placement text default 'promotions_feed', p_category text default null, p_limit int default 24)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_loc record; v_pl text := coalesce(p_placement, 'promotions_feed');
begin
  select * into v_loc from public.resolve_location(p_country, p_region, p_city, p_campus);
  return coalesce((
    select jsonb_agg(to_jsonb(x) - 'rk' - 'fixed' order by x.rk)
    from (
      select g.*, row_number() over (order by
               case when v_pl = 'featured' then g.specificity end desc nulls last,
               case when v_pl = 'featured' and g.fixed then (g.slot_type <> 'top')::int end nulls last,
               case when v_pl = 'featured' and g.fixed then g.starts_at end,
               random()) as rk
        from (
          select c.id, c.title, c.description, c.category, c.creative_path, c.destination_url,
                 c.advertiser_name, c.placement, c.starts_at, c.ends_at, c.slot_type,
                 max(case t.level when 'campus' then 4 when 'city' then 3 when 'region' then 2
                                  when 'country' then 1 else 0 end) as specificity,
                 coalesce(bool_or(s.rotation_mode = 'fixed_position'), false) as fixed
            from public.campaigns c
            join public.campaign_targets t on t.campaign_id = c.id
            left join public.ad_slot_settings s on s.target_key = t.target_key
           where public.campaign_is_live(c)
             and (c.placement = v_pl or (v_pl in ('random','promotions_feed','wall_inline') and c.placement in ('promotions_feed','wall_inline')))
             and (p_category is null or c.category = p_category)
             and (t.level = 'global'
                  or (t.level = 'country' and v_loc.country_code is not null and t.country_code = v_loc.country_code)
                  or (t.level = 'region'  and v_loc.region_id is not null and t.region_id = v_loc.region_id)
                  or (t.level = 'city'    and v_loc.city_id is not null and t.city_id = v_loc.city_id)
                  or (t.level = 'campus'  and v_loc.campus_id is not null and t.campus_id = v_loc.campus_id))
           group by c.id
        ) g
    ) x
    where x.rk <= least(greatest(coalesce(p_limit, 24), 1), 50)), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Utilization
-- ---------------------------------------------------------------------------
-- Fill % of a location over [from, to] (Jakarta days, inclusive) at the CURRENT slot count.
create or replace function public.ad_fill_pct(p_key text, p_from date, p_to date) returns numeric
language sql stable security definer set search_path = '' as $$
  select round(public.ad_slot_days_sold('featured', p_key, p_from, p_to) * 100.0
               / ((p_to - p_from + 1) * public.ad_slots_for('featured', p_key)), 1)
$$;

-- Average days from "sales open" (14 days before the week starts, the furthest-ahead start date allowed) until the
-- last slot of that week was paid, over weeks in the window where every slot sold. Null when no week sold out.
-- A week's bookings = paid featured campaigns that START in that week; the slots-th payment is the sell-out moment.
create or replace function public.ad_sellout_days(p_key text, p_from date, p_to date) returns numeric
language sql stable security definer set search_path = '' as $$
  select round(avg(greatest(extract(epoch from (w.sold_out_at - ((w.wk - 14)::timestamp at time zone 'Asia/Jakarta'))) / 86400, 0))::numeric, 1)
  from (
    select b.wk, max(b.paid_at) as sold_out_at
      from (select date_trunc('week', c.starts_at at time zone 'Asia/Jakarta')::date as wk, o.paid_at,
                   row_number() over (partition by date_trunc('week', c.starts_at at time zone 'Asia/Jakarta') order by o.paid_at) as n
              from public.campaigns c
              join public.campaign_targets t on t.campaign_id = c.id and t.target_key = p_key
              join public.orders o on o.id = c.order_id and o.status = 'paid'
             where c.placement = 'featured' and c.status not in ('canceled','rejected') and c.starts_at is not null
               and (c.starts_at at time zone 'Asia/Jakarta')::date between p_from and p_to) b
     where b.n <= public.ad_slots_for('featured', p_key)
     group by b.wk
    having count(*) >= public.ad_slots_for('featured', p_key)) w
$$;

create or replace function public.admin_utilization() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_low int := coalesce((public.config_value('slot_underfilled_pct') #>> '{}')::int, 50);
  v_high int := coalesce((public.config_value('slot_soldout_pct') #>> '{}')::int, 85);
  v_enough boolean;
begin
  perform public.require_admin();
  -- Same rule as pricing analytics: no verdicts until 14 days of selling history exist.
  select coalesce(min(c.starts_at) <= now() - interval '14 days', false) into v_enough
    from public.campaigns c join public.orders o on o.id = c.order_id and o.status = 'paid' where c.placement = 'featured';
  return jsonb_build_object('underfilled_pct', v_low, 'soldout_pct', v_high, 'enough_data', v_enough,
    'rows', coalesce((select jsonb_agg(r order by r.label) from (
      select q.*,
        case when not v_enough then 'no_data' when q.fill_30 > v_high then 'sold_out' when q.fill_30 < v_low then 'underfilled' else 'healthy' end as status,
        case when not v_enough then null
             when q.fill_30 > v_high and q.waitlist >= q.slots then 'Sold out with a waitlist: consider raising the price or adding a slot.'
             when q.fill_30 > v_high then 'Sold out: consider raising the price.'
             when q.fill_30 < v_low then 'Underfilled: fix traffic or demand before changing price.' end as recommendation
      from (
        select k.key, public.target_label(k.key) as label, public.ad_slots_for('featured', k.key) as slots,
               public.ad_fill_pct(k.key, v_today - 6, v_today) as fill_7,
               public.ad_fill_pct(k.key, v_today - 29, v_today) as fill_30,
               public.ad_fill_pct(k.key, v_today - 89, v_today) as fill_90,
               public.ad_sellout_days(k.key, v_today - 89, v_today) as avg_days_to_sell_out,
               (select count(*) from public.ad_waitlist w where w.status = 'waiting' and w.spot = 'featured'
                   and (w.target_key = k.key or (w.target_key is null and w.scope_level = split_part(k.key, ':', 1)))) as waitlist
          from (select target_key as key from public.ad_slot_settings
                union select t.target_key from public.campaign_targets t join public.campaigns c on c.id = t.campaign_id
                       where c.placement = 'featured' and c.status not in ('canceled','rejected','draft')
                union select target_key from public.ad_waitlist where target_key is not null and spot = 'featured') k) q) r), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Waitlist: FCFS with a time-limited hold. No bidding: the price a person pays is the normal price.
-- ---------------------------------------------------------------------------
drop function if exists public.join_ad_waitlist(text, text, text, text, int);
create or replace function public.join_ad_waitlist(p_email text, p_spot text, p_scope_level text, p_target_key text, p_duration int,
  p_max_budget bigint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_h jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
        v_ip text := btrim(split_part(coalesce(v_h ->> 'cf-connecting-ip', v_h ->> 'x-forwarded-for', 'none'), ',', 1));
        v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.check_rate_limit('waitlist:' || public.visitor_hash(v_ip, ''), 10, 3600)
     or not public.check_rate_limit('waitlist:all', 300, 3600) then
    perform public.app_error('CSW29', 'RATE_LIMITED', 'Too many requests. Try again later.');
  end if;
  if v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 200 then
    perform public.app_error('CSW40', 'INVALID_EMAIL', 'Enter a valid email address.');
  end if;
  if p_spot not in ('featured','random') or p_scope_level not in ('global','country','region','city','campus')
     or p_duration is null or p_duration not between 1 and 365 then
    perform public.app_error('CSW40', 'INVALID_WAITLIST', 'Choose a placement, reach and duration.');
  end if;
  if p_max_budget is not null and p_max_budget < 1 then
    perform public.app_error('CSW40', 'INVALID_BUDGET', 'Maximum budget must be more than zero, or empty.');
  end if;
  insert into public.ad_waitlist (email, user_id, spot, scope_level, target_key, desired_duration, max_budget)
  values (v_email, (select auth.uid()), p_spot, p_scope_level, nullif(p_target_key, ''), p_duration, p_max_budget)
  on conflict (lower(email), spot, scope_level, coalesce(target_key, ''), desired_duration) where status = 'waiting'
  do update set max_budget = excluded.max_budget;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.ad_enqueue(p_kind text, p_email text, p_user uuid, p_payload jsonb, p_dedupe text) returns void
language sql security definer set search_path = '' as $$
  insert into public.ad_outbox (kind, to_email, user_id, payload, dedupe_key)
  values (p_kind, p_email, p_user, coalesce(p_payload, '{}'::jsonb), p_dedupe) on conflict (dedupe_key) do nothing
$$;

-- Cron job (service role): expire old holds, then offer each free slot to the longest-waiting person whose budget covers it.
create or replace function public.process_ad_waitlist() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_hours int := coalesce((public.config_value('waitlist_hold_hours') #>> '{}')::int, 24);
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_expired int; v_notified int := 0;
  w public.ad_waitlist; v_price bigint; v_cap jsonb; v_exp timestamptz;
begin
  update public.ad_waitlist set status = 'expired' where status = 'notified' and hold_expires_at <= now();
  get diagnostics v_expired = row_count;
  for w in select * from public.ad_waitlist where status = 'waiting' and spot = 'featured' and target_key is not null
            order by created_at, id for update skip locked loop
    -- Price a buyer would pay now: the matching package at the standard multiplier, one location.
    select round(public.ad_effective_base(p) * (public.ad_slot_cfg(w.target_key) ->> 'standard_multiplier')::numeric)::bigint into v_price
      from public.ad_products p
     where p.enabled and p.placement = 'featured' and p.scope_level = w.scope_level and p.duration_days = w.desired_duration limit 1;
    continue when v_price is null or (w.max_budget is not null and w.max_budget < v_price);
    v_cap := public.ad_capacity(w.target_key, 'standard', v_today, w.desired_duration, null, w.email);
    continue when (v_cap ->> 'available')::int < 1;
    v_exp := now() + make_interval(hours => v_hours);
    update public.ad_waitlist set status = 'notified', notified_at = now(), hold_expires_at = v_exp where id = w.id;
    perform public.ad_enqueue('waitlist_slot_free', w.email, w.user_id,
      jsonb_build_object('location', public.target_label(w.target_key), 'duration', w.desired_duration,
                         'price', v_price::text, 'hold_expires_at', v_exp), 'wl:' || w.id);
    v_notified := v_notified + 1;
  end loop;
  return jsonb_build_object('expired', v_expired, 'notified', v_notified);
end $$;

-- Mail queue for the sender job.
create or replace function public.ad_outbox_claim(p_limit int default 25) returns setof public.ad_outbox
language sql security definer set search_path = '' as $$
  update public.ad_outbox o set attempts = attempts + 1
   where o.id in (select id from public.ad_outbox where sent_at is null and attempts < 5 order by created_at limit least(p_limit, 100) for update skip locked)
  returning o.*
$$;
create or replace function public.ad_outbox_mark_sent(p_id uuid) returns void
language sql security definer set search_path = '' as $$ update public.ad_outbox set sent_at = now() where id = p_id $$;

-- ---------------------------------------------------------------------------
-- 8. Price proposals: suggestions only. Approving changes the package price for FUTURE quotes (never old orders).
-- ---------------------------------------------------------------------------
create or replace function public.generate_price_proposals() returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_on boolean := coalesce((public.config_value('ad_auto_price_step_enabled') #>> '{}')::boolean, false);
  v_step int := least(coalesce((public.config_value('ad_auto_price_step_pct') #>> '{}')::int, 20), 30);
  v_high int := coalesce((public.config_value('slot_soldout_pct') #>> '{}')::int, 85);
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  p public.ad_products; v_new bigint; v_n int := 0; v_sold text;
begin
  if not v_on or v_step <= 0 then return 0; end if;
  for p in select * from public.ad_products where enabled and placement = 'featured' loop
    -- "Sold out last cycle": a location at this package's reach level with 30-day fill above the sold-out threshold.
    select k.key into v_sold from (
      select distinct t.target_key as key from public.campaign_targets t join public.campaigns c on c.id = t.campaign_id
       where c.placement = 'featured' and t.level = p.scope_level and c.status not in ('canceled','rejected','draft')) k
     where public.ad_fill_pct(k.key, v_today - 29, v_today) > v_high limit 1;
    continue when v_sold is null;
    v_new := greatest(round(p.price_per_target * (1 + v_step / 100.0) / 1000) * 1000, p.price_per_target + 1000);
    insert into public.ad_price_proposals (product_id, old_base, new_base, step_pct, reason)
    values (p.id, p.price_per_target, v_new, v_step,
            public.target_label(v_sold) || ' sold out in the last 30 days (fill above ' || v_high || '%).')
    on conflict (product_id) where status = 'pending' do nothing;
    v_n := v_n + (found)::int;
  end loop;
  return v_n;
end $$;

create or replace function public.admin_generate_price_proposals() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_admin();
  if not coalesce((public.config_value('ad_auto_price_step_enabled') #>> '{}')::boolean, false) then
    perform public.app_error('CSW09', 'AUTO_STEP_OFF', 'Turn on the price step setting first.');
  end if;
  return jsonb_build_object('created', public.generate_price_proposals());
end $$;

create or replace function public.admin_decide_price_proposal(p_id uuid, p_approve boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_p public.ad_price_proposals; v_cur bigint;
begin
  select * into v_p from public.ad_price_proposals where id = p_id for update;
  if not found or v_p.status <> 'pending' then
    perform public.app_error('CSW04', 'NOT_FOUND', 'Proposal not found or already decided.');
  end if;
  if p_approve then
    select price_per_target into v_cur from public.ad_products where id = v_p.product_id for update;
    if v_cur is distinct from v_p.old_base then
      perform public.app_error('CSW09', 'PROPOSAL_STALE', 'The price changed since this proposal. Generate a new one.');
    end if;
    -- A plain UPDATE: the ad_products trigger writes price history + audit; existing campaigns and orders keep their frozen price.
    update public.ad_products set price_per_target = v_p.new_base where id = v_p.product_id;
  end if;
  update public.ad_price_proposals set status = case when p_approve then 'approved' else 'rejected' end,
         decided_at = now(), decided_by = v_admin where id = p_id;
  perform public.audit('price_proposal.decide', 'ad_product', v_p.product_id, null,
    jsonb_build_object('proposal', p_id, 'approved', p_approve, 'old', v_p.old_base, 'new', v_p.new_base));
  return jsonb_build_object('ok', true, 'approved', p_approve);
end $$;

create or replace function public.admin_list_price_proposals() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'product_id', x.product_id, 'product_name', a.name,
      'old_base', x.old_base::text, 'new_base', x.new_base::text, 'step_pct', x.step_pct, 'reason', x.reason,
      'status', x.status, 'created_at', x.created_at, 'decided_at', x.decided_at) order by (x.status = 'pending') desc, x.created_at desc)
    from (select * from public.ad_price_proposals order by created_at desc limit 30) x join public.ad_products a on a.id = x.product_id), '[]'::jsonb);
end $$;

-- Price history per package (prices are per package tier, not per campus) with the 30-day fill around each change.
create or replace function public.admin_price_history(p_product text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_scope text; v_placement text;
begin
  perform public.require_admin();
  select scope_level, placement into v_scope, v_placement from public.ad_products where id = p_product;
  return coalesce((select jsonb_agg(jsonb_build_object('changed_at', h.changed_at, 'old_base', h.old_base::text, 'new_base', h.new_base::text,
      'old_enabled', h.old_enabled, 'new_enabled', h.new_enabled,
      'fill_before_30d', case when v_placement = 'featured' then f.before_fill end,
      'fill_after_30d', case when v_placement = 'featured' and h.changed_at <= now() - interval '30 days' then f.after_fill end)
      order by h.changed_at desc)
    from (select * from public.ad_price_history where product_id = p_product order by changed_at desc limit 20) h
    cross join lateral (
      select round(avg(public.ad_fill_pct(k.key, d.d0 - 30, d.d0 - 1)), 1) as before_fill,
             round(avg(public.ad_fill_pct(k.key, d.d0, d.d0 + 29)), 1) as after_fill
        from (select distinct t.target_key as key from public.campaign_targets t join public.campaigns c on c.id = t.campaign_id
               where c.placement = 'featured' and t.level = v_scope and c.status not in ('canceled','rejected','draft')) k
       cross join (select (h.changed_at at time zone 'Asia/Jakarta')::date as d0) d) f
  ), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 9. Grants (function default privileges are revoked project-wide, so everything is explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.upsert_campaign_draft(uuid, uuid, text, text, text, text, text, text, text, text, date, jsonb, text) from public, anon, authenticated;
grant execute on function public.upsert_campaign_draft(uuid, uuid, text, text, text, text, text, text, text, text, date, jsonb, text) to service_role;
grant execute on function public.get_ad_availability(text[], text, date, int),
  public.join_ad_waitlist(text, text, text, text, int, bigint) to anon, authenticated, service_role;
grant execute on function public.admin_set_slot_config(text, int, int, numeric, numeric, text), public.admin_list_slot_configs(),
  public.admin_utilization(), public.admin_generate_price_proposals(), public.admin_decide_price_proposal(uuid, boolean),
  public.admin_list_price_proposals(), public.admin_price_history(text) to authenticated, service_role;
grant execute on function public.process_ad_waitlist(), public.generate_price_proposals(), public.ad_outbox_claim(int),
  public.ad_outbox_mark_sent(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- EXECUTE allowlist (005 pattern) for the functions this migration ADDS.
-- Supabase grants EXECUTE on new public functions to anon/authenticated by default and the 005 default-privilege
-- change does not undo that, so revoke first, then re-run the client grants from the Grants section above. Everything not granted to a client role is service_role
-- only; each client-facing admin function re-checks require_admin() itself.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.ad_active_holds(text,text,uuid),
  public.ad_capacity(text,text,date,integer,uuid,text),
  public.ad_day_usage(text,date,integer,uuid),
  public.ad_enqueue(text,text,uuid,jsonb,text),
  public.ad_fill_pct(text,date,date),
  public.ad_outbox_claim(integer),
  public.ad_outbox_mark_sent(uuid),
  public.ad_sellout_days(text,date,date),
  public.ad_slot_cfg(text),
  public.ad_slot_multiplier(text[],text),
  public.admin_decide_price_proposal(uuid,boolean),
  public.admin_generate_price_proposals(),
  public.admin_list_price_proposals(),
  public.admin_list_slot_configs(),
  public.admin_price_history(text),
  public.admin_set_slot_config(text,integer,integer,numeric,numeric,text),
  public.admin_utilization(),
  public.assert_ad_capacity(campaigns,text),
  public.campaign_end_day(campaigns),
  public.campaign_start_day(campaigns),
  public.generate_price_proposals(),
  public.get_ad_availability(text[],text,date,integer),
  public.join_ad_waitlist(text,text,text,text,integer,bigint),
  public.process_ad_waitlist(),
  public.upsert_campaign_draft(uuid,uuid,text,text,text,text,text,text,text,text,date,jsonb,text)
  from public, anon, authenticated;
grant execute on function
  public.ad_active_holds(text,text,uuid),
  public.ad_capacity(text,text,date,integer,uuid,text),
  public.ad_day_usage(text,date,integer,uuid),
  public.ad_enqueue(text,text,uuid,jsonb,text),
  public.ad_fill_pct(text,date,date),
  public.ad_outbox_claim(integer),
  public.ad_outbox_mark_sent(uuid),
  public.ad_sellout_days(text,date,date),
  public.ad_slot_cfg(text),
  public.ad_slot_multiplier(text[],text),
  public.admin_decide_price_proposal(uuid,boolean),
  public.admin_generate_price_proposals(),
  public.admin_list_price_proposals(),
  public.admin_list_slot_configs(),
  public.admin_price_history(text),
  public.admin_set_slot_config(text,integer,integer,numeric,numeric,text),
  public.admin_utilization(),
  public.assert_ad_capacity(campaigns,text),
  public.campaign_end_day(campaigns),
  public.campaign_start_day(campaigns),
  public.generate_price_proposals(),
  public.get_ad_availability(text[],text,date,integer),
  public.join_ad_waitlist(text,text,text,text,integer,bigint),
  public.process_ad_waitlist(),
  public.upsert_campaign_draft(uuid,uuid,text,text,text,text,text,text,text,text,date,jsonb,text)
  to service_role;
grant execute on function public.upsert_campaign_draft(uuid, uuid, text, text, text, text, text, text, text, text, date, jsonb, text) to service_role;
grant execute on function public.get_ad_availability(text[], text, date, int),
  public.join_ad_waitlist(text, text, text, text, int, bigint) to anon, authenticated, service_role;
grant execute on function public.admin_set_slot_config(text, int, int, numeric, numeric, text), public.admin_list_slot_configs(),
  public.admin_utilization(), public.admin_generate_price_proposals(), public.admin_decide_price_proposal(uuid, boolean),
  public.admin_list_price_proposals(), public.admin_price_history(text) to authenticated, service_role;
grant execute on function public.process_ad_waitlist(), public.generate_price_proposals(), public.ad_outbox_claim(int),
  public.ad_outbox_mark_sent(uuid) to service_role;
