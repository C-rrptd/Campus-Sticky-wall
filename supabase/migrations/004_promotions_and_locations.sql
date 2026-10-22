-- 004_promotions_and_locations.sql
-- Geographic hierarchy (country > region > city > campus), user location
-- preferences, advertising products, campaigns, targeting and measurement.
--
-- Adding a country is a data task: insert into countries/regions/cities/
-- campuses. Regions use a free-text `kind` because administrative levels
-- differ per country (province, state, prefecture, ...).

create table public.countries (
  code char(2) primary key check (code ~ '^[A-Z]{2}$'),
  name text not null,
  enabled boolean not null default true,
  sort_order int not null default 0
);

create table public.regions (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null references public.countries (code),
  name text not null,
  kind text not null default 'province',
  enabled boolean not null default true,
  unique (country_code, name)
);

create table public.cities (
  id uuid primary key default gen_random_uuid(),
  region_id uuid not null references public.regions (id),
  name text not null,
  enabled boolean not null default true,
  unique (region_id, name)
);

create table public.campuses (
  id uuid primary key default gen_random_uuid(),
  city_id uuid not null references public.cities (id),
  name text not null,
  short_name text,
  enabled boolean not null default true,
  unique (city_id, name)
);

-- Seed: Indonesia with a starter set. Extend via the admin panel or SQL.
insert into public.countries (code, name, sort_order) values ('ID', 'Indonesia', 1);
with r as (
  insert into public.regions (country_code, name, kind) values
    ('ID', 'Jawa Barat', 'province'),
    ('ID', 'DKI Jakarta', 'province'),
    ('ID', 'DI Yogyakarta', 'province'),
    ('ID', 'Jawa Timur', 'province')
  returning id, name
), c as (
  insert into public.cities (region_id, name)
  select r.id, x.city from r join (values
    ('Jawa Barat', 'Bogor'), ('Jawa Barat', 'Bandung'), ('Jawa Barat', 'Depok'),
    ('DKI Jakarta', 'Jakarta Selatan'), ('DI Yogyakarta', 'Sleman'), ('Jawa Timur', 'Surabaya')
  ) as x(region, city) on x.region = r.name
  returning id, name
)
insert into public.campuses (city_id, name, short_name)
select c.id, x.campus, x.short from c join (values
  ('Bogor', 'IPB University (Dramaga)', 'IPB'),
  ('Bandung', 'Institut Teknologi Bandung', 'ITB'),
  ('Depok', 'Universitas Indonesia', 'UI'),
  ('Sleman', 'Universitas Gadjah Mada', 'UGM'),
  ('Surabaya', 'Institut Teknologi Sepuluh Nopember', 'ITS')
) as x(city, campus, short) on x.city = c.name;

-- Notes can optionally belong to a campus (for wall filtering).
alter table public.notes add column campus_id uuid references public.campuses (id);

-- Profile location preference (optional, never precise GPS).
alter table public.profiles
  add column country_code char(2) references public.countries (code),
  add column region_id uuid references public.regions (id),
  add column city_id uuid references public.cities (id),
  add column campus_id uuid references public.campuses (id);
grant update (country_code, region_id, city_id, campus_id) on public.profiles to authenticated;

