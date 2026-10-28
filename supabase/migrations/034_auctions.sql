-- Applies on top of 033.
-- 034 — Phase 3: auction module for the NEXT period of a full featured slot. SHIPPED OFF.
-- Idempotent: safe to re-run. Rollback: supabase/rollbacks/034_rollback.sql.
--
-- Switched off means inert: with auctions_enabled = false (the default) no auction can be opened or bid on, the public
-- list returns nothing, and no normal price, order or campaign is touched. Even when on, an auction only ever sets the
-- price of the one campaign that wins it; fixed prices, existing orders and other campaigns are never changed.
--
-- Payment assumption: Midtrans Snap (e-wallets, virtual accounts, cards) is a one-shot charge here; no authorization
-- hold is used. So NO money is taken at bid time. The winner gets a 24h payment window; unpaid -> strike + next bidder.

-- ---------------------------------------------------------------------------
-- 1. Settings. auctions_enabled has NO config rule on purpose: admin_set_config cannot flip it. Only the dedicated
--    admin_set_auctions_enabled (confirmation phrase) and the kill switch can.
-- ---------------------------------------------------------------------------
insert into public.site_config (key, value, is_public, description) values
  ('auctions_enabled',          'false', false, 'Global auction switch (default OFF). Changed only by the auction admin functions'),
  ('auction_hours',             '72',    false, 'How long an auction runs'),
  ('auction_min_increment',     '10000', false, 'Minimum raise over the current highest bid, in rupiah'),
  ('auction_pay_hours',         '24',    false, 'Hours the winner has to pay before the slot goes to the next bidder'),
  ('auction_max_strikes',       '3',     false, 'Unpaid wins before an account is blocked from bidding'),
  ('auction_min_fill_pct',      '85',    false, 'Readiness: fill rate every week must exceed this %'),
  ('auction_fill_weeks',        '4',     false, 'Readiness: number of consecutive weeks above the fill rate'),
  ('auction_waitlist_multiple', '2',     false, 'Readiness: waitlist must be at least this many times the slot count')
on conflict (key) do nothing;
insert into public.config_rules (key, kind, min_v, max_v) values
  ('auction_hours','int',1,168), ('auction_min_increment','int',1000,1000000000), ('auction_pay_hours','int',1,168),
  ('auction_max_strikes','int',1,10), ('auction_min_fill_pct','int',1,100), ('auction_fill_weeks','int',1,12),
  ('auction_waitlist_multiple','int',1,20)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Schema
-- ---------------------------------------------------------------------------
alter table public.ad_slot_settings add column if not exists auction_enabled boolean not null default false;

create table if not exists public.ad_auctions (
  id uuid primary key default gen_random_uuid(),
  target_key text not null check (target_key ~ '^(global:\*|country:[A-Z]{2}|(region|city|campus):[0-9a-f-]{36})$'),
  product_id text not null references public.ad_products (id),
  duration_days int not null check (duration_days > 0),
  period_start date not null,
  reserve_amount bigint not null check (reserve_amount > 0),
  buy_now_amount bigint not null check (buy_now_amount > 0),
  min_increment bigint not null check (min_increment > 0),
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  original_ends_at timestamptz not null,
  extensions int not null default 0 check (extensions between 0 and 6),
  status text not null default 'open' check (status in ('open','awaiting_payment','settled','no_winner','canceled')),
  cancel_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  settled_at timestamptz
);
-- One live auction per location + package: two admins cannot open the same slot twice.
create unique index if not exists ad_auctions_one_live on public.ad_auctions (target_key, product_id)
  where status in ('open','awaiting_payment');
create index if not exists ad_auctions_due on public.ad_auctions (ends_at) where status = 'open';

create table if not exists public.ad_bids (
  id uuid primary key default gen_random_uuid(),
  auction_id uuid not null references public.ad_auctions (id) on delete cascade,
  bidder_id uuid not null references auth.users (id) on delete cascade,
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  amount bigint not null check (amount > 0),
  is_buy_now boolean not null default false,
  status text not null default 'valid' check (status in ('valid','canceled')),
  cancel_reason text,
  ip_hash text,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists ad_bids_rank on public.ad_bids (auction_id, amount desc, created_at, id);

create table if not exists public.ad_auction_offers (
  id uuid primary key default gen_random_uuid(),
  auction_id uuid not null references public.ad_auctions (id) on delete cascade,
  bid_id uuid not null references public.ad_bids (id),
  bidder_id uuid not null,
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  amount bigint not null,
  orig_price bigint, orig_list bigint, orig_start date,
  offered_at timestamptz not null default now(),
  pay_by timestamptz not null,
  status text not null default 'pending' check (status in ('pending','paid','expired','canceled'))
);
create unique index if not exists ad_offers_one_pending on public.ad_auction_offers (auction_id) where status = 'pending';

create table if not exists public.ad_auction_strikes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  auction_id uuid references public.ad_auctions (id) on delete set null,
  offer_id uuid references public.ad_auction_offers (id) on delete set null,
  created_at timestamptz not null default now(),
  cleared_at timestamptz,
  cleared_by uuid
);
create index if not exists ad_strikes_user on public.ad_auction_strikes (user_id) where cleared_at is null;

