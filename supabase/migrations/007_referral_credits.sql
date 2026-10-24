-- 007_referral_credits.sql
-- Referral credits: both the inviter and the invited friend receive 2 free post
-- credits and 2 free decoration credits once the friend's account is verified
-- AND their first sticky post is published. Post credits and decoration credits
-- are separate counters and can be mixed with paid items in either direction
-- (free decoration on a paid post, paid decoration on a free post).
-- Additive: 001-006 untouched. Credits already issued by the old verify-time
-- rule (table credits, Rp5.000) stay valid; no NEW ones are issued.

create table if not exists public.referral_credits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('post', 'decoration')),
  slot int not null check (slot in (1, 2)),
  source_ref uuid not null,                      -- the referred user's id
  recipient text not null check (recipient in ('invitee', 'inviter')),
  status text not null default 'available' check (status in ('available', 'reserved', 'redeemed', 'revoked')),
  reserved_order_id uuid references public.orders (id) on delete set null,
  redeemed_order_id uuid references public.orders (id) on delete set null,
  created_at timestamptz not null default now(),
  reserved_at timestamptz,
  redeemed_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid,
  revoked_reason text,
  unique (source_ref, user_id, kind, slot),
  check (status <> 'reserved' or reserved_order_id is not null)
);
create index if not exists referral_credits_user_idx on public.referral_credits (user_id, kind, status);
create index if not exists referral_credits_order_idx on public.referral_credits (reserved_order_id) where reserved_order_id is not null;
alter table public.referral_credits enable row level security;
revoke all on public.referral_credits from anon, authenticated;

