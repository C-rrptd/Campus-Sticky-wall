-- 056_owner_referrals.sql
-- Owner referrals. Idempotent.
--   * The owner's own referral code (and any owner-made custom code) pays out with NO requirements: the friend gets the
--     credits the moment their email is verified. Nobody has to pay first, and the owner's code is always "active".
--   * The owner can make custom codes (e.g. KAMPUS2026) with a usage limit and their own credit amounts.
--   * Owner credits never expire (there is no expiry column anywhere) and do not count toward the 3+3 cap on
--     friend-to-friend referral credits (046): that cap now only counts origin = 'friend'.
--   * Friend-to-friend referrals (046) are unchanged.

-- ---------------------------------------------------------------- credits: more than 2 per kind, and where they came from
alter table public.referral_credits drop constraint if exists referral_credits_slot_check;
alter table public.referral_credits add constraint referral_credits_slot_check check (slot between 1 and 100);
alter table public.referral_credits add column if not exists origin text not null default 'friend' check (origin in ('friend', 'owner'));

-- ---------------------------------------------------------------- custom owner codes
create table if not exists public.owner_referral_codes (
  code text primary key check (code ~ '^[A-Z0-9_-]{3,24}$'),
  created_by uuid not null references auth.users (id) on delete cascade,
  post_credits int not null default 3 check (post_credits between 0 and 100),
  deco_credits int not null default 10 check (deco_credits between 0 and 100),
  max_uses int check (max_uses is null or max_uses >= 1),   -- null = unlimited
  uses int not null default 0 check (uses >= 0),
  enabled boolean not null default true,
  note text check (note is null or char_length(note) <= 200),
  created_at timestamptz not null default now()
);
alter table public.owner_referral_codes enable row level security;
revoke all on public.owner_referral_codes from anon, authenticated;

