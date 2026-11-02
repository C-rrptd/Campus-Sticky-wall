-- 039_user_decorations.sql
-- Admin-only decoration uploads: an admin creates a pending submission, uploads the PNG, then approves it (the admin
-- page does all three in one step), and it joins the catalog (category "Community", placeable). Idempotent.
--   1. decoration_submissions: one row per upload. Its id ("u-" + 12 hex) becomes decorations.id on approval,
--      and the image lives at decoration-art/<id>.png so the browser can build the URL from the id alone.
--   2. submit_decoration(name): admins only; creates the pending row and returns the id.
--   3. admin_review_decoration(id, approve, name, price, reason): approve inserts into decorations.
--   4. Storage bucket decoration-art: public read; only an admin may upload <their pending id>.png or delete.

create table if not exists public.decoration_submissions (
  id text primary key check (id ~ '^u-[0-9a-f]{12}$'),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 50),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reason text check (reason is null or char_length(reason) <= 500),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists decoration_submissions_user_idx on public.decoration_submissions (user_id, created_at desc);
create index if not exists decoration_submissions_pending_idx on public.decoration_submissions (created_at) where status = 'pending';

alter table public.decoration_submissions enable row level security;
revoke all on public.decoration_submissions from anon, authenticated;
grant select on public.decoration_submissions to authenticated;
drop policy if exists decoration_submissions_read on public.decoration_submissions;
create policy decoration_submissions_read on public.decoration_submissions for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin((select auth.uid())));

create or replace function public.submit_decoration(p_name text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public.require_admin();
  v_name text := btrim(coalesce(p_name, ''));
  v_id text;
begin
  if char_length(v_name) not between 2 and 50 then perform public.app_error('CSW02', 'INVALID_FIELD', 'Name must be 2–50 characters.'); end if;
  v_id := 'u-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
  insert into public.decoration_submissions (id, user_id, name) values (v_id, v_uid, v_name);
  return v_id;
end $$;

create or replace function public.admin_review_decoration(p_id text, p_approve boolean, p_name text, p_price text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  s public.decoration_submissions;
  v_name text;
begin
  perform public.require_admin();
  select * into s from public.decoration_submissions where id = p_id for update;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  if s.status <> 'pending' then perform public.app_error('CSW07', 'ALREADY_REVIEWED', 'This upload was already reviewed.'); end if;
  if p_approve then
    v_name := coalesce(nullif(btrim(p_name), ''), s.name);
    insert into public.decorations (id, name, description, price, enabled, sort_order, render, category, placeable, default_x, default_y)
    values (s.id, v_name, 'Made by the community', public.parse_amount(coalesce(p_price, '0')), true, 900,
            jsonb_build_object('class', 'deco-' || s.id), 'Community', true, 85, 15);
    update public.decoration_submissions set status = 'approved', name = v_name, reviewed_at = now() where id = s.id;
  else
    update public.decoration_submissions set status = 'rejected', reason = nullif(btrim(p_reason), ''), reviewed_at = now() where id = s.id;
  end if;
  perform public.audit(case when p_approve then 'decoration.approve' else 'decoration.reject' end, 'decoration', s.id, p_reason);
  return jsonb_build_object('id', s.id, 'status', case when p_approve then 'approved' else 'rejected' end);
end $$;

revoke all on function public.submit_decoration(text), public.admin_review_decoration(text, boolean, text, text, text) from public, anon;
grant execute on function public.submit_decoration(text), public.admin_review_decoration(text, boolean, text, text, text) to authenticated;

-- Storage: public-read bucket. Upload only "<your pending submission id>.png"; no update policy, so a file is never replaced.
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'storage' and c.relname = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('decoration-art', 'decoration-art', true, 524288, array['image/png'])
    on conflict (id) do nothing;
    drop policy if exists "decoration art upload own pending" on storage.objects;
    drop policy if exists "decoration art read" on storage.objects;
    drop policy if exists "decoration art admin delete" on storage.objects;
    execute $p$create policy "decoration art upload own pending" on storage.objects for insert to authenticated
      with check (bucket_id = 'decoration-art' and exists (
        select 1 from public.decoration_submissions s
         where s.id || '.png' = name and s.user_id = (select auth.uid()) and s.status = 'pending')
        and public.is_admin((select auth.uid())))$p$;
    execute $p$create policy "decoration art read" on storage.objects for select to anon, authenticated
      using (bucket_id = 'decoration-art')$p$;
    execute $p$create policy "decoration art admin delete" on storage.objects for delete to authenticated
      using (bucket_id = 'decoration-art' and public.is_admin((select auth.uid())))$p$;
  end if;
end $$;