-- Eligibility: referral still pending, invited account email-verified, and the
-- invited user has at least one published sticky post. Runs once per account
-- (the status flip is atomic; the unique key blocks any replay).
create or replace function public.qualify_referral(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_referrer uuid; v_slot int; v_kind text;
begin
  if not exists (select 1 from auth.users u where u.id = p_user and u.email_confirmed_at is not null) then return; end if;
  if not exists (select 1 from public.notes n where n.author_id = p_user and n.status = 'published') then return; end if;
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

create or replace function public.on_note_published_qualify() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'published' and new.author_id is not null
     and (tg_op = 'INSERT' or old.status is distinct from 'published') then
    perform public.qualify_referral(new.author_id);
  end if;
  return new;
end $$;
drop trigger if exists notes_qualify_referral on public.notes;
create trigger notes_qualify_referral after insert or update of status on public.notes
  for each row execute function public.on_note_published_qualify();

-- Order credit lifecycle now covers both ledgers.
create or replace function public.consume_order_credit(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.credits
     set status = 'redeemed', redeemed_order_id = p_order_id, redeemed_at = now(), reserved_order_id = null
   where reserved_order_id = p_order_id and status = 'reserved';
  update public.referral_credits
     set status = 'redeemed', redeemed_order_id = p_order_id, redeemed_at = now(), reserved_order_id = null
   where reserved_order_id = p_order_id and status = 'reserved';
end $$;

create or replace function public.release_order_credit(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.credits
     set status = 'available', reserved_order_id = null, reserved_at = null
   where reserved_order_id = p_order_id and status = 'reserved';
  update public.referral_credits
     set status = 'available', reserved_order_id = null, reserved_at = null
   where reserved_order_id = p_order_id and status = 'reserved';
end $$;

-- Reserve referral credits on an unpaid publication order.
--   post credit:       the publication price is free (the note shows no amount)
--   decoration credit: p_deco of the order's paid decorations are free, highest price first
create or replace function public.apply_referral_credits(p_order_id uuid, p_user uuid, p_use_post boolean, p_deco int)
returns void language plpgsql security definer set search_path = '' as $$
declare
  o public.orders; v_credit uuid; v_discount bigint := 0; v_item record; v_paid int; v_deco int := coalesce(p_deco, 0);
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.kind <> 'publication' or p_user is null or o.user_id is distinct from p_user then
    perform public.app_error('CSW03', 'CREDIT_NOT_ALLOWED', 'Referral credits can only be used on your own note orders.');
  end if;
  if o.status <> 'awaiting_payment' or o.payment_locked_at is not null then
    perform public.app_error('CSW09', 'ORDER_LOCKED', 'Payment has started; the order can no longer change.');
  end if;
  if o.discount_amount > 0 then
    perform public.app_error('CSW09', 'CREDIT_ALREADY_APPLIED', 'A credit is already applied to this order.');
  end if;
  if v_deco < 0 or v_deco > 10 then perform public.app_error('CSW40', 'INVALID_CREDIT_COUNT'); end if;

  if coalesce(p_use_post, false) then
    select id into v_credit from public.referral_credits
     where user_id = p_user and kind = 'post' and status = 'available'
     order by created_at, slot limit 1 for update skip locked;
    if v_credit is null then
      perform public.app_error('CSW09', 'NO_CREDIT_AVAILABLE', 'You have no free post credit left.');
    end if;
    update public.referral_credits set status = 'reserved', reserved_order_id = p_order_id, reserved_at = now() where id = v_credit;
    insert into public.order_items (order_id, item_type, item_ref, name, unit_amount)
    values (p_order_id, 'credit', v_credit::text, 'Referral credit: free post', -o.publication_amount);
    v_discount := o.publication_amount;
    update public.notes set show_amount = false where order_id = p_order_id;
  end if;

  if v_deco > 0 then
    select count(*) into v_paid from public.order_items
     where order_id = p_order_id and item_type = 'decoration' and unit_amount > 0;
    if v_deco > v_paid then
      perform public.app_error('CSW40', 'TOO_MANY_DECORATION_CREDITS', 'You chose more free decorations than paid decorations on this note.');
    end if;
    for v_item in
      select name, unit_amount from public.order_items
       where order_id = p_order_id and item_type = 'decoration' and unit_amount > 0
       order by unit_amount desc, id limit v_deco
    loop
      select id into v_credit from public.referral_credits
       where user_id = p_user and kind = 'decoration' and status = 'available'
       order by created_at, slot limit 1 for update skip locked;
      if v_credit is null then
        perform public.app_error('CSW09', 'NO_CREDIT_AVAILABLE', 'You do not have enough free decoration credits.');
      end if;
      update public.referral_credits set status = 'reserved', reserved_order_id = p_order_id, reserved_at = now() where id = v_credit;
      insert into public.order_items (order_id, item_type, item_ref, name, unit_amount)
      values (p_order_id, 'credit', v_credit::text, left('Referral credit: ' || v_item.name, 50), -v_item.unit_amount);
      v_discount := v_discount + v_item.unit_amount;
    end loop;
  end if;

  update public.orders
     set discount_amount = v_discount, total_amount = subtotal_amount - v_discount,
         snapshot = snapshot || jsonb_build_object('credit_discount', v_discount::text,
                                                   'total_amount', (subtotal_amount - v_discount)::text)
   where id = p_order_id returning * into o;
  if o.total_amount = 0 then
    perform public.complete_free_order(p_order_id);
  else
    perform public.require_payable_total(o.total_amount);
  end if;
end $$;

-- One transaction: create the order, then reserve credits. If credits cannot be
-- applied the whole call (including the order) rolls back.
create or replace function public.create_publication_order_credits(
  p_user_id uuid, p_author_name text, p_body text, p_color text, p_social_link text, p_show_amount boolean,
  p_amount text, p_decorations text[], p_guest_token_hash text, p_campus_id uuid,
  p_use_post_credit boolean, p_deco_credits int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_order jsonb; v_id uuid;
begin
  if p_user_id is null then
    perform public.app_error('CSW03', 'ACCOUNT_REQUIRED', 'Sign in to use referral credits.');
  end if;
  v_order := public.create_publication_order(p_user_id, p_author_name, p_body, p_color, p_social_link, p_show_amount,
                                             p_amount, p_decorations, false, p_guest_token_hash, p_campus_id);
  select id into v_id from public.orders where order_ref = v_order ->> 'order_ref';
  perform public.apply_referral_credits(v_id, p_user_id, p_use_post_credit, p_deco_credits);
  return public.order_summary(v_id);
end $$;

-- Dashboard numbers: old keys kept; new keys carry the referral-credit counters.
create or replace function public.my_referral_summary() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'code', (select code from public.referral_codes where user_id = auth.uid()),
    'successful_referrals', (select count(*) from public.referral_attributions where referrer_id = auth.uid() and status = 'qualified'),
    'pending_referrals', (select count(*) from public.referral_attributions where referrer_id = auth.uid() and status = 'pending_verification'),
    'rejected_referrals', (select count(*) from public.referral_attributions where referrer_id = auth.uid() and status = 'rejected'),
    'credits_available', (select count(*) from public.credits where user_id = auth.uid() and status = 'available'),
    'credits_reserved', (select count(*) from public.credits where user_id = auth.uid() and status = 'reserved'),
    'credits_redeemed', (select count(*) from public.credits where user_id = auth.uid() and status = 'redeemed'),
    'credits_issued', (select count(*) from public.credits where user_id = auth.uid()),
    'free_posts_left', (select count(*) from public.referral_credits where user_id = auth.uid() and kind = 'post' and status = 'available'),
    'free_decorations_left', (select count(*) from public.referral_credits where user_id = auth.uid() and kind = 'decoration' and status = 'available'),
    'free_posts_used', (select count(*) from public.referral_credits where user_id = auth.uid() and kind = 'post' and status in ('reserved', 'redeemed')),
    'free_decorations_used', (select count(*) from public.referral_credits where user_id = auth.uid() and kind = 'decoration' and status in ('reserved', 'redeemed')),
    'referred_by_you_recent', coalesce((select jsonb_agg(jsonb_build_object('status', a.status, 'created_at', a.created_at,
                                   'qualified_at', a.qualified_at) order by a.created_at desc)
                                 from (select * from public.referral_attributions where referrer_id = auth.uid()
                                       order by created_at desc limit 20) a), '[]'::jsonb),
    'credit_history', coalesce((select jsonb_agg(h order by h ->> 'created_at' desc) from (
        select jsonb_build_object('status', c.status, 'created_at', c.created_at, 'redeemed_at', c.redeemed_at,
                                  'label', 'Rp5.000 off a post') as h
          from public.credits c where c.user_id = auth.uid()
        union all
        select jsonb_build_object('status', r.status, 'created_at', r.created_at, 'redeemed_at', r.redeemed_at,
                                  'label', case r.kind when 'post' then 'Free post' else 'Free decoration' end
                                           || case r.recipient when 'inviter' then ' (friend joined)' else ' (you joined)' end)
          from public.referral_credits r where r.user_id = auth.uid()) q), '[]'::jsonb)) end
$$;

-- Leaderboard: a referral counts once it has an unrevoked reward (old or new).
create or replace function public.leaderboard(p_kind text, p_period text default 'all', p_limit int default 25)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_since timestamptz;
  v_limit int := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_rows jsonb;
  v_me jsonb;
begin
  if v_uid is null then
    perform public.app_error('CSW03', 'AUTH_REQUIRED', 'Sign in to view leaderboards.');
  end if;
  if p_period not in ('all','week') or p_kind not in ('referrals','donations','notes') then
    perform public.app_error('CSW40', 'INVALID_LEADERBOARD');
  end if;
  v_since := case when p_period = 'week'
                  then date_trunc('week', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta'
                  else '-infinity'::timestamptz end;

  with totals as (
    select a.referrer_id as user_id, count(*)::numeric as value
      from public.referral_attributions a
     where p_kind = 'referrals' and a.status = 'qualified' and a.referrer_id is not null and a.qualified_at >= v_since
     -- a referral counts once it has an unrevoked reward: the old verify-time credit, or the new referral credits
      and (exists (select 1 from public.credits c where c.source = 'referral' and c.source_ref = a.referred_user_id and c.status <> 'revoked')
           or exists (select 1 from public.referral_credits rc where rc.source_ref = a.referred_user_id and rc.user_id = a.referrer_id and rc.status <> 'revoked'))
     group by 1
    union all
    select o.user_id, sum(o.total_amount - o.refunded_amount)::numeric
      from public.orders o join public.profiles p on p.id = o.user_id
     where p_kind = 'donations' and o.kind = 'donation' and o.status in ('paid','partially_refunded')
       and p.donor_recognition and o.paid_at >= v_since
     group by 1
    union all
    select n.author_id, count(*)::numeric
      from public.notes n
     where p_kind = 'notes' and n.status = 'published' and n.author_id is not null and n.published_at >= v_since
     group by 1
  ), ranked as (
    select t.user_id, p.display_name, t.value, rank() over (order by t.value desc) as rank
      from totals t join public.profiles p on p.id = t.user_id
     where p.suspended_at is null and t.value > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object('rank', r.rank, 'display_name', r.display_name,
                    'value', r.value::text, 'is_me', r.user_id = v_uid) order by r.rank, r.display_name), '[]'::jsonb)
    into v_rows
    from (select * from ranked order by rank, display_name limit v_limit) r;

  return jsonb_build_object('kind', p_kind, 'period', p_period, 'since', case when p_period = 'week' then v_since end,
                            'timezone', 'Asia/Jakarta', 'rows', v_rows);
end $$;

-- Admin: show the new rewards and allow revoking unused ones.
create or replace function public.admin_list_referrals(p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select a.referred_user_id, rp.display_name as referred_name, a.referrer_id, fp.display_name as referrer_name,
           a.code, a.status, a.reject_reason, a.created_at, a.qualified_at,
           c.id as credit_id, c.status as credit_status,
           (select count(*) from public.referral_credits rc where rc.source_ref = a.referred_user_id and rc.status <> 'revoked') as reward_credits
      from public.referral_attributions a
      left join public.profiles rp on rp.id = a.referred_user_id
      left join public.profiles fp on fp.id = a.referrer_id
      left join public.credits c on c.source = 'referral' and c.source_ref = a.referred_user_id
     order by a.created_at desc limit least(greatest(p_limit, 1), 500)) x), '[]'::jsonb);
end $$;

create or replace function public.admin_revoke_referral_credits(p_referred_user_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_n int; v_reason text := btrim(coalesce(p_reason, ''));
begin
  if char_length(v_reason) not between 5 and 500 then
    perform public.app_error('CSW40', 'REASON_REQUIRED', 'A reason of 5-500 characters is required.');
  end if;
  update public.referral_credits
     set status = 'revoked', revoked_at = now(), revoked_by = v_admin, revoked_reason = v_reason
   where source_ref = p_referred_user_id and status = 'available';
  get diagnostics v_n = row_count;
  perform public.audit('referral.credits_revoked', 'user', p_referred_user_id::text, v_reason,
                       jsonb_build_object('revoked', v_n));
  return jsonb_build_object('revoked', v_n);
end $$;

revoke execute on function
  public.apply_referral_credits(uuid, uuid, boolean, int),
  public.create_publication_order_credits(uuid, text, text, text, text, boolean, text, text[], text, uuid, boolean, int),
  public.admin_revoke_referral_credits(uuid, text), public.on_note_published_qualify()
  from public, anon, authenticated;
grant execute on function
  public.apply_referral_credits(uuid, uuid, boolean, int),
  public.create_publication_order_credits(uuid, text, text, text, text, boolean, text, text[], text, uuid, boolean, int),
  public.admin_revoke_referral_credits(uuid, text), public.on_note_published_qualify()
  to service_role;
grant execute on function public.admin_revoke_referral_credits(uuid, text) to authenticated;
