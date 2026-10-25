-- 012_paid_posting_v2.sql
-- Lower minimum price (Rp5.000 -> Rp2.500, config-driven), server max + confirm threshold,
-- random order refs, free weekly post, promo codes, author-name rules, and an
-- anonymity pass: after payment no table links an account to a note.
-- Additive and safe to re-run. Apply after 011.
--
-- WHAT IS NOW UNLINKED (see docs/PRIVACY_POSTING.md):
--   notes.author_id        never stored (set null at creation)
--   orders.user_id         set null when a publication order is fulfilled
--   *credits.redeemed_*    set null at fulfilment
--   promo_redemptions / free_post_claims   hold user_id + hour-rounded time, order_id only while pending
--   storage.objects.owner  cleared for the note's media at fulfilment
-- COST: no per-account note counts (Notes leaderboard empties), no "my notes" list,
--       self-voting cannot be blocked, referral qualification uses the paid/free order instead of the published note.

-- ---------------------------------------------------------------------------
-- 1. Pricing config: ONE place (site_config). Frontend reads the public rows.
-- ---------------------------------------------------------------------------
insert into public.site_config (key, value, is_public, description) values
  ('min_publication_price', '2500',    true, 'Minimum publication price in rupiah (promo discounts apply to this part only)'),
  ('max_publication_price', '1000000', true, 'Server-side hard cap in rupiah, blocks typos and abuse'),
  ('price_presets',         '[2500,5000,10000]', true, 'Preset buttons on the compose page; the first one is preselected'),
  ('confirm_above_amount',  '100000',   true, 'Publication amounts above this need an explicit confirmation')
on conflict (key) do update set value = excluded.value, description = excluded.description
  where public.site_config.key = 'min_publication_price';  -- only the minimum is forced; other keys keep admin edits

-- Unpaid posts are deleted after 30 minutes.
update public.site_config set value = '30' where key = 'unpaid_order_ttl_minutes';

