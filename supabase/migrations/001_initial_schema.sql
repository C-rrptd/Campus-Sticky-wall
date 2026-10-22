-- 001_initial_schema.sql
-- Core community tables: profiles, roles, site configuration, decorations,
-- notes, votes, bookmarks, reports, announcements, audit log, rate limits.
--
-- Conventions used by every migration:
--   * Money is stored as BIGINT whole rupiah (no floating point). The storage
--     ceiling (9,223,372,036,854,775,807) is a technical limit, not a pricing cap.
--   * Functions set search_path = '' and use fully-qualified names.
--   * Application errors use custom SQLSTATEs that Edge Functions map to HTTP:
--       CSW40 -> 400, CSW03 -> 403, CSW04 -> 404, CSW09 -> 409, CSW29 -> 429.
--     The MESSAGE is a stable machine code; the HINT is human-readable text.

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function public.app_error(p_state text, p_code text, p_hint text default null)
returns void language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = p_state, message = p_code, hint = coalesce(p_hint, p_code);
end $$;

-- Minimum customer-selected publication price and the fixed referral-credit
-- value. Both are product rules from the specification, deliberately not
-- admin-editable. There is intentionally NO maximum publication price.
create or replace function public.min_publication_price() returns bigint
language sql immutable set search_path = '' as $$ select 5000::bigint $$;

create or replace function public.referral_credit_value() returns bigint
language sql immutable set search_path = '' as $$ select 5000::bigint $$;

-- ---------------------------------------------------------------------------
-- Profiles and roles
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 2 and 40),
  avatar_url text check (avatar_url is null or (avatar_url ~ '^https://' and char_length(avatar_url) <= 500)),
  social_links jsonb not null default '{}'::jsonb check (jsonb_typeof(social_links) = 'object'),
  donor_recognition boolean not null default false,
  suspended_at timestamptz,
  suspension_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

create table public.user_roles (
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('admin')),
  granted_at timestamptz not null default now(),
  granted_by text,
  primary key (user_id, role)
);

