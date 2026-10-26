-- 019 — Advertising price = BASE FEE (covers the first location) + extra_location_pct % of the base for each
-- additional location. Idempotent; run after 018.
--   * ad_products.price_per_target now means "base fee"; extra_location_pct defaults to 100, which keeps the
--     old "price x locations" behaviour for existing packages until the admin lowers it.
--   * ad_price() is the single place the total is computed (campaign submit and order creation both call it).
--   * The order line is one item for the whole amount: base + % of base rarely divides evenly by the location
--     count, and Midtrans needs the item lines to add up exactly to the total.

alter table public.ad_products add column if not exists extra_location_pct int not null default 100
  check (extra_location_pct between 0 and 1000);

create or replace function public.ad_price(p_base bigint, p_pct int, p_locations int) returns bigint
language sql immutable set search_path = '' as $$
  select p_base + round(p_base::numeric * p_pct * greatest(p_locations - 1, 0) / 100)::bigint
$$;

drop function if exists public.admin_upsert_ad_product(text, text, text, text, int, text, boolean, int);
create or replace function public.admin_upsert_ad_product(p_id text, p_name text, p_placement text, p_scope_level text,
  p_duration_days int, p_price text, p_enabled boolean, p_sort int default 0, p_extra_pct int default 100)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_price bigint := public.parse_amount(p_price);
begin
  perform public.require_admin();
  insert into public.ad_products (id, name, placement, scope_level, duration_days, price_per_target, extra_location_pct, enabled, sort_order)
  values (p_id, p_name, p_placement, p_scope_level, p_duration_days, v_price, coalesce(p_extra_pct, 100), coalesce(p_enabled, true), coalesce(p_sort, 0))
  on conflict (id) do update set name = excluded.name, placement = excluded.placement, scope_level = excluded.scope_level,
    duration_days = excluded.duration_days, price_per_target = excluded.price_per_target,
    extra_location_pct = excluded.extra_location_pct, enabled = excluded.enabled, sort_order = excluded.sort_order;
  perform public.audit('ad_product.upsert', 'ad_product', p_id, null,
    jsonb_build_object('price', v_price::text, 'extra_location_pct', coalesce(p_extra_pct, 100)));
  return jsonb_build_object('id', p_id);
end $$;
grant execute on function public.admin_upsert_ad_product(text, text, text, text, int, text, boolean, int, int)
  to authenticated, service_role;

-- Campaign submit (015 version) with the new total.
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

  v_price := public.ad_price(v_product.price_per_target, v_product.extra_location_pct, v_count);
  perform public.require_payable_total(v_price);
  update public.campaigns set price_snapshot = v_price where id = v_id;
  return jsonb_build_object('campaign_id', v_id, 'target_count', v_count,
    'price', v_price::text, 'duration_days', v_product.duration_days);
end $$;

-- Payment order (013 version): total from the frozen snapshot, one order line.
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
                             'duration_days', v_c.duration_days, 'priced_at', now()),
          p_guest_token_hash,
          now() + make_interval(mins => coalesce((public.config_value('unpaid_order_ttl_minutes') #>> '{}')::int, 120)))
  returning id into v_order_id;
  insert into public.order_items (order_id, item_type, item_ref, name, unit_amount, quantity)
  values (v_order_id, 'advertising', v_product.id, left(v_product.name, 44) || ' ×' || v_targets, v_price, 1);
  update public.campaigns set status = 'awaiting_payment', order_id = v_order_id, price_snapshot = v_price
   where id = v_c.id;
  return public.order_summary(v_order_id);
end $$;