create or replace function public.min_publication_price() returns bigint
language sql stable security definer set search_path = '' as $$
  select coalesce((public.config_value('min_publication_price') #>> '{}')::bigint, 2500)
$$;

create or replace function public.max_publication_price() returns bigint
language sql stable security definer set search_path = '' as $$
  select coalesce((public.config_value('max_publication_price') #>> '{}')::bigint, 1000000)
$$;

-- The old CHECKs hard-coded 5000. The real minimum is now enforced by quote_publication() from config.
do $$ declare r record; begin
  for r in select conrelid::regclass as t, conname from pg_constraint
            where contype = 'c' and conrelid in ('public.notes'::regclass, 'public.orders'::regclass)
              and pg_get_constraintdef(oid) ~ 'publication_amount.*>=\s*5000' loop
    execute format('alter table %s drop constraint %I', r.t, r.conname);
  end loop;
end $$;
alter table public.notes  drop constraint if exists notes_amount_positive;
alter table public.orders drop constraint if exists orders_amount_positive;
alter table public.notes  add constraint notes_amount_positive  check (publication_amount >= 1);
alter table public.orders add constraint orders_amount_positive check (publication_amount is null or publication_amount >= 1);

-- Same body as 003, but min and max come from config.
create or replace function public.quote_publication(p_amount text, p_decorations text[] default '{}',
  p_use_credit boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_amount bigint := public.parse_amount(p_amount);
  v_min bigint := public.min_publication_price();
  v_max bigint := public.max_publication_price();
  v_decos text[] := coalesce(p_decorations, '{}');
  v_deco_total bigint; v_deco_count int; v_discount bigint := 0; v_subtotal bigint; v_total bigint;
  v_lines jsonb;
begin
  if v_amount < v_min then
    perform public.app_error('CSW40', 'PRICE_BELOW_MINIMUM', format('The minimum publication price is Rp%s.', v_min));
  end if;
  if v_amount > v_max then
    perform public.app_error('CSW40', 'PRICE_ABOVE_MAXIMUM', format('The maximum publication price is Rp%s.', v_max));
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
  v_subtotal := v_amount + v_deco_total;
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

-- Random order id (no timestamp, no user data). Goes to Midtrans as order_id (max 50 chars).
create or replace function public.new_order_ref(p_kind text) returns text
language sql volatile set search_path = '' as $$
  select 'CSW-' || upper(left(p_kind, 1)) || '-' ||
         replace(gen_random_uuid()::text, '-', '') || left(replace(gen_random_uuid()::text, '-', ''), 8)
$$;  -- 'CSW-P-' + 40 hex = 46 chars, matches ^[A-Za-z0-9_.~-]{8,50}$

-- Cheap methods only at tiny totals. Flat/min-amount rules: see docs/PRIVACY_POSTING.md section "Midtrans".
-- Midtrans minimums: card 10.000, BCA VA 10.000, Indomaret 10.000. VA flat fee ~Rp4.000 > Rp2.500 payment.
update public.payment_methods set min_amount = 20000
 where code in ('virtual_account', 'credit_card', 'convenience_store') and min_amount is null;

-- ---------------------------------------------------------------------------
-- 2. Free weekly post + promo codes (no post id anywhere; hour-rounded times)
-- ---------------------------------------------------------------------------
create table if not exists public.free_post_claims (
  user_id uuid not null references auth.users (id) on delete cascade,
  week_start date not null,                       -- Monday of the claim week, Asia/Jakarta
  order_id uuid references public.orders (id) on delete cascade,   -- only while the order is pending; nulled at fulfilment
  claimed_hour timestamptz not null default date_trunc('hour', now()),
  primary key (user_id, week_start)
);
create unique index if not exists free_post_claims_order_uq on public.free_post_claims (order_id) where order_id is not null;

create table if not exists public.promo_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9]{4,24}$'),
  kind text not null check (kind in ('percent', 'fixed')),   -- 100% off = percent 100
  value bigint not null check (value > 0),
  max_uses int check (max_uses is null or max_uses > 0),
  per_user_limit int not null default 1 check (per_user_limit > 0),
  uses int not null default 0 check (uses >= 0),
  expires_at timestamptz,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  check (kind <> 'percent' or value <= 100)
);

create table if not exists public.promo_redemptions (
  id bigint generated always as identity primary key,
  code_id uuid not null references public.promo_codes (id) on delete cascade,
  user_id uuid references auth.users (id) on delete cascade,
  order_id uuid references public.orders (id) on delete cascade,  -- only while pending; nulled at fulfilment
  redeemed_hour timestamptz not null default date_trunc('hour', now())
);
create index if not exists promo_redemptions_code_user_idx on public.promo_redemptions (code_id, user_id);
create unique index if not exists promo_redemptions_order_uq on public.promo_redemptions (order_id) where order_id is not null;

alter table public.free_post_claims enable row level security;
alter table public.promo_codes enable row level security;
alter table public.promo_redemptions enable row level security;
revoke all on public.free_post_claims, public.promo_codes, public.promo_redemptions from anon, authenticated;

create or replace function public.jakarta_week_start() returns date
language sql stable set search_path = '' as $$
  select date_trunc('week', now() at time zone 'Asia/Jakarta')::date   -- Postgres weeks start Monday 00:00
$$;

-- Form hint: "1 free post available". Own row only, through auth.uid().
create or replace function public.my_free_post_available() returns boolean
language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and not exists (
    select 1 from public.free_post_claims c where c.user_id = auth.uid() and c.week_start = public.jakarta_week_start())
$$;

-- ---------------------------------------------------------------------------
-- 3. Author-name rules: plain text, no impersonation
-- ---------------------------------------------------------------------------
-- Comparison key: NFKC, lowercase, leetspeak folded, only letters/digits left.
create or replace function public.name_key(p text) returns text
language sql immutable set search_path = '' as $$
  select regexp_replace(translate(lower(normalize(coalesce(p, ''), nfkc)), '013457@$', 'oieastas'), '[^[:alnum:]]', '', 'g')
$$;

create or replace function public.validate_author_name(p_name text) returns void
language plpgsql stable security definer set search_path = '' as $$
declare v text := btrim(coalesce(p_name, '')); k text;
begin
  if v ~ '[<>"`{}\\]' then
    perform public.app_error('CSW40', 'INVALID_AUTHOR_NAME', 'Names cannot contain < > " ` { } or backslashes.');
  end if;
  -- zero-width and bidi-control characters are used to fake other names
  if v ~ '[\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]' then
    perform public.app_error('CSW40', 'INVALID_AUTHOR_NAME', 'That name contains invisible characters.');
  end if;
  if v ~ '@' or v ~* '(https?:|www\.|[a-z0-9-]\.(com|id|net|org|co|me|io|xyz|ly|gl|link)\M)' then
    perform public.app_error('CSW40', 'INVALID_AUTHOR_NAME', 'Names cannot contain links or @handles.');
  end if;
  k := public.name_key(v);
  if k = '' then
    perform public.app_error('CSW40', 'INVALID_AUTHOR_NAME', 'Use letters or numbers in the name.');
  end if;
  if k in ('admin','administrator','moderator','mod','official','staff','support','team','owner')
     or k like '%campusstickywall%'
     or exists (select 1 from public.profiles p where public.name_key(p.display_name) = k) then
    perform public.app_error('CSW40', 'NAME_NOT_AVAILABLE',
      'That name belongs to a registered member or is reserved. Please pick another.');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Discounts: free weekly post and promo codes (minimum price only, tips never discounted)
-- ---------------------------------------------------------------------------
-- Read-only quote for the compose page (called by the rate-limited check-promo function).
create or replace function public.quote_post_discount(p_user_id uuid, p_amount text, p_decorations text[],
  p_code text, p_use_free boolean) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_q jsonb := public.quote_publication(p_amount, coalesce(p_decorations, '{}'), false);
  v_base bigint := least((v_q ->> 'publication_amount')::bigint, public.min_publication_price());
  v_p public.promo_codes; v_disc bigint := 0; v_label text;
begin
  if p_use_free then
    if p_user_id is null or exists (select 1 from public.free_post_claims where user_id = p_user_id and week_start = public.jakarta_week_start()) then
      perform public.app_error('CSW09', 'FREE_POST_USED', 'Your free post for this week is already used.');
    end if;
    v_disc := v_base; v_label := 'Free weekly post';
  elsif nullif(btrim(coalesce(p_code, '')), '') is not null then
    if p_user_id is null then perform public.app_error('CSW03', 'ACCOUNT_REQUIRED', 'Sign in to use a promo code.'); end if;
    select * into v_p from public.promo_codes where code = upper(btrim(p_code));
    if not found or not v_p.enabled or (v_p.expires_at is not null and v_p.expires_at <= now())
       or (v_p.max_uses is not null and v_p.uses >= v_p.max_uses)
       or (select count(*) from public.promo_redemptions r where r.code_id = v_p.id and r.user_id = p_user_id) >= v_p.per_user_limit then
      perform public.app_error('CSW40', 'PROMO_INVALID', 'This code is not valid.');
    end if;
    v_disc := case when v_p.kind = 'percent' then (v_base * v_p.value) / 100 else least(v_p.value, v_base) end;
    v_label := 'Promo ' || v_p.code;
  end if;
  return v_q || jsonb_build_object('discount', v_disc::text, 'discount_label', v_label,
    'total_amount', ((v_q ->> 'subtotal_amount')::bigint - v_disc)::text);
end $$;

-- Write path. Runs inside create_publication_order_v2's transaction.
create or replace function public.apply_post_discount(p_order_id uuid, p_user_id uuid, p_code text, p_use_free boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  o public.orders; v_base bigint; v_disc bigint; v_p public.promo_codes; v_label text; v_ref text;
begin
  select * into o from public.orders where id = p_order_id for update;
  v_base := least(o.publication_amount, public.min_publication_price());
  if p_use_free then
    insert into public.free_post_claims (user_id, week_start, order_id)
    values (p_user_id, public.jakarta_week_start(), p_order_id)
    on conflict (user_id, week_start) do nothing;
    if not found then
      perform public.app_error('CSW09', 'FREE_POST_USED', 'Your free post for this week is already used or in progress.');
    end if;
    v_disc := v_base; v_label := 'Free weekly post'; v_ref := 'free-week';
  else
    -- FOR UPDATE on the code row serialises every redemption of this code:
    -- the uses and per-user checks below cannot race.
    select * into v_p from public.promo_codes where code = upper(btrim(p_code)) for update;
    if not found or not v_p.enabled or (v_p.expires_at is not null and v_p.expires_at <= now())
       or (v_p.max_uses is not null and v_p.uses >= v_p.max_uses)
       or (select count(*) from public.promo_redemptions r where r.code_id = v_p.id and r.user_id = p_user_id) >= v_p.per_user_limit then
      perform public.app_error('CSW40', 'PROMO_INVALID', 'This code is not valid.');
    end if;
    v_disc := case when v_p.kind = 'percent' then (v_base * v_p.value) / 100 else least(v_p.value, v_base) end;
    if v_disc <= 0 then
      perform public.app_error('CSW40', 'PROMO_NO_DISCOUNT', 'This code gives no discount on this amount.');
    end if;
    update public.promo_codes set uses = uses + 1 where id = v_p.id;
    insert into public.promo_redemptions (code_id, user_id, order_id) values (v_p.id, p_user_id, p_order_id);
    v_label := left('Promo ' || v_p.code, 50); v_ref := 'promo';
  end if;
  insert into public.order_items (order_id, item_type, item_ref, name, unit_amount)
  values (p_order_id, 'credit', v_ref, v_label, -v_disc);
  update public.orders
     set discount_amount = discount_amount + v_disc,
         total_amount = subtotal_amount - (discount_amount + v_disc),
         snapshot = snapshot || jsonb_build_object('credit_discount', (discount_amount + v_disc)::text,
                                                   'total_amount', (subtotal_amount - discount_amount - v_disc)::text,
                                                   'discount_kind', v_ref)
   where id = p_order_id;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Order lifecycle: defer free completion, delete failed posts, burn links at fulfilment
-- ---------------------------------------------------------------------------
-- create_publication_order_v2 applies discounts AFTER the inner functions run; it sets
-- csw.defer_free so they do not complete a zero-total order too early.
create or replace function public.complete_free_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('csw.defer_free', true), '') = '1' then return; end if;
  update public.orders set status = 'completed_free', closed_at = now()
   where id = p_order_id and status = 'awaiting_payment' and total_amount = 0;
  if found then
    perform public.fulfill_order(p_order_id);
  end if;
end $$;

-- Old Rp5.000 credits required redeemed_order_id; that link must be removable.
do $$ declare r record; begin
  for r in select conname from pg_constraint
            where conrelid = 'public.credits'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ~ 'redeemed_order_id IS NOT NULL' loop
    execute format('alter table public.credits drop constraint %I', r.conname);
  end loop;
end $$;

-- Clear the storage owner of a note's files (best effort: column names differ by Supabase version).
create or replace function public.burn_media_owner(p_paths text[]) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_paths is null or cardinality(p_paths) = 0 or to_regclass('storage.objects') is null then return; end if;
  begin
    execute 'update storage.objects set owner_id = null where bucket_id = ''note-media'' and name = any($1)' using p_paths;
  exception when others then null; end;   -- ponytail: swallow, column may not exist on old Supabase
  begin
    execute 'update storage.objects set owner = null where bucket_id = ''note-media'' and name = any($1)' using p_paths;
  exception when others then null; end;
end $$;

create or replace function public.fulfill_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_paths text[];
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order.fulfilled_at is not null then
    return;
  end if;
  update public.orders set fulfilled_at = now() where id = p_order_id;
  if v_order.kind = 'publication' then
    perform public.consume_order_credit(p_order_id);
    perform public.release_note_for_order(p_order_id);
    -- Referral qualification now keys on the fulfilled order, not on the published note.
    if v_order.user_id is not null then perform public.qualify_referral(v_order.user_id); end if;
    -- Burn every account <-> order link. The note itself never had one.
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
    update public.campaigns set status = 'pending_review'
     where order_id = p_order_id and status = 'awaiting_payment';
  end if;
end $$;

-- Failed, cancelled, denied or expired: DELETE the pending post (was: keep it as payment_failed),
-- and give back the promo use and the free weekly post.
create or replace function public.abandon_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.release_order_credit(p_order_id);
  with d as (delete from public.promo_redemptions where order_id = p_order_id returning code_id),
       c as (select code_id, count(*)::int n from d group by code_id)
  update public.promo_codes p set uses = greatest(p.uses - c.n, 0) from c where p.id = c.code_id;
  delete from public.free_post_claims where order_id = p_order_id;
  delete from public.notes where order_id = p_order_id and status = 'awaiting_payment';  -- cascades decorations; 010 queues media for deletion
  update public.donations set status = 'failed' where order_id = p_order_id and status = 'pending';
  update public.campaigns set status = 'draft', order_id = null
   where order_id = p_order_id and status = 'awaiting_payment';
end $$;

-- A Snap session now lives 30 minutes (matches the Snap expiry sent by create-payment) + 5 min grace.
create or replace function public.record_payment_session(p_order_ref text, p_token text, p_redirect_url text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_token is null or p_redirect_url !~ '^https://' then
    perform public.app_error('CSW40', 'INVALID_PAYMENT_SESSION');
  end if;
  update public.orders
     set payment_session_token = p_token, payment_redirect_url = p_redirect_url,
         expires_at = now() + interval '35 minutes'
   where order_ref = p_order_ref and payment_locked_at is not null and payment_session_token is null;
  if not found then
    perform public.app_error('CSW09', 'PAYMENT_SESSION_CONFLICT');
  end if;
end $$;

-- Referral rule: first fulfilled post (paid or free) instead of "first published note".
create or replace function public.qualify_referral(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_referrer uuid; v_slot int; v_kind text;
begin
  if not exists (select 1 from auth.users u where u.id = p_user and u.email_confirmed_at is not null) then return; end if;
  if not exists (select 1 from public.orders o where o.user_id = p_user and o.kind = 'publication' and o.fulfilled_at is not null) then return; end if;
  update public.referral_attributions
     set status = 'qualified', qualified_at = now()
   where referred_user_id = p_user and status = 'pending_verification'
     and referrer_id is not null and not public.is_suspended(referrer_id)
  returning referrer_id into v_referrer;
  if v_referrer is null then return; end if;
  foreach v_kind in array array['post', 'decoration'] loop
    for v_slot in 1..2 loop
      insert into public.referral_credits (user_id, kind, slot, source_ref, recipient)
      values (p_user, v_kind, v_slot, p_user, 'invitee'),
             (v_referrer, v_kind, v_slot, p_user, 'inviter')
      on conflict (source_ref, user_id, kind, slot) do nothing;
    end loop;
  end loop;
  perform public.audit('referral.credits_issued', 'user', p_user::text, null,
    jsonb_build_object('referrer', v_referrer::text));
end $$;

-- ---------------------------------------------------------------------------
-- 6. The single entry point used by create-publication
-- ---------------------------------------------------------------------------
create or replace function public.create_publication_order_v2(
  p_user_id uuid, p_author_name text, p_body text, p_color text, p_social_link text, p_show_amount boolean,
  p_amount text, p_decorations text[], p_use_credit boolean, p_guest_token_hash text, p_campus_id uuid,
  p_media jsonb, p_use_post_credit boolean, p_deco_credits int, p_positions jsonb,
  p_promo text, p_use_free_post boolean, p_confirmed boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_amount bigint := public.parse_amount(p_amount);
  v_confirm bigint := coalesce((public.config_value('confirm_above_amount') #>> '{}')::bigint, 100000);
  v_promo text := nullif(btrim(coalesce(p_promo, '')), '');
  v_wants boolean := v_promo is not null or coalesce(p_use_free_post, false);
  v_credits boolean := coalesce(p_use_credit, false) or coalesce(p_use_post_credit, false) or coalesce(p_deco_credits, 0) > 0;
  v jsonb; v_id uuid; v_total bigint;
begin
  if v_amount > v_confirm and not coalesce(p_confirmed, false) then
    perform public.app_error('CSW40', 'AMOUNT_NOT_CONFIRMED', 'Please confirm the amount you want to pay.');
  end if;
  perform public.validate_author_name(p_author_name);
  if v_wants then
    if p_user_id is null then perform public.app_error('CSW03', 'ACCOUNT_REQUIRED', 'Sign in to use a free post or promo code.'); end if;
    if v_credits or (v_promo is not null and coalesce(p_use_free_post, false)) then
      perform public.app_error('CSW40', 'DISCOUNT_CONFLICT', 'Use only one of: free weekly post, promo code, credits.');
    end if;
  end if;

  perform set_config('csw.defer_free', '1', true);
  v := public.create_publication_order_full(p_user_id, p_author_name, p_body, p_color, p_social_link, p_show_amount,
         p_amount, p_decorations, p_use_credit, p_guest_token_hash, p_campus_id, p_media,
         p_use_post_credit, p_deco_credits, p_positions);
  perform set_config('csw.defer_free', '', true);

  select id into v_id from public.orders where order_ref = v ->> 'order_ref';
  if v_wants then perform public.apply_post_discount(v_id, p_user_id, v_promo, coalesce(p_use_free_post, false)); end if;
  update public.notes set author_id = null where order_id = v_id;   -- never keep the account on the note

  select total_amount into v_total from public.orders where id = v_id;
  if v_total = 0 then perform public.complete_free_order(v_id);
  else perform public.require_payable_total(v_total); end if;
  return public.order_summary(v_id);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Admin: promo codes (called through admin-api as the admin's JWT)
-- ---------------------------------------------------------------------------
create or replace function public.admin_create_promo(p_code text, p_kind text, p_value bigint, p_max_uses int,
  p_per_user int, p_expires timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(btrim(coalesce(p_code, ''))); v_row public.promo_codes;
begin
  perform public.require_admin();
  if v_code !~ '^[A-Z0-9]{4,24}$' then perform public.app_error('CSW40', 'INVALID_PROMO', 'Code: 4-24 letters or digits.'); end if;
  if p_kind not in ('percent', 'fixed') or p_value is null or p_value < 1 or (p_kind = 'percent' and p_value > 100) then
    perform public.app_error('CSW40', 'INVALID_PROMO', 'Percent 1-100, or a fixed rupiah amount.');
  end if;
  insert into public.promo_codes (code, kind, value, max_uses, per_user_limit, expires_at)
  values (v_code, p_kind, p_value, p_max_uses, coalesce(p_per_user, 1), p_expires)
  returning * into v_row;
  perform public.audit('promo.create', 'promo', v_row.id::text, null, jsonb_build_object('code', v_code, 'kind', p_kind, 'value', p_value));
  return to_jsonb(v_row);
exception when unique_violation then
  perform public.app_error('CSW09', 'PROMO_EXISTS', 'That code already exists.');
end $$;

create or replace function public.admin_list_promos() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.promo_codes p), '[]'::jsonb);
end $$;

create or replace function public.admin_set_promo_enabled(p_id uuid, p_enabled boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_admin();
  update public.promo_codes set enabled = p_enabled where id = p_id;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  perform public.audit('promo.set_enabled', 'promo', p_id::text, null, jsonb_build_object('enabled', p_enabled));
  return jsonb_build_object('id', p_id, 'enabled', p_enabled);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Grants (every new function: closed by default)
-- ---------------------------------------------------------------------------
revoke execute on function
  public.min_publication_price(), public.max_publication_price(), public.jakarta_week_start(),
  public.my_free_post_available(), public.name_key(text), public.validate_author_name(text),
  public.quote_post_discount(uuid, text, text[], text, boolean),
  public.apply_post_discount(uuid, uuid, text, boolean), public.burn_media_owner(text[]),
  public.complete_free_order(uuid), public.fulfill_order(uuid), public.abandon_order(uuid),
  public.record_payment_session(text, text, text), public.qualify_referral(uuid),
  public.create_publication_order_v2(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid, jsonb, boolean, int, jsonb, text, boolean, boolean),
  public.admin_create_promo(text, text, bigint, int, int, timestamptz), public.admin_list_promos(),
  public.admin_set_promo_enabled(uuid, boolean)
  from public, anon, authenticated;

grant execute on function
  public.min_publication_price(), public.max_publication_price(), public.jakarta_week_start(),
  public.name_key(text), public.validate_author_name(text),
  public.quote_post_discount(uuid, text, text[], text, boolean),
  public.apply_post_discount(uuid, uuid, text, boolean), public.burn_media_owner(text[]),
  public.complete_free_order(uuid), public.fulfill_order(uuid), public.abandon_order(uuid),
  public.record_payment_session(text, text, text), public.qualify_referral(uuid),
  public.create_publication_order_v2(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid, jsonb, boolean, int, jsonb, text, boolean, boolean)
  to service_role;

-- Public: quote_publication already allowed in 005 (reads min/max from config now).
grant execute on function public.my_free_post_available() to authenticated;
grant execute on function public.admin_create_promo(text, text, bigint, int, int, timestamptz),
  public.admin_list_promos(), public.admin_set_promo_enabled(uuid, boolean) to authenticated, service_role;
grant execute on function public.min_publication_price(), public.max_publication_price() to anon, authenticated;
