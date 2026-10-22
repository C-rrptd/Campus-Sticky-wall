-- 002_security_and_rls.sql
-- Row Level Security and privilege hardening for the tables created in 001.
-- Later migrations enable RLS on their own tables; 005 performs a final
-- function-execute allowlist sweep.
--
-- Model: RLS is enabled on every table and access defaults to deny. Clients
-- only receive the narrow read/write paths listed here. Everything sensitive
-- (payments, credits, moderation, configuration) goes through SECURITY DEFINER
-- functions that are executable only by service_role or that check is_admin().

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.site_config enable row level security;
alter table public.decorations enable row level security;
alter table public.notes enable row level security;
alter table public.note_decorations enable row level security;
alter table public.votes enable row level security;
alter table public.bookmarks enable row level security;
alter table public.reports enable row level security;
alter table public.announcements enable row level security;
alter table public.admin_audit_log enable row level security;
alter table public.rate_limits enable row level security;

-- ---------------------------------------------------------------------------
-- Table privileges (defense in depth on top of RLS)
-- ---------------------------------------------------------------------------
revoke all on public.profiles, public.user_roles, public.site_config, public.decorations,
  public.notes, public.note_decorations, public.votes, public.bookmarks, public.reports,
  public.announcements, public.admin_audit_log, public.rate_limits
  from anon, authenticated;

grant select on public.site_config, public.decorations, public.notes, public.note_decorations,
  public.announcements to anon, authenticated;

grant select on public.profiles, public.user_roles, public.votes, public.bookmarks, public.reports
  to authenticated;
grant update (display_name, avatar_url, social_links, donor_recognition) on public.profiles to authenticated;
grant insert, delete on public.votes, public.bookmarks to authenticated;
grant insert (note_id, reporter_id, reason, details) on public.reports to authenticated;

-- ---------------------------------------------------------------------------
-- Policy helpers. Cross-table checks run as SECURITY DEFINER so policies do
-- not need client column privileges on notes (e.g. author_id stays private).
-- ---------------------------------------------------------------------------
create or replace function public.note_is_published(p_note uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.notes n where n.id = p_note and n.status = 'published')
$$;

create or replace function public.note_visible_to(p_note uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.notes n where n.id = p_note
                 and (n.status = 'published' or (p_user is not null and n.author_id = p_user)))
$$;

create or replace function public.note_is_votable(p_note uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user is not null
     and not public.is_suspended(p_user)
     and exists (select 1 from public.notes n where n.id = p_note and n.status = 'published'
                 and n.author_id is distinct from p_user)
$$;

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------
create policy profiles_select_own on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()) and suspended_at is null)
  with check (id = (select auth.uid()));

create policy user_roles_select_own on public.user_roles
  for select to authenticated using (user_id = (select auth.uid()));

create policy site_config_public_read on public.site_config
  for select to anon, authenticated using (is_public);

create policy decorations_public_read on public.decorations
  for select to anon, authenticated using (enabled);

create policy notes_public_read on public.notes
  for select to anon, authenticated using (status = 'published');
create policy notes_author_read on public.notes
  for select to authenticated using (author_id = (select auth.uid()));

create policy note_decorations_read on public.note_decorations
  for select to anon, authenticated using (public.note_visible_to(note_id, (select auth.uid())));

create policy votes_select_own on public.votes
  for select to authenticated using (user_id = (select auth.uid()));
create policy votes_insert_own on public.votes
  for insert to authenticated with check (
    user_id = (select auth.uid()) and public.note_is_votable(note_id, (select auth.uid())));
create policy votes_delete_own on public.votes
  for delete to authenticated using (user_id = (select auth.uid()));

create policy bookmarks_select_own on public.bookmarks
  for select to authenticated using (user_id = (select auth.uid()));
create policy bookmarks_insert_own on public.bookmarks
  for insert to authenticated with check (
    user_id = (select auth.uid()) and public.note_is_published(note_id));
create policy bookmarks_delete_own on public.bookmarks
  for delete to authenticated using (user_id = (select auth.uid()));

create policy reports_select_own on public.reports
  for select to authenticated using (reporter_id = (select auth.uid()));
create policy reports_insert_own on public.reports
  for insert to authenticated with check (
    reporter_id = (select auth.uid())
    and not public.is_suspended((select auth.uid()))
    and public.note_is_published(note_id));

create policy announcements_public_read on public.announcements
  for select to anon, authenticated using (status = 'published');

-- admin_audit_log and rate_limits intentionally have no policies: no client
-- role can read or write them. Admins read the audit log via admin functions.