create table if not exists public.ad_auction_flags (
  id uuid primary key default gen_random_uuid(),
  auction_id uuid not null references public.ad_auctions (id) on delete cascade,
  kind text not null,
  details jsonb not null default '{}'::jsonb,
  dedupe_key text not null unique,
  created_at timestamptz not null default now()
);

alter table public.ad_auctions enable row level security;
alter table public.ad_bids enable row level security;
alter table public.ad_auction_offers enable row level security;
alter table public.ad_auction_strikes enable row level security;
alter table public.ad_auction_flags enable row level security;
revoke all on public.ad_auctions, public.ad_bids, public.ad_auction_offers, public.ad_auction_strikes, public.ad_auction_flags from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Flags, readiness
-- ---------------------------------------------------------------------------
create or replace function public.auctions_on() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((public.config_value('auctions_enabled') #>> '{}')::boolean, false)
$$;
create or replace function public.auction_location_on(p_key text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select auction_enabled from public.ad_slot_settings where target_key = p_key), false)
$$;
create or replace function public.cfg_int(p_key text, p_default int) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce((public.config_value(p_key) #>> '{}')::int, p_default)
$$;

-- Readiness for one location: every one of the last N weeks above the fill threshold, and the waitlist >= multiple x slots.
create or replace function public.auction_readiness(p_key text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_weeks int := public.cfg_int('auction_fill_weeks', 4);
  v_min int := public.cfg_int('auction_min_fill_pct', 85);
  v_mult int := public.cfg_int('auction_waitlist_multiple', 2);
  v_slots int := public.ad_slots_for('featured', p_key);
  v_fills jsonb := '[]'::jsonb; v_f numeric; v_ok int := 0; v_wl int; i int;
begin
  for i in 0 .. v_weeks - 1 loop
    v_f := public.ad_fill_pct(p_key, v_today - 7 * i - 6, v_today - 7 * i);
    v_fills := v_fills || to_jsonb(v_f);
    if v_f > v_min then v_ok := v_ok + 1; end if;
  end loop;
  select count(*) into v_wl from public.ad_waitlist w where w.status = 'waiting' and w.spot = 'featured'
     and (w.target_key = p_key or (w.target_key is null and w.scope_level = split_part(p_key, ':', 1)));
  return jsonb_build_object('key', p_key, 'weeks_required', v_weeks, 'weeks_ok', v_ok, 'weekly_fill', v_fills,
    'fill_threshold', v_min, 'waitlist', v_wl, 'waitlist_needed', v_mult * v_slots, 'slots', v_slots,
    'ready', v_ok = v_weeks and v_wl >= v_mult * v_slots);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Ranking. ONE definition of "who is ahead", used for the live high bid, the winner and the fallback:
--    highest amount first, then the EARLIEST bid, then id (so the order is total and repeatable).
--    Only valid bids whose campaign is still approved count.
-- ---------------------------------------------------------------------------
create or replace function public.auction_ranked_bids(p_auction uuid)
returns table (bid_id uuid, bidder_id uuid, campaign_id uuid, amount bigint, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select b.id, b.bidder_id, b.campaign_id, b.amount, b.created_at
    from public.ad_bids b join public.campaigns c on c.id = b.campaign_id
   where b.auction_id = p_auction and b.status = 'valid' and c.status = 'approved'
   order by b.amount desc, b.created_at asc, b.id asc
$$;

-- The winner now: best-ranked bid from someone who has not already had (and lost) an offer on this auction and is not blocked.
create or replace function public.auction_pick_winner(p_auction uuid)
returns table (bid_id uuid, bidder_id uuid, campaign_id uuid, amount bigint)
language sql stable security definer set search_path = '' as $$
  select r.bid_id, r.bidder_id, r.campaign_id, r.amount from public.auction_ranked_bids(p_auction) r
   where not exists (select 1 from public.ad_auction_offers o where o.auction_id = p_auction and o.bidder_id = r.bidder_id)
     and (select count(*) from public.ad_auction_strikes s where s.user_id = r.bidder_id and s.cleared_at is null)
         < public.cfg_int('auction_max_strikes', 3)
   limit 1
$$;

-- Anti-sniping: a bid in the last 5 minutes pushes the end back 5 minutes, at most 6 times. Returns the new end.
create or replace function public.auction_extended_end(p_ends timestamptz, p_now timestamptz, p_extensions int) returns timestamptz
language sql immutable set search_path = '' as $$
  select case when p_extensions < 6 and p_ends - p_now <= interval '5 minutes' then p_ends + interval '5 minutes' else p_ends end
$$;

-- A bidder's own minimum first bid: the public reserve, or less when a founding price lock applies to them.
-- (A lock never discounts a WINNING bid: the winner pays exactly what they bid.)
create or replace function public.auction_reserve_for(p_bidder uuid, a public.ad_auctions) returns bigint
language plpgsql stable security definer set search_path = '' as $$
declare p public.ad_products; v_mine bigint;
begin
  select * into p from public.ad_products where id = a.product_id;
  v_mine := round((public.ad_quote(p_bidder, p, 1) ->> 'total')::numeric * (public.ad_slot_cfg(a.target_key) ->> 'standard_multiplier')::numeric)::bigint;
  return greatest(least(a.reserve_amount, v_mine), 1);
end $$;

-- While an auction is open or awaiting payment, its slot is reserved: nobody else can buy it at the fixed price.
create or replace function public.ad_active_holds(p_key text, p_email text, p_exclude uuid) returns int
language sql stable security definer set search_path = '' as $$
  select (select count(*) from public.ad_waitlist w
   where w.spot = 'featured' and w.target_key = p_key
     and lower(w.email) is distinct from lower(coalesce(p_email, ''))
     and (p_exclude is null or w.claimed_campaign_id is distinct from p_exclude)
     and ((w.status = 'notified' and w.hold_expires_at > now())
       or (w.status = 'claimed' and exists (select 1 from public.campaigns c
            where c.id = w.claimed_campaign_id and c.status in ('pending_approval','approved')))))::int
       + (select count(*) from public.ad_auctions a
           where a.target_key = p_key and a.status in ('open','awaiting_payment')
             and not exists (select 1 from public.ad_auction_offers o
                              where o.auction_id = a.id and o.status = 'pending' and o.campaign_id is not distinct from p_exclude))::int
$$;

-- ---------------------------------------------------------------------------
-- 5. Offers: turn the auction result into a payable campaign. The winning amount becomes the campaign price, and
--    from there create_ad_order copies it onto the order, so it can never change afterwards.
-- ---------------------------------------------------------------------------
create or replace function public.auction_label(a public.ad_auctions) returns text
language sql stable security definer set search_path = '' as $$ select public.target_label(a.target_key) $$;

create or replace function public.user_email(p_user uuid) returns text
language sql stable security definer set search_path = '' as $$ select email from auth.users where id = p_user $$;

-- Mail to everyone who bid (once per person per kind), optionally skipping one user.
create or replace function public.auction_mail_bidders(a public.ad_auctions, p_kind text, p_payload jsonb, p_skip uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select distinct b.bidder_id from public.ad_bids b where b.auction_id = a.id and b.bidder_id is distinct from p_skip loop
    perform public.ad_enqueue(p_kind, public.user_email(r.bidder_id), r.bidder_id, p_payload, p_kind || ':' || a.id || ':' || r.bidder_id);
  end loop;
end $$;

-- Give the slot to the best remaining bidder. No bidder left = no winner. Safe to call twice.
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
  insert into public.ad_auction_offers (auction_id, bid_id, bidder_id, campaign_id, amount, orig_price, orig_list, orig_start, pay_by)
  values (a.id, w.bid_id, w.bidder_id, c.id, w.amount, c.price_snapshot, c.list_price_snapshot, c.requested_start, v_pay_by)
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

-- Put a campaign back exactly as it was before the offer.
create or replace function public.auction_release_offer(p_offer uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.ad_auction_offers;
begin
  select * into o from public.ad_auction_offers where id = p_offer and status = 'pending' for update;
  if not found then return; end if;
  update public.ad_auction_offers set status = p_status where id = o.id;
  update public.campaigns set price_snapshot = o.orig_price, list_price_snapshot = o.orig_list, requested_start = o.orig_start
   where id = o.campaign_id and status = 'approved';
end $$;

-- ---------------------------------------------------------------------------
-- 6. Bidding (service role: called by the auction-bid edge function after it has authenticated the user)
-- ---------------------------------------------------------------------------
create or replace function public.place_bid(p_bidder uuid, p_auction uuid, p_campaign uuid, p_amount bigint, p_ip text, p_buy_now boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a public.ad_auctions; c public.campaigns; v_high_amount bigint; v_high_bidder uuid; v_min bigint; v_amount bigint; v_buy boolean := coalesce(p_buy_now, false);
  v_ip text := public.visitor_hash(coalesce(nullif(btrim(p_ip), ''), 'none'), '');
  v_bid uuid; v_new_end timestamptz; v_extended boolean := false; v_verified timestamptz;
begin
  if p_bidder is null then
    perform public.app_error('CSW03', 'AUTH_REQUIRED', 'Sign in to bid.');
  end if;
  if not public.check_rate_limit('bid:u:' || p_bidder, 20, 60) or not public.check_rate_limit('bid:ip:' || v_ip, 60, 60) then
    perform public.app_error('CSW29', 'RATE_LIMITED', 'Too many bids. Wait a minute and try again.');
  end if;
  -- Lock the auction row: bids on one auction are strictly serial, so "earliest bid wins" and the minimum raise are exact.
  select * into a from public.ad_auctions where id = p_auction for update;
  if not found then
    perform public.app_error('CSW04', 'NOT_FOUND', 'Auction not found.');
  end if;
  if not public.auctions_on() or not public.auction_location_on(a.target_key) then
    perform public.app_error('CSW09', 'AUCTIONS_OFF', 'Auctions are not available.');
  end if;
  if a.status <> 'open' or now() >= a.ends_at then
    perform public.app_error('CSW09', 'AUCTION_CLOSED', 'This auction has ended.');
  end if;
  select email_confirmed_at into v_verified from auth.users where id = p_bidder;
  if v_verified is null then
    perform public.app_error('CSW03', 'EMAIL_NOT_VERIFIED', 'Verify your email address before bidding.');
  end if;
  if public.is_suspended(p_bidder) then
    perform public.app_error('CSW03', 'ACCOUNT_SUSPENDED', 'This account is suspended.');
  end if;
  if (select count(*) from public.ad_auction_strikes s where s.user_id = p_bidder and s.cleared_at is null) >= public.cfg_int('auction_max_strikes', 3) then
    perform public.app_error('CSW03', 'BIDDING_BLOCKED', 'Bidding is blocked after unpaid wins. Contact support.');
  end if;
  -- The bid is for the bidder's OWN approved ad, so the creative is already reviewed before the slot is won.
  select * into c from public.campaigns where id = p_campaign;
  if not found or c.owner_id <> p_bidder or c.status <> 'approved' or c.placement <> 'featured' or c.product_id <> a.product_id
     or (select count(*) from public.campaign_targets t where t.campaign_id = c.id) <> 1
     or not exists (select 1 from public.campaign_targets t where t.campaign_id = c.id and t.target_key = a.target_key) then
    perform public.app_error('CSW09', 'CAMPAIGN_NOT_ELIGIBLE', 'Bid with one of your approved ads for this exact package and location.');
  end if;
  select r.amount, r.bidder_id into v_high_amount, v_high_bidder from public.auction_ranked_bids(a.id) r limit 1;
  if v_high_bidder = p_bidder then
    perform public.app_error('CSW09', 'ALREADY_HIGHEST', 'You already have the highest bid.');
  end if;
  if v_buy then
    v_amount := a.buy_now_amount;
  else
    v_min := case when v_high_amount is null then public.auction_reserve_for(p_bidder, a) else v_high_amount + a.min_increment end;
    if p_amount is null or p_amount < v_min then
      perform public.app_error('CSW40', 'BID_TOO_LOW', 'Minimum bid is Rp' || v_min);
    end if;
    -- A bid at or above the buy-now price is just a buy-now: nobody pays more than the buy-now price.
    v_buy := p_amount >= a.buy_now_amount;
    v_amount := case when v_buy then a.buy_now_amount else p_amount end;
  end if;
  perform public.require_payable_total(v_amount);

  insert into public.ad_bids (auction_id, bidder_id, campaign_id, amount, is_buy_now, ip_hash)
  values (a.id, p_bidder, c.id, v_amount, v_buy, v_ip) returning id into v_bid;

  -- Same network, different accounts, same auction: flag for admin review (nothing is blocked automatically).
  if exists (select 1 from public.ad_bids b where b.auction_id = a.id and b.ip_hash = v_ip and b.bidder_id <> p_bidder) then
    insert into public.ad_auction_flags (auction_id, kind, details, dedupe_key)
    values (a.id, 'same_ip', jsonb_build_object('ip_hash', left(v_ip, 12), 'bidders', (select jsonb_agg(distinct b.bidder_id) from public.ad_bids b where b.auction_id = a.id and b.ip_hash = v_ip)),
            'ip:' || a.id || ':' || v_ip) on conflict (dedupe_key) do nothing;
  end if;

  if v_buy then
    update public.ad_auctions set ends_at = now() where id = a.id;
    perform public.auction_make_offer(a.id);
    return jsonb_build_object('ok', true, 'amount', v_amount::text, 'bought', true);
  end if;

  v_new_end := public.auction_extended_end(a.ends_at, now(), a.extensions);
  if v_new_end <> a.ends_at then
    v_extended := true;
    update public.ad_auctions set ends_at = v_new_end, extensions = extensions + 1 where id = a.id;
  end if;
  -- Outbid mail to the previous leader. The new leader's identity is never revealed.
  if v_high_bidder is not null then
    perform public.ad_enqueue('auction_outbid', public.user_email(v_high_bidder), v_high_bidder,
      jsonb_build_object('location', public.auction_label(a), 'amount', v_amount::text, 'ends_at', v_new_end), 'outbid:' || v_bid);
  end if;
  return jsonb_build_object('ok', true, 'amount', v_amount::text, 'bought', false, 'ends_at', v_new_end, 'extended', v_extended);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Cron: settle ended auctions, expire unpaid offers (strike + next bidder), notifications. Idempotent.
-- ---------------------------------------------------------------------------
create or replace function public.run_auction_jobs() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.ad_auctions; o public.ad_auction_offers; c public.campaigns;
        v_settled int := 0; v_expired int := 0; v_paid int := 0; v_mail int := 0; r record;
begin
  -- Paid offers (the webhook fulfilled the order): the auction is done.
  for o in select o2.* from public.ad_auction_offers o2 where o2.status = 'pending' loop
    if exists (select 1 from public.campaigns cc join public.orders od on od.id = cc.order_id
                where cc.id = o.campaign_id and od.status = 'paid') then
      update public.ad_auction_offers set status = 'paid' where id = o.id;
      update public.ad_auctions set status = 'settled', settled_at = now() where id = o.auction_id;
      v_paid := v_paid + 1;
    end if;
  end loop;
  -- Ended auctions get their winner.
  for a in select * from public.ad_auctions where status = 'open' and ends_at <= now() for update skip locked loop
    perform public.auction_make_offer(a.id);
    v_settled := v_settled + 1;
  end loop;
  -- Winner did not pay in time. A payment already started (live unexpired order) is allowed to finish.
  for o in select * from public.ad_auction_offers where status = 'pending' and pay_by <= now() for update skip locked loop
    select * into c from public.campaigns where id = o.campaign_id;
    continue when c.status = 'awaiting_payment' and exists (select 1 from public.orders od where od.id = c.order_id
                   and od.status = 'awaiting_payment' and (od.expires_at is null or od.expires_at > now()));
    continue when c.status in ('pending_review','scheduled','active','paused','awaiting_payment');
    perform public.auction_release_offer(o.id, 'expired');
    insert into public.ad_auction_strikes (user_id, auction_id, offer_id) values (o.bidder_id, o.auction_id, o.id);
    perform public.auction_make_offer(o.auction_id);
    v_expired := v_expired + 1;
  end loop;
  -- Ending in 1 hour.
  for r in select a2.*, b.bidder_id from public.ad_auctions a2 join (select distinct auction_id, bidder_id from public.ad_bids) b on b.auction_id = a2.id
            where a2.status = 'open' and a2.ends_at > now() and a2.ends_at <= now() + interval '1 hour' loop
    perform public.ad_enqueue('auction_ending', public.user_email(r.bidder_id), r.bidder_id,
      jsonb_build_object('location', public.target_label(r.target_key), 'ends_at', r.ends_at), 'ending:' || r.id || ':' || r.bidder_id);
    v_mail := v_mail + 1;
  end loop;
  -- Payment reminder: 6 hours before the payment deadline.
  for r in select o2.*, a2.target_key from public.ad_auction_offers o2 join public.ad_auctions a2 on a2.id = o2.auction_id
            where o2.status = 'pending' and o2.pay_by > now() and o2.pay_by <= now() + interval '6 hours' loop
    perform public.ad_enqueue('auction_pay_reminder', public.user_email(r.bidder_id), r.bidder_id,
      jsonb_build_object('location', public.target_label(r.target_key), 'amount', r.amount::text, 'pay_by', r.pay_by), 'payrem:' || r.id);
    v_mail := v_mail + 1;
  end loop;
  return jsonb_build_object('paid', v_paid, 'settled', v_settled, 'expired_offers', v_expired, 'notifications', v_mail);
end $$;

-- ---------------------------------------------------------------------------
-- 8. create_ad_order: a campaign with an auction offer must be paid inside the offer window. Everything else is the
--    033 function unchanged (the winning amount is already in price_snapshot, which is what gets copied to the order).
-- ---------------------------------------------------------------------------
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
  if exists (select 1 from public.ad_auction_offers ao where ao.campaign_id = v_c.id and ao.status = 'pending' and ao.pay_by < now()) then
    perform public.app_error('CSW09', 'OFFER_EXPIRED', 'The payment window for this auction win has ended.');
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

-- upsert_campaign_draft: 033 version + skip the submit-time sold-out pre-check while an auction is open there.
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
  -- While an auction is open for a location, advertisers may submit ads to bid with even though it is sold out at the
  -- fixed price. Nothing can be bought until create_ad_order, which always enforces capacity.
  if not exists (select 1 from public.ad_auctions au where au.status = 'open' and au.target_key = any (v_keys)) then
    perform public.assert_ad_capacity(v_camp, p_contact_email);
  end if;
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

-- ---------------------------------------------------------------------------
-- 9. Public read API. Returns nothing while auctions are off. NEVER returns who bid: only counts, amounts, and whether
--    the signed-in caller is the one leading.
-- ---------------------------------------------------------------------------
create or replace function public.list_open_auctions() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_me uuid := (select auth.uid());
begin
  if not public.auctions_on() then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x order by x.ends_at) from (
    select a.id, a.target_key, public.target_label(a.target_key) as label, a.product_id, p.name as product_name, a.duration_days,
           a.period_start, a.reserve_amount::text as reserve, a.buy_now_amount::text as buy_now, a.min_increment::text as min_increment,
           a.ends_at, a.extensions,
           (select count(*) from public.ad_bids b where b.auction_id = a.id and b.status = 'valid') as bid_count,
           h.amount::text as high_amount,
           coalesce((h.amount + a.min_increment), a.reserve_amount)::text as min_next_bid,
           (h.bidder_id is not null and h.bidder_id = v_me) as leading,
           (select max(b.amount)::text from public.ad_bids b where b.auction_id = a.id and b.bidder_id = v_me and b.status = 'valid') as my_bid
      from public.ad_auctions a
      join public.ad_products p on p.id = a.product_id
      left join lateral (select r.amount, r.bidder_id from public.auction_ranked_bids(a.id) r limit 1) h on true
     where a.status = 'open' and a.ends_at > now() and public.auction_location_on(a.target_key)) x), '[]'::jsonb);
end $$;

create or replace function public.my_auction_offers() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('offer_id', o.id, 'auction_id', o.auction_id, 'campaign_id', o.campaign_id,
      'amount', o.amount::text, 'pay_by', o.pay_by, 'label', public.target_label(a.target_key), 'period_start', a.period_start)
      order by o.pay_by), '[]'::jsonb)
    from public.ad_auction_offers o join public.ad_auctions a on a.id = o.auction_id
   where o.bidder_id = (select auth.uid()) and o.status = 'pending'
$$;

-- ---------------------------------------------------------------------------
-- 10. Admin
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_auctions_enabled(p_enabled boolean, p_confirm text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old boolean := public.auctions_on();
begin
  perform public.require_admin();
  if p_enabled and p_confirm is distinct from 'ENABLE AUCTIONS' then
    perform public.app_error('CSW40', 'CONFIRM_REQUIRED', 'Type ENABLE AUCTIONS to turn auctions on.');
  end if;
  update public.site_config set value = to_jsonb(p_enabled) where key = 'auctions_enabled';
  perform public.audit('auction.global', 'config', 'auctions_enabled', null, jsonb_build_object('old', v_old, 'new', p_enabled));
  return jsonb_build_object('ok', true, 'enabled', p_enabled);
end $$;

create or replace function public.admin_set_auction_location(p_key text, p_enabled boolean, p_override_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ready jsonb; v_old boolean := public.auction_location_on(p_key); v_override boolean := false;
begin
  perform public.require_admin();
  if p_key is null or p_key !~ '^(global:\*|country:[A-Z]{2}|(region|city|campus):[0-9a-f-]{36})$' then
    perform public.app_error('CSW40', 'INVALID_LOCATION', 'Unknown location key.');
  end if;
  v_ready := public.auction_readiness(p_key);
  if p_enabled and not (v_ready ->> 'ready')::boolean then
    if char_length(btrim(coalesce(p_override_reason, ''))) < 5 then
      perform public.app_error('CSW09', 'NOT_READY', 'This location does not meet the readiness rules. Enter an override reason to enable it anyway.');
    end if;
    v_override := true;
  end if;
  insert into public.ad_slot_settings (target_key, slots, auction_enabled)
  values (p_key, public.ad_slots_for('featured', p_key), p_enabled)
  on conflict (target_key) do update set auction_enabled = p_enabled, updated_at = now();
  perform public.audit('auction.location', 'ad_location', p_key, case when v_override then btrim(p_override_reason) end,
    jsonb_build_object('old', v_old, 'new', p_enabled, 'override', v_override, 'readiness', v_ready));
  return jsonb_build_object('ok', true, 'enabled', p_enabled, 'override', v_override, 'readiness', v_ready);
end $$;

-- Cancel an auction: pending offer released (campaign price restored), bidders told. Nothing was charged, so nothing to refund.
create or replace function public.auction_cancel_internal(p_auction uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.ad_auctions; o record;
begin
  select * into a from public.ad_auctions where id = p_auction and status in ('open','awaiting_payment') for update;
  if not found then return; end if;
  for o in select id from public.ad_auction_offers where auction_id = a.id and status = 'pending' loop
    perform public.auction_release_offer(o.id, 'canceled');
  end loop;
  update public.ad_auctions set status = 'canceled', cancel_reason = p_reason, settled_at = now() where id = a.id;
  perform public.auction_mail_bidders(a, 'auction_canceled', jsonb_build_object('location', public.auction_label(a)), null);
end $$;

create or replace function public.admin_cancel_auction(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_admin();
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then
    perform public.app_error('CSW40', 'REASON_REQUIRED', 'Enter a reason (at least 5 characters).');
  end if;
  if not exists (select 1 from public.ad_auctions where id = p_id and status in ('open','awaiting_payment')) then
    perform public.app_error('CSW04', 'NOT_FOUND', 'Auction not found or already finished.');
  end if;
  perform public.auction_cancel_internal(p_id, btrim(p_reason));
  perform public.audit('auction.cancel', 'ad_auction', p_id::text, btrim(p_reason), '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

-- Kill switch: auctions off everywhere, every OPEN auction canceled, fixed prices carry on. A winner who already has a
-- payment window keeps it (they won fairly); cancel that auction by hand if needed.
create or replace function public.admin_auction_kill_switch(p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  perform public.require_admin();
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then
    perform public.app_error('CSW40', 'REASON_REQUIRED', 'Enter a reason (at least 5 characters).');
  end if;
  update public.site_config set value = 'false'::jsonb where key = 'auctions_enabled';
  for r in select id from public.ad_auctions where status = 'open' loop
    perform public.auction_cancel_internal(r.id, 'Kill switch: ' || btrim(p_reason));
    v_n := v_n + 1;
  end loop;
  perform public.audit('auction.kill_switch', 'config', 'auctions_enabled', btrim(p_reason), jsonb_build_object('canceled_open_auctions', v_n));
  return jsonb_build_object('ok', true, 'canceled', v_n);
end $$;

create or replace function public.admin_open_auction(p_key text, p_product text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p public.ad_products; v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_cap jsonb; v_cap2 jsonb; v_start date; v_ends timestamptz; v_reserve bigint; v_id uuid;
begin
  perform public.require_admin();
  if not public.auctions_on() then
    perform public.app_error('CSW09', 'AUCTIONS_OFF', 'Auctions are switched off.');
  end if;
  if not public.auction_location_on(p_key) then
    perform public.app_error('CSW09', 'LOCATION_OFF', 'Auctions are not enabled for this location.');
  end if;
  select * into p from public.ad_products where id = p_product and enabled and placement = 'featured';
  if not found or p.scope_level <> split_part(p_key, ':', 1) then
    perform public.app_error('CSW40', 'INVALID_PRODUCT', 'Choose an enabled Featured package of the same reach as the location.');
  end if;
  -- Only a FULL slot is auctioned, and only the period that starts when the next slot frees up.
  v_cap := public.ad_capacity(p_key, 'standard', v_today, p.duration_days, null, null);
  if (v_cap ->> 'free')::int > 0 then
    perform public.app_error('CSW09', 'NOT_FULL', 'This location still has a free slot. Sell it at the fixed price.');
  end if;
  v_start := (v_cap ->> 'next_free_date')::date;
  v_ends := now() + make_interval(hours => public.cfg_int('auction_hours', 72));
  if v_start is null or v_start < (v_ends at time zone 'Asia/Jakarta')::date + 2 then
    perform public.app_error('CSW09', 'AUCTION_TOO_LATE', 'The next slot frees up too soon to finish an auction and a payment window.');
  end if;
  v_cap2 := public.ad_capacity(p_key, 'standard', v_start, p.duration_days, null, null);
  if (v_cap2 ->> 'free')::int < 1 then
    perform public.app_error('CSW09', 'NOT_SELLABLE', 'No slot is free for the whole period from ' || v_start || '.');
  end if;
  v_reserve := greatest(round((public.ad_quote(null, p, 1) ->> 'total')::numeric * (public.ad_slot_cfg(p_key) ->> 'standard_multiplier')::numeric)::bigint, 1);
  begin
    insert into public.ad_auctions (target_key, product_id, duration_days, period_start, reserve_amount, buy_now_amount, min_increment,
                                    ends_at, original_ends_at, created_by)
    values (p_key, p.id, p.duration_days, v_start, v_reserve, round(v_reserve * 1.5), public.cfg_int('auction_min_increment', 10000),
            v_ends, v_ends, (select auth.uid()))
    returning id into v_id;
  exception when unique_violation then
    perform public.app_error('CSW09', 'AUCTION_EXISTS', 'There is already a live auction for this location and package.');
  end;
  perform public.audit('auction.open', 'ad_auction', v_id::text, null,
    jsonb_build_object('key', p_key, 'product', p.id, 'period_start', v_start, 'reserve', v_reserve, 'ends_at', v_ends));
  return jsonb_build_object('ok', true, 'id', v_id, 'period_start', v_start, 'reserve', v_reserve::text, 'ends_at', v_ends);
end $$;

create or replace function public.admin_cancel_bid(p_bid uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b public.ad_bids; a public.ad_auctions;
begin
  perform public.require_admin();
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then
    perform public.app_error('CSW40', 'REASON_REQUIRED', 'Enter a reason (at least 5 characters).');
  end if;
  select * into b from public.ad_bids where id = p_bid and status = 'valid' for update;
  if not found then
    perform public.app_error('CSW04', 'NOT_FOUND', 'Bid not found or already canceled.');
  end if;
  select * into a from public.ad_auctions where id = b.auction_id for update;
  if a.status <> 'open' then
    perform public.app_error('CSW09', 'AUCTION_CLOSED', 'Only bids in an open auction can be canceled.');
  end if;
  update public.ad_bids set status = 'canceled', cancel_reason = btrim(p_reason) where id = b.id;
  perform public.audit('auction.cancel_bid', 'ad_bid', b.id::text, btrim(p_reason),
    jsonb_build_object('auction', b.auction_id, 'amount', b.amount, 'bidder', b.bidder_id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_clear_strikes(p_user uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_n int;
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then
    perform public.app_error('CSW40', 'REASON_REQUIRED', 'Enter a reason (at least 5 characters).');
  end if;
  update public.ad_auction_strikes set cleared_at = now(), cleared_by = v_admin where user_id = p_user and cleared_at is null;
  get diagnostics v_n = row_count;
  perform public.audit('auction.clear_strikes', 'user', p_user::text, btrim(p_reason), jsonb_build_object('cleared', v_n));
  return jsonb_build_object('ok', true, 'cleared', v_n);
end $$;

create or replace function public.admin_auction_bids(p_auction uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'bids', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'bidder_id', b.bidder_id, 'email', public.user_email(b.bidder_id),
        'amount', b.amount::text, 'status', b.status, 'cancel_reason', b.cancel_reason, 'buy_now', b.is_buy_now,
        'ip', left(b.ip_hash, 8), 'created_at', b.created_at, 'campaign_id', b.campaign_id) order by b.created_at desc)
      from public.ad_bids b where b.auction_id = p_auction), '[]'::jsonb),
    'flags', coalesce((select jsonb_agg(jsonb_build_object('kind', f.kind, 'details', f.details, 'created_at', f.created_at))
      from public.ad_auction_flags f where f.auction_id = p_auction), '[]'::jsonb),
    'offers', coalesce((select jsonb_agg(jsonb_build_object('bidder', public.user_email(o.bidder_id), 'amount', o.amount::text,
        'status', o.status, 'pay_by', o.pay_by) order by o.offered_at)
      from public.ad_auction_offers o where o.auction_id = p_auction), '[]'::jsonb));
end $$;

create or replace function public.admin_auction_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return jsonb_build_object('enabled', public.auctions_on(),
    'locations', coalesce((select jsonb_agg(jsonb_build_object('key', k.key, 'label', public.target_label(k.key),
        'enabled', public.auction_location_on(k.key), 'readiness', public.auction_readiness(k.key)) order by public.target_label(k.key))
      from (select target_key as key from public.ad_slot_settings
            union select t.target_key from public.campaign_targets t join public.campaigns c on c.id = t.campaign_id
                   where c.placement = 'featured' and c.status not in ('canceled','rejected','draft')) k), '[]'::jsonb),
    'auctions', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'label', public.target_label(a.target_key), 'product', a.product_id,
        'status', a.status, 'period_start', a.period_start, 'reserve', a.reserve_amount::text, 'buy_now', a.buy_now_amount::text,
        'ends_at', a.ends_at, 'extensions', a.extensions, 'cancel_reason', a.cancel_reason,
        'bids', (select count(*) from public.ad_bids b where b.auction_id = a.id and b.status = 'valid'),
        'high', (select r.amount::text from public.auction_ranked_bids(a.id) r limit 1),
        'flags', (select count(*) from public.ad_auction_flags f where f.auction_id = a.id)) order by a.created_at desc)
      from (select * from public.ad_auctions order by created_at desc limit 30) a), '[]'::jsonb),
    'strikes', coalesce((select jsonb_agg(jsonb_build_object('user_id', s.user_id, 'email', public.user_email(s.user_id), 'strikes', s.n))
      from (select user_id, count(*) as n from public.ad_auction_strikes where cleared_at is null group by user_id) s), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 11. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.list_open_auctions() to anon, authenticated, service_role;
grant execute on function public.my_auction_offers() to authenticated, service_role;
grant execute on function public.admin_set_auctions_enabled(boolean, text), public.admin_set_auction_location(text, boolean, text),
  public.admin_cancel_auction(uuid, text), public.admin_auction_kill_switch(text), public.admin_open_auction(text, text),
  public.admin_cancel_bid(uuid, text), public.admin_clear_strikes(uuid, text), public.admin_auction_bids(uuid),
  public.admin_auction_overview() to authenticated, service_role;
grant execute on function public.place_bid(uuid, uuid, uuid, bigint, text, boolean), public.run_auction_jobs() to service_role;

-- ---------------------------------------------------------------------------
-- EXECUTE allowlist (005 pattern) for the functions this migration ADDS.
-- Supabase grants EXECUTE on new public functions to anon/authenticated by default and the 005 default-privilege
-- change does not undo that, so revoke first, then re-run the client grants from the Grants section above. Everything not granted to a client role is service_role
-- only; each client-facing admin function re-checks require_admin() itself.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.admin_auction_bids(uuid),
  public.admin_auction_kill_switch(text),
  public.admin_auction_overview(),
  public.admin_cancel_auction(uuid,text),
  public.admin_cancel_bid(uuid,text),
  public.admin_clear_strikes(uuid,text),
  public.admin_open_auction(text,text),
  public.admin_set_auction_location(text,boolean,text),
  public.admin_set_auctions_enabled(boolean,text),
  public.auction_cancel_internal(uuid,text),
  public.auction_extended_end(timestamp with time zone,timestamp with time zone,integer),
  public.auction_label(ad_auctions),
  public.auction_location_on(text),
  public.auction_mail_bidders(ad_auctions,text,jsonb,uuid),
  public.auction_make_offer(uuid),
  public.auction_pick_winner(uuid),
  public.auction_ranked_bids(uuid),
  public.auction_readiness(text),
  public.auction_release_offer(uuid,text),
  public.auction_reserve_for(uuid,ad_auctions),
  public.auctions_on(),
  public.cfg_int(text,integer),
  public.list_open_auctions(),
  public.my_auction_offers(),
  public.place_bid(uuid,uuid,uuid,bigint,text,boolean),
  public.run_auction_jobs(),
  public.user_email(uuid)
  from public, anon, authenticated;
grant execute on function
  public.admin_auction_bids(uuid),
  public.admin_auction_kill_switch(text),
  public.admin_auction_overview(),
  public.admin_cancel_auction(uuid,text),
  public.admin_cancel_bid(uuid,text),
  public.admin_clear_strikes(uuid,text),
  public.admin_open_auction(text,text),
  public.admin_set_auction_location(text,boolean,text),
  public.admin_set_auctions_enabled(boolean,text),
  public.auction_cancel_internal(uuid,text),
  public.auction_extended_end(timestamp with time zone,timestamp with time zone,integer),
  public.auction_label(ad_auctions),
  public.auction_location_on(text),
  public.auction_mail_bidders(ad_auctions,text,jsonb,uuid),
  public.auction_make_offer(uuid),
  public.auction_pick_winner(uuid),
  public.auction_ranked_bids(uuid),
  public.auction_readiness(text),
  public.auction_release_offer(uuid,text),
  public.auction_reserve_for(uuid,ad_auctions),
  public.auctions_on(),
  public.cfg_int(text,integer),
  public.list_open_auctions(),
  public.my_auction_offers(),
  public.place_bid(uuid,uuid,uuid,bigint,text,boolean),
  public.run_auction_jobs(),
  public.user_email(uuid)
  to service_role;
grant execute on function public.list_open_auctions() to anon, authenticated, service_role;
grant execute on function public.my_auction_offers() to authenticated, service_role;
grant execute on function public.admin_set_auctions_enabled(boolean, text), public.admin_set_auction_location(text, boolean, text),
  public.admin_cancel_auction(uuid, text), public.admin_auction_kill_switch(text), public.admin_open_auction(text, text),
  public.admin_cancel_bid(uuid, text), public.admin_clear_strikes(uuid, text), public.admin_auction_bids(uuid),
  public.admin_auction_overview() to authenticated, service_role;
grant execute on function public.place_bid(uuid, uuid, uuid, bigint, text, boolean), public.run_auction_jobs() to service_role;
