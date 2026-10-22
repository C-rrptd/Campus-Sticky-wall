-- 003_payments_and_referrals.sql
-- Orders, immutable order items, payment methods, Midtrans notification log,
-- donations, referral codes/attributions, free-publication credits, and the
-- trusted state machine that moves orders between states.
--
-- All order/payment/credit mutations happen inside SECURITY DEFINER functions
-- that only service_role may execute (enforced in 005). Edge Functions call
-- them after authenticating the caller; the browser never calls them directly.
--
-- Note: some plpgsql bodies here reference tables created in 004
-- (campaigns, notes.campus_id). plpgsql resolves names at execution time, and
-- no function here runs before every migration has been applied.

-- ---------------------------------------------------------------------------
-- Payment methods (eligibility by amount; limits come from the merchant's
-- Midtrans agreement and MUST be verified by the operator; NULL = no limit
-- configured here, in which case Midtrans itself may still reject).
-- ---------------------------------------------------------------------------
create table public.payment_methods (
  code text primary key check (code ~ '^[a-z0-9_]{2,40}$'),
  label text not null,
  midtrans_codes text[] not null check (cardinality(midtrans_codes) > 0),
  min_amount bigint check (min_amount is null or min_amount >= 1),
  max_amount bigint check (max_amount is null or max_amount >= 1),
  enabled boolean not null default true,
  sort_order int not null default 0,
  notes text,
  updated_at timestamptz not null default now(),
  check (min_amount is null or max_amount is null or min_amount <= max_amount)
);
create trigger payment_methods_updated_at before update on public.payment_methods
  for each row execute function public.set_updated_at();

insert into public.payment_methods (code, label, midtrans_codes, sort_order, notes) values
  ('qris', 'QRIS', array['other_qris'], 1, 'Verify per-transaction limit with Midtrans/your acquirer and set max_amount.'),
  ('ewallet', 'E-wallets (GoPay, ShopeePay, DANA)', array['gopay','shopeepay','dana'], 2, 'Wallet balance limits apply; verify and set max_amount.'),
  ('virtual_account', 'Bank transfer (virtual account)', array['bca_va','bni_va','bri_va','permata_va','echannel','cimb_va'], 3, 'Verify VA limits for your merchant account.'),
  ('credit_card', 'Credit / debit card', array['credit_card'], 4, 'Card limits are set by the issuer.'),
  ('convenience_store', 'Alfamart / Indomaret', array['alfamart','indomaret'], 5, 'Counter payments have low limits; verify and set max_amount.');

create or replace function public.eligible_payment_methods(p_total bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', m.code, 'label', m.label, 'midtrans_codes', to_jsonb(m.midtrans_codes),
           'min_amount', m.min_amount::text, 'max_amount', m.max_amount::text)
         order by m.sort_order), '[]'::jsonb)
  from public.payment_methods m
  where m.enabled
    and p_total > 0
    and (m.min_amount is null or p_total >= m.min_amount)
    and (m.max_amount is null or p_total <= m.max_amount)
$$;

-- ---------------------------------------------------------------------------
-- Orders and items
-- ---------------------------------------------------------------------------
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_ref text not null unique check (order_ref ~ '^[A-Za-z0-9_.~-]{8,50}$'),
  kind text not null check (kind in ('publication','donation','advertising')),
  user_id uuid references auth.users (id) on delete set null,
  status text not null default 'awaiting_payment' check (status in
    ('awaiting_payment','challenge','paid','completed_free','failed','canceled','expired',
     'partially_refunded','refunded','reversed')),
  currency text not null default 'IDR' check (currency = 'IDR'),
  publication_amount bigint check (publication_amount is null or publication_amount >= 5000),
  decorations_amount bigint not null default 0 check (decorations_amount >= 0),
  subtotal_amount bigint not null check (subtotal_amount >= 0),
  discount_amount bigint not null default 0 check (discount_amount >= 0),
  total_amount bigint not null check (total_amount >= 0),
  refunded_amount bigint not null default 0 check (refunded_amount >= 0),
  snapshot jsonb not null default '{}'::jsonb,
  guest_token_hash text check (guest_token_hash is null or guest_token_hash ~ '^[0-9a-f]{64}$'),
  payment_locked_at timestamptz,
  payment_session_token text,
  payment_redirect_url text,
  payment_type text,
  midtrans_transaction_id text,
  review_required boolean not null default false,
  review_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz,
  paid_at timestamptz,
  fulfilled_at timestamptz,
  closed_at timestamptz,
  check (total_amount = subtotal_amount - discount_amount),
  check (kind <> 'publication' or publication_amount is not null),
  check (refunded_amount <= total_amount)
);
create trigger orders_updated_at before update on public.orders
  for each row execute function public.set_updated_at();

-- Amount fields become immutable once a payment session exists or the order
-- has left awaiting_payment. Ownership and kind never change.
create or replace function public.guard_order_immutability() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.kind <> old.kind or new.order_ref <> old.order_ref
     or new.user_id is distinct from old.user_id and old.user_id is not null and new.user_id is not null
     or new.guest_token_hash is distinct from old.guest_token_hash then
    perform public.app_error('CSW09', 'ORDER_IMMUTABLE', 'Order identity fields cannot change.');
  end if;
  if (old.payment_locked_at is not null or old.status <> 'awaiting_payment')
     and (new.publication_amount is distinct from old.publication_amount
          or new.decorations_amount <> old.decorations_amount
          or new.subtotal_amount <> old.subtotal_amount
          or new.discount_amount <> old.discount_amount
          or new.total_amount <> old.total_amount
          or new.snapshot <> old.snapshot) then
    perform public.app_error('CSW09', 'ORDER_IMMUTABLE', 'Order amounts are locked.');
  end if;
  return new;
