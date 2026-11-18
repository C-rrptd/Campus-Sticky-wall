-- 046: referral rework, daily top-note email, feature suggestions. Idempotent.
--
-- A. Referral rework. A referral pays out only when BOTH sides have moved real money:
--    the referrer must have one paid post (that "activates" their code) and the friend must have one paid post.
--    Anyone can still sign up with the code; the referral waits as pending until both conditions hold, then each
--    side gets 1 free post credit and 1 free decoration credit. Whichever side pays last triggers the payout.
--    Credits issued by the old rule (2 + 2) stay as they are.
-- B. Daily digest: at 8 AM in the member's own time zone (campus/city/region -> regions.timezone, default Asia/Jakarta),
--    email the note that got the most upvotes the previous local day. On by default, one click to turn off.
-- C. Suggestions: signed-in members suggest features/fixes/decorations; decoration ideas may attach one file.

-- ---------------------------------------------------------------- A
-- Orders drop their account link once fulfilled (privacy), so "has paid once" is remembered on the profile
-- the moment paid publication orders add up to at least Rp5.000 (trigger below, before fulfill_order clears the account link). No back-fill: past orders no longer say who paid.
alter table public.profiles add column if not exists first_paid_at timestamptz;
alter table public.profiles add column if not exists paid_total bigint not null default 0;  -- Rp paid on fulfilled publication orders; first_paid_at is set once it reaches 5000
create or replace function public.has_paid_publication(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user is not null and exists (select 1 from public.profiles where id = p_user and first_paid_at is not null)
$$;
revoke execute on function public.has_paid_publication(uuid) from public, anon, authenticated;
grant execute on function public.has_paid_publication(uuid) to service_role;

create or replace function public.qualify_referral(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_referrer uuid; v_slot int; v_kind text;
begin
  if not exists (select 1 from auth.users u where u.id = p_user and u.email_confirmed_at is not null) then return; end if;
  if not public.has_paid_publication(p_user) then return; end if;           -- the friend paid
  update public.referral_attributions
     set status = 'qualified', qualified_at = now()
   where referred_user_id = p_user and status = 'pending_verification'
     and referrer_id is not null and not public.is_suspended(referrer_id)
     and public.has_paid_publication(referrer_id)                           -- the referrer's code is active
  returning referrer_id into v_referrer;
  if v_referrer is null then return; end if;
  -- Referral credits are capped per person: at most 3 free posts and 3 free decorations in total (the weekly free post is separate).
  foreach v_kind in array array['post', 'decoration'] loop
    for v_slot in 1..1 loop
      insert into public.referral_credits (user_id, kind, slot, source_ref, recipient)
      select u.id, v_kind, v_slot, p_user, u.role
        from (values (p_user, 'invitee'), (v_referrer, 'inviter')) as u(id, role)
       where (select count(*) from public.referral_credits c where c.user_id = u.id and c.kind = v_kind) < 3
      on conflict (source_ref, user_id, kind, slot) do nothing;
    end loop;
  end loop;
  perform public.audit('referral.credits_issued', 'user', p_user::text, null,
    jsonb_build_object('referrer', v_referrer::text));
end $$;

-- When a referrer's first paid post lands, every friend already waiting on them can now qualify.
create or replace function public.qualify_waiting_referrals(p_referrer uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if not public.has_paid_publication(p_referrer) then return; end if;
  for r in select referred_user_id from public.referral_attributions
            where referrer_id = p_referrer and status = 'pending_verification' loop
    perform public.qualify_referral(r.referred_user_id);
  end loop;
end $$;
revoke execute on function public.qualify_waiting_referrals(uuid) from public, anon, authenticated;
grant execute on function public.qualify_waiting_referrals(uuid) to service_role;

create or replace function public.on_order_fulfilled_paid() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind = 'publication' and new.status = 'paid' and new.total_amount > 0 and new.user_id is not null
     and new.fulfilled_at is not null and old.fulfilled_at is null then
    update public.profiles set paid_total = paid_total + new.total_amount::bigint,
           first_paid_at = coalesce(first_paid_at, case when paid_total + new.total_amount >= 5000 then now() end)
     where id = new.user_id;
    perform public.qualify_waiting_referrals(new.user_id);   -- as the referrer: waiting friends can now qualify
  end if;
  return new;
end $$;
drop trigger if exists orders_fulfilled_paid on public.orders;
create trigger orders_fulfilled_paid after update of fulfilled_at on public.orders
  for each row execute function public.on_order_fulfilled_paid();

create or replace function public.on_note_published_qualify() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'published' and new.author_id is not null
     and (tg_op = 'INSERT' or old.status is distinct from 'published') then
    perform public.qualify_referral(new.author_id);          -- as the invited friend
    perform public.qualify_waiting_referrals(new.author_id); -- as the referrer
  end if;
  return new;
end $$;

-- Dashboard: say whether the member's own code is active, and what each referral is waiting for.
create or replace function public.my_referral_summary() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'code', (select code from public.referral_codes where user_id = auth.uid()),
    'code_active', public.has_paid_publication(auth.uid()),
    'my_referral', (select jsonb_build_object('status', a.status, 'referrer_active', public.has_paid_publication(a.referrer_id),
                                              'i_paid', public.has_paid_publication(auth.uid()))
                      from public.referral_attributions a where a.referred_user_id = auth.uid() and a.referrer_id is not null),
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
                                   'qualified_at', a.qualified_at, 'friend_paid', public.has_paid_publication(a.referred_user_id)) order by a.created_at desc)
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

-- Referrals that were waiting only on the referrer, for members who already have a paid post, qualify now.
do $$ declare r record; begin
  for r in select distinct referrer_id from public.referral_attributions where status = 'pending_verification' and referrer_id is not null loop
    perform public.qualify_waiting_referrals(r.referrer_id);
  end loop;
end $$;

-- note_json: the 'profile' key (044) now appears only on profile-linked notes.
create or replace function public.note_json(n public.notes, p_viewer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', n.id, 'author_name', n.author_name, 'body', n.body, 'color', n.color,
    'social_link', n.social_link,
    'amount', case when n.show_amount then n.publication_amount::text end,
    'vote_count', n.vote_count, 'published_at', n.published_at, 'campus_id', n.campus_id, 'media', n.media,
    'poll', public.poll_json(n, p_viewer), 'spotify', n.spotify,
    'decorations', coalesce(a.decos, '[]'::jsonb),
    'stickers', coalesce(a.stk, '[]'::jsonb),
    'placements', coalesce(a.plc, '{}'::jsonb),
    'voted', p_viewer is not null and exists (select 1 from public.votes v where v.note_id = n.id and v.user_id = p_viewer),
    'bookmarked', p_viewer is not null and exists (select 1 from public.bookmarks b where b.note_id = n.id and b.user_id = p_viewer),
    'is_mine', p_viewer is not null and n.author_id = p_viewer)
    -- the key exists only on notes whose author linked their profile, so other notes carry no account hint at all
    || coalesce((select jsonb_build_object('profile', jsonb_build_object('id', p.id, 'name', p.display_name, 'avatar_url', p.avatar_url))
                   from public.profiles p where n.show_profile and p.id = n.author_id and p.suspended_at is null), '{}'::jsonb)
  from (
    select jsonb_agg(d.decoration_id order by d.decoration_id, d.id) as decos,
           jsonb_agg(jsonb_build_object('id', d.decoration_id, 'x', coalesce(d.pos_x, c.default_x),
                                        'y', coalesce(d.pos_y, c.default_y), 'rot', d.rot) order by d.id) filter (where c.placeable) as stk,
           jsonb_object_agg(d.decoration_id, jsonb_build_object('x', coalesce(d.pos_x, c.default_x),
                                        'y', coalesce(d.pos_y, c.default_y), 'rot', d.rot)) filter (where c.placeable) as plc
      from public.note_decorations d left join public.decorations c on c.id = d.decoration_id
     where d.note_id = n.id) a
$$;

-- ---------------------------------------------------------------- B
alter table public.regions add column if not exists timezone text not null default 'Asia/Jakarta';
update public.regions set timezone = 'Asia/Makassar' where country_code = 'ID' and timezone = 'Asia/Jakarta' and name in
  ('Bali', 'Nusa Tenggara Barat', 'Nusa Tenggara Timur', 'Kalimantan Selatan', 'Kalimantan Tengah', 'Kalimantan Timur', 'Kalimantan Utara',
   'Sulawesi Selatan', 'Sulawesi Tengah', 'Sulawesi Tenggara', 'Sulawesi Utara', 'Sulawesi Barat', 'Gorontalo');
update public.regions set timezone = 'Asia/Jayapura' where country_code = 'ID' and timezone = 'Asia/Jakarta' and name in
  ('Maluku', 'Maluku Utara', 'Papua', 'Papua Barat', 'Papua Barat Daya', 'Papua Selatan', 'Papua Tengah', 'Papua Pegunungan');

alter table public.profiles add column if not exists email_digest boolean not null default true;
alter table public.profiles add column if not exists last_digest_on date;

create or replace function public.my_digest() returns boolean
language sql stable security definer set search_path = '' as $$
  select email_digest from public.profiles where id = auth.uid()
$$;
create or replace function public.set_my_digest(p_on boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then perform public.app_error('CSW01', 'UNAUTHENTICATED'); end if;
  update public.profiles set email_digest = coalesce(p_on, true) where id = auth.uid();
end $$;
create or replace function public.set_digest_for(p_user uuid, p_on boolean) returns void
language sql security definer set search_path = '' as $$
  update public.profiles set email_digest = p_on where id = p_user
$$;
revoke execute on function public.my_digest(), public.set_my_digest(boolean) from public, anon;
grant execute on function public.my_digest(), public.set_my_digest(boolean) to authenticated;
revoke execute on function public.set_digest_for(uuid, boolean) from public, anon, authenticated;
grant execute on function public.set_digest_for(uuid, boolean) to service_role;

-- Claims up to p_limit digests that are due (local hour 8-11, not yet sent for the local day) and returns them.
-- Claiming marks the day as sent first, so a crash can skip a day for someone but never double-sends.
-- A member's scope is their campus when set (falling back to the whole site if the campus had no votes), else the whole site.
create or replace function public.digest_claim(p_limit int default 100, p_now timestamptz default now())
returns table (user_id uuid, email text, display_name text, note_id uuid, body text, author_name text, votes bigint, campus_scoped boolean)
language plpgsql security definer set search_path = '' as $$
begin
  return query
  with u as (
    select p.id, au.email::text as email, p.display_name, p.campus_id,
           coalesce(r.timezone, 'Asia/Jakarta') as tz,
           (p_now at time zone coalesce(r.timezone, 'Asia/Jakarta'))::date as local_day
      from public.profiles p
      join auth.users au on au.id = p.id
      left join public.cities ci on ci.id = coalesce(p.city_id, (select cp.city_id from public.campuses cp where cp.id = p.campus_id))
      left join public.regions r on r.id = coalesce(p.region_id, ci.region_id)
     where p.email_digest and p.suspended_at is null and au.email_confirmed_at is not null and au.email is not null
       and extract(hour from p_now at time zone coalesce(r.timezone, 'Asia/Jakarta')) between 8 and 11
       and (p.last_digest_on is null or p.last_digest_on < (p_now at time zone coalesce(r.timezone, 'Asia/Jakarta'))::date)
  ), picked as (
    select u.id, u.email, u.display_name, u.local_day,
           coalesce(c.id, g.id) as note_id, coalesce(c.body, g.body) as body,
           coalesce(c.author_name, g.author_name) as author_name, coalesce(c.votes, g.votes) as votes, c.id is not null as scoped
      from u
      left join lateral (
        select n.id, n.body, n.author_name, count(*) as votes
          from public.votes v join public.notes n on n.id = v.note_id and n.status = 'published'
         where u.campus_id is not null and n.campus_id = u.campus_id
           and v.created_at >= ((u.local_day - 1)::timestamp at time zone u.tz) and v.created_at < (u.local_day::timestamp at time zone u.tz)
         group by n.id order by count(*) desc, n.published_at desc limit 1) c on true
      left join lateral (
        select n.id, n.body, n.author_name, count(*) as votes
          from public.votes v join public.notes n on n.id = v.note_id and n.status = 'published'
         where v.created_at >= ((u.local_day - 1)::timestamp at time zone u.tz) and v.created_at < (u.local_day::timestamp at time zone u.tz)
         group by n.id order by count(*) desc, n.published_at desc limit 1) g on c.id is null
     where coalesce(c.id, g.id) is not null
     limit greatest(1, least(p_limit, 500))
  ), marked as (
    update public.profiles pr set last_digest_on = pk.local_day from picked pk where pr.id = pk.id returning pr.id
  )
  select pk.id, pk.email, pk.display_name, pk.note_id, pk.body, pk.author_name, pk.votes, pk.scoped
    from picked pk join marked m on m.id = pk.id;
end $$;
revoke execute on function public.digest_claim(int, timestamptz) from public, anon, authenticated;
grant execute on function public.digest_claim(int, timestamptz) to service_role;

-- ---------------------------------------------------------------- C
create table if not exists public.suggestions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('feature', 'improvement', 'bug', 'decoration', 'other')),
  title text not null check (char_length(title) between 3 and 100),
  body text not null check (char_length(body) between 10 and 2000),
  attachment_path text check (attachment_path is null or attachment_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(png|jpg|webp|pdf|txt)$'),
  status text not null default 'new' check (status in ('new', 'reviewing', 'planned', 'done', 'declined')),
  admin_note text check (admin_note is null or char_length(admin_note) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists suggestions_created_idx on public.suggestions (created_at desc);
create index if not exists suggestions_user_idx on public.suggestions (user_id, created_at desc);
alter table public.suggestions enable row level security;
revoke all on public.suggestions from anon, authenticated;

create or replace function public.submit_suggestion(p_kind text, p_title text, p_body text, p_attachment text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_title text := btrim(coalesce(p_title, ''));
  v_body text := btrim(coalesce(p_body, ''));
  v_id uuid;
begin
  if v_uid is null then perform public.app_error('CSW01', 'UNAUTHENTICATED', 'Sign in to send a suggestion.'); end if;
  if public.is_suspended(v_uid) then perform public.app_error('CSW03', 'FORBIDDEN'); end if;
  if p_kind is null or p_kind not in ('feature', 'improvement', 'bug', 'decoration', 'other') then perform public.app_error('CSW40', 'INVALID_KIND'); end if;
  if char_length(v_title) not between 3 and 100 or public.has_control_chars(v_title) then perform public.app_error('CSW40', 'INVALID_TITLE', 'Title must be 3 to 100 characters.'); end if;
  if char_length(v_body) not between 10 and 2000 then perform public.app_error('CSW40', 'INVALID_BODY', 'Details must be 10 to 2000 characters.'); end if;
  if p_attachment is not null and (p_kind <> 'decoration' or p_attachment not like v_uid::text || '/%') then
    perform public.app_error('CSW40', 'INVALID_ATTACHMENT', 'Only decoration ideas can include a file.');
  end if;
  if (select count(*) from public.suggestions where user_id = v_uid and created_at > now() - interval '24 hours') >= 5 then
    perform public.app_error('CSW29', 'RATE_LIMITED', 'You can send 5 suggestions a day. Try again tomorrow.');
  end if;
  insert into public.suggestions (user_id, kind, title, body, attachment_path)
  values (v_uid, p_kind, v_title, v_body, p_attachment) returning id into v_id;
  return v_id;
end $$;

create or replace function public.my_suggestions() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'kind', s.kind, 'title', s.title, 'status', s.status,
           'admin_note', s.admin_note, 'has_file', s.attachment_path is not null, 'created_at', s.created_at) order by s.created_at desc), '[]'::jsonb)
  from (select * from public.suggestions where user_id = auth.uid() order by created_at desc limit 50) s
$$;

create or replace function public.admin_list_suggestions(p_status text default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'kind', s.kind, 'title', s.title, 'body', s.body, 'status', s.status,
           'admin_note', s.admin_note, 'attachment_path', s.attachment_path, 'created_at', s.created_at,
           'from', (select display_name from public.profiles where id = s.user_id)) order by s.created_at desc)
    from (select * from public.suggestions where p_status is null or status = p_status
           order by created_at desc limit greatest(1, least(coalesce(p_limit, 100), 300))) s), '[]'::jsonb);
