-- 015 — Advertising fixes (idempotent; safe to re-run).
--   * get_promotions ranks BEFORE applying the limit (featured = most specific first; random rotation is fair)
--   * admin can reject/cancel a campaign whose payment is open; the open order is closed
--   * at most 5 submissions waiting for review per advertiser
--   * the legacy 3-day featured package from 004 is switched off (013 sells 7/14/30 days)

update public.ad_products set enabled = false where id = 'featured-campus-3d';

create or replace function public.get_promotions(
  p_country text default null, p_region uuid default null, p_city uuid default null, p_campus uuid default null,
  p_placement text default 'promotions_feed', p_category text default null, p_limit int default 24)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_loc record; v_pl text := coalesce(p_placement, 'promotions_feed');
begin
  select * into v_loc from public.resolve_location(p_country, p_region, p_city, p_campus);
  -- Rank FIRST, then cut to the limit (a LIMIT before ranking kept arbitrary rows).
  return coalesce((
    select jsonb_agg(to_jsonb(x) - 'rk' order by x.rk)
    from (
      select g.*, row_number() over (order by case when v_pl = 'featured' then g.specificity end desc nulls last, random()) as rk
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
        ) g
    ) x
    where x.rk <= least(greatest(coalesce(p_limit, 24), 1), 50)), '[]'::jsonb);
end $$;

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

  perform public.require_payable_total(v_product.price_per_target * v_count);
  update public.campaigns set price_snapshot = v_product.price_per_target * v_count where id = v_id;
  return jsonb_build_object('campaign_id', v_id, 'target_count', v_count,
    'price', (v_product.price_per_target * v_count)::text, 'duration_days', v_product.duration_days);
end $$;

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
  elsif p_action = 'reject' and v_c.status in ('pending_approval','pending_review','draft','approved','awaiting_payment') then
    update public.campaigns set status = 'rejected', moderation_reason = btrim(p_reason) where id = p_campaign_id;
  elsif p_action = 'pause' and v_c.status in ('active','scheduled') then
    update public.campaigns set status = 'paused', moderation_reason = p_reason where id = p_campaign_id;
  elsif p_action = 'resume' and v_c.status = 'paused' and v_paid then
    update public.campaigns set status = case when starts_at > now() then 'scheduled' else 'active' end,
           moderation_reason = p_reason where id = p_campaign_id;
  elsif p_action = 'cancel' and v_c.status in ('pending_approval','approved','pending_review','scheduled','active','paused','awaiting_payment') then
    update public.campaigns set status = 'canceled', moderation_reason = p_reason where id = p_campaign_id;
  else
    perform public.app_error('CSW09', 'INVALID_CAMPAIGN_ACTION', 'That action is not valid for the campaign''s current status.');
  end if;
  -- An open payment must not stay payable; a late settlement is then flagged 'payment_after_close' by the webhook.
  if v_c.status = 'awaiting_payment' and p_action in ('reject','cancel') then
    update public.orders set status = 'canceled', closed_at = now() where id = v_c.order_id and status = 'awaiting_payment';
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
