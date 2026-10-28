-- 032 — Phase 1: launch pricing, founding-advertiser price lock, server-side tracking, public + advertiser
-- stats, pricing analytics, waitlist. Idempotent: safe to re-run. Rollback: supabase/rollbacks/032_rollback.sql.
--
-- Nothing here changes an existing order or campaign price: prices are frozen in campaigns.price_snapshot at
-- submit and in orders.total_amount at checkout (013/019); this migration only changes how NEW quotes are made.

-- ---------------------------------------------------------------------------
-- 1. Settings. config_rules makes later phases' keys editable without re-writing admin_set_config.
-- ---------------------------------------------------------------------------
create table if not exists public.config_rules (
  key text primary key references public.site_config (key) on delete cascade,
  kind text not null check (kind in ('bool','int','number','int_array')),
  min_v numeric, max_v numeric
);
alter table public.config_rules enable row level security;
revoke all on public.config_rules from anon, authenticated;

insert into public.site_config (key, value, is_public, description) values
  ('launch_mode_enabled',     'false',       true,  'Founding advertiser launch pricing on/off (new quotes only)'),
  ('launch_discount_pct',     '50',          true,  'Global launch discount % off the base fee (per-package override on ad_products)'),
  ('founding_advertiser_count','10',         true,  'How many first paying advertisers get a locked renewal rate'),
  ('price_lock_grace_days',   '7',           true,  'Founding advertisers keep their rate when they renew within this many days of expiry'),
  ('ad_allowed_durations',    '[7,30,60,90]', true, 'Campaign lengths (days) an admin may sell'),
  ('target_cpm',              '0',           false, 'Admin target price per 1,000 ad views, in rupiah (0 = not set)'),
  ('ad_default_slots',        '3',           false, 'Featured slots per location until set per location (Phase 2)'),
  ('ad_report_email_enabled', 'true',        false, 'Email a campaign summary to the advertiser when it ends'),
  ('ad_visitor_salt',         to_jsonb(md5(random()::text || clock_timestamp()::text)), false, 'Secret salt for hashed visitor ids (not editable)')
on conflict (key) do nothing;

insert into public.config_rules (key, kind, min_v, max_v) values
  ('launch_mode_enabled','bool',null,null), ('launch_discount_pct','int',0,90),
  ('founding_advertiser_count','int',0,1000), ('price_lock_grace_days','int',0,365),
  ('ad_allowed_durations','int_array',1,365), ('target_cpm','number',0,100000000),
  ('ad_default_slots','int',1,10), ('ad_report_email_enabled','bool',null,null)
on conflict (key) do nothing;