end $$;
create trigger orders_immutability before update on public.orders
  for each row execute function public.guard_order_immutability();

create table public.order_items (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders (id) on delete cascade,
  item_type text not null check (item_type in ('publication','decoration','credit','donation','advertising')),
  item_ref text,
  name text not null check (char_length(name) between 1 and 50),
  unit_amount bigint not null,
  quantity int not null default 1 check (quantity >= 1),
  created_at timestamptz not null default now(),
  check (item_type = 'credit' or unit_amount >= 0),
  check (item_type <> 'credit' or unit_amount < 0)
);

create or replace function public.guard_order_items() returns trigger
language plpgsql set search_path = '' as $$
declare v_order public.orders;
begin
  if tg_op = 'UPDATE' then
    perform public.app_error('CSW09', 'ORDER_ITEMS_IMMUTABLE', 'Order items cannot be edited.');
  end if;
  select * into v_order from public.orders where id = coalesce(new.order_id, old.order_id);
  if found and (v_order.payment_locked_at is not null or v_order.status <> 'awaiting_payment') then
    perform public.app_error('CSW09', 'ORDER_ITEMS_IMMUTABLE', 'Order items are locked.');
  end if;
  return coalesce(new, old);
end $$;
create trigger order_items_guard before insert or update or delete on public.order_items
  for each row execute function public.guard_order_items();

alter table public.notes
  add constraint notes_order_fk foreign key (order_id) references public.orders (id) on delete restrict;

-- ---------------------------------------------------------------------------
-- Payment notification log (idempotency + audit)
-- ---------------------------------------------------------------------------
create table public.payment_notifications (
  id bigint generated always as identity primary key,
  dedupe_key text not null unique,
  order_ref text not null,
  transaction_id text,
  transaction_status text not null,
  fraud_status text,
  status_code text,
  gross_amount text,
  payment_type text,
  result text,
  raw jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now(),
  processed_at timestamptz
);

-- ---------------------------------------------------------------------------
-- Donations
-- ---------------------------------------------------------------------------
create table public.donations (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders (id) on delete restrict,
  user_id uuid references auth.users (id) on delete set null,
  amount bigint not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending','succeeded','failed','refunded')),
  created_at timestamptz not null default now(),
  succeeded_at timestamptz
);

-- ---------------------------------------------------------------------------
-- Referrals and credits
-- ---------------------------------------------------------------------------
create table public.referral_codes (
  user_id uuid primary key references auth.users (id) on delete cascade,
  code text not null unique check (code ~ '^[A-Z2-9]{8}$'),
  created_at timestamptz not null default now()
);

create table public.referral_attributions (
  referred_user_id uuid primary key references auth.users (id) on delete cascade,
  referrer_id uuid references auth.users (id) on delete set null,
  code text not null,
  status text not null default 'pending_verification'
    check (status in ('pending_verification','qualified','rejected')),
  reject_reason text,
  created_at timestamptz not null default now(),
  qualified_at timestamptz
);

create or replace function public.guard_referral_attribution() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.referred_user_id <> old.referred_user_id
     or (new.referrer_id is distinct from old.referrer_id and new.referrer_id is not null)
     or new.code <> old.code then
    perform public.app_error('CSW09', 'ATTRIBUTION_IMMUTABLE', 'Referral attribution cannot be reassigned.');
  end if;
  if old.status = 'qualified' and new.status <> 'qualified' then
    perform public.app_error('CSW09', 'ATTRIBUTION_IMMUTABLE', 'Qualified referrals cannot change status.');
  end if;
  return new;
end $$;
create trigger referral_attributions_guard before update on public.referral_attributions
  for each row execute function public.guard_referral_attribution();

create table public.credits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  source text not null check (source in ('referral')),
  source_ref uuid not null,
  value bigint not null check (value = 5000),
  status text not null default 'available' check (status in ('available','reserved','redeemed','revoked')),
  reserved_order_id uuid references public.orders (id) on delete set null,
  redeemed_order_id uuid references public.orders (id) on delete set null,
  created_at timestamptz not null default now(),
  reserved_at timestamptz,
  redeemed_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid,
  revoked_reason text,
  unique (source, source_ref),
  check (status <> 'reserved' or reserved_order_id is not null),
  check (status <> 'redeemed' or redeemed_order_id is not null)
);
create unique index credits_one_per_order on public.credits (reserved_order_id) where status = 'reserved';
create unique index credits_one_redeemed_per_order on public.credits (redeemed_order_id) where status = 'redeemed';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
-- Parse a whole-rupiah amount supplied as a decimal string. Rejects signs,
-- decimals, exponents and whitespace. Values above BIGINT are rejected with a
-- clear storage-limit error; nothing is ever rounded or capped.
create or replace function public.parse_amount(p_amount text) returns bigint
language plpgsql immutable set search_path = '' as $$
begin
  if p_amount is null or p_amount !~ '^[0-9]{1,30}$' then
    perform public.app_error('CSW40', 'INVALID_AMOUNT', 'Enter a whole rupiah amount using digits only.');
  end if;
  if p_amount::numeric > 9223372036854775807 then
    perform public.app_error('CSW40', 'AMOUNT_EXCEEDS_STORAGE_LIMIT',
      'This amount is larger than the system can store safely.');
  end if;
  return p_amount::bigint;
