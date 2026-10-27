-- 028 — Ad cancellation rules and stale-submission expiry.
--   * A paid, scheduled ad can be cancelled for a full refund only until 24 hours before it starts.
--   * Max 2 refunded cancellations per account per 30 days; further ones still cancel, but the refund is a manual decision.
--   * Ads nobody reviewed expire after 7 days, or once their requested start date has passed (never auto-approved).

alter table public.campaigns add column if not exists cancelled_paid_at timestamptz;

create or replace function public.cancel_my_campaign(p_campaign_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_c public.campaigns; v_paid boolean; v_over boolean := false;
begin
  if v_uid is null then perform public.app_error('CSW03', 'AUTH_REQUIRED'); end if;
  select * into v_c from public.campaigns where id = p_campaign_id and owner_id = v_uid for update;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  select exists (select 1 from public.orders o where o.id = v_c.order_id and o.status = 'paid') into v_paid;
  if v_c.status in ('pending_approval','approved')
     or (v_c.status = 'scheduled' and v_c.starts_at > now() + interval '24 hours') then
    if v_paid then
      select count(*) >= 2 into v_over from public.campaigns
       where owner_id = v_uid and cancelled_paid_at > now() - interval '30 days';
      update public.campaigns set status = 'canceled', moderation_reason = 'Cancelled by advertiser', cancelled_paid_at = now()
       where id = v_c.id;
      update public.orders set review_required = true,
             review_reason = case when v_over then 'Advertiser cancelled before start, but already had 2 refunded cancellations in 30 days: decide the refund manually'
                                  else 'Advertiser cancelled before start — full refund due' end
       where id = v_c.order_id;
    else
      update public.campaigns set status = 'canceled', moderation_reason = 'Cancelled by advertiser' where id = v_c.id;
    end if;
  else
    perform public.app_error('CSW09', 'CANNOT_CANCEL', 'Paid ads can’t be cancelled within 24 hours of their start. Contact us if something went wrong.');
  end if;
  return jsonb_build_object('id', v_c.id, 'status', 'canceled', 'refund_due', v_paid and not v_over, 'refund_review', v_paid and v_over);
end $$;

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
  update public.campaigns set status = 'expired', moderation_reason = 'Not reviewed in time'
   where status = 'pending_approval'
     and (updated_at < now() - interval '7 days' or requested_start < (now() at time zone 'Asia/Jakarta')::date);
  return v_count;
end $$;

revoke execute on function public.cancel_my_campaign(uuid) from public, anon;
grant execute on function public.cancel_my_campaign(uuid) to authenticated, service_role;
