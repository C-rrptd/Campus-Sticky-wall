-- Applies on top of 034. Idempotent: safe to re-run. Existing migrations are untouched.
-- 035 — Auction fix: when a winner does not pay (or an auction is canceled) the campaign must go back EXACTLY as it was.
-- 034 saved only price, list price and start date, but auction_make_offer also resets slot_type, launch_discount_pct and
-- price_locked. A Top-slot or founding-price ad that lost its offer came back at its old price but as a Standard slot with
-- no launch discount / price lock. These columns remember the three values so auction_release_offer can restore them.
-- Offers created before this migration have NULLs here and keep the old behaviour (nothing extra is restored).

alter table public.ad_auction_offers
  add column if not exists orig_slot text,
  add column if not exists orig_discount int,
  add column if not exists orig_locked boolean;

create or replace function public.auction_make_offer(p_auction uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.ad_auctions; w record; c public.campaigns; v_off uuid;
  v_pay_by timestamptz := now() + make_interval(hours => public.cfg_int('auction_pay_hours', 24));
begin
  select * into a from public.ad_auctions where id = p_auction for update;
  if not found or a.status not in ('open','awaiting_payment') then return; end if;
  if exists (select 1 from public.ad_auction_offers o where o.auction_id = a.id and o.status = 'pending') then return; end if;
  select * into w from public.auction_pick_winner(a.id);
  if not found then
    update public.ad_auctions set status = 'no_winner', settled_at = now() where id = a.id;
    perform public.auction_mail_bidders(a, 'auction_lost', jsonb_build_object('location', public.auction_label(a), 'final', true), null);
    return;
  end if;
  select * into c from public.campaigns where id = w.campaign_id for update;
  insert into public.ad_auction_offers (auction_id, bid_id, bidder_id, campaign_id, amount, orig_price, orig_list, orig_start,
                                        orig_slot, orig_discount, orig_locked, pay_by)
  values (a.id, w.bid_id, w.bidder_id, c.id, w.amount, c.price_snapshot, c.list_price_snapshot, c.requested_start,
          c.slot_type, c.launch_discount_pct, c.price_locked, v_pay_by)
  returning id into v_off;
  -- approved_at restarts the 7-day "unpaid approval" clock so the sweeper cannot expire the winner mid-window.
  update public.campaigns set price_snapshot = w.amount, list_price_snapshot = w.amount, launch_discount_pct = 0, price_locked = false,
         requested_start = a.period_start, slot_type = 'standard', approved_at = now()
   where id = c.id;
  update public.ad_auctions set status = 'awaiting_payment' where id = a.id;
  perform public.ad_enqueue('auction_won', public.user_email(w.bidder_id), w.bidder_id,
    jsonb_build_object('location', public.auction_label(a), 'amount', w.amount::text, 'pay_by', v_pay_by, 'period_start', a.period_start),
    'won:' || v_off);
  perform public.auction_mail_bidders(a, 'auction_lost', jsonb_build_object('location', public.auction_label(a), 'final', false), w.bidder_id);
end $$;

create or replace function public.auction_release_offer(p_offer uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.ad_auction_offers;
begin
  select * into o from public.ad_auction_offers where id = p_offer and status = 'pending' for update;
  if not found then return; end if;
  update public.ad_auction_offers set status = p_status where id = o.id;
  update public.campaigns set price_snapshot = o.orig_price, list_price_snapshot = o.orig_list, requested_start = o.orig_start,
         slot_type = coalesce(o.orig_slot, slot_type),
         launch_discount_pct = coalesce(o.orig_discount, launch_discount_pct),
         price_locked = coalesce(o.orig_locked, price_locked)
   where id = o.campaign_id and status = 'approved';
end $$;
