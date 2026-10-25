-- 013 — Advertising v3: submit -> admin approval -> Midtrans payment -> scheduled -> live -> expired.
--   * destination link and image are optional
--   * duration packages (7 / 14 / 30 days) x placement (random / featured); admin edits prices in ad_products
--   * price is quoted and frozen when the campaign is submitted (campaigns.price_snapshot)
--   * paid campaigns go live by date alone (campaign_is_live); the 15-minute sweeper only tidies statuses
--   * advertisers can cancel unpaid / not-yet-started campaigns; paid ones raise a refund review on the order
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------
alter table public.campaigns alter column destination_url drop not null;

do $$ declare r record; begin
  for r in select conname from pg_constraint
            where conrelid = 'public.campaigns'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%awaiting_payment%' loop
    execute format('alter table public.campaigns drop constraint %I', r.conname);
  end loop;
  alter table public.campaigns add constraint campaigns_status_check check (status in
    ('draft','pending_approval','approved','awaiting_payment','pending_review','scheduled','active',
     'paused','expired','rejected','canceled'));
end $$;

-- Old drafts were never reviewed: send them to the review queue.
update public.campaigns set status = 'pending_approval' where status = 'draft' and order_id is null;

-- Contact for custom packages. Public; edited from Admin -> Prices & settings.
insert into public.site_config (key, value, is_public, description) values
  ('ad_whatsapp', '""', true, 'WhatsApp number (digits with country code, e.g. 6281234567890) for custom ad packages'),
  ('ad_payment_window_days', '7', false, 'Days an advertiser has to pay after admin approval before the campaign expires')
on conflict (key) do nothing;

