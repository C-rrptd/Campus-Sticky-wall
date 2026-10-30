-- Username login for email accounts: a unique, case-insensitive username on profiles.
-- Login resolves username -> email only inside the username-login Edge Function (service_role); the browser never sees emails.

alter table public.profiles add column username text check (username ~ '^[A-Za-z0-9_.-]{3,30}$');
create unique index profiles_username_key on public.profiles (lower(username));
grant update (username) on public.profiles to authenticated;

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
  -- A bad or taken username never fails a signup; the profile just starts without one.
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

create or replace function public.username_available(p_username text) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_username ~ '^[A-Za-z0-9_.-]{3,30}$'
     and not exists (select 1 from public.profiles where lower(username) = lower(p_username))
     and not exists (select 1 from auth.users where lower(email) = lower(p_username) || '@users.csw.invalid');
$$;

create or replace function public.login_email(p_username text) returns text
language sql stable security definer set search_path = '' as $$
  select u.email from public.profiles p join auth.users u on u.id = p.id where lower(p.username) = lower(p_username);
$$;

revoke execute on function public.username_available(text), public.login_email(text) from public, anon, authenticated;
grant execute on function public.username_available(text) to anon, authenticated, service_role;
grant execute on function public.login_email(text) to service_role;