-- Validate one config value against its rule. CASE keeps casts from running on the wrong JSON type.
create or replace function public.config_value_ok(p_kind text, p_min numeric, p_max numeric, p_value jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case p_kind
    when 'bool' then jsonb_typeof(p_value) = 'boolean'
    when 'int' then jsonb_typeof(p_value) = 'number'
      and (p_value #>> '{}')::numeric = trunc((p_value #>> '{}')::numeric)
      and (p_value #>> '{}')::numeric between p_min and p_max
    when 'number' then jsonb_typeof(p_value) = 'number' and (p_value #>> '{}')::numeric between p_min and p_max
    when 'int_array' then jsonb_typeof(p_value) = 'array' and jsonb_array_length(p_value) between 1 and 20
      and not exists (select 1 from jsonb_array_elements(p_value) e
                       where jsonb_typeof(e) <> 'number' or (e #>> '{}')::numeric <> trunc((e #>> '{}')::numeric)
                          or (e #>> '{}')::numeric not between p_min and p_max)
    else false end
$$;

-- 013's admin_set_config + config_rules keys. Every change is audited with old and new value.
create or replace function public.admin_set_config(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_rule public.config_rules; v_old jsonb;
begin
  select * into v_rule from public.config_rules where key = p_key;
  if found then
    if not public.config_value_ok(v_rule.kind, v_rule.min_v, v_rule.max_v, p_value) then
      perform public.app_error('CSW40', 'INVALID_CONFIG_VALUE');
    end if;
  else
    if p_key not in ('note_moderation','donation_min_amount','donation_max_amount','official_social_links',
                     'contact_email','display_ads_enabled','unpaid_order_ttl_minutes','ad_whatsapp','ad_payment_window_days') then
      perform public.app_error('CSW40', 'CONFIG_KEY_NOT_EDITABLE');
    end if;
    if (p_key = 'note_moderation' and p_value #>> '{}' not in ('pre','post'))
       or (p_key in ('donation_min_amount','donation_max_amount','unpaid_order_ttl_minutes','ad_payment_window_days')
           and (jsonb_typeof(p_value) <> 'number' or (p_value #>> '{}')::numeric < 1))
       or (p_key = 'display_ads_enabled' and jsonb_typeof(p_value) <> 'boolean')
       or (p_key = 'official_social_links' and jsonb_typeof(p_value) <> 'object')
       or (p_key = 'contact_email' and jsonb_typeof(p_value) <> 'string')
       or (p_key = 'ad_whatsapp' and (jsonb_typeof(p_value) <> 'string' or p_value #>> '{}' !~ '^([0-9]{8,15})?$')) then
      perform public.app_error('CSW40', 'INVALID_CONFIG_VALUE');
    end if;
    if p_key = 'official_social_links' and exists (
         select 1 from jsonb_each(p_value) e where jsonb_typeof(e.value) <> 'string'
           or not public.is_allowed_social_url(e.value #>> '{}')) then
      perform public.app_error('CSW40', 'INVALID_SOCIAL_LINK');
    end if;
  end if;
  select value into v_old from public.site_config where key = p_key;
  update public.site_config set value = p_value, updated_by = v_admin where key = p_key;
  perform public.audit('config.set', 'config', p_key, null, jsonb_build_object('old', v_old, 'value', p_value));
  return jsonb_build_object('key', p_key, 'value', p_value);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Schema: launch discount, price breakdown on the campaign, founding advertisers, price history
-- ---------------------------------------------------------------------------
alter table public.ad_products add column if not exists launch_discount_pct int
  check (launch_discount_pct is null or launch_discount_pct between 0 and 90);

alter table public.campaigns
  add column if not exists list_price_snapshot bigint,
  add column if not exists launch_discount_pct int,
  add column if not exists price_locked boolean not null default false,
  add column if not exists price_base_used bigint,
  add column if not exists price_extra_pct_used int,
  add column if not exists report_emailed_at timestamptz;

create table if not exists public.founding_advertisers (
  user_id uuid primary key references auth.users (id) on delete cascade,
  rank int not null unique,
  first_order_id uuid references public.orders (id) on delete set null,
  created_at timestamptz not null default now()
);
-- The rate a founding advertiser first paid for a package (base fee before any slot multiplier).
create table if not exists public.founding_rates (
  user_id uuid not null references auth.users (id) on delete cascade,
  product_id text not null references public.ad_products (id),
  base_fee bigint not null check (base_fee > 0),
  extra_location_pct int not null,
  source_order_id uuid references public.orders (id) on delete set null,
  locked_at timestamptz not null default now(),
  primary key (user_id, product_id)
);
alter table public.founding_advertisers enable row level security;
alter table public.founding_rates enable row level security;
revoke all on public.founding_advertisers, public.founding_rates from anon, authenticated;
grant select on public.founding_advertisers, public.founding_rates to authenticated;
drop policy if exists founding_own_read on public.founding_advertisers;
drop policy if exists founding_rates_own_read on public.founding_rates;
create policy founding_own_read on public.founding_advertisers for select to authenticated using (user_id = (select auth.uid()));
create policy founding_rates_own_read on public.founding_rates for select to authenticated using (user_id = (select auth.uid()));

create table if not exists public.ad_price_history (
  id bigint generated always as identity primary key,
  product_id text not null references public.ad_products (id) on delete cascade,
  changed_at timestamptz not null default now(),
  changed_by uuid,
  old_base bigint, new_base bigint,
  old_extra_pct int, new_extra_pct int,
  old_enabled boolean, new_enabled boolean,
  old_duration int, new_duration int,
  old_launch_pct int, new_launch_pct int
);
create index if not exists ad_price_history_product on public.ad_price_history (product_id, changed_at desc);
alter table public.ad_price_history enable row level security;
revoke all on public.ad_price_history from anon, authenticated;

-- Every change to a package (admin save, approved proposal, SQL) is logged here and in the audit log.
create or replace function public.ad_products_log_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and (old.price_per_target, old.extra_location_pct, old.enabled, old.duration_days, old.launch_discount_pct)
       is not distinct from (new.price_per_target, new.extra_location_pct, new.enabled, new.duration_days, new.launch_discount_pct) then
    return new;
  end if;
  insert into public.ad_price_history (product_id, changed_by, old_base, new_base, old_extra_pct, new_extra_pct,
    old_enabled, new_enabled, old_duration, new_duration, old_launch_pct, new_launch_pct)
  values (new.id, auth.uid(),
    case when tg_op = 'UPDATE' then old.price_per_target end, new.price_per_target,
    case when tg_op = 'UPDATE' then old.extra_location_pct end, new.extra_location_pct,
    case when tg_op = 'UPDATE' then old.enabled end, new.enabled,
    case when tg_op = 'UPDATE' then old.duration_days end, new.duration_days,
    case when tg_op = 'UPDATE' then old.launch_discount_pct end, new.launch_discount_pct);
  perform public.audit('ad_product.change', 'ad_product', new.id, null, jsonb_build_object(
    'old', case when tg_op = 'UPDATE' then jsonb_build_object('base', old.price_per_target::text, 'extra_pct', old.extra_location_pct,
             'enabled', old.enabled, 'duration', old.duration_days, 'launch_pct', old.launch_discount_pct) end,
    'new', jsonb_build_object('base', new.price_per_target::text, 'extra_pct', new.extra_location_pct,
             'enabled', new.enabled, 'duration', new.duration_days, 'launch_pct', new.launch_discount_pct)));
  return new;
end $$;
drop trigger if exists ad_products_log_change on public.ad_products;
create trigger ad_products_log_change after insert or update on public.ad_products
  for each row execute function public.ad_products_log_change();

-- ---------------------------------------------------------------------------
-- 3. 14-day tier: soft-disable only. Rows, campaigns and orders stay as they are.
-- ---------------------------------------------------------------------------
update public.ad_products set enabled = false where duration_days = 14 and enabled;

-- ---------------------------------------------------------------------------
-- 4. Quoting. ONE place decides what a new quote costs (submit and checkout both read the frozen snapshot).
--    price = ad_price(effective base, extra %, locations), where effective base = list base - launch discount.
--    A founding advertiser renewing inside the grace period pays the LOWER of that and their locked rate.
-- ---------------------------------------------------------------------------
create or replace function public.launch_mode_on() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((public.config_value('launch_mode_enabled') #>> '{}')::boolean, false)
$$;

create or replace function public.ad_discount_pct(p public.ad_products) returns int
language sql stable security definer set search_path = '' as $$
  select case when public.launch_mode_on()
              then coalesce(p.launch_discount_pct, coalesce((public.config_value('launch_discount_pct') #>> '{}')::int, 0))
              else 0 end
$$;

create or replace function public.ad_effective_base(p public.ad_products) returns bigint
language sql stable security definer set search_path = '' as $$
  select greatest(round(p.price_per_target::numeric * (100 - public.ad_discount_pct(p)) / 100)::bigint, 1)
$$;

-- Did this advertiser run this exact package and is it still running or within the grace period after it ended?
create or replace function public.price_lock_renewal_ok(p_owner uuid, p_product text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.campaigns c join public.orders o on o.id = c.order_id and o.status = 'paid'
     where c.owner_id = p_owner and c.product_id = p_product and c.ends_at is not null
       and c.status not in ('canceled','rejected')
       and c.ends_at >= now() - make_interval(days => coalesce((public.config_value('price_lock_grace_days') #>> '{}')::int, 7)))
$$;

create or replace function public.ad_quote(p_owner uuid, p_product public.ad_products, p_locations int) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_disc int := public.ad_discount_pct(p_product);
  v_base bigint := public.ad_effective_base(p_product);
  v_pct int := p_product.extra_location_pct;
  v_total bigint;
  v_locked boolean := false;
  v_lb bigint; v_lp int; v_lt bigint;
begin
  v_total := public.ad_price(v_base, v_pct, p_locations);
  select r.base_fee, r.extra_location_pct into v_lb, v_lp
    from public.founding_rates r where r.user_id = p_owner and r.product_id = p_product.id;
  if found and public.price_lock_renewal_ok(p_owner, p_product.id) then
    v_lt := public.ad_price(v_lb, v_lp, p_locations);
    if v_lt < v_total then v_total := v_lt; v_base := v_lb; v_pct := v_lp; v_locked := true; end if;
  end if;
  return jsonb_build_object('list_total', public.ad_price(p_product.price_per_target, p_product.extra_location_pct, p_locations),
    'total', v_total, 'discount_pct', v_disc, 'locked', v_locked, 'base_used', v_base, 'extra_pct_used', v_pct);
end $$;

-- Public price list: list base, launch-adjusted base and the badge flag. The browser prices from THIS, never from raw rows.
create or replace function public.ad_catalog() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'name', a.name, 'placement', a.placement, 'scope_level', a.scope_level, 'duration_days', a.duration_days,
    'extra_location_pct', a.extra_location_pct,
    'price_per_target', public.ad_effective_base(a)::text,
    'list_price_per_target', a.price_per_target::text,
    'discount_pct', public.ad_discount_pct(a),
    'launch', public.ad_discount_pct(a) > 0) order by a.sort_order), '[]'::jsonb)
  from public.ad_products a where a.enabled
$$;

-- ---------------------------------------------------------------------------
-- 5. Founding advertisers: the first N paying advertisers keep the rate they first paid for each package.
-- ---------------------------------------------------------------------------
create or replace function public.register_founding_advertiser(p_user uuid, p_order uuid, p_campaign public.campaigns)
returns void language plpgsql security definer set search_path = '' as $$
declare v_limit int := coalesce((public.config_value('founding_advertiser_count') #>> '{}')::int, 10);
begin
  if p_user is null then return; end if;
  perform pg_advisory_xact_lock(hashtext('founding_advertisers'));
  if not exists (select 1 from public.founding_advertisers where user_id = p_user)
     and (select count(*) from public.founding_advertisers) < v_limit then
    insert into public.founding_advertisers (user_id, rank, first_order_id)
    values (p_user, coalesce((select max(rank) from public.founding_advertisers), 0) + 1, p_order);
  end if;
  if exists (select 1 from public.founding_advertisers where user_id = p_user) and p_campaign.price_base_used is not null then
    insert into public.founding_rates (user_id, product_id, base_fee, extra_location_pct, source_order_id)
    values (p_user, p_campaign.product_id, p_campaign.price_base_used, p_campaign.price_extra_pct_used, p_order)
    on conflict (user_id, product_id) do nothing;
  end if;
end $$;

-- Backfill: existing paying advertisers, oldest first, up to the limit. Their base fee comes from the order snapshot.
do $$
declare r record; v_limit int := coalesce((public.config_value('founding_advertiser_count') #>> '{}')::int, 10);
begin
  for r in select o.user_id, min(o.paid_at) as first_paid,
                  (array_agg(o.id order by o.paid_at))[1] as first_order
             from public.orders o
            where o.kind = 'advertising' and o.status = 'paid' and o.user_id is not null
            group by o.user_id order by min(o.paid_at) loop
    exit when (select count(*) from public.founding_advertisers) >= v_limit;
    insert into public.founding_advertisers (user_id, rank, first_order_id)
    values (r.user_id, coalesce((select max(rank) from public.founding_advertisers), 0) + 1, r.first_order)
    on conflict do nothing;
  end loop;
  insert into public.founding_rates (user_id, product_id, base_fee, extra_location_pct, source_order_id)
  select distinct on (o.user_id, o.snapshot ->> 'product_id') o.user_id, o.snapshot ->> 'product_id',
         (o.snapshot ->> 'price_per_target')::bigint, p.extra_location_pct, o.id
    from public.orders o
    join public.founding_advertisers f on f.user_id = o.user_id
    join public.ad_products p on p.id = o.snapshot ->> 'product_id'
   where o.kind = 'advertising' and o.status = 'paid' and (o.snapshot ->> 'price_per_target') ~ '^[0-9]+$'
     and (o.snapshot ->> 'price_per_target')::bigint > 0
   order by o.user_id, o.snapshot ->> 'product_id', o.paid_at
  on conflict do nothing;
end $$;

create or replace function public.my_price_locks() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then return jsonb_build_object('founding', false, 'locks', '[]'::jsonb); end if;
  return jsonb_build_object(
    'founding', exists (select 1 from public.founding_advertisers where user_id = v_uid),
    'rank', (select rank from public.founding_advertisers where user_id = v_uid),
    'grace_days', coalesce((public.config_value('price_lock_grace_days') #>> '{}')::int, 7),
    'locks', coalesce((select jsonb_agg(jsonb_build_object('product_id', r.product_id, 'name', p.name,
        'base_fee', r.base_fee::text, 'extra_location_pct', r.extra_location_pct, 'locked_at', r.locked_at,
        'renewal_open', public.price_lock_renewal_ok(v_uid, r.product_id)) order by p.sort_order)
        from public.founding_rates r join public.ad_products p on p.id = r.product_id where r.user_id = v_uid), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 6. Submit / checkout / fulfil with the new quote. Copies of 031 / 019 / 013 with ONLY the pricing parts changed.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_campaign_draft(
  p_owner uuid, p_campaign_id uuid, p_advertiser_name text, p_contact_email text, p_title text,
  p_description text, p_category text, p_creative_path text, p_destination_url text,
  p_product_id text, p_requested_start date, p_targets jsonb
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
      creative_path, destination_url, product_id, placement, scope_level, duration_days, requested_start, status)
    values (p_owner, btrim(p_advertiser_name), btrim(p_contact_email), btrim(p_title), btrim(p_description), p_category,
      p_creative_path, nullif(btrim(coalesce(p_destination_url, '')), ''), v_product.id, v_product.placement,
      v_product.scope_level, v_product.duration_days, p_requested_start, 'pending_approval')
    returning id into v_id;
  else
    update public.campaigns set advertiser_name = btrim(p_advertiser_name), contact_email = btrim(p_contact_email),
           title = btrim(p_title), description = btrim(p_description), category = p_category,
           creative_path = p_creative_path, destination_url = nullif(btrim(coalesce(p_destination_url, '')), ''),
           product_id = v_product.id, placement = v_product.placement, scope_level = v_product.scope_level,
           duration_days = v_product.duration_days, requested_start = p_requested_start, status = 'pending_approval',
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

  v_q := public.ad_quote(p_owner, v_product, v_count);
  v_price := (v_q ->> 'total')::bigint;
  perform public.require_payable_total(v_price);
  update public.campaigns set price_snapshot = v_price, list_price_snapshot = (v_q ->> 'list_total')::bigint,
         launch_discount_pct = (v_q ->> 'discount_pct')::int, price_locked = (v_q ->> 'locked')::boolean,
         price_base_used = (v_q ->> 'base_used')::bigint, price_extra_pct_used = (v_q ->> 'extra_pct_used')::int
   where id = v_id;
  return jsonb_build_object('campaign_id', v_id, 'target_count', v_count, 'price', v_price::text,
    'list_price', (v_q ->> 'list_total'), 'discount_pct', (v_q ->> 'discount_pct')::int,
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
create or replace function public.fulfill_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_paths text[]; v_c public.campaigns; v_start timestamptz;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order.fulfilled_at is not null then
    return;
  end if;
  update public.orders set fulfilled_at = now() where id = p_order_id;
  if v_order.kind = 'publication' then
    perform public.consume_order_credit(p_order_id);
    perform public.release_note_for_order(p_order_id);
    if v_order.user_id is not null then perform public.qualify_referral(v_order.user_id); end if;
    update public.promo_redemptions set order_id = null where order_id = p_order_id;
    update public.free_post_claims set order_id = null where order_id = p_order_id;
    update public.referral_credits set redeemed_order_id = null where redeemed_order_id = p_order_id;
    update public.credits set redeemed_order_id = null where redeemed_order_id = p_order_id;
    update public.orders set user_id = null where id = p_order_id;
    select public.note_media_paths(media) into v_paths from public.notes where order_id = p_order_id;
    perform public.burn_media_owner(v_paths);
  elsif v_order.kind = 'donation' then
    update public.donations set status = 'succeeded', succeeded_at = now()
     where order_id = p_order_id and status = 'pending';
  elsif v_order.kind = 'advertising' then
    select * into v_c from public.campaigns where order_id = p_order_id and status = 'awaiting_payment' for update;
    if found then
      if v_c.approved_at is null then
        update public.campaigns set status = 'pending_review' where id = v_c.id;
      else
        v_start := greatest(now(), (v_c.requested_start::timestamp at time zone 'Asia/Jakarta'));
        update public.campaigns set starts_at = v_start, ends_at = v_start + make_interval(days => v_c.duration_days),
               status = case when v_start > now() then 'scheduled' else 'active' end
         where id = v_c.id;
      end if;
      perform public.register_founding_advertiser(v_order.user_id, p_order_id, v_c);
    end if;
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 7. Admin package editor: server-side validation, no retroactive change, confirmations.
-- ---------------------------------------------------------------------------
create or replace function public.admin_ad_product_impact(p_id text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'open_campaigns', (select count(*) from public.campaigns where product_id = p_id
       and status in ('pending_approval','approved','awaiting_payment','pending_review','scheduled','active','paused')),
    'running_campaigns', (select count(*) from public.campaigns where product_id = p_id
       and status in ('scheduled','active','paused')));
end $$;

drop function if exists public.admin_upsert_ad_product(text, text, text, text, int, text, boolean, int, int);
create or replace function public.admin_upsert_ad_product(p_id text, p_name text, p_placement text, p_scope_level text,
  p_duration_days int, p_price text, p_enabled boolean, p_sort int default 0, p_extra_pct int default 100,
  p_launch_pct int default null, p_confirm_active boolean default false, p_confirm_big boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_price bigint := public.parse_amount(p_price);
  v_old public.ad_products;
  v_open int;
  v_allowed jsonb := coalesce(public.config_value('ad_allowed_durations'), '[7,30,60,90]'::jsonb);
  v_enabled boolean := coalesce(p_enabled, true);
begin
  perform public.require_admin();
  if v_price is null or v_price <= 0 then perform public.app_error('CSW40', 'INVALID_PRICE', 'Price must be more than 0.'); end if;
  if coalesce(p_extra_pct, 100) not between 0 and 100 then
    perform public.app_error('CSW40', 'INVALID_SURCHARGE', 'Extra-location surcharge must be between 0 and 100.');
  end if;
  if p_launch_pct is not null and p_launch_pct not between 0 and 90 then
    perform public.app_error('CSW40', 'INVALID_DISCOUNT', 'Launch discount must be between 0 and 90.');
  end if;
  select * into v_old from public.ad_products where id = p_id for update;
  -- Duration must be on the allowed list. A retired row (e.g. 14 days) may be saved as long as it stays disabled and unchanged.
  if not (v_allowed @> to_jsonb(p_duration_days))
     and not (found and v_old.duration_days = p_duration_days and not v_enabled) then
    perform public.app_error('CSW40', 'INVALID_DURATION', 'Duration must be one of the allowed lengths.');
  end if;
  if v_old.id is not null then
    select count(*) into v_open from public.campaigns where product_id = p_id
       and status in ('pending_approval','approved','awaiting_payment','pending_review','scheduled','active','paused');
    if (v_old.price_per_target is distinct from v_price or v_old.extra_location_pct is distinct from coalesce(p_extra_pct, 100)) then
      if v_old.price_per_target > 0 and abs(v_price - v_old.price_per_target)::numeric / v_old.price_per_target > 0.5
         and not coalesce(p_confirm_big, false) then
        perform public.app_error('CSW40', 'PRICE_CHANGE_CONFIRM_BIG', 'This changes the price by more than 50%. Confirm to continue.');
      end if;
      if v_open > 0 and not coalesce(p_confirm_active, false) then
        perform public.app_error('CSW40', 'PRICE_CHANGE_CONFIRM_ACTIVE',
          v_open || ' campaigns use this package. Their prices will NOT change; only new quotes use the new price. Confirm to continue.');
      end if;
    end if;
  end if;
  insert into public.ad_products (id, name, placement, scope_level, duration_days, price_per_target, extra_location_pct, enabled, sort_order, launch_discount_pct)
  values (p_id, p_name, p_placement, p_scope_level, p_duration_days, v_price, coalesce(p_extra_pct, 100), v_enabled, coalesce(p_sort, 0), p_launch_pct)
  on conflict (id) do update set name = excluded.name, placement = excluded.placement, scope_level = excluded.scope_level,
    duration_days = excluded.duration_days, price_per_target = excluded.price_per_target,
    extra_location_pct = excluded.extra_location_pct, enabled = excluded.enabled, sort_order = excluded.sort_order,
    launch_discount_pct = excluded.launch_discount_pct;
  return jsonb_build_object('id', p_id);
end $$;

-- Admin lists: locked rate and founding rank next to the order / campaign.
create or replace function public.admin_list_orders(p_kind text default null, p_status text default null,
  p_review_only boolean default false, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select o.order_ref, o.kind, o.status, o.total_amount::text as total_amount, o.discount_amount::text as discount_amount,
           o.refunded_amount::text as refunded_amount, o.payment_type, o.review_required, o.review_reason,
           o.created_at, o.paid_at, o.user_id is not null as has_account,
           (o.snapshot ->> 'list_price') as list_price, (o.snapshot ->> 'launch_discount_pct')::int as launch_discount_pct,
           coalesce((o.snapshot ->> 'price_locked')::boolean, false) as price_locked,
           (o.snapshot ->> 'base_fee_used') as locked_base_fee,
           (select f.rank from public.founding_advertisers f where f.user_id = o.user_id) as founding_rank
      from public.orders o
     where (p_kind is null or o.kind = p_kind) and (p_status is null or o.status = p_status)
       and (not coalesce(p_review_only, false) or o.review_required)
     order by o.created_at desc
     limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) x), '[]'::jsonb);
end $$;

create or replace function public.admin_list_campaigns(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select c.id, c.title, c.description, c.advertiser_name, c.contact_email, c.category, c.placement, c.scope_level,
           c.duration_days, c.destination_url, c.creative_path, c.status, c.requested_start, c.starts_at, c.ends_at,
           c.price_snapshot::text as price, c.list_price_snapshot::text as list_price, c.launch_discount_pct, c.price_locked,
           c.price_base_used::text as price_base_used,
           (select f.rank from public.founding_advertisers f where f.user_id = c.owner_id) as founding_rank,
           (select coalesce(sum(s.impressions), 0) from public.campaign_daily_stats s where s.campaign_id = c.id) as impressions,
           (select coalesce(sum(s.clicks), 0) from public.campaign_daily_stats s where s.campaign_id = c.id) as clicks,
           c.created_at, c.moderation_reason,
           o.status as payment_status, o.order_ref,
           (select jsonb_agg(t.target_key) from public.campaign_targets t where t.campaign_id = c.id) as targets
      from public.campaigns c left join public.orders o on o.id = c.order_id
     where p_status is null or c.status = p_status
     order by c.created_at desc limit 200) x), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Tracking. Counting rules live in ONE function (record_ad_event, service role). The public wrapper keeps the
--    old rpc name working for impressions; clicks only count through the server-side redirect (ad-click).
-- ---------------------------------------------------------------------------
create table if not exists public.ad_impression_log (
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  visitor_hash text not null,
  hour_bucket timestamptz not null,
  target_keys text[] not null default '{}',
  primary key (campaign_id, visitor_hash, hour_bucket)
);
create index if not exists ad_impression_log_hour on public.ad_impression_log (hour_bucket);

create table if not exists public.ad_click_log (
  id bigint generated always as identity primary key,
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  at timestamptz not null default now(),
  visitor_hash text,
  target_keys text[] not null default '{}',
  referrer_host text,
  utm_source text, utm_medium text, utm_campaign text
);
create index if not exists ad_click_log_campaign on public.ad_click_log (campaign_id, at);

-- Impressions/clicks per campaign target and spot ('featured' | 'random') per day: public stats, fill, pricing analytics.
create table if not exists public.ad_location_daily (
  target_key text not null,
  spot text not null check (spot in ('featured','random')),
  day date not null,
  impressions bigint not null default 0,
  clicks bigint not null default 0,
  primary key (target_key, spot, day)
);
alter table public.ad_impression_log enable row level security;
alter table public.ad_click_log enable row level security;
alter table public.ad_location_daily enable row level security;
revoke all on public.ad_impression_log, public.ad_click_log, public.ad_location_daily from anon, authenticated;

create or replace function public.ad_spot(p_placement text) returns text
language sql immutable set search_path = '' as $$ select case when p_placement = 'featured' then 'featured' else 'random' end $$;

-- The campaign targets that cover this viewer location (the same rule get_promotions uses).
create or replace function public.campaign_matched_keys(p_campaign uuid, p_country text, p_region uuid, p_city uuid, p_campus uuid)
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare v_loc record;
begin
  select * into v_loc from public.resolve_location(p_country, p_region, p_city, p_campus);
  return coalesce((select array_agg(t.target_key order by t.target_key) from public.campaign_targets t
    where t.campaign_id = p_campaign and (t.level = 'global'
      or (t.level = 'country' and v_loc.country_code is not null and t.country_code = v_loc.country_code)
      or (t.level = 'region'  and v_loc.region_id is not null and t.region_id = v_loc.region_id)
      or (t.level = 'city'    and v_loc.city_id is not null and t.city_id = v_loc.city_id)
      or (t.level = 'campus'  and v_loc.campus_id is not null and t.campus_id = v_loc.campus_id))), '{}');
end $$;

create or replace function public.is_bot_agent(p_ua text) returns boolean
language sql immutable set search_path = '' as $$
  select p_ua is null or length(btrim(p_ua)) < 8
      or p_ua ~* '(bot|crawl|spider|slurp|facebookexternalhit|preview|headless|lighthouse|pingdom|uptime|monitor|curl/|wget|python-requests|httpclient|go-http|okhttp|node-fetch|axios|java/|libwww|scrapy|phantomjs)'
$$;

create or replace function public.visitor_hash(p_ip text, p_ua text) returns text
language sql stable security definer set search_path = '' as $$
  select encode(sha256(convert_to(coalesce(public.config_value('ad_visitor_salt') #>> '{}', '') || '|' ||
         coalesce(p_ip, '') || '|' || coalesce(p_ua, ''), 'UTF8')), 'hex')
$$;

create or replace function public.record_ad_event(
  p_campaign_id uuid, p_kind text, p_visitor_hash text, p_ua text default null, p_is_admin boolean default false,
  p_country text default null, p_region uuid default null, p_city uuid default null, p_campus uuid default null,
  p_referrer_host text default null, p_utm_source text default null, p_utm_medium text default null, p_utm_campaign text default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_c public.campaigns; v_keys text[]; v_spot text; v_day date := (now() at time zone 'Asia/Jakarta')::date; v_rows int; v_k text;
begin
  if p_kind not in ('impression','click') then perform public.app_error('CSW40', 'INVALID_EVENT'); end if;
  if coalesce(p_is_admin, false) or public.is_bot_agent(p_ua) or p_visitor_hash is null then return false; end if;
  select * into v_c from public.campaigns where id = p_campaign_id;
  if not found or not public.campaign_is_live(v_c) then return false; end if;
  if not public.check_rate_limit('ad-event:' || p_kind || ':' || p_campaign_id::text, case p_kind when 'click' then 60 else 600 end, 60)
     or not public.check_rate_limit('ad-event:v:' || p_kind || ':' || p_visitor_hash, case p_kind when 'click' then 10 else 120 end, 60) then
    return false;
  end if;
  v_keys := public.campaign_matched_keys(p_campaign_id, p_country, p_region, p_city, p_campus);
  v_spot := public.ad_spot(v_c.placement);
  if p_kind = 'impression' then
    -- once per visitor per ad per hour
    insert into public.ad_impression_log (campaign_id, visitor_hash, hour_bucket, target_keys)
    values (p_campaign_id, p_visitor_hash, date_trunc('hour', now()), v_keys) on conflict do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then return false; end if;
    if random() < 0.01 then delete from public.ad_impression_log where hour_bucket < now() - interval '100 days'; end if;
  else
    insert into public.ad_click_log (campaign_id, visitor_hash, target_keys, referrer_host, utm_source, utm_medium, utm_campaign)
    values (p_campaign_id, p_visitor_hash, v_keys, left(p_referrer_host, 100), left(p_utm_source, 60), left(p_utm_medium, 60), left(p_utm_campaign, 80));
  end if;
  insert into public.campaign_daily_stats (campaign_id, day, impressions, clicks)
  values (p_campaign_id, v_day, (p_kind = 'impression')::int, (p_kind = 'click')::int)
  on conflict (campaign_id, day) do update
    set impressions = public.campaign_daily_stats.impressions + excluded.impressions,
        clicks = public.campaign_daily_stats.clicks + excluded.clicks;
  foreach v_k in array v_keys loop
    insert into public.ad_location_daily (target_key, spot, day, impressions, clicks)
    values (v_k, v_spot, v_day, (p_kind = 'impression')::int, (p_kind = 'click')::int)
    on conflict (target_key, spot, day) do update
      set impressions = public.ad_location_daily.impressions + excluded.impressions,
          clicks = public.ad_location_daily.clicks + excluded.clicks;
  end loop;
  return true;
end $$;

-- Old name kept for cached clients. Impressions only; the visitor comes from the request headers PostgREST sets.
drop function if exists public.record_campaign_event(uuid, text);
create or replace function public.record_campaign_event(p_campaign_id uuid, p_kind text,
  p_country text default null, p_region uuid default null, p_city uuid default null, p_campus uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_h jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb); v_ip text; v_ua text;
begin
  if p_kind not in ('impression','click') then perform public.app_error('CSW40', 'INVALID_EVENT'); end if;
  if p_kind = 'click' then return; end if;          -- clicks count only through the server-side redirect
  v_ip := btrim(split_part(coalesce(v_h ->> 'cf-connecting-ip', v_h ->> 'x-forwarded-for', ''), ',', 1));
  v_ua := v_h ->> 'user-agent';
  perform public.record_ad_event(p_campaign_id, 'impression', public.visitor_hash(v_ip, v_ua), v_ua,
    public.is_admin((select auth.uid())), p_country, p_region, p_city, p_campus);
end $$;

-- Destination for the click redirect. Only a live campaign's own https link is ever returned (no open redirect).
create or replace function public.ad_click_target(p_campaign_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select c.destination_url from public.campaigns c where c.id = p_campaign_id and public.campaign_is_live(c)
$$;

-- ---------------------------------------------------------------------------
-- 9. Live stats (public), advertiser report, end-of-campaign email queue
-- ---------------------------------------------------------------------------
create or replace function public.target_label(p_key text) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(case split_part(p_key, ':', 1)
    when 'global'  then 'Global'
    when 'country' then (select name from public.countries where code = split_part(p_key, ':', 2))
    when 'region'  then (select name from public.regions where id::text = split_part(p_key, ':', 2))
    when 'city'    then (select name from public.cities where id::text = split_part(p_key, ':', 2))
    when 'campus'  then (select coalesce(short_name, name) from public.campuses where id::text = split_part(p_key, ':', 2))
  end, p_key)
$$;

-- Real numbers only: callers show "New platform, launch pricing applies" when views_total is 0.
create or replace function public.get_public_stats() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'updated_at', now(),
    'views_total', (select coalesce(sum(impressions), 0) from public.campaign_daily_stats),
    'clicks_total', (select coalesce(sum(clicks), 0) from public.campaign_daily_stats),
    'views_30d', (select coalesce(sum(impressions), 0) from public.campaign_daily_stats where day >= (now() at time zone 'Asia/Jakarta')::date - 29),
    'clicks_30d', (select coalesce(sum(clicks), 0) from public.campaign_daily_stats where day >= (now() at time zone 'Asia/Jakarta')::date - 29),
    'since', (select min(day) from public.campaign_daily_stats),
    'locations', coalesce((select jsonb_agg(x order by x.views desc) from (
        select l.target_key as key, public.target_label(l.target_key) as label,
               sum(l.impressions) as views, sum(l.clicks) as clicks,
               coalesce(sum(l.impressions) filter (where l.day >= (now() at time zone 'Asia/Jakarta')::date - 29), 0) as views_30d,
               coalesce(sum(l.clicks) filter (where l.day >= (now() at time zone 'Asia/Jakarta')::date - 29), 0) as clicks_30d
          from public.ad_location_daily l group by l.target_key having sum(l.impressions) > 0
         order by sum(l.impressions) desc limit 200) x), '[]'::jsonb))
$$;

-- Views in the last 7 days per location key, for the buyer-facing trust line.
create or replace function public.get_locations_recent_views(p_spot text, p_keys text[]) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'label', public.target_label(k),
    'views_7d', coalesce((select sum(l.impressions) from public.ad_location_daily l
        where l.target_key = k and l.spot = p_spot and l.day >= (now() at time zone 'Asia/Jakarta')::date - 6), 0))), '[]'::jsonb)
  from unnest((select array_agg(distinct x) from unnest(p_keys[1:20]) x
                where x ~ '^(global:\*|country:[A-Z]{2}|(region|city|campus):[0-9a-f-]{36})$')) k
  where p_spot in ('featured','random')
$$;

create or replace function public.campaign_report(p_campaign_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_c public.campaigns; v_imp bigint; v_clk bigint;
begin
  select * into v_c from public.campaigns where id = p_campaign_id and (owner_id = v_uid or public.is_admin(v_uid));
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  select coalesce(sum(impressions), 0), coalesce(sum(clicks), 0) into v_imp, v_clk
    from public.campaign_daily_stats where campaign_id = p_campaign_id;
  return jsonb_build_object(
    'campaign', jsonb_build_object('id', v_c.id, 'title', v_c.title, 'advertiser_name', v_c.advertiser_name, 'status', v_c.status,
      'product', (select name from public.ad_products where id = v_c.product_id), 'starts_at', v_c.starts_at, 'ends_at', v_c.ends_at,
      'duration_days', v_c.duration_days, 'price_paid', (select total_amount::text from public.orders where id = v_c.order_id),
      'list_price', v_c.list_price_snapshot::text, 'price_locked', v_c.price_locked),
    'totals', jsonb_build_object('impressions', v_imp, 'clicks', v_clk,
      'ctr', case when v_imp > 0 then round(v_clk::numeric * 100 / v_imp, 2) end,
      'unique_visitors', (select count(distinct visitor_hash) from public.ad_impression_log where campaign_id = p_campaign_id)),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'impressions', impressions, 'clicks', clicks,
      'ctr', case when impressions > 0 then round(clicks::numeric * 100 / impressions, 2) end) order by day)
      from public.campaign_daily_stats where campaign_id = p_campaign_id), '[]'::jsonb),
    'referrers', coalesce((select jsonb_agg(jsonb_build_object('host', h, 'clicks', n) order by n desc)
      from (select coalesce(nullif(referrer_host, ''), '(direct)') h, count(*) n from public.ad_click_log
             where campaign_id = p_campaign_id group by 1 order by 2 desc limit 20) r), '[]'::jsonb),
    'utm_sources', coalesce((select jsonb_agg(jsonb_build_object('source', s, 'clicks', n) order by n desc)
      from (select coalesce(nullif(utm_source, ''), '(none)') s, count(*) n from public.ad_click_log
             where campaign_id = p_campaign_id group by 1 order by 2 desc limit 20) r), '[]'::jsonb));
end $$;

-- Campaigns that ended and whose summary email has not gone out. Existing ended campaigns are marked done so nobody
-- receives a report for an old campaign.
update public.campaigns set report_emailed_at = now() where ends_at is not null and ends_at <= now() and report_emailed_at is null;

create or replace function public.campaigns_due_report() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'contact_email', c.contact_email,
    'impressions', coalesce((select sum(impressions) from public.campaign_daily_stats where campaign_id = c.id), 0),
    'clicks', coalesce((select sum(clicks) from public.campaign_daily_stats where campaign_id = c.id), 0),
    'starts_at', c.starts_at, 'ends_at', c.ends_at)), '[]'::jsonb)
  from (select * from public.campaigns where ends_at <= now() and report_emailed_at is null
           and status in ('expired','active','scheduled') and order_id is not null limit 50) c
  where coalesce((public.config_value('ad_report_email_enabled') #>> '{}')::boolean, true)
$$;
create or replace function public.mark_report_emailed(p_ids uuid[]) returns void
language sql security definer set search_path = '' as $$
  update public.campaigns set report_emailed_at = now() where id = any (p_ids) and report_emailed_at is null
$$;

-- ---------------------------------------------------------------------------
-- 10. Pricing analytics (admin). Slots per location come from ad_slots_for (default now, per-location in Phase 2).
-- ---------------------------------------------------------------------------
create or replace function public.ad_slots_for(p_spot text, p_key text) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce((public.config_value('ad_default_slots') #>> '{}')::int, 3)
$$;

-- Sold slot-days at a target between two dates (Jakarta days, inclusive): per day min(campaigns running, slots).
create or replace function public.ad_slot_days_sold(p_spot text, p_key text, p_from date, p_to date) returns bigint
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(least(n, public.ad_slots_for(p_spot, p_key))), 0)::bigint from (
    select d, (select count(*) from public.campaigns c
                join public.campaign_targets t on t.campaign_id = c.id and t.target_key = p_key
                join public.orders o on o.id = c.order_id and o.status = 'paid'
               where public.ad_spot(c.placement) = p_spot and c.status not in ('canceled','rejected')
                 and c.starts_at < ((d + 1)::timestamp at time zone 'Asia/Jakarta')
                 and c.ends_at > (d::timestamp at time zone 'Asia/Jakarta')) n
      from generate_series(p_from, p_to, interval '1 day') g(d0), lateral (select d0::date as d) x) q
$$;

create or replace function public.admin_pricing_analytics(p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_days int := case when p_days = 7 then 7 else 30 end;
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_from date;
  v_cpm numeric := coalesce((public.config_value('target_cpm') #>> '{}')::numeric, 0);
  v_rows jsonb;
begin
  perform public.require_admin();
  v_from := v_today - (v_days - 1);
  select coalesce(jsonb_agg(r order by r.impressions desc, r.label), '[]'::jsonb) into v_rows from (
    select q.*,
      case when q.spot = 'featured' then round(q.sold::numeric * 100 / nullif(q.slots * v_days, 0), 1) end as fill_rate_pct,
      case when q.enough and v_cpm > 0 then round(q.weekly_views * v_cpm / 1000) end as suggested_weekly_price,
      case when q.enough and v_cpm > 0 and q.current_weekly_price is not null and q.weekly_views > 0 then
        case when q.current_weekly_price > q.weekly_views * v_cpm / 1000 * 1.3 then 'above'
             when q.current_weekly_price < q.weekly_views * v_cpm / 1000 * 0.7 then 'below' end end as price_warning
    from (
      select k.target_key as key, k.spot, public.target_label(k.target_key) as label,
        coalesce(w.impressions, 0) as impressions, coalesce(w.clicks, 0) as clicks,
        case when coalesce(w.impressions, 0) > 0 then round(w.clicks::numeric * 100 / w.impressions, 2) end as ctr_pct,
        (select count(distinct l.visitor_hash) from public.ad_impression_log l join public.campaigns c on c.id = l.campaign_id
          where l.target_keys @> array[k.target_key] and public.ad_spot(c.placement) = k.spot
            and l.hour_bucket >= (v_from::timestamp at time zone 'Asia/Jakarta')) as unique_visitors,
        coalesce(dd.days_of_data, 0) as days_of_data,
        coalesce(dd.days_of_data, 0) >= 14 as enough,
        public.ad_slots_for(k.spot, k.target_key) as slots,
        case when k.spot = 'featured' then public.ad_slot_days_sold(k.spot, k.target_key, v_from, v_today) end as sold,
        coalesce(w.impressions, 0)::numeric / greatest(least(v_days, coalesce(dd.days_of_data, 1)), 1) * 7 as weekly_views,
        (select min(a.price_per_target::numeric * 7 / a.duration_days) from public.ad_products a
          where a.enabled and public.ad_spot(a.placement) = k.spot and a.scope_level = split_part(k.target_key, ':', 1)) as current_weekly_price
      from (select t.target_key, public.ad_spot(c.placement) as spot
              from public.campaign_targets t join public.campaigns c on c.id = t.campaign_id
              join public.orders o on o.id = c.order_id and o.status = 'paid'
            union select target_key, spot from public.ad_location_daily) k
      left join lateral (select sum(l.impressions) as impressions, sum(l.clicks) as clicks from public.ad_location_daily l
                          where l.target_key = k.target_key and l.spot = k.spot and l.day >= v_from) w on true
      left join lateral (select (v_today - min(l.day) + 1)::int as days_of_data from public.ad_location_daily l
                          where l.target_key = k.target_key and l.spot = k.spot) dd on true
    ) q) r;
  return jsonb_build_object('days', v_days, 'target_cpm', v_cpm, 'min_days_required', 14, 'rows', v_rows);
end $$;

-- ---------------------------------------------------------------------------
-- 11. Waitlist (hidden or sold-out tier). Phase 2 adds max budget and the hold fields.
-- ---------------------------------------------------------------------------
create table if not exists public.ad_waitlist (
  id uuid primary key default gen_random_uuid(),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 200),
  user_id uuid references auth.users (id) on delete set null,
  spot text not null check (spot in ('featured','random')),
  scope_level text not null check (scope_level in ('global','country','region','city','campus')),
  target_key text check (target_key is null or target_key ~ '^(global:\*|country:[A-Z]{2}|(region|city|campus):[0-9a-f-]{36})$'),
  desired_duration int not null check (desired_duration between 1 and 365),
  status text not null default 'waiting' check (status in ('waiting','notified','claimed','expired','canceled')),
  created_at timestamptz not null default now()
);
create unique index if not exists ad_waitlist_unique_waiting on public.ad_waitlist
  (lower(email), spot, scope_level, coalesce(target_key, ''), desired_duration) where status = 'waiting';
alter table public.ad_waitlist enable row level security;
revoke all on public.ad_waitlist from anon, authenticated;

create or replace function public.join_ad_waitlist(p_email text, p_spot text, p_scope_level text, p_target_key text, p_duration int)
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
  insert into public.ad_waitlist (email, user_id, spot, scope_level, target_key, desired_duration)
  values (v_email, (select auth.uid()), p_spot, p_scope_level, nullif(p_target_key, ''), p_duration)
  on conflict (lower(email), spot, scope_level, coalesce(target_key, ''), desired_duration) where status = 'waiting' do nothing;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_waitlist_counts() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'total_waiting', (select count(*) from public.ad_waitlist where status = 'waiting'),
    'rows', coalesce((select jsonb_agg(x order by x.waiting desc) from (
      select spot, scope_level, target_key, public.target_label(target_key) as label, desired_duration,
             count(*) filter (where status = 'waiting') as waiting
        from public.ad_waitlist group by spot, scope_level, target_key, desired_duration
        having count(*) filter (where status = 'waiting') > 0) x), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 12. Grants (what each caller needs; the allowlist block at the end revokes the Supabase defaults first)
-- ---------------------------------------------------------------------------
grant execute on function public.ad_catalog(), public.get_public_stats(), public.get_locations_recent_views(text, text[]),
  public.join_ad_waitlist(text, text, text, text, int),
  public.record_campaign_event(uuid, text, text, uuid, uuid, uuid) to anon, authenticated, service_role;
grant execute on function public.my_price_locks(), public.campaign_report(uuid) to authenticated, service_role;
grant execute on function public.admin_ad_product_impact(text), public.admin_pricing_analytics(int), public.admin_waitlist_counts(),
  public.admin_upsert_ad_product(text, text, text, text, int, text, boolean, int, int, int, boolean, boolean) to authenticated, service_role;
grant execute on function public.record_ad_event(uuid, text, text, text, boolean, text, uuid, uuid, uuid, text, text, text, text),
  public.ad_click_target(uuid), public.visitor_hash(text, text), public.campaigns_due_report(), public.mark_report_emailed(uuid[])
  to service_role;

-- ---------------------------------------------------------------------------
-- EXECUTE allowlist (005 pattern) for the functions this migration ADDS.
-- Supabase grants EXECUTE on new public functions to anon/authenticated by default and the 005 default-privilege
-- change does not undo that, so revoke first, then re-run the client grants from the Grants section above. Everything not granted to a client role is service_role
-- only; each client-facing admin function re-checks require_admin() itself.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.ad_catalog(),
  public.ad_click_target(uuid),
  public.ad_discount_pct(ad_products),
  public.ad_effective_base(ad_products),
  public.ad_products_log_change(),
  public.ad_quote(uuid,ad_products,integer),
  public.ad_slot_days_sold(text,text,date,date),
  public.ad_slots_for(text,text),
  public.ad_spot(text),
  public.admin_ad_product_impact(text),
  public.admin_pricing_analytics(integer),
  public.admin_upsert_ad_product(text,text,text,text,integer,text,boolean,integer,integer,integer,boolean,boolean),
  public.admin_waitlist_counts(),
  public.campaign_matched_keys(uuid,text,uuid,uuid,uuid),
  public.campaign_report(uuid),
  public.campaigns_due_report(),
  public.config_value_ok(text,numeric,numeric,jsonb),
  public.get_locations_recent_views(text,text[]),
  public.get_public_stats(),
  public.is_bot_agent(text),
  public.join_ad_waitlist(text,text,text,text,integer),
  public.launch_mode_on(),
  public.mark_report_emailed(uuid[]),
  public.my_price_locks(),
  public.price_lock_renewal_ok(uuid,text),
  public.record_ad_event(uuid,text,text,text,boolean,text,uuid,uuid,uuid,text,text,text,text),
  public.record_campaign_event(uuid,text,text,uuid,uuid,uuid),
  public.register_founding_advertiser(uuid,uuid,campaigns),
  public.target_label(text),
  public.visitor_hash(text,text)
  from public, anon, authenticated;
grant execute on function
  public.ad_catalog(),
  public.ad_click_target(uuid),
  public.ad_discount_pct(ad_products),
  public.ad_effective_base(ad_products),
  public.ad_products_log_change(),
  public.ad_quote(uuid,ad_products,integer),
  public.ad_slot_days_sold(text,text,date,date),
  public.ad_slots_for(text,text),
  public.ad_spot(text),
  public.admin_ad_product_impact(text),
  public.admin_pricing_analytics(integer),
  public.admin_upsert_ad_product(text,text,text,text,integer,text,boolean,integer,integer,integer,boolean,boolean),
  public.admin_waitlist_counts(),
  public.campaign_matched_keys(uuid,text,uuid,uuid,uuid),
  public.campaign_report(uuid),
  public.campaigns_due_report(),
  public.config_value_ok(text,numeric,numeric,jsonb),
  public.get_locations_recent_views(text,text[]),
  public.get_public_stats(),
  public.is_bot_agent(text),
  public.join_ad_waitlist(text,text,text,text,integer),
  public.launch_mode_on(),
  public.mark_report_emailed(uuid[]),
  public.my_price_locks(),
  public.price_lock_renewal_ok(uuid,text),
  public.record_ad_event(uuid,text,text,text,boolean,text,uuid,uuid,uuid,text,text,text,text),
  public.record_campaign_event(uuid,text,text,uuid,uuid,uuid),
  public.register_founding_advertiser(uuid,uuid,campaigns),
  public.target_label(text),
  public.visitor_hash(text,text)
  to service_role;
grant execute on function public.ad_catalog(), public.get_public_stats(), public.get_locations_recent_views(text, text[]),
  public.join_ad_waitlist(text, text, text, text, int),
  public.record_campaign_event(uuid, text, text, uuid, uuid, uuid) to anon, authenticated, service_role;
grant execute on function public.my_price_locks(), public.campaign_report(uuid) to authenticated, service_role;
grant execute on function public.admin_ad_product_impact(text), public.admin_pricing_analytics(int), public.admin_waitlist_counts(),
  public.admin_upsert_ad_product(text, text, text, text, int, text, boolean, int, int, int, boolean, boolean) to authenticated, service_role;
grant execute on function public.record_ad_event(uuid, text, text, text, boolean, text, uuid, uuid, uuid, text, text, text, text),
  public.ad_click_target(uuid), public.visitor_hash(text, text), public.campaigns_due_report(), public.mark_report_emailed(uuid[])
  to service_role;