end $$;

create or replace function public.admin_set_suggestion(p_id uuid, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_admin();
  if p_status not in ('new', 'reviewing', 'planned', 'done', 'declined') then perform public.app_error('CSW40', 'INVALID_STATUS'); end if;
  update public.suggestions set status = p_status, admin_note = nullif(btrim(coalesce(p_note, '')), ''), updated_at = now() where id = p_id;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  perform public.audit('suggestion.set', 'suggestion', p_id::text, p_note, jsonb_build_object('status', p_status));
end $$;

revoke execute on function public.submit_suggestion(text, text, text, text), public.my_suggestions(),
  public.admin_list_suggestions(text, int), public.admin_set_suggestion(uuid, text, text) from public, anon;
grant execute on function public.submit_suggestion(text, text, text, text), public.my_suggestions(),
  public.admin_list_suggestions(text, int), public.admin_set_suggestion(uuid, text, text) to authenticated;

-- Private bucket: a member uploads into their own folder only; the member and admins can read; only admins delete.
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'storage' and c.relname = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('suggestion-files', 'suggestion-files', false, 2097152,
            array['image/png', 'image/jpeg', 'image/webp', 'application/pdf', 'text/plain'])
    on conflict (id) do nothing;
    drop policy if exists "suggestion files upload own" on storage.objects;
    drop policy if exists "suggestion files read" on storage.objects;
    drop policy if exists "suggestion files admin delete" on storage.objects;
    execute $p$create policy "suggestion files upload own" on storage.objects for insert to authenticated
      with check (bucket_id = 'suggestion-files' and name ~ ('^' || (select auth.uid())::text || '/[0-9a-f-]{36}\.(png|jpg|webp|pdf|txt)$'))$p$;
    execute $p$create policy "suggestion files read" on storage.objects for select to authenticated
      using (bucket_id = 'suggestion-files' and (name like (select auth.uid())::text || '/%' or public.is_admin((select auth.uid()))))$p$;
    execute $p$create policy "suggestion files admin delete" on storage.objects for delete to authenticated
      using (bucket_id = 'suggestion-files' and public.is_admin((select auth.uid())))$p$;
  end if;
end $$;