end $$;

create or replace function public.new_order_ref(p_kind text) returns text
language sql volatile set search_path = '' as $$
  select 'CSW-' || upper(left(p_kind, 1)) || '-' || to_char(now() at time zone 'UTC', 'YYMMDDHH24MISS')
         || '-' || left(replace(gen_random_uuid()::text, '-', ''), 12)
$$;

create or replace function public.has_control_chars(p text) returns boolean
language sql immutable set search_path = '' as $$
  select p ~ '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]'
$$;

create or replace function public.order_summary(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  return (select jsonb_build_object(
    'order_ref', o.order_ref,
    'kind', o.kind,
    'status', o.status,
    'currency', o.currency,
    'publication_amount', o.publication_amount::text,
    'decorations_amount', o.decorations_amount::text,
    'subtotal_amount', o.subtotal_amount::text,
    'discount_amount', o.discount_amount::text,
    'total_amount', o.total_amount::text,
    'refunded_amount', o.refunded_amount::text,
    'created_at', o.created_at,
    'paid_at', o.paid_at,
    'expires_at', o.expires_at,
    'payment_started', o.payment_session_token is not null,
    'payment_redirect_url', o.payment_redirect_url,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'type', i.item_type, 'ref', i.item_ref, 'name', i.name,
        'unit_amount', i.unit_amount::text, 'quantity', i.quantity) order by i.id)
      from public.order_items i where i.order_id = o.id), '[]'::jsonb),
    'payment_methods', case when o.status = 'awaiting_payment'
                            then public.eligible_payment_methods(o.total_amount) else '[]'::jsonb end,
    'note', (select jsonb_build_object('id', n.id, 'status', n.status, 'author_name', n.author_name,
               'body', n.body, 'color', n.color, 'published_at', n.published_at)
             from public.notes n where n.order_id = o.id),
    'donation', (select jsonb_build_object('status', d.status) from public.donations d where d.order_id = o.id),
    'campaign', (select jsonb_build_object('id', c.id, 'status', c.status, 'title', c.title)
                 from public.campaigns c where c.order_id = o.id)
  )
  from public.orders o where o.id = p_order_id);
end $$;