-- The owner's personal code counts as "paid", so it is active from day one.
create or replace function public.has_paid_publication(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user is not null and exists (
    select 1 from public.profiles where id = p_user and (first_paid_at is not null or role = 'owner'))
$$;

-- ---------------------------------------------------------------- qualification
create or replace function public.qualify_referral(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.referral_attributions; oc public.owner_referral_codes; v_custom boolean;
  v_referrer uuid; v_slot int; v_kind text; v_posts int; v_decos int;
begin
  if not exists (select 1 from auth.users u where u.id = p_user and u.email_confirmed_at is not null) then return; end if;
  select * into a from public.referral_attributions
   where referred_user_id = p_user and status = 'pending_verification' and referrer_id is not null for update;
  if not found or public.is_suspended(a.referrer_id) then return; end if;

  -- Owner path: a custom owner code, or the owner's personal code. Email verified is the only requirement.
  select * into oc from public.owner_referral_codes where code = a.code for update;
  v_custom := found;
  if v_custom or public.is_owner(a.referrer_id) then
    if v_custom and (not oc.enabled or (oc.max_uses is not null and oc.uses >= oc.max_uses)) then
      update public.referral_attributions
         set status = 'rejected', reject_reason = case when oc.enabled then 'code_full' else 'code_disabled' end
       where referred_user_id = p_user;
      return;
    end if;
    if v_custom then update public.owner_referral_codes set uses = uses + 1 where code = oc.code; end if;
    -- ponytail: the owner's personal code gives a fixed 3 posts + 10 decorations; use a custom code for other amounts.
    v_posts := case when v_custom then oc.post_credits else 3 end;
    v_decos := case when v_custom then oc.deco_credits else 10 end;
    for v_slot in 1..v_posts loop
      insert into public.referral_credits (user_id, kind, slot, source_ref, recipient, origin)
      values (p_user, 'post', v_slot, p_user, 'invitee', 'owner') on conflict (source_ref, user_id, kind, slot) do nothing;
    end loop;
    for v_slot in 1..v_decos loop
      insert into public.referral_credits (user_id, kind, slot, source_ref, recipient, origin)
      values (p_user, 'decoration', v_slot, p_user, 'invitee', 'owner') on conflict (source_ref, user_id, kind, slot) do nothing;
    end loop;
    update public.referral_attributions set status = 'qualified', qualified_at = now() where referred_user_id = p_user;
    perform public.audit('referral.owner_credits_issued', 'user', p_user::text, null,
      jsonb_build_object('referrer', a.referrer_id::text, 'code', a.code, 'posts', v_posts, 'decorations', v_decos));
    return;
  end if;

  -- Friend path (046): both sides must have paid. Credits are capped per person at 3 posts and 3 decorations from friends.
  if not public.has_paid_publication(p_user) then return; end if;
  update public.referral_attributions
     set status = 'qualified', qualified_at = now()
   where referred_user_id = p_user and status = 'pending_verification'
     and referrer_id is not null and not public.is_suspended(referrer_id)
     and public.has_paid_publication(referrer_id)
  returning referrer_id into v_referrer;
  if v_referrer is null then return; end if;
  foreach v_kind in array array['post', 'decoration'] loop
    for v_slot in 1..1 loop
      insert into public.referral_credits (user_id, kind, slot, source_ref, recipient)
      select u.id, v_kind, v_slot, p_user, u.role
        from (values (p_user, 'invitee'), (v_referrer, 'inviter')) as u(id, role)
       where (select count(*) from public.referral_credits c where c.user_id = u.id and c.kind = v_kind and c.origin = 'friend') < 3
      on conflict (source_ref, user_id, kind, slot) do nothing;
    end loop;
  end loop;
  perform public.audit('referral.credits_issued', 'user', p_user::text, null,
    jsonb_build_object('referrer', v_referrer::text));
end $$;

-- ---------------------------------------------------------------- signup: custom codes are accepted too
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := btrim(coalesce(new.raw_user_meta_data ->> 'display_name', ''));
  v_ref text := upper(btrim(coalesce(new.raw_user_meta_data ->> 'referral_code', '')));
  v_referrer uuid;
  v_referrer_email text;
  v_user text := btrim(coalesce(new.raw_user_meta_data ->> 'username', ''));
begin
  if char_length(v_name) not between 2 and 40 or public.has_control_chars(v_name) then
    v_name := left(coalesce(nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'Student'), 40);
    if char_length(v_name) < 2 then v_name := 'Student'; end if;
  end if;
  if v_user !~ '^[A-Za-z0-9_.-]{3,30}$' or exists (select 1 from public.profiles where lower(username) = lower(v_user)) then
    v_user := null;
  end if;
  begin
    insert into public.profiles (id, display_name, username) values (new.id, v_name, v_user) on conflict (id) do nothing;
  exception when unique_violation then
    insert into public.profiles (id, display_name) values (new.id, v_name) on conflict (id) do nothing;
  end;

  loop
    begin
      insert into public.referral_codes (user_id, code) values (new.id, public.generate_referral_code());
      exit;
    exception when unique_violation then
      if exists (select 1 from public.referral_codes where user_id = new.id) then exit; end if;
    end;
  end loop;

  if v_ref ~ '^[A-Z0-9_-]{3,24}$' then
    select rc.user_id, u.email into v_referrer, v_referrer_email
      from public.referral_codes rc join auth.users u on u.id = rc.user_id
     where rc.code = v_ref;
    if v_referrer is null then   -- not a personal code: try an owner's custom code
      select oc.created_by, u.email into v_referrer, v_referrer_email
        from public.owner_referral_codes oc join auth.users u on u.id = oc.created_by
       where oc.code = v_ref and oc.enabled;
    end if;
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

-- ---------------------------------------------------------------- owner admin functions (called through admin-api)
create or replace function public.owner_create_referral_code(p_code text, p_posts int, p_decos int, p_max_uses int, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public.require_owner(); v_code text := upper(btrim(coalesce(p_code, ''))); v_row public.owner_referral_codes;
begin
  if v_code !~ '^[A-Z0-9_-]{3,24}$' then
    perform public.app_error('CSW40', 'INVALID_CODE', 'Code: 3-24 letters, digits, - or _.');
  end if;
  if coalesce(p_posts, -1) not between 0 and 100 or coalesce(p_decos, -1) not between 0 and 100 then
    perform public.app_error('CSW40', 'INVALID_CREDITS', 'Free posts and free decorations: 0-100 each.');
  end if;
  if p_max_uses is not null and p_max_uses < 1 then
    perform public.app_error('CSW40', 'INVALID_LIMIT', 'Usage limit must be 1 or more, or blank for unlimited.');
  end if;
  if exists (select 1 from public.referral_codes where code = v_code) then
    perform public.app_error('CSW09', 'CODE_EXISTS', 'That code already exists.');
  end if;
  insert into public.owner_referral_codes (code, created_by, post_credits, deco_credits, max_uses, note)
  values (v_code, v_uid, p_posts, p_decos, p_max_uses, nullif(btrim(p_note), ''))
  returning * into v_row;
  perform public.audit('referral.owner_code_create', 'referral_code', v_code, null,
    jsonb_build_object('posts', p_posts, 'decorations', p_decos, 'max_uses', p_max_uses));
  return to_jsonb(v_row);
exception when unique_violation then
  perform public.app_error('CSW09', 'CODE_EXISTS', 'That code already exists.');
end $$;

create or replace function public.owner_list_referral_codes() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_owner();
  return coalesce((select jsonb_agg(to_jsonb(c) - 'created_by' order by c.created_at desc) from public.owner_referral_codes c), '[]'::jsonb);
end $$;

-- p_max_uses null = unlimited. Lowering it below the current uses simply closes the code.
create or replace function public.owner_update_referral_code(p_code text, p_enabled boolean, p_max_uses int)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner();
  if p_max_uses is not null and p_max_uses < 1 then
    perform public.app_error('CSW40', 'INVALID_LIMIT', 'Usage limit must be 1 or more, or blank for unlimited.');
  end if;
  update public.owner_referral_codes set enabled = coalesce(p_enabled, enabled), max_uses = p_max_uses where code = upper(p_code);
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  perform public.audit('referral.owner_code_update', 'referral_code', upper(p_code), null,
    jsonb_build_object('enabled', p_enabled, 'max_uses', p_max_uses));
  return jsonb_build_object('code', upper(p_code), 'enabled', p_enabled, 'max_uses', p_max_uses);
end $$;

revoke execute on function
  public.owner_create_referral_code(text, int, int, int, text), public.owner_list_referral_codes(),
  public.owner_update_referral_code(text, boolean, int) from public, anon;
grant execute on function
  public.owner_create_referral_code(text, int, int, int, text), public.owner_list_referral_codes(),
  public.owner_update_referral_code(text, boolean, int) to authenticated, service_role;