create or replace function public.is_admin(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user is not null and exists (
    select 1 from public.user_roles r where r.user_id = p_user and r.role = 'admin')
$$;

create or replace function public.require_admin() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if not public.is_admin(v_uid) then
    perform public.app_error('CSW03', 'FORBIDDEN', 'Administrator access required.');
  end if;
  return v_uid;
end $$;

create or replace function public.is_suspended(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = p_user and p.suspended_at is not null)
$$;

-- Allowed social link hosts (used for profiles and notes).
create or replace function public.is_allowed_social_url(p_url text) returns boolean
language sql immutable set search_path = '' as $$
  select p_url is not null
     and char_length(p_url) <= 300
     and p_url ~* '^https://(www\.)?(instagram\.com|x\.com|twitter\.com|tiktok\.com|linkedin\.com|github\.com|youtube\.com|facebook\.com|threads\.net)(/[A-Za-z0-9._~%/@?=&+-]*)?$'
$$;

create or replace function public.validate_social_links() returns trigger
language plpgsql set search_path = '' as $$
declare v_key text; v_val jsonb;
begin
  if (select count(*) from jsonb_object_keys(new.social_links)) > 5 then
    perform public.app_error('CSW40', 'TOO_MANY_SOCIAL_LINKS', 'At most 5 social links are allowed.');
  end if;
  for v_key, v_val in select * from jsonb_each(new.social_links) loop
    if v_key not in ('instagram','x','tiktok','linkedin','github','youtube','facebook','threads')
       or jsonb_typeof(v_val) <> 'string'
       or not public.is_allowed_social_url(v_val #>> '{}') then
      perform public.app_error('CSW40', 'INVALID_SOCIAL_LINK', 'Social links must be https URLs on supported platforms.');
    end if;
  end loop;
  return new;
end $$;
create trigger profiles_social_links before insert or update of social_links on public.profiles
  for each row execute function public.validate_social_links();

-- ---------------------------------------------------------------------------
-- Site configuration (key/value; only allowlisted keys are editable by admins)
-- ---------------------------------------------------------------------------
create table public.site_config (
  key text primary key,
  value jsonb not null,
  is_public boolean not null default false,
  description text,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create trigger site_config_updated_at before update on public.site_config
  for each row execute function public.set_updated_at();

insert into public.site_config (key, value, is_public, description) values
  ('note_moderation', '"post"', true, 'pre = paid notes wait for admin approval; post = paid notes publish immediately and can be removed later'),
  ('donation_min_amount', '1000', true, 'Minimum donation in rupiah'),
  ('donation_max_amount', '100000000', true, 'Maximum donation in rupiah (donations only; never applied to note prices)'),
  ('official_social_links', '{}', true, 'Official site social links shown in the footer'),
  ('contact_email', '""', true, 'Public contact address'),
  ('display_ads_enabled', 'false', true, 'Third-party display ad slots stay hidden until true and a provider is configured'),
  ('unpaid_order_ttl_minutes', '120', false, 'Unpaid orders without a payment session expire after this many minutes');

create or replace function public.config_value(p_key text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select value from public.site_config where key = p_key
$$;

-- ---------------------------------------------------------------------------
-- Decorations (prices editable by admins; orders keep immutable snapshots)
-- ---------------------------------------------------------------------------
create table public.decorations (
  id text primary key check (id ~ '^[a-z0-9-]{2,40}$'),
  name text not null check (char_length(name) between 2 and 50),
  description text,
  price bigint not null check (price >= 0),
  enabled boolean not null default true,
  sort_order int not null default 0,
  render jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create trigger decorations_updated_at before update on public.decorations
  for each row execute function public.set_updated_at();

insert into public.decorations (id, name, description, price, sort_order, render) values
  ('tape', 'Decorative tape', 'A strip of washi tape across the top', 1000, 1, '{"class":"deco-tape"}'),
  ('border', 'Premium border', 'A hand-drawn double border', 2000, 2, '{"class":"deco-border"}'),
  ('stickers', 'Sticker set', 'Little star and heart stickers', 2000, 3, '{"class":"deco-stickers"}');

-- ---------------------------------------------------------------------------
-- Notes
-- ---------------------------------------------------------------------------
create table public.notes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid unique,                 -- FK added in 003 once orders exists
  author_id uuid references auth.users (id) on delete set null,
  author_name text not null check (char_length(btrim(author_name)) between 1 and 40),
  body text not null check (char_length(btrim(body)) between 1 and 500),
  color text not null default 'yellow' check (color in ('yellow','pink','blue','green','orange','purple')),
  social_link text check (social_link is null or public.is_allowed_social_url(social_link)),
  show_amount boolean not null default true,
  publication_amount bigint not null check (publication_amount >= 5000),
  status text not null default 'awaiting_payment' check (status in
    ('awaiting_payment','pending_moderation','published','rejected','removed','withdrawn','payment_failed','refunded')),
  vote_count int not null default 0 check (vote_count >= 0),
  report_count int not null default 0 check (report_count >= 0),
  moderation_reason text,
  moderated_by uuid,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  updated_at timestamptz not null default now()
);
create trigger notes_updated_at before update on public.notes
  for each row execute function public.set_updated_at();

create table public.note_decorations (
  note_id uuid not null references public.notes (id) on delete cascade,
  decoration_id text not null references public.decorations (id),
  primary key (note_id, decoration_id)
);

create table public.votes (
  note_id uuid not null references public.notes (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

create table public.bookmarks (
  note_id uuid not null references public.notes (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null references public.notes (id) on delete cascade,
  reporter_id uuid not null references auth.users (id) on delete cascade,
  reason text not null check (reason in ('spam','harassment','hate','sexual','personal_info','scam','other')),
  details text check (details is null or char_length(details) <= 500),
  status text not null default 'open' check (status in ('open','resolved','dismissed')),
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (note_id, reporter_id)
);

-- Maintain denormalised counters without giving clients write access.
create or replace function public.bump_vote_count() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    update public.notes set vote_count = vote_count + 1 where id = new.note_id;
  elsif tg_op = 'DELETE' then
    update public.notes set vote_count = greatest(vote_count - 1, 0) where id = old.note_id;
  end if;
  return null;
end $$;
create trigger votes_count after insert or delete on public.votes
  for each row execute function public.bump_vote_count();

create or replace function public.bump_report_count() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.notes set report_count = report_count + 1 where id = new.note_id;
  return null;
end $$;
create trigger reports_count after insert on public.reports
  for each row execute function public.bump_report_count();

-- ---------------------------------------------------------------------------
-- Announcements
-- ---------------------------------------------------------------------------
create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 3 and 120),
  body text not null check (char_length(body) between 1 and 4000),
  status text not null default 'draft' check (status in ('draft','published','archived')),
  pinned boolean not null default false,
  published_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger announcements_updated_at before update on public.announcements
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Administrative audit log and rate limiting
-- ---------------------------------------------------------------------------
create table public.admin_audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid,
  action text not null,
  target_type text,
  target_id text,
  reason text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.audit(p_action text, p_target_type text, p_target_id text,
  p_reason text default null, p_details jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into public.admin_audit_log (actor_id, action, target_type, target_id, reason, details)
  values (auth.uid(), p_action, p_target_type, p_target_id, p_reason, coalesce(p_details, '{}'::jsonb));
$$;

create table public.rate_limits (
  key text not null,
  window_start timestamptz not null,
  hits int not null default 0,
  primary key (key, window_start)
);

-- Fixed-window counter stored in Postgres so limits hold across Edge Function
-- instances. Returns true when the call is allowed.
create or replace function public.check_rate_limit(p_key text, p_limit int, p_window_seconds int)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_window timestamptz := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  v_hits int;
begin
  if p_key is null or p_limit < 1 or p_window_seconds < 1 then
    perform public.app_error('CSW40', 'INVALID_RATE_LIMIT');
  end if;
  insert into public.rate_limits (key, window_start, hits) values (p_key, v_window, 1)
  on conflict (key, window_start) do update set hits = public.rate_limits.hits + 1
  returning hits into v_hits;
  -- Opportunistic cleanup of expired windows (cheap, bounded).
  if random() < 0.01 then
    delete from public.rate_limits where window_start < now() - interval '1 day';
  end if;
  return v_hits <= p_limit;
end $$;