-- Publish (or queue for moderation) the note attached to an order.
create or replace function public.release_note_for_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_mode text := coalesce(public.config_value('note_moderation') #>> '{}', 'post');
begin
  update public.notes
     set status = case when v_mode = 'pre' then 'pending_moderation' else 'published' end,
         published_at = case when v_mode = 'pre' then null else now() end
   where order_id = p_order_id and status = 'awaiting_payment';
end $$;

create or replace function public.consume_order_credit(p_order_id uuid) returns void
language sql security definer set search_path = '' as $$
  update public.credits
     set status = 'redeemed', redeemed_order_id = p_order_id, redeemed_at = now(), reserved_order_id = null
   where reserved_order_id = p_order_id and status = 'reserved';
$$;

create or replace function public.release_order_credit(p_order_id uuid) returns void
language sql security definer set search_path = '' as $$
  update public.credits
     set status = 'available', reserved_order_id = null, reserved_at = null
   where reserved_order_id = p_order_id and status = 'reserved';
$$;

-- Fulfil an order exactly once (paid via Midtrans or completed free).
create or replace function public.fulfill_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order.fulfilled_at is not null then
    return;
  end if;
  update public.orders set fulfilled_at = now() where id = p_order_id;
  if v_order.kind = 'publication' then
    perform public.consume_order_credit(p_order_id);
    perform public.release_note_for_order(p_order_id);
  elsif v_order.kind = 'donation' then
    update public.donations set status = 'succeeded', succeeded_at = now()
     where order_id = p_order_id and status = 'pending';
  elsif v_order.kind = 'advertising' then
    -- Paid campaigns still require admin approval before going live.
    update public.campaigns set status = 'pending_review'
     where order_id = p_order_id and status = 'awaiting_payment';
  end if;
end $$;

-- Undo reservations for an order that will never be paid.
create or replace function public.abandon_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.release_order_credit(p_order_id);
  update public.notes set status = 'payment_failed' where order_id = p_order_id and status = 'awaiting_payment';
  update public.donations set status = 'failed' where order_id = p_order_id and status = 'pending';
  update public.campaigns set status = 'draft', order_id = null
   where order_id = p_order_id and status = 'awaiting_payment';
end $$;

-- Reverse fulfilment effects after a full refund or chargeback.
create or replace function public.reverse_order_effects(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.notes set status = 'refunded'
   where order_id = p_order_id and status in ('published','pending_moderation','awaiting_payment');
  update public.donations set status = 'refunded' where order_id = p_order_id;
  update public.campaigns set status = 'canceled' where order_id = p_order_id;
end $$;

-- Attach one available credit to an unpaid publication order.
create or replace function public.attach_credit(p_order_id uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_credit uuid; v_discount bigint;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order.kind <> 'publication' or v_order.user_id is distinct from p_user or p_user is null then
    perform public.app_error('CSW03', 'CREDIT_NOT_ALLOWED', 'Credits can only be used on your own note orders.');
  end if;
  if v_order.discount_amount > 0 then
    perform public.app_error('CSW09', 'CREDIT_ALREADY_APPLIED', 'A credit is already applied to this order.');
  end if;
  select id into v_credit from public.credits
   where user_id = p_user and status = 'available'
   order by created_at
   limit 1
   for update skip locked;
  if v_credit is null then
    perform public.app_error('CSW09', 'NO_CREDIT_AVAILABLE', 'You have no available free-publication credit.');
  end if;
  update public.credits set status = 'reserved', reserved_order_id = p_order_id, reserved_at = now()
   where id = v_credit;
  v_discount := least(public.referral_credit_value(), v_order.publication_amount);
  insert into public.order_items (order_id, item_type, item_ref, name, unit_amount)
  values (p_order_id, 'credit', v_credit::text, 'Referral credit', -v_discount);
  update public.orders
     set discount_amount = v_discount,
         total_amount = subtotal_amount - v_discount,
         snapshot = snapshot || jsonb_build_object('credit_discount', v_discount::text,
                                                   'total_amount', (subtotal_amount - v_discount)::text)
   where id = p_order_id;
end $$;

create or replace function public.detach_credit(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.release_order_credit(p_order_id);
  delete from public.order_items where order_id = p_order_id and item_type = 'credit';
  update public.orders
     set discount_amount = 0, total_amount = subtotal_amount,
         snapshot = snapshot || jsonb_build_object('credit_discount', '0', 'total_amount', subtotal_amount::text)
   where id = p_order_id;
end $$;

-- Complete a zero-total order without any payment transaction.
create or replace function public.complete_free_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.orders set status = 'completed_free', closed_at = now()
   where id = p_order_id and status = 'awaiting_payment' and total_amount = 0;
  if found then
    perform public.fulfill_order(p_order_id);
  end if;
end $$;

create or replace function public.require_payable_total(p_total bigint) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_total > 0 and jsonb_array_length(public.eligible_payment_methods(p_total)) = 0 then
    perform public.app_error('CSW40', 'NO_ELIGIBLE_PAYMENT_METHOD',
      'No enabled payment method can process this total. Choose a different amount or contact us; the amount was not changed.');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Publication pricing
-- ---------------------------------------------------------------------------
-- Read-only quote (safe for anyone). Amount is a decimal string.
create or replace function public.quote_publication(p_amount text, p_decorations text[] default '{}',
  p_use_credit boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_amount bigint := public.parse_amount(p_amount);
  v_decos text[] := coalesce(p_decorations, '{}');
  v_deco_total bigint; v_deco_count int; v_discount bigint := 0; v_subtotal bigint; v_total bigint;
  v_lines jsonb;
begin
  if v_amount < public.min_publication_price() then
    perform public.app_error('CSW40', 'PRICE_BELOW_MINIMUM', 'The minimum publication price is Rp5.000.');
  end if;
  if cardinality(v_decos) <> (select count(distinct d) from unnest(v_decos) d) then
    perform public.app_error('CSW40', 'DUPLICATE_DECORATION', 'Each decoration can be selected once.');
  end if;
  select coalesce(sum(price), 0), count(*),
         coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'price', price::text) order by sort_order), '[]')
    into v_deco_total, v_deco_count, v_lines
    from public.decorations where id = any (v_decos) and enabled;
  if v_deco_count <> cardinality(v_decos) then
    perform public.app_error('CSW40', 'INVALID_DECORATION', 'A selected decoration is not available.');
  end if;
  begin
    v_subtotal := v_amount + v_deco_total;
  exception when numeric_value_out_of_range then
    perform public.app_error('CSW40', 'AMOUNT_EXCEEDS_STORAGE_LIMIT', 'This total is larger than the system can store safely.');
  end;
  if p_use_credit then
    v_discount := least(public.referral_credit_value(), v_amount);
  end if;
  v_total := v_subtotal - v_discount;
  return jsonb_build_object(
    'publication_amount', v_amount::text,
    'decorations', v_lines,
    'decorations_amount', v_deco_total::text,
    'subtotal_amount', v_subtotal::text,
    'credit_discount', v_discount::text,
    'total_amount', v_total::text,
    'payment_required', v_total > 0,
    'payment_methods', public.eligible_payment_methods(v_total));
end $$;

-- Create a pending publication order + note. Service role only.
create or replace function public.create_publication_order(
  p_user_id uuid,
  p_author_name text,
  p_body text,
  p_color text,
  p_social_link text,
  p_show_amount boolean,
  p_amount text,
  p_decorations text[],
  p_use_credit boolean,
  p_guest_token_hash text,
  p_campus_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_quote jsonb;
  v_order_id uuid;
  v_note_id uuid;
  v_ttl int := coalesce((public.config_value('unpaid_order_ttl_minutes') #>> '{}')::int, 120);
  v_name text := btrim(coalesce(p_author_name, ''));
  v_body text := btrim(coalesce(p_body, ''));
  v_link text := nullif(btrim(coalesce(p_social_link, '')), '');
  r record;
begin
  if p_user_id is not null and public.is_suspended(p_user_id) then
    perform public.app_error('CSW03', 'ACCOUNT_SUSPENDED', 'This account is suspended.');
  end if;
  if p_use_credit and p_user_id is null then
    perform public.app_error('CSW03', 'CREDIT_REQUIRES_ACCOUNT', 'Sign in to use a referral credit.');
  end if;
  if char_length(v_name) not between 1 and 40 or public.has_control_chars(v_name) or v_name ~ '[\n\r\t]' then
    perform public.app_error('CSW40', 'INVALID_AUTHOR_NAME', 'Author name must be 1-40 characters.');
  end if;
  if char_length(v_body) not between 1 and 500 or public.has_control_chars(v_body) then
    perform public.app_error('CSW40', 'INVALID_NOTE_TEXT', 'Note text must be 1-500 characters.');
  end if;
  if coalesce(p_color, '') not in ('yellow','pink','blue','green','orange','purple') then
    perform public.app_error('CSW40', 'INVALID_COLOR', 'Choose one of the available note colours.');
  end if;
  if v_link is not null and not public.is_allowed_social_url(v_link) then
    perform public.app_error('CSW40', 'INVALID_SOCIAL_LINK', 'Social links must be https URLs on supported platforms.');
  end if;
  if p_guest_token_hash is null or p_guest_token_hash !~ '^[0-9a-f]{64}$' then
    perform public.app_error('CSW40', 'INVALID_ACCESS_TOKEN');
  end if;
  if p_campus_id is not null and not exists (select 1 from public.campuses c where c.id = p_campus_id and c.enabled) then
    perform public.app_error('CSW40', 'INVALID_CAMPUS', 'Unknown campus.');
  end if;

  v_quote := public.quote_publication(p_amount, coalesce(p_decorations, '{}'), false);

  insert into public.orders (order_ref, kind, user_id, publication_amount, decorations_amount,
                             subtotal_amount, discount_amount, total_amount, snapshot, guest_token_hash, expires_at)
  values (public.new_order_ref('publication'), 'publication', p_user_id,
          (v_quote->>'publication_amount')::bigint, (v_quote->>'decorations_amount')::bigint,
          (v_quote->>'subtotal_amount')::bigint, 0, (v_quote->>'subtotal_amount')::bigint,
          jsonb_build_object('min_publication_price', public.min_publication_price()::text,
                             'publication_amount', v_quote->>'publication_amount',
                             'decorations', v_quote->'decorations',
                             'decorations_amount', v_quote->>'decorations_amount',
                             'credit_discount', '0',
                             'total_amount', v_quote->>'subtotal_amount',
                             'priced_at', now()),
          p_guest_token_hash, now() + make_interval(mins => v_ttl))
  returning id into v_order_id;

  insert into public.order_items (order_id, item_type, item_ref, name, unit_amount)
  values (v_order_id, 'publication', null, 'Sticky note publication', (v_quote->>'publication_amount')::bigint);
  for r in select * from jsonb_to_recordset(v_quote->'decorations') as x(id text, name text, price text) loop
    insert into public.order_items (order_id, item_type, item_ref, name, unit_amount)
    values (v_order_id, 'decoration', r.id, left(r.name, 50), r.price::bigint);
  end loop;

  insert into public.notes (order_id, author_id, author_name, body, color, social_link, show_amount,
                            publication_amount, campus_id)
  values (v_order_id, p_user_id, v_name, v_body, p_color, v_link, coalesce(p_show_amount, true),
          (v_quote->>'publication_amount')::bigint, p_campus_id)
  returning id into v_note_id;
  insert into public.note_decorations (note_id, decoration_id)
  select v_note_id, unnest(coalesce(p_decorations, '{}'));

  if p_use_credit then
    perform public.attach_credit(v_order_id, p_user_id);
  end if;

  if (select total_amount from public.orders where id = v_order_id) = 0 then
    perform public.complete_free_order(v_order_id);
  else
    perform public.require_payable_total((select total_amount from public.orders where id = v_order_id));
  end if;

  return public.order_summary(v_order_id);
end $$;

-- Apply or remove a referral credit on an unpaid order. Service role only.
create or replace function public.set_order_credit(p_order_ref text, p_user_id uuid, p_apply boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  select * into v_order from public.orders where order_ref = p_order_ref for update;
  if not found or p_user_id is null or v_order.user_id is distinct from p_user_id then
    perform public.app_error('CSW04', 'NOT_FOUND', 'Order not found.');
  end if;
  if v_order.kind <> 'publication' then
    perform public.app_error('CSW40', 'CREDIT_NOT_ALLOWED', 'Credits apply to sticky-note publications only.');
  end if;
  if v_order.status <> 'awaiting_payment' or v_order.payment_locked_at is not null then
    perform public.app_error('CSW09', 'ORDER_LOCKED', 'Payment has started; the order can no longer change.');
  end if;
  if p_apply then
    perform public.attach_credit(v_order.id, p_user_id);
  elsif v_order.discount_amount > 0 then
    perform public.detach_credit(v_order.id);
  end if;
  select * into v_order from public.orders where id = v_order.id;
  if v_order.total_amount = 0 then
    perform public.complete_free_order(v_order.id);
  else
    perform public.require_payable_total(v_order.total_amount);
  end if;
  return public.order_summary(v_order.id);
end $$;

-- ---------------------------------------------------------------------------
-- Donations
-- ---------------------------------------------------------------------------
create or replace function public.create_donation_order(p_user_id uuid, p_amount text, p_guest_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_amount bigint := public.parse_amount(p_amount);
  v_min bigint := coalesce((public.config_value('donation_min_amount') #>> '{}')::bigint, 1000);
  v_max bigint := (public.config_value('donation_max_amount') #>> '{}')::bigint;
  v_order_id uuid;
begin
  if p_user_id is not null and public.is_suspended(p_user_id) then
    perform public.app_error('CSW03', 'ACCOUNT_SUSPENDED', 'This account is suspended.');
  end if;
  if p_guest_token_hash is null or p_guest_token_hash !~ '^[0-9a-f]{64}$' then
    perform public.app_error('CSW40', 'INVALID_ACCESS_TOKEN');
  end if;
  if v_amount < v_min or (v_max is not null and v_amount > v_max) then
    perform public.app_error('CSW40', 'DONATION_OUT_OF_RANGE',
      format('Donations must be between Rp%s and Rp%s.', v_min, coalesce(v_max::text, '∞')));
  end if;
  perform public.require_payable_total(v_amount);
  insert into public.orders (order_ref, kind, user_id, subtotal_amount, total_amount, snapshot, guest_token_hash, expires_at)
  values (public.new_order_ref('donation'), 'donation', p_user_id, v_amount, v_amount,
          jsonb_build_object('donation_amount', v_amount::text, 'priced_at', now()),
          p_guest_token_hash,
          now() + make_interval(mins => coalesce((public.config_value('unpaid_order_ttl_minutes') #>> '{}')::int, 120)))
  returning id into v_order_id;
  insert into public.order_items (order_id, item_type, name, unit_amount)
  values (v_order_id, 'donation', 'Voluntary donation', v_amount);
  insert into public.donations (order_id, user_id, amount) values (v_order_id, p_user_id, v_amount);
  return public.order_summary(v_order_id);
end $$;

-- ---------------------------------------------------------------------------
-- Payment session lifecycle (called by create-payment)
-- ---------------------------------------------------------------------------
create or replace function public.order_access_ok(p_order public.orders, p_user_id uuid, p_token_hash text)
returns boolean language sql stable set search_path = '' as $$
  select (p_user_id is not null and p_order.user_id = p_user_id)
      or (p_token_hash is not null and p_order.guest_token_hash = p_token_hash)
$$;

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
  if v_order.payment_session_token is not null then
    return jsonb_build_object('reused', true, 'order_ref', v_order.order_ref,
      'token', v_order.payment_session_token, 'redirect_url', v_order.payment_redirect_url);
  end if;
  if v_order.expires_at is not null and v_order.expires_at < now() then
    perform public.app_error('CSW09', 'ORDER_EXPIRED', 'This order expired. Please create it again.');
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

create or replace function public.record_payment_session(p_order_ref text, p_token text, p_redirect_url text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_token is null or p_redirect_url !~ '^https://' then
    perform public.app_error('CSW40', 'INVALID_PAYMENT_SESSION');
  end if;
  update public.orders
     set payment_session_token = p_token, payment_redirect_url = p_redirect_url,
         expires_at = now() + interval '25 hours'
   where order_ref = p_order_ref and payment_locked_at is not null and payment_session_token is null;
  if not found then
    perform public.app_error('CSW09', 'PAYMENT_SESSION_CONFLICT');
  end if;
end $$;

create or replace function public.release_payment_lock(p_order_ref text) returns void
language sql security definer set search_path = '' as $$
  update public.orders set payment_locked_at = null
   where order_ref = p_order_ref and payment_session_token is null and status = 'awaiting_payment';
$$;

-- ---------------------------------------------------------------------------
-- Payment notification state machine (called by midtrans-webhook only after
-- the signature AND the Midtrans Get Status API have been verified).
-- ---------------------------------------------------------------------------
create or replace function public.parse_gateway_amount(p text) returns bigint
language plpgsql immutable set search_path = '' as $$
begin
  if p is null or p !~ '^[0-9]{1,19}(\.0{1,2})?$' then
    return null;
  end if;
  return split_part(p, '.', 1)::numeric::bigint;
exception when others then
  return null;
end $$;

create or replace function public.apply_payment_notification(
  p_order_ref text,
  p_transaction_id text,
  p_transaction_status text,
  p_fraud_status text,
  p_status_code text,
  p_gross_amount text,
  p_currency text,
  p_payment_type text,
  p_refund_amount text,
  p_raw jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_tx text := lower(coalesce(p_transaction_status, ''));
  v_fraud text := lower(coalesce(p_fraud_status, ''));
  v_key text;
  v_note_id bigint;
  v_order public.orders;
  v_target text;
  v_gross bigint := public.parse_gateway_amount(p_gross_amount);
  v_refund bigint := public.parse_gateway_amount(p_refund_amount);
  v_result text;
begin
  v_key := concat_ws('|', p_order_ref, v_tx, v_fraud, coalesce(p_status_code, ''),
                     coalesce(p_transaction_id, ''), coalesce(p_gross_amount, ''), coalesce(p_refund_amount, ''));
  insert into public.payment_notifications (dedupe_key, order_ref, transaction_id, transaction_status, fraud_status,
                                            status_code, gross_amount, payment_type, raw)
  values (v_key, p_order_ref, p_transaction_id, v_tx, v_fraud, p_status_code, p_gross_amount, p_payment_type,
          coalesce(p_raw, '{}'::jsonb))
  on conflict (dedupe_key) do nothing
  returning id into v_note_id;
  if v_note_id is null then
    return jsonb_build_object('result', 'duplicate');
  end if;

  select * into v_order from public.orders where order_ref = p_order_ref for update;
  if not found then
    v_result := 'unknown_order';
  elsif v_gross is null or v_gross <> v_order.total_amount
        or (p_currency is not null and upper(p_currency) <> v_order.currency) then
    update public.orders set review_required = true, review_reason = 'amount_or_currency_mismatch'
     where id = v_order.id;
    v_result := 'amount_mismatch';
  else
    -- Map the gateway status to our target status.
    v_target := case
      when v_fraud = 'deny' then 'failed'
      when v_tx = 'settlement' then 'paid'
      when v_tx = 'capture' and v_fraud = 'accept' then 'paid'
      when v_tx = 'capture' and v_fraud = 'challenge' then 'challenge'
      when v_tx in ('pending','authorize') then 'awaiting_payment'
      when v_tx in ('deny','failure') then 'failed'
      when v_tx = 'cancel' then 'canceled'
      when v_tx = 'expire' then 'expired'
      when v_tx = 'refund' then 'refunded'
      when v_tx = 'partial_refund' then 'partially_refunded'
      when v_tx in ('chargeback','partial_chargeback') then 'reversed'
      else null end;

    if v_target is null then
      v_result := 'unrecognized_status';
    elsif v_target = v_order.status and v_target <> 'partially_refunded' then
      v_result := 'no_change';
    elsif v_order.status in ('awaiting_payment','challenge') then
      if v_target = 'paid' then
        update public.orders set status = 'paid', paid_at = now(), payment_type = p_payment_type,
               midtrans_transaction_id = p_transaction_id where id = v_order.id;
        perform public.fulfill_order(v_order.id);
        v_result := 'paid';
      elsif v_target = 'challenge' then
        update public.orders set status = 'challenge', review_required = true, review_reason = 'fraud_challenge'
         where id = v_order.id;
        v_result := 'challenge';
      elsif v_target in ('failed','canceled','expired') then
        update public.orders set status = v_target, closed_at = now() where id = v_order.id;
        perform public.abandon_order(v_order.id);
        v_result := v_target;
      elsif v_target = 'awaiting_payment' then
        v_result := 'still_pending';
      else
        -- refund/chargeback before any success: inconsistent, needs a human.
        update public.orders set review_required = true, review_reason = 'refund_before_payment' where id = v_order.id;
        v_result := 'needs_review';
      end if;
    elsif v_order.status in ('paid','partially_refunded') then
      if v_target = 'refunded' then
        update public.orders set status = 'refunded', refunded_amount = total_amount, closed_at = now()
         where id = v_order.id;
        perform public.reverse_order_effects(v_order.id);
        v_result := 'refunded';
      elsif v_target = 'partially_refunded' then
        if v_refund is null or v_refund > v_order.total_amount then
          update public.orders set status = 'partially_refunded', review_required = true,
                 review_reason = 'partial_refund_amount_unknown' where id = v_order.id;
        else
          update public.orders set status = 'partially_refunded',
                 refunded_amount = greatest(refunded_amount, v_refund) where id = v_order.id;
        end if;
        v_result := 'partially_refunded';
      elsif v_target = 'reversed' then
        update public.orders set status = 'reversed', refunded_amount = total_amount, closed_at = now()
         where id = v_order.id;
        perform public.reverse_order_effects(v_order.id);
        v_result := 'reversed';
      else
        -- e.g. a late 'pending' or 'expire' after success: never regress.
        v_result := 'ignored_regression';
      end if;
    elsif v_order.status in ('failed','canceled','expired') and v_target = 'paid' then
      -- Money arrived for an order we already closed. Never auto-fulfil;
      -- flag for reconciliation (refund or manual fulfilment).
      update public.orders set review_required = true, review_reason = 'payment_after_close',
             midtrans_transaction_id = p_transaction_id where id = v_order.id;
      v_result := 'needs_review';
    else
      v_result := 'ignored_terminal';
    end if;
  end if;

  update public.payment_notifications set result = v_result, processed_at = now() where id = v_note_id;
  return jsonb_build_object('result', v_result);
end $$;

-- ---------------------------------------------------------------------------
-- Receipts and guest self-service (called by manage-guest-publication)
-- ---------------------------------------------------------------------------
create or replace function public.get_order_receipt(p_order_ref text, p_user_id uuid, p_token_hash text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_order public.orders;
begin
  select * into v_order from public.orders where order_ref = p_order_ref;
  if not found or not public.order_access_ok(v_order, p_user_id, p_token_hash) then
    perform public.app_error('CSW04', 'NOT_FOUND', 'Receipt not found.');
  end if;
  return public.order_summary(v_order.id);
end $$;

create or replace function public.withdraw_own_note(p_order_ref text, p_user_id uuid, p_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  select * into v_order from public.orders where order_ref = p_order_ref;
  if not found or not public.order_access_ok(v_order, p_user_id, p_token_hash) or v_order.kind <> 'publication' then
    perform public.app_error('CSW04', 'NOT_FOUND', 'Receipt not found.');
  end if;
  update public.notes set status = 'withdrawn'
   where order_id = v_order.id and status in ('published','pending_moderation');
  if not found then
    perform public.app_error('CSW09', 'NOTE_NOT_WITHDRAWABLE', 'This note is not currently visible.');
  end if;
  return public.order_summary(v_order.id);
end $$;

-- ---------------------------------------------------------------------------
-- Referral lifecycle (driven by auth.users triggers)
-- ---------------------------------------------------------------------------
create or replace function public.normalize_email(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare v_local text; v_domain text;
begin
  if p is null or position('@' in p) = 0 then return lower(p); end if;
  v_local := lower(split_part(p, '@', 1));
  v_domain := lower(split_part(p, '@', 2));
  v_local := split_part(v_local, '+', 1);
  if v_domain in ('gmail.com', 'googlemail.com') then
    v_local := replace(v_local, '.', '');
    v_domain := 'gmail.com';
  end if;
  return v_local || '@' || v_domain;
end $$;

create or replace function public.generate_referral_code() returns text
language plpgsql volatile set search_path = '' as $$
declare
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea := uuid_send(gen_random_uuid());
  v_code text := '';
begin
  for i in 0..7 loop
    v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) % 32) + 1, 1);
  end loop;
  return v_code;
end $$;

create or replace function public.qualify_referral(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.referral_attributions
     set status = 'qualified', qualified_at = now()
   where referred_user_id = p_user and status = 'pending_verification';
  if found then
    insert into public.credits (user_id, source, source_ref, value)
    values (p_user, 'referral', p_user, public.referral_credit_value())
    on conflict (source, source_ref) do nothing;
  end if;
end $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := btrim(coalesce(new.raw_user_meta_data ->> 'display_name', ''));
  v_ref text := upper(btrim(coalesce(new.raw_user_meta_data ->> 'referral_code', '')));
  v_referrer uuid;
  v_referrer_email text;
begin
  if char_length(v_name) not between 2 and 40 or public.has_control_chars(v_name) then
    v_name := left(coalesce(nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'Student'), 40);
    if char_length(v_name) < 2 then v_name := 'Student'; end if;
  end if;
  insert into public.profiles (id, display_name) values (new.id, v_name) on conflict (id) do nothing;

  loop
    begin
      insert into public.referral_codes (user_id, code) values (new.id, public.generate_referral_code());
      exit;
    exception when unique_violation then
      if exists (select 1 from public.referral_codes where user_id = new.id) then exit; end if;
    end;
  end loop;

  if v_ref ~ '^[A-Z2-9]{8}$' then
    select rc.user_id, u.email into v_referrer, v_referrer_email
      from public.referral_codes rc join auth.users u on u.id = rc.user_id
     where rc.code = v_ref;
    if v_referrer is not null and v_referrer <> new.id then
      if public.normalize_email(v_referrer_email) = public.normalize_email(new.email) then
        insert into public.referral_attributions (referred_user_id, referrer_id, code, status, reject_reason)
        values (new.id, v_referrer, v_ref, 'rejected', 'self_referral');
      elsif public.is_suspended(v_referrer) then
        insert into public.referral_attributions (referred_user_id, referrer_id, code, status, reject_reason)
        values (new.id, v_referrer, v_ref, 'rejected', 'referrer_suspended');
      else
        insert into public.referral_attributions (referred_user_id, referrer_id, code)
        values (new.id, v_referrer, v_ref);
        if new.email_confirmed_at is not null then
          perform public.qualify_referral(new.id);
        end if;
      end if;
    end if;
  end if;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.handle_user_confirmed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null then
    perform public.qualify_referral(new.id);
  end if;
  return new;
end $$;

create trigger on_auth_user_confirmed after update of email_confirmed_at on auth.users
  for each row execute function public.handle_user_confirmed();

-- ---------------------------------------------------------------------------
-- RLS for tables in this migration
-- ---------------------------------------------------------------------------
alter table public.payment_methods enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payment_notifications enable row level security;
alter table public.donations enable row level security;
alter table public.referral_codes enable row level security;
alter table public.referral_attributions enable row level security;
alter table public.credits enable row level security;

revoke all on public.payment_methods, public.orders, public.order_items, public.payment_notifications,
  public.donations, public.referral_codes, public.referral_attributions, public.credits
  from anon, authenticated;

grant select on public.payment_methods to anon, authenticated;
grant select (id, order_ref, kind, status, currency, publication_amount, decorations_amount, subtotal_amount,
              discount_amount, total_amount, refunded_amount, created_at, paid_at, expires_at, payment_type)
  on public.orders to authenticated;
grant select on public.order_items to authenticated;
grant select (id, order_id, amount, status, created_at, succeeded_at) on public.donations to authenticated;
grant select on public.referral_codes to authenticated;
grant select (referrer_id, status, reject_reason, created_at, qualified_at) on public.referral_attributions to authenticated;
grant select (id, user_id, value, status, created_at, reserved_at, redeemed_at, revoked_at) on public.credits to authenticated;

create policy payment_methods_read on public.payment_methods for select to anon, authenticated using (enabled);
create policy orders_select_own on public.orders for select to authenticated using (user_id = (select auth.uid()));
create or replace function public.order_owned_by(p_order uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user is not null and exists (select 1 from public.orders o where o.id = p_order and o.user_id = p_user)
$$;
create policy order_items_select_own on public.order_items for select to authenticated using (
  public.order_owned_by(order_id, (select auth.uid())));
create policy donations_select_own on public.donations for select to authenticated using (user_id = (select auth.uid()));
create policy referral_codes_select_own on public.referral_codes for select to authenticated using (user_id = (select auth.uid()));
create policy referral_attributions_select on public.referral_attributions for select to authenticated using (
  referrer_id = (select auth.uid()) or referred_user_id = (select auth.uid()));
create policy credits_select_own on public.credits for select to authenticated using (user_id = (select auth.uid()));