create or replace function public.admin_set_config(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin();
begin
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
  update public.site_config set value = p_value, updated_by = v_admin where key = p_key;
  perform public.audit('config.set', 'config', p_key, null, jsonb_build_object('value', p_value));
  return jsonb_build_object('key', p_key, 'value', p_value);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Packages: 14 and 30 day versions of every 7 day package, plus featured packages.
--    Example prices only: edit or disable them in Admin -> Prices & settings.
-- ---------------------------------------------------------------------------
insert into public.ad_products (id, name, placement, scope_level, duration_days, price_per_target, sort_order)
select replace(id, '-7d', '-14d'), replace(name, '7 days', '14 days'), placement, scope_level, 14,
       round(price_per_target * 1.8 / 1000) * 1000, sort_order + 100
  from public.ad_products where id like '%-7d'
on conflict (id) do nothing;
insert into public.ad_products (id, name, placement, scope_level, duration_days, price_per_target, sort_order)
select replace(id, '-7d', '-30d'), replace(name, '7 days', '30 days'), placement, scope_level, 30,
       round(price_per_target * 3.2 / 1000) * 1000, sort_order + 200
  from public.ad_products where id like '%-7d'
on conflict (id) do nothing;

insert into public.ad_products (id, name, placement, scope_level, duration_days, price_per_target, sort_order) values
  ('featured-campus-7d',   'Featured spot — one campus, 7 days',     'featured', 'campus',   7,   60000, 11),
  ('featured-campus-14d',  'Featured spot — one campus, 14 days',    'featured', 'campus',  14,  110000, 111),
  ('featured-campus-30d',  'Featured spot — one campus, 30 days',    'featured', 'campus',  30,  200000, 211),
  ('featured-city-7d',     'Featured spot — one city, 7 days',       'featured', 'city',     7,  120000, 12),
  ('featured-city-14d',    'Featured spot — one city, 14 days',      'featured', 'city',    14,  220000, 112),
  ('featured-city-30d',    'Featured spot — one city, 30 days',      'featured', 'city',    30,  400000, 212),
  ('featured-country-7d',  'Featured spot — nationwide, 7 days',     'featured', 'country',  7,  600000, 13),
  ('featured-country-14d', 'Featured spot — nationwide, 14 days',    'featured', 'country', 14, 1100000, 113),
  ('featured-country-30d', 'Featured spot — nationwide, 30 days',    'featured', 'country', 30, 2000000, 213)
on conflict (id) do nothing;

-- Wall slots are part of Random Placement now; the separate wall packages would be duplicates.
update public.ad_products set enabled = false where placement = 'wall_inline';

-- ---------------------------------------------------------------------------
-- 3. Live rule: paid + inside its dates. Going live and expiring need no job.
-- ---------------------------------------------------------------------------
create or replace function public.campaign_is_live(c public.campaigns) returns boolean
language sql stable set search_path = '' as $$
  select c.status in ('active','scheduled') and c.starts_at is not null and c.ends_at is not null
     and c.starts_at <= now() and c.ends_at > now()
     and exists (select 1 from public.orders o where o.id = c.order_id and o.status = 'paid')
$$;

-- ---------------------------------------------------------------------------
-- 4. Submit: validates package + targets, freezes the quoted price, queues for approval.
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

  perform public.require_payable_total(v_product.price_per_target * v_count);
  update public.campaigns set price_snapshot = v_product.price_per_target * v_count where id = v_id;
  return jsonb_build_object('campaign_id', v_id, 'target_count', v_count,
    'price', (v_product.price_per_target * v_count)::text, 'duration_days', v_product.duration_days);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Payment order: only for APPROVED campaigns, at the price quoted at submission.
-- ---------------------------------------------------------------------------
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
  v_price := coalesce(v_c.price_snapshot, v_product.price_per_target * v_targets);
  perform public.require_payable_total(v_price);
  insert into public.orders (order_ref, kind, user_id, subtotal_amount, total_amount, snapshot, guest_token_hash, expires_at)
  values (public.new_order_ref('advertising'), 'advertising', p_owner, v_price, v_price,
          jsonb_build_object('product_id', v_product.id, 'product_name', v_product.name,
                             'price_per_target', (v_price / v_targets)::text, 'target_count', v_targets,
                             'duration_days', v_c.duration_days, 'priced_at', now()),
          p_guest_token_hash,
          now() + make_interval(mins => coalesce((public.config_value('unpaid_order_ttl_minutes') #>> '{}')::int, 120)))
  returning id into v_order_id;
  insert into public.order_items (order_id, item_type, item_ref, name, unit_amount, quantity)
  values (v_order_id, 'advertising', v_product.id, left(v_product.name, 50), v_price / v_targets, v_targets);
  update public.campaigns set status = 'awaiting_payment', order_id = v_order_id, price_snapshot = v_price
   where id = v_c.id;
  return public.order_summary(v_order_id);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Payment settled: schedule (or start) the campaign. Campaigns that were never approved
--    (created before 013) still go through the old paid -> review step.
-- ---------------------------------------------------------------------------
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
    end if;
  end if;
end $$;

-- A failed / expired payment sends an approved campaign back to "approved" so the advertiser can pay again.
create or replace function public.abandon_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.release_order_credit(p_order_id);
  with d as (delete from public.promo_redemptions where order_id = p_order_id returning code_id),
       c as (select code_id, count(*)::int n from d group by code_id)
  update public.promo_codes p set uses = greatest(p.uses - c.n, 0) from c where p.id = c.code_id;
  delete from public.free_post_claims where order_id = p_order_id;
  delete from public.notes where order_id = p_order_id and status = 'awaiting_payment';
  update public.donations set status = 'failed' where order_id = p_order_id and status = 'pending';
  update public.campaigns set status = case when approved_at is null then 'draft' else 'approved' end, order_id = null
   where order_id = p_order_id and status = 'awaiting_payment';
end $$;

-- ---------------------------------------------------------------------------
-- 7. Public feed. 'random' = promotions feed + wall slots, shuffled on every load (fair rotation);
--    'featured' = pinned spots, most specific location first.
-- ---------------------------------------------------------------------------
create or replace function public.get_promotions(
  p_country text default null, p_region uuid default null, p_city uuid default null, p_campus uuid default null,
  p_placement text default 'promotions_feed', p_category text default null, p_limit int default 24)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_loc record; v_pl text := coalesce(p_placement, 'promotions_feed');
begin
  select * into v_loc from public.resolve_location(p_country, p_region, p_city, p_campus);
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by case when v_pl = 'featured' then x.specificity end desc nulls last, random())
    from (
      select c.id, c.title, c.description, c.category, c.creative_path, c.destination_url,
             c.advertiser_name, c.placement, c.starts_at, c.ends_at,
             max(case t.level when 'campus' then 4 when 'city' then 3 when 'region' then 2
                              when 'country' then 1 else 0 end) as specificity
        from public.campaigns c
        join public.campaign_targets t on t.campaign_id = c.id
       where public.campaign_is_live(c)
         and (c.placement = v_pl or (v_pl in ('random','promotions_feed','wall_inline') and c.placement in ('promotions_feed','wall_inline')))
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

-- ---------------------------------------------------------------------------
-- 8. Admin review. Approve = allow payment. Reject needs a reason the advertiser can read.
--    Cancelling a paid campaign flags its order for a refund review (refund in Midtrans, then the webhook reverses it).
-- ---------------------------------------------------------------------------
create or replace function public.admin_review_campaign(p_campaign_id uuid, p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_c public.campaigns; v_paid boolean; v_start timestamptz;
begin
  select * into v_c from public.campaigns where id = p_campaign_id for update;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  select exists (select 1 from public.orders o where o.id = v_c.order_id and o.status = 'paid') into v_paid;
  if p_action = 'reject' and length(btrim(coalesce(p_reason, ''))) < 3 then
    perform public.app_error('CSW40', 'REASON_REQUIRED', 'Give the advertiser a reason for the rejection.');
  end if;
  if p_action = 'approve' and v_c.status = 'pending_approval' then
    update public.campaigns set status = 'approved', approved_by = v_admin, approved_at = now(), moderation_reason = null
     where id = p_campaign_id;
  elsif p_action = 'approve' and v_c.status = 'pending_review' and v_paid then   -- legacy: paid before approval existed
    v_start := greatest(now(), (v_c.requested_start::timestamp at time zone 'Asia/Jakarta'));
    update public.campaigns set approved_by = v_admin, approved_at = now(), starts_at = v_start,
           ends_at = v_start + make_interval(days => v_c.duration_days), moderation_reason = p_reason,
           status = case when v_start > now() then 'scheduled' else 'active' end
     where id = p_campaign_id;
  elsif p_action = 'reject' and v_c.status in ('pending_approval','pending_review','draft','approved') then
    update public.campaigns set status = 'rejected', moderation_reason = btrim(p_reason) where id = p_campaign_id;
  elsif p_action = 'pause' and v_c.status in ('active','scheduled') then
    update public.campaigns set status = 'paused', moderation_reason = p_reason where id = p_campaign_id;
  elsif p_action = 'resume' and v_c.status = 'paused' and v_paid then
    update public.campaigns set status = case when starts_at > now() then 'scheduled' else 'active' end,
           moderation_reason = p_reason where id = p_campaign_id;
  elsif p_action = 'cancel' and v_c.status in ('pending_approval','approved','pending_review','scheduled','active','paused') then
    update public.campaigns set status = 'canceled', moderation_reason = p_reason where id = p_campaign_id;
  else
    perform public.app_error('CSW09', 'INVALID_CAMPAIGN_ACTION', 'That action is not valid for the campaign''s current status.');
  end if;
  -- Paid money must be handled: flag the order so it appears under "needs review".
  if v_paid and p_action in ('reject','cancel') then
    update public.orders set review_required = true, review_reason = 'Campaign ' || p_action || 'ed — refund per advertising policy'
     where id = v_c.order_id;
  end if;
  perform public.audit('campaign.' || p_action, 'campaign', p_campaign_id::text, p_reason,
    jsonb_build_object('from', v_c.status, 'paid', v_paid));
  return (select jsonb_build_object('id', id, 'status', status, 'starts_at', starts_at, 'ends_at', ends_at)
            from public.campaigns where id = p_campaign_id);
end $$;

create or replace function public.admin_list_campaigns(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select c.id, c.title, c.description, c.advertiser_name, c.contact_email, c.category, c.placement, c.scope_level,
           c.duration_days, c.destination_url, c.creative_path, c.status, c.requested_start, c.starts_at, c.ends_at,
           c.price_snapshot::text as price, c.impressions, c.clicks, c.created_at, c.moderation_reason,
           o.status as payment_status, o.order_ref,
           (select jsonb_agg(t.target_key) from public.campaign_targets t where t.campaign_id = c.id) as targets
      from public.campaigns c left join public.orders o on o.id = c.order_id
     where p_status is null or c.status = p_status
     order by c.created_at desc limit 200) x), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 9. Advertiser self-service cancel: before payment (free) or before start (refund review).
-- ---------------------------------------------------------------------------
create or replace function public.cancel_my_campaign(p_campaign_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_c public.campaigns; v_paid boolean;
begin
  if v_uid is null then perform public.app_error('CSW03', 'AUTH_REQUIRED'); end if;
  select * into v_c from public.campaigns where id = p_campaign_id and owner_id = v_uid for update;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  select exists (select 1 from public.orders o where o.id = v_c.order_id and o.status = 'paid') into v_paid;
  if v_c.status in ('pending_approval','approved') or (v_c.status = 'scheduled' and v_c.starts_at > now()) then
    update public.campaigns set status = 'canceled', moderation_reason = 'Cancelled by advertiser' where id = v_c.id;
    if v_paid then
      update public.orders set review_required = true, review_reason = 'Advertiser cancelled before start — full refund due'
       where id = v_c.order_id;
    end if;
  else
    perform public.app_error('CSW09', 'CANNOT_CANCEL', 'This campaign can no longer be cancelled here. Contact us.');
  end if;
  return jsonb_build_object('id', v_c.id, 'status', 'canceled', 'refund_due', v_paid);
end $$;

-- ---------------------------------------------------------------------------
-- 10. Sweeper (already scheduled every 15 minutes): also tidies campaign statuses.
-- ---------------------------------------------------------------------------
create or replace function public.expire_stale_orders() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_count int := 0;
begin
  for r in select id from public.orders
            where status = 'awaiting_payment' and expires_at is not null and expires_at < now()
            for update skip locked loop
    update public.orders set status = 'expired', closed_at = now() where id = r.id;
    perform public.abandon_order(r.id);
    v_count := v_count + 1;
  end loop;
  update public.campaigns set status = 'expired'
   where status in ('active','scheduled','paused') and ends_at is not null and ends_at <= now();
  update public.campaigns set status = 'active'
   where status = 'scheduled' and starts_at <= now() and ends_at > now();
  update public.campaigns set status = 'expired', moderation_reason = 'Not paid within the payment window'
   where status = 'approved'
     and approved_at < now() - make_interval(days => coalesce((public.config_value('ad_payment_window_days') #>> '{}')::int, 7));
  return v_count;
end $$;

-- Grants (005 pattern): cancel is a signed-in user API; everything else keeps its existing grants.
revoke execute on function public.cancel_my_campaign(uuid) from public, anon;
grant execute on function public.cancel_my_campaign(uuid) to authenticated, service_role;