-- Resolve the most specific supplied location into a full hierarchy.
-- Unknown or disabled ids resolve to NULLs (never to a broader match).
create or replace function public.resolve_location(p_country text, p_region uuid, p_city uuid, p_campus uuid)
returns table (country_code char(2), region_id uuid, city_id uuid, campus_id uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_campus is not null then
    return query select co.code, r.id, ci.id, ca.id
      from public.campuses ca join public.cities ci on ci.id = ca.city_id
      join public.regions r on r.id = ci.region_id join public.countries co on co.code = r.country_code
     where ca.id = p_campus and ca.enabled and ci.enabled and r.enabled and co.enabled;
  elsif p_city is not null then
    return query select co.code, r.id, ci.id, null::uuid
      from public.cities ci join public.regions r on r.id = ci.region_id
      join public.countries co on co.code = r.country_code
     where ci.id = p_city and ci.enabled and r.enabled and co.enabled;
  elsif p_region is not null then
    return query select co.code, r.id, null::uuid, null::uuid
      from public.regions r join public.countries co on co.code = r.country_code
     where r.id = p_region and r.enabled and co.enabled;
  elsif p_country is not null then
    return query select co.code, null::uuid, null::uuid, null::uuid
      from public.countries co where co.code = upper(p_country) and co.enabled;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Advertising products and campaigns
-- ---------------------------------------------------------------------------
create table public.ad_products (
  id text primary key check (id ~ '^[a-z0-9-]{2,60}$'),
  name text not null,
  placement text not null check (placement in ('promotions_feed','wall_inline','featured')),
  scope_level text not null check (scope_level in ('global','country','region','city','campus')),
  duration_days int not null check (duration_days between 1 and 365),
  price_per_target bigint not null check (price_per_target > 0),
  enabled boolean not null default true,
  sort_order int not null default 0,
  updated_at timestamptz not null default now()
);
create trigger ad_products_updated_at before update on public.ad_products
  for each row execute function public.set_updated_at();

-- Example launch prices (rupiah). Adjust in the admin panel.
insert into public.ad_products (id, name, placement, scope_level, duration_days, price_per_target, sort_order) values
  ('feed-campus-7d',  'Promotions feed — one campus, 7 days',   'promotions_feed', 'campus',  7,   25000, 1),
  ('feed-city-7d',    'Promotions feed — one city, 7 days',     'promotions_feed', 'city',    7,   50000, 2),
  ('feed-region-7d',  'Promotions feed — one province, 7 days', 'promotions_feed', 'region',  7,  100000, 3),
  ('feed-country-7d', 'Promotions feed — nationwide, 7 days',   'promotions_feed', 'country', 7,  300000, 4),
  ('feed-global-7d',  'Promotions feed — global, 7 days',       'promotions_feed', 'global',  7,  500000, 5),
  ('wall-campus-7d',  'Wall placement — one campus, 7 days',    'wall_inline',     'campus',  7,   40000, 6),
  ('wall-country-7d', 'Wall placement — nationwide, 7 days',    'wall_inline',     'country', 7,  450000, 7),
  ('featured-campus-3d', 'Featured spot — one campus, 3 days',  'featured',        'campus',  3,   35000, 8);

create table public.campaigns (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  advertiser_name text not null check (char_length(btrim(advertiser_name)) between 2 and 80),
  contact_email text not null check (contact_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(contact_email) <= 200),
  title text not null check (char_length(btrim(title)) between 3 and 80),
  description text not null check (char_length(btrim(description)) between 1 and 500),
  category text not null check (category in ('local_business','student_discount','campus_event','workshop',
                                             'competition','recruitment','student_service','club_event','other')),
  creative_path text check (creative_path is null or creative_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(png|jpg|jpeg|webp)$'),
  destination_url text not null check (destination_url ~ '^https://[^\s<>"'']+$' and char_length(destination_url) <= 500),
  product_id text not null references public.ad_products (id),
  placement text not null,
  scope_level text not null,
  duration_days int not null,
  requested_start date not null,
  starts_at timestamptz,
  ends_at timestamptz,
  status text not null default 'draft' check (status in
    ('draft','awaiting_payment','pending_review','active','paused','rejected','canceled')),
  order_id uuid unique references public.orders (id),
  price_snapshot bigint,
  moderation_reason text,
  approved_by uuid,
  approved_at timestamptz,
  impressions bigint not null default 0,
  clicks bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger campaigns_updated_at before update on public.campaigns
  for each row execute function public.set_updated_at();

create table public.campaign_targets (
  id bigint generated always as identity primary key,
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  level text not null check (level in ('global','country','region','city','campus')),
  country_code char(2) references public.countries (code),
  region_id uuid references public.regions (id),
  city_id uuid references public.cities (id),
  campus_id uuid references public.campuses (id),
  target_key text generated always as (
    level || ':' || coalesce(country_code::text, region_id::text, city_id::text, campus_id::text, '*')) stored,
  unique (campaign_id, target_key),
  -- Exactly the identifier for the declared level must be present.
  check (
    (level = 'global'  and country_code is null and region_id is null and city_id is null and campus_id is null) or
    (level = 'country' and country_code is not null and region_id is null and city_id is null and campus_id is null) or
    (level = 'region'  and region_id is not null and country_code is null and city_id is null and campus_id is null) or
    (level = 'city'    and city_id is not null and country_code is null and region_id is null and campus_id is null) or
    (level = 'campus'  and campus_id is not null and country_code is null and region_id is null and city_id is null))
);

create table public.campaign_daily_stats (
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  day date not null,
  impressions bigint not null default 0,
  clicks bigint not null default 0,
  primary key (campaign_id, day)
);

-- Campaign is live right now.
create or replace function public.campaign_is_live(c public.campaigns) returns boolean
language sql stable set search_path = '' as $$
  select c.status = 'active' and c.starts_at is not null and c.ends_at is not null
     and c.starts_at <= now() and c.ends_at > now()
     and exists (select 1 from public.orders o where o.id = c.order_id and o.status = 'paid')
$$;

-- Create or replace a draft campaign. Service role only (create-advertiser-campaign).
-- p_targets: jsonb array of {"level": "...", "id": "..."} (id omitted for global).
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
begin
  if p_owner is null then
    perform public.app_error('CSW03', 'AUTH_REQUIRED', 'Sign in to create a campaign.');
  end if;
  if public.is_suspended(p_owner) then
    perform public.app_error('CSW03', 'ACCOUNT_SUSPENDED', 'This account is suspended.');
  end if;
  select * into v_product from public.ad_products where id = p_product_id and enabled;
  if not found then
    perform public.app_error('CSW40', 'INVALID_PRODUCT', 'Choose an available advertising package.');
  end if;
  if p_requested_start is null or p_requested_start < (now() at time zone 'Asia/Jakarta')::date
     or p_requested_start > (now() at time zone 'Asia/Jakarta')::date + 180 then
    perform public.app_error('CSW40', 'INVALID_START_DATE', 'Start date must be within the next 180 days.');
  end if;
  if p_targets is null or jsonb_typeof(p_targets) <> 'array' or jsonb_array_length(p_targets) not between 1 and 20 then
    perform public.app_error('CSW40', 'INVALID_TARGETS', 'Choose between 1 and 20 target locations.');
  end if;
  if v_product.scope_level = 'global' and jsonb_array_length(p_targets) <> 1 then
    perform public.app_error('CSW40', 'INVALID_TARGETS', 'Global packages take exactly one global target.');
  end if;

  if p_campaign_id is null then
    insert into public.campaigns (owner_id, advertiser_name, contact_email, title, description, category,
      creative_path, destination_url, product_id, placement, scope_level, duration_days, requested_start)
    values (p_owner, btrim(p_advertiser_name), btrim(p_contact_email), btrim(p_title), btrim(p_description), p_category,
      p_creative_path, p_destination_url, v_product.id, v_product.placement, v_product.scope_level,
      v_product.duration_days, p_requested_start)
    returning id into v_id;
  else
    update public.campaigns set advertiser_name = btrim(p_advertiser_name), contact_email = btrim(p_contact_email),
           title = btrim(p_title), description = btrim(p_description), category = p_category,
           creative_path = p_creative_path, destination_url = p_destination_url, product_id = v_product.id,
           placement = v_product.placement, scope_level = v_product.scope_level,
           duration_days = v_product.duration_days, requested_start = p_requested_start
     where id = p_campaign_id and owner_id = p_owner and status = 'draft'
    returning id into v_id;
    if v_id is null then
      perform public.app_error('CSW04', 'NOT_FOUND', 'Draft campaign not found.');
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

  return jsonb_build_object('campaign_id', v_id, 'target_count', v_count,
    'price', (v_product.price_per_target * v_count)::text, 'duration_days', v_product.duration_days);
end $$;

-- Create the payment order for a draft campaign. Service role only.
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
  if v_c.status <> 'draft' then
    perform public.app_error('CSW09', 'CAMPAIGN_NOT_DRAFT', 'Only draft campaigns can be ordered.');
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
  v_price := v_product.price_per_target * v_targets;
  perform public.require_payable_total(v_price);
  insert into public.orders (order_ref, kind, user_id, subtotal_amount, total_amount, snapshot, guest_token_hash, expires_at)
  values (public.new_order_ref('advertising'), 'advertising', p_owner, v_price, v_price,
          jsonb_build_object('product_id', v_product.id, 'product_name', v_product.name,
                             'price_per_target', v_product.price_per_target::text, 'target_count', v_targets,
                             'duration_days', v_product.duration_days, 'priced_at', now()),
          p_guest_token_hash,
          now() + make_interval(mins => coalesce((public.config_value('unpaid_order_ttl_minutes') #>> '{}')::int, 120)))
  returning id into v_order_id;
  insert into public.order_items (order_id, item_type, item_ref, name, unit_amount, quantity)
  values (v_order_id, 'advertising', v_product.id, left(v_product.name, 50), v_product.price_per_target, v_targets);
  update public.campaigns set status = 'awaiting_payment', order_id = v_order_id, price_snapshot = v_price
   where id = v_c.id;
  return public.order_summary(v_order_id);
end $$;

-- Public promotions query. Location inputs are hierarchy-resolved; a missing
-- or invalid location yields global campaigns only (never a broader target).
create or replace function public.get_promotions(
  p_country text default null, p_region uuid default null, p_city uuid default null, p_campus uuid default null,
  p_placement text default 'promotions_feed', p_category text default null, p_limit int default 24)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_loc record;
begin
  select * into v_loc from public.resolve_location(p_country, p_region, p_city, p_campus);
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by x.specificity desc, x.starts_at desc)
    from (
      select c.id, c.title, c.description, c.category, c.creative_path, c.destination_url,
             c.advertiser_name, c.placement, c.starts_at, c.ends_at,
             max(case t.level when 'campus' then 4 when 'city' then 3 when 'region' then 2
                              when 'country' then 1 else 0 end) as specificity
        from public.campaigns c
        join public.campaign_targets t on t.campaign_id = c.id
       where public.campaign_is_live(c)
         and c.placement = coalesce(p_placement, 'promotions_feed')
         and (p_category is null or c.category = p_category)
         and (t.level = 'global'
              or (t.level = 'country' and v_loc.country_code is not null and t.country_code = v_loc.country_code)
              or (t.level = 'region'  and v_loc.region_id is not null and t.region_id = v_loc.region_id)
              or (t.level = 'city'    and v_loc.city_id is not null and t.city_id = v_loc.city_id)
              or (t.level = 'campus'  and v_loc.campus_id is not null and t.campus_id = v_loc.campus_id))
       group by c.id
       limit least(greatest(coalesce(p_limit, 24), 1), 50)
    ) x), '[]'::jsonb);
end $$;

-- Client-reported impression/click counters (approximate; documented as such).
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

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.countries enable row level security;
alter table public.regions enable row level security;
alter table public.cities enable row level security;
alter table public.campuses enable row level security;
alter table public.ad_products enable row level security;
alter table public.campaigns enable row level security;
alter table public.campaign_targets enable row level security;
alter table public.campaign_daily_stats enable row level security;

revoke all on public.countries, public.regions, public.cities, public.campuses, public.ad_products,
  public.campaigns, public.campaign_targets, public.campaign_daily_stats from anon, authenticated;

grant select on public.countries, public.regions, public.cities, public.campuses, public.ad_products to anon, authenticated;
grant select on public.campaigns, public.campaign_targets, public.campaign_daily_stats to authenticated;

create policy countries_read on public.countries for select to anon, authenticated using (enabled);
create policy regions_read on public.regions for select to anon, authenticated using (enabled);
create policy cities_read on public.cities for select to anon, authenticated using (enabled);
create policy campuses_read on public.campuses for select to anon, authenticated using (enabled);
create policy ad_products_read on public.ad_products for select to anon, authenticated using (enabled);

-- Advertisers see only their own campaigns; the public feed goes through get_promotions().
create policy campaigns_owner_read on public.campaigns for select to authenticated using (owner_id = (select auth.uid()));
create policy campaign_targets_owner_read on public.campaign_targets for select to authenticated using (
  exists (select 1 from public.campaigns c where c.id = campaign_id and c.owner_id = (select auth.uid())));
create policy campaign_stats_owner_read on public.campaign_daily_stats for select to authenticated using (
  exists (select 1 from public.campaigns c where c.id = campaign_id and c.owner_id = (select auth.uid())));
