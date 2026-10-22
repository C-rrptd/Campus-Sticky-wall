-- 005_indexes_and_functions.sql
-- Indexes, public read functions (wall, account views, leaderboards),
-- order expiry, administrator operations, revenue reporting, and the final
-- function-execute allowlist.

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
create index notes_published_idx on public.notes (published_at desc) where status = 'published';
create index notes_top_idx on public.notes (vote_count desc, published_at desc) where status = 'published';
create index notes_amount_idx on public.notes (publication_amount desc, published_at desc) where status = 'published' and show_amount;
create index notes_campus_idx on public.notes (campus_id, published_at desc) where status = 'published';
create index notes_author_idx on public.notes (author_id, status);
create index notes_status_idx on public.notes (status, created_at desc);
create index votes_user_idx on public.votes (user_id);
create index bookmarks_user_idx on public.bookmarks (user_id, created_at desc);
create index reports_status_idx on public.reports (status, created_at desc);
create index orders_user_idx on public.orders (user_id, created_at desc);
create index orders_status_idx on public.orders (status, created_at desc);
create index orders_paid_idx on public.orders (kind, paid_at) where paid_at is not null;
create index orders_expiry_idx on public.orders (expires_at) where status = 'awaiting_payment';
create index orders_review_idx on public.orders (created_at desc) where review_required;
create index payment_notifications_order_idx on public.payment_notifications (order_ref, received_at desc);
create index donations_user_idx on public.donations (user_id, status);
create index attributions_referrer_idx on public.referral_attributions (referrer_id, status, qualified_at);
create index credits_user_idx on public.credits (user_id, status);
create index campaigns_live_idx on public.campaigns (placement, status, starts_at, ends_at);
create index campaigns_owner_idx on public.campaigns (owner_id, created_at desc);
create index campaign_targets_lookup_idx on public.campaign_targets (level, country_code, region_id, city_id, campus_id);
create index announcements_published_idx on public.announcements (pinned desc, published_at desc) where status = 'published';
create index audit_created_idx on public.admin_audit_log (created_at desc);

-- Column-level read access on notes: never expose order linkage, moderation
-- internals or the raw amount when the author chose to hide it (the wall goes
-- through get_wall(), which applies show_amount).
revoke select on public.notes from anon, authenticated;
grant select (id, author_name, body, color, social_link, show_amount, vote_count, status,
              created_at, published_at, campus_id) on public.notes to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Wall and account read functions
-- ---------------------------------------------------------------------------
create or replace function public.note_json(n public.notes, p_viewer uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', n.id, 'author_name', n.author_name, 'body', n.body, 'color', n.color,
    'social_link', n.social_link,
    'amount', case when n.show_amount then n.publication_amount::text end,
    'vote_count', n.vote_count, 'published_at', n.published_at, 'campus_id', n.campus_id,
    'decorations', coalesce((select jsonb_agg(d.decoration_id order by d.decoration_id)
                             from public.note_decorations d where d.note_id = n.id), '[]'::jsonb),
    'voted', p_viewer is not null and exists (select 1 from public.votes v where v.note_id = n.id and v.user_id = p_viewer),
    'bookmarked', p_viewer is not null and exists (select 1 from public.bookmarks b where b.note_id = n.id and b.user_id = p_viewer),
    'is_mine', p_viewer is not null and n.author_id = p_viewer)
$$;

create or replace function public.get_wall(p_sort text default 'newest', p_campus uuid default null,
  p_limit int default 24, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_viewer uuid := auth.uid();
  v_limit int := least(greatest(coalesce(p_limit, 24), 1), 50);
  v_offset int := least(greatest(coalesce(p_offset, 0), 0), 5000);
begin
  if p_sort not in ('newest','top','contribution') then
    perform public.app_error('CSW40', 'INVALID_SORT');
  end if;
  return coalesce((
    select jsonb_agg(public.note_json(n, v_viewer) order by
             case when p_sort = 'top' then n.vote_count end desc nulls last,
             case when p_sort = 'contribution' then n.publication_amount end desc nulls last,
             n.published_at desc, n.id)
    from (select * from public.notes n
           where n.status = 'published'
             and (p_campus is null or n.campus_id = p_campus)
             and (p_sort <> 'contribution' or n.show_amount)
           order by
             case when p_sort = 'top' then n.vote_count end desc nulls last,
             case when p_sort = 'contribution' then n.publication_amount end desc nulls last,
             n.published_at desc, n.id
           limit v_limit offset v_offset) n), '[]'::jsonb);
end $$;

create or replace function public.my_notes() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(public.note_json(n, auth.uid()) || jsonb_build_object(
           'status', n.status, 'created_at', n.created_at, 'order_ref', o.order_ref,
           'amount', n.publication_amount::text) order by n.created_at desc), '[]'::jsonb)
  from public.notes n join public.orders o on o.id = n.order_id
  where auth.uid() is not null and n.author_id = auth.uid()
$$;

create or replace function public.my_bookmarks() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(public.note_json(n, auth.uid()) order by b.created_at desc), '[]'::jsonb)
  from public.bookmarks b join public.notes n on n.id = b.note_id
  where auth.uid() is not null and b.user_id = auth.uid() and n.status = 'published'
$$;

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
    'referred_by_you_recent', coalesce((select jsonb_agg(jsonb_build_object('status', a.status, 'created_at', a.created_at,
                                   'qualified_at', a.qualified_at) order by a.created_at desc)
                                 from (select * from public.referral_attributions where referrer_id = auth.uid()
                                       order by created_at desc limit 20) a), '[]'::jsonb),
    'credit_history', coalesce((select jsonb_agg(jsonb_build_object('status', c.status, 'created_at', c.created_at,
                            'redeemed_at', c.redeemed_at, 'value', c.value::text) order by c.created_at desc)
                         from public.credits c where c.user_id = auth.uid()), '[]'::jsonb)) end
$$;

-- ---------------------------------------------------------------------------
-- Leaderboards (authenticated accounts only)
-- Week boundary: Monday 00:00 Asia/Jakarta.
-- ---------------------------------------------------------------------------
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
      join public.credits c on c.source = 'referral' and c.source_ref = a.referred_user_id and c.status <> 'revoked'
     where p_kind = 'referrals' and a.status = 'qualified' and a.referrer_id is not null and a.qualified_at >= v_since
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

-- ---------------------------------------------------------------------------
-- Expiry sweeper (schedule with pg_cron, see OPERATIONS.md)
-- ---------------------------------------------------------------------------
create or replace function public.expire_stale_orders() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_count int := 0;
begin
  for r in select id from public.orders
            where status = 'awaiting_payment' and expires_at is not null and expires_at < now()
            for update skip locked loop
    update public.orders set status = 'expired', closed_at = now() where id = r.id;
    perform public.abandon_order(r.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

-- ---------------------------------------------------------------------------
-- Administrator operations. Every function calls require_admin() first and
-- writes to admin_audit_log for mutations.
-- ---------------------------------------------------------------------------
create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'open_reports', (select count(*) from public.reports where status = 'open'),
    'notes_pending_moderation', (select count(*) from public.notes where status = 'pending_moderation'),
    'campaigns_pending_review', (select count(*) from public.campaigns where status = 'pending_review'),
    'orders_needing_review', (select count(*) from public.orders where review_required),
    'published_notes', (select count(*) from public.notes where status = 'published'),
    'users', (select count(*) from public.profiles));
end $$;

create or replace function public.admin_list_notes(p_status text default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select n.id, n.author_name, n.body, n.color, n.status, n.publication_amount::text as amount, n.vote_count,
           n.report_count, n.created_at, n.published_at, n.moderation_reason, o.order_ref, o.status as order_status
      from public.notes n join public.orders o on o.id = n.order_id
     where (p_status is null or n.status = p_status)
     order by n.created_at desc
     limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) x), '[]'::jsonb);
end $$;

create or replace function public.admin_moderate_note(p_note_id uuid, p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_note public.notes; v_new text;
begin
  select * into v_note from public.notes where id = p_note_id for update;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  v_new := case
    when p_action = 'approve' and v_note.status = 'pending_moderation' then 'published'
    when p_action = 'reject' and v_note.status = 'pending_moderation' then 'rejected'
    when p_action = 'remove' and v_note.status in ('published','pending_moderation') then 'removed'
    when p_action = 'restore' and v_note.status = 'removed' then 'published'
    else null end;
  if v_new is null then
    perform public.app_error('CSW09', 'INVALID_MODERATION_ACTION', 'That action is not valid for the note''s current status.');
  end if;
  update public.notes set status = v_new, moderated_by = v_admin, moderation_reason = p_reason,
         published_at = case when v_new = 'published' then coalesce(published_at, now()) else published_at end
   where id = p_note_id;
  perform public.audit('note.' || p_action, 'note', p_note_id::text, p_reason, jsonb_build_object('from', v_note.status, 'to', v_new));
  return jsonb_build_object('id', p_note_id, 'status', v_new);
end $$;

create or replace function public.admin_list_reports(p_status text default 'open', p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select r.id, r.note_id, r.reason, r.details, r.status, r.created_at, n.body as note_body,
           n.author_name, n.status as note_status, n.report_count
      from public.reports r join public.notes n on n.id = r.note_id
     where (p_status is null or r.status = p_status)
     order by r.created_at desc limit least(greatest(p_limit, 1), 500)) x), '[]'::jsonb);
end $$;

create or replace function public.admin_resolve_report(p_report_id uuid, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin();
begin
  if p_status not in ('resolved','dismissed') then perform public.app_error('CSW40', 'INVALID_STATUS'); end if;
  update public.reports set status = p_status, resolved_by = v_admin, resolved_at = now() where id = p_report_id;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  perform public.audit('report.' || p_status, 'report', p_report_id::text, p_reason);
  return jsonb_build_object('id', p_report_id, 'status', p_status);
end $$;

create or replace function public.admin_list_users(p_search text default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select p.id, p.display_name, u.email, u.email_confirmed_at is not null as email_verified, p.suspended_at,
           p.suspension_reason, p.created_at, public.is_admin(p.id) as is_admin,
           (select count(*) from public.notes n where n.author_id = p.id and n.status = 'published') as published_notes
      from public.profiles p join auth.users u on u.id = p.id
     where p_search is null or p.display_name ilike '%' || p_search || '%' or u.email ilike '%' || p_search || '%'
     order by p.created_at desc
     limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) x), '[]'::jsonb);
end $$;

create or replace function public.admin_set_user_suspension(p_user_id uuid, p_suspend boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin();
begin
  if p_user_id = v_admin then perform public.app_error('CSW40', 'CANNOT_SUSPEND_SELF'); end if;
  update public.profiles set suspended_at = case when p_suspend then now() end,
         suspension_reason = case when p_suspend then p_reason end
   where id = p_user_id;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  perform public.audit(case when p_suspend then 'user.suspend' else 'user.unsuspend' end, 'user', p_user_id::text, p_reason);
  return jsonb_build_object('id', p_user_id, 'suspended', p_suspend);
end $$;

create or replace function public.admin_upsert_decoration(p_id text, p_name text, p_description text,
  p_price text, p_enabled boolean, p_sort int default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_price bigint := public.parse_amount(p_price);
begin
  perform public.require_admin();
  insert into public.decorations (id, name, description, price, enabled, sort_order, render)
  values (p_id, p_name, p_description, v_price, coalesce(p_enabled, true), coalesce(p_sort, 0),
          jsonb_build_object('class', 'deco-' || p_id))
  on conflict (id) do update set name = excluded.name, description = excluded.description, price = excluded.price,
          enabled = excluded.enabled, sort_order = excluded.sort_order;
  perform public.audit('decoration.upsert', 'decoration', p_id, null, jsonb_build_object('price', v_price::text, 'enabled', p_enabled));
  return (select to_jsonb(d) || jsonb_build_object('price', d.price::text) from public.decorations d where d.id = p_id);
end $$;

create or replace function public.admin_list_catalog() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'decorations', (select coalesce(jsonb_agg(to_jsonb(d) || jsonb_build_object('price', d.price::text) order by d.sort_order), '[]') from public.decorations d),
    'payment_methods', (select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('min_amount', m.min_amount::text, 'max_amount', m.max_amount::text) order by m.sort_order), '[]') from public.payment_methods m),
    'ad_products', (select coalesce(jsonb_agg(to_jsonb(a) || jsonb_build_object('price_per_target', a.price_per_target::text) order by a.sort_order), '[]') from public.ad_products a),
    'config', (select coalesce(jsonb_agg(to_jsonb(c) order by c.key), '[]') from public.site_config c),
    'pricing_policy', jsonb_build_object('min_publication_price', public.min_publication_price()::text,
                                         'max_publication_price', null,
                                         'referral_credit_value', public.referral_credit_value()::text));
end $$;

create or replace function public.admin_upsert_payment_method(p_code text, p_label text, p_midtrans_codes text[],
  p_min text, p_max text, p_enabled boolean, p_sort int default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_min bigint := case when nullif(p_min, '') is null then null else public.parse_amount(p_min) end;
  v_max bigint := case when nullif(p_max, '') is null then null else public.parse_amount(p_max) end;
begin
  perform public.require_admin();
  insert into public.payment_methods (code, label, midtrans_codes, min_amount, max_amount, enabled, sort_order)
  values (p_code, p_label, p_midtrans_codes, v_min, v_max, coalesce(p_enabled, true), coalesce(p_sort, 0))
  on conflict (code) do update set label = excluded.label, midtrans_codes = excluded.midtrans_codes,
    min_amount = excluded.min_amount, max_amount = excluded.max_amount, enabled = excluded.enabled,
    sort_order = excluded.sort_order;
  perform public.audit('payment_method.upsert', 'payment_method', p_code, null,
    jsonb_build_object('min', p_min, 'max', p_max, 'enabled', p_enabled));
  return jsonb_build_object('code', p_code);
end $$;

create or replace function public.admin_upsert_ad_product(p_id text, p_name text, p_placement text, p_scope_level text,
  p_duration_days int, p_price text, p_enabled boolean, p_sort int default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_price bigint := public.parse_amount(p_price);
begin
  perform public.require_admin();
  insert into public.ad_products (id, name, placement, scope_level, duration_days, price_per_target, enabled, sort_order)
  values (p_id, p_name, p_placement, p_scope_level, p_duration_days, v_price, coalesce(p_enabled, true), coalesce(p_sort, 0))
  on conflict (id) do update set name = excluded.name, placement = excluded.placement, scope_level = excluded.scope_level,
    duration_days = excluded.duration_days, price_per_target = excluded.price_per_target,
    enabled = excluded.enabled, sort_order = excluded.sort_order;
  perform public.audit('ad_product.upsert', 'ad_product', p_id, null, jsonb_build_object('price', v_price::text));
  return jsonb_build_object('id', p_id);
end $$;

create or replace function public.admin_set_config(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin();
begin
  if p_key not in ('note_moderation','donation_min_amount','donation_max_amount','official_social_links',
                   'contact_email','display_ads_enabled','unpaid_order_ttl_minutes') then
    perform public.app_error('CSW40', 'CONFIG_KEY_NOT_EDITABLE');
  end if;
  if (p_key = 'note_moderation' and p_value #>> '{}' not in ('pre','post'))
     or (p_key in ('donation_min_amount','donation_max_amount','unpaid_order_ttl_minutes')
         and (jsonb_typeof(p_value) <> 'number' or (p_value #>> '{}')::numeric < 1))
     or (p_key = 'display_ads_enabled' and jsonb_typeof(p_value) <> 'boolean')
     or (p_key = 'official_social_links' and jsonb_typeof(p_value) <> 'object')
     or (p_key = 'contact_email' and jsonb_typeof(p_value) <> 'string') then
    perform public.app_error('CSW40', 'INVALID_CONFIG_VALUE');
  end if;
  if p_key = 'official_social_links' and exists (
       select 1 from jsonb_each(p_value) e where jsonb_typeof(e.value) <> 'string'
         or not public.is_allowed_social_url(e.value #>> '{}')) then
    perform public.app_error('CSW40', 'INVALID_SOCIAL_LINK');
  end if;
  update public.site_config set value = p_value, updated_by = v_admin where key = p_key;
  perform public.audit('config.set', 'config', p_key, null, jsonb_build_object('value', p_value));
  return jsonb_build_object('key', p_key, 'value', p_value);
end $$;

create or replace function public.admin_list_orders(p_kind text default null, p_status text default null,
  p_review_only boolean default false, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select o.order_ref, o.kind, o.status, o.total_amount::text as total_amount, o.discount_amount::text as discount_amount,
           o.refunded_amount::text as refunded_amount, o.payment_type, o.review_required, o.review_reason,
           o.created_at, o.paid_at, o.user_id is not null as has_account
      from public.orders o
     where (p_kind is null or o.kind = p_kind) and (p_status is null or o.status = p_status)
       and (not coalesce(p_review_only, false) or o.review_required)
     order by o.created_at desc
     limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) x), '[]'::jsonb);
end $$;

create or replace function public.admin_order_detail(p_order_ref text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_id uuid;
begin
  perform public.require_admin();
  select id into v_id from public.orders where order_ref = p_order_ref;
  if v_id is null then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  return public.order_summary(v_id) || jsonb_build_object(
    'review_required', (select review_required from public.orders where id = v_id),
    'review_reason', (select review_reason from public.orders where id = v_id),
    'notifications', (select coalesce(jsonb_agg(jsonb_build_object('status', transaction_status, 'fraud', fraud_status,
                         'result', result, 'received_at', received_at) order by received_at), '[]')
                        from public.payment_notifications where order_ref = p_order_ref));
end $$;

create or replace function public.admin_clear_order_review(p_order_ref text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_admin();
  if coalesce(btrim(p_reason), '') = '' then perform public.app_error('CSW40', 'REASON_REQUIRED'); end if;
  update public.orders set review_required = false where order_ref = p_order_ref;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  perform public.audit('order.review_cleared', 'order', p_order_ref, p_reason);
  return jsonb_build_object('order_ref', p_order_ref);
end $$;

create or replace function public.admin_list_campaigns(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select c.id, c.title, c.description, c.advertiser_name, c.contact_email, c.category, c.placement, c.scope_level,
           c.destination_url, c.creative_path, c.status, c.requested_start, c.starts_at, c.ends_at,
           c.price_snapshot::text as price, c.impressions, c.clicks, c.created_at, c.moderation_reason,
           o.status as payment_status, o.order_ref,
           (select jsonb_agg(t.target_key) from public.campaign_targets t where t.campaign_id = c.id) as targets
      from public.campaigns c left join public.orders o on o.id = c.order_id
     where p_status is null or c.status = p_status
     order by c.created_at desc limit 200) x), '[]'::jsonb);
end $$;

create or replace function public.admin_review_campaign(p_campaign_id uuid, p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_c public.campaigns; v_paid boolean; v_start timestamptz;
begin
  select * into v_c from public.campaigns where id = p_campaign_id for update;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  select exists (select 1 from public.orders o where o.id = v_c.order_id and o.status = 'paid') into v_paid;
  if p_action = 'approve' then
    if v_c.status <> 'pending_review' or not v_paid then
      perform public.app_error('CSW09', 'CAMPAIGN_NOT_APPROVABLE', 'Only paid campaigns awaiting review can be approved.');
    end if;
    v_start := greatest(now(), (v_c.requested_start::timestamp at time zone 'Asia/Jakarta'));
    update public.campaigns set status = 'active', approved_by = v_admin, approved_at = now(),
           starts_at = v_start, ends_at = v_start + make_interval(days => v_c.duration_days), moderation_reason = p_reason
     where id = p_campaign_id;
  elsif p_action = 'reject' and v_c.status in ('pending_review','draft') then
    update public.campaigns set status = 'rejected', moderation_reason = p_reason where id = p_campaign_id;
  elsif p_action = 'pause' and v_c.status = 'active' then
    update public.campaigns set status = 'paused', moderation_reason = p_reason where id = p_campaign_id;
  elsif p_action = 'resume' and v_c.status = 'paused' and v_paid then
    update public.campaigns set status = 'active', moderation_reason = p_reason where id = p_campaign_id;
  elsif p_action = 'cancel' and v_c.status in ('active','paused','pending_review') then
    update public.campaigns set status = 'canceled', moderation_reason = p_reason where id = p_campaign_id;
  else
    perform public.app_error('CSW09', 'INVALID_CAMPAIGN_ACTION', 'That action is not valid for the campaign''s current status.');
  end if;
  perform public.audit('campaign.' || p_action, 'campaign', p_campaign_id::text, p_reason,
    jsonb_build_object('from', v_c.status, 'paid', v_paid));
  return (select jsonb_build_object('id', id, 'status', status, 'starts_at', starts_at, 'ends_at', ends_at)
            from public.campaigns where id = p_campaign_id);
end $$;

create or replace function public.admin_upsert_location(p_level text, p_id text, p_parent text, p_name text,
  p_short_name text default null, p_enabled boolean default true, p_kind text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id text;
begin
  perform public.require_admin();
  if coalesce(btrim(p_name), '') = '' then perform public.app_error('CSW40', 'NAME_REQUIRED'); end if;
  if p_level = 'country' then
    insert into public.countries (code, name, enabled) values (upper(p_id), p_name, coalesce(p_enabled, true))
    on conflict (code) do update set name = excluded.name, enabled = excluded.enabled;
    v_id := upper(p_id);
  elsif p_level = 'region' then
    if p_id is null then
      insert into public.regions (country_code, name, kind, enabled)
      values (upper(p_parent), p_name, coalesce(p_kind, 'province'), coalesce(p_enabled, true)) returning id::text into v_id;
    else
      update public.regions set name = p_name, kind = coalesce(p_kind, kind), enabled = coalesce(p_enabled, enabled)
       where id = p_id::uuid returning id::text into v_id;
    end if;
  elsif p_level = 'city' then
    if p_id is null then
      insert into public.cities (region_id, name, enabled) values (p_parent::uuid, p_name, coalesce(p_enabled, true))
      returning id::text into v_id;
    else
      update public.cities set name = p_name, enabled = coalesce(p_enabled, enabled) where id = p_id::uuid returning id::text into v_id;
    end if;
  elsif p_level = 'campus' then
    if p_id is null then
      insert into public.campuses (city_id, name, short_name, enabled)
      values (p_parent::uuid, p_name, p_short_name, coalesce(p_enabled, true)) returning id::text into v_id;
    else
      update public.campuses set name = p_name, short_name = p_short_name, enabled = coalesce(p_enabled, enabled)
       where id = p_id::uuid returning id::text into v_id;
    end if;
  else
    perform public.app_error('CSW40', 'INVALID_LEVEL');
  end if;
  if v_id is null then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  perform public.audit('location.upsert', p_level, v_id, null, jsonb_build_object('name', p_name, 'enabled', p_enabled));
  return jsonb_build_object('level', p_level, 'id', v_id);
end $$;

create or replace function public.admin_list_announcements() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(to_jsonb(a) order by a.pinned desc, a.created_at desc) from public.announcements a), '[]');
end $$;

create or replace function public.admin_upsert_announcement(p_id uuid, p_title text, p_body text, p_pinned boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin(); v_id uuid;
begin
  if p_id is null then
    insert into public.announcements (title, body, pinned, created_by) values (btrim(p_title), btrim(p_body), coalesce(p_pinned, false), v_admin)
    returning id into v_id;
  else
    update public.announcements set title = btrim(p_title), body = btrim(p_body), pinned = coalesce(p_pinned, pinned)
     where id = p_id returning id into v_id;
    if v_id is null then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  end if;
  perform public.audit('announcement.upsert', 'announcement', v_id::text);
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.admin_set_announcement_status(p_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_admin();
  if p_status not in ('draft','published','archived') then perform public.app_error('CSW40', 'INVALID_STATUS'); end if;
  update public.announcements set status = p_status,
         published_at = case when p_status = 'published' then coalesce(published_at, now()) else published_at end
   where id = p_id;
  if not found then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  perform public.audit('announcement.' || p_status, 'announcement', p_id::text);
  return jsonb_build_object('id', p_id, 'status', p_status);
end $$;

create or replace function public.admin_list_referrals(p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select a.referred_user_id, rp.display_name as referred_name, a.referrer_id, fp.display_name as referrer_name,
           a.code, a.status, a.reject_reason, a.created_at, a.qualified_at,
           c.id as credit_id, c.status as credit_status
      from public.referral_attributions a
      left join public.profiles rp on rp.id = a.referred_user_id
      left join public.profiles fp on fp.id = a.referrer_id
      left join public.credits c on c.source = 'referral' and c.source_ref = a.referred_user_id
     order by a.created_at desc limit least(greatest(p_limit, 1), 500)) x), '[]'::jsonb);
end $$;

create or replace function public.admin_revoke_credit(p_credit_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.require_admin();
begin
  if coalesce(btrim(p_reason), '') = '' then perform public.app_error('CSW40', 'REASON_REQUIRED'); end if;
  update public.credits set status = 'revoked', revoked_at = now(), revoked_by = v_admin, revoked_reason = p_reason
   where id = p_credit_id and status = 'available';
  if not found then
    perform public.app_error('CSW09', 'CREDIT_NOT_REVOCABLE', 'Only unredeemed, unreserved credits can be revoked.');
  end if;
  perform public.audit('credit.revoke', 'credit', p_credit_id::text, p_reason);
  return jsonb_build_object('id', p_credit_id, 'status', 'revoked');
end $$;

create or replace function public.admin_audit_entries(p_limit int default 100, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.id desc) from (
    select l.id, l.actor_id, p.display_name as actor_name, l.action, l.target_type, l.target_id, l.reason, l.details, l.created_at
      from public.admin_audit_log l left join public.profiles p on p.id = l.actor_id
     order by l.id desc limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0)) x), '[]'::jsonb);
end $$;

create or replace function public.admin_leaderboard_diagnostics() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'qualified_referrals', (select count(*) from public.referral_attributions where status = 'qualified'),
    'revoked_credits', (select count(*) from public.credits where status = 'revoked'),
    'opted_in_donors', (select count(*) from public.profiles where donor_recognition),
    'successful_donations', (select count(*) from public.orders where kind = 'donation' and status in ('paid','partially_refunded')),
    'published_account_notes', (select count(*) from public.notes where status = 'published' and author_id is not null));
end $$;

-- Revenue report. All amounts are rupiah strings. Definitions are returned
-- with the data so the dashboard never has to guess what a number means.
create or replace function public.admin_revenue_report(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform public.require_admin();
  with settled as (
    select * from public.orders
     where paid_at >= p_from and paid_at < p_to and status in ('paid','partially_refunded','refunded','reversed')
  ), sessions as (
    select * from public.orders
     where created_at >= p_from and created_at < p_to and payment_session_token is not null
  ), pubs as (
    select * from public.orders
     where kind = 'publication' and status in ('paid','partially_refunded','refunded','reversed','completed_free')
       and coalesce(paid_at, closed_at) >= p_from and coalesce(paid_at, closed_at) < p_to
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'publication_revenue', (select coalesce(sum(publication_amount - discount_amount), 0)::text from settled where kind = 'publication'),
    'decoration_revenue', (select coalesce(sum(decorations_amount), 0)::text from settled where kind = 'publication'),
    'donations', (select coalesce(sum(total_amount), 0)::text from settled where kind = 'donation'),
    'advertising_revenue', (select coalesce(sum(total_amount), 0)::text from settled where kind = 'advertising'),
    'gross_payment_volume', (select coalesce(sum(total_amount), 0)::text from settled),
    'refunds_and_reversals', (select coalesce(sum(refunded_amount), 0)::text from settled),
    'net_collected', (select coalesce(sum(total_amount - refunded_amount), 0)::text from settled),
    'credit_discounts_given', (select coalesce(sum(discount_amount), 0)::text from pubs),
    'processing_fees', null,
    'paid_orders', (select count(*) from settled),
    'average_order_value', (select case when count(*) = 0 then '0' else (sum(total_amount) / count(*))::bigint::text end from settled),
    'free_publications', (select count(*) from pubs where status = 'completed_free'),
    'checkout_sessions', (select count(*) from sessions),
    'checkout_completion_rate', (select case when count(*) filter (where status <> 'awaiting_payment') = 0 then null
        else round(count(*) filter (where status in ('paid','partially_refunded','refunded','reversed'))::numeric
                   / count(*) filter (where status <> 'awaiting_payment'), 4) end from sessions),
    'decoration_attachment_rate', (select case when count(*) = 0 then null
        else round(count(*) filter (where decorations_amount > 0)::numeric / count(*), 4) end from pubs),
    'credits_issued', (select count(*) from public.credits where created_at >= p_from and created_at < p_to),
    'credits_redeemed', (select count(*) from public.credits where redeemed_at >= p_from and redeemed_at < p_to),
    'campaign_impressions', (select coalesce(sum(impressions), 0) from public.campaign_daily_stats
                              where day >= (p_from at time zone 'Asia/Jakarta')::date and day < (p_to at time zone 'Asia/Jakarta')::date),
    'campaign_clicks', (select coalesce(sum(clicks), 0) from public.campaign_daily_stats
                         where day >= (p_from at time zone 'Asia/Jakarta')::date and day < (p_to at time zone 'Asia/Jakarta')::date),
    'campaign_renewals', (select count(*) from settled s where s.kind = 'advertising' and exists (
        select 1 from public.orders e where e.kind = 'advertising' and e.user_id = s.user_id and e.paid_at < s.paid_at
          and e.status in ('paid','partially_refunded','refunded','reversed'))),
    'definitions', jsonb_build_object(
      'publication_revenue', 'Sum of customer-selected publication amounts minus referral-credit discounts, for orders paid in the period (includes later-refunded orders; see refunds_and_reversals).',
      'gross_payment_volume', 'Total amount of all orders paid through Midtrans in the period.',
      'net_collected', 'Gross payment volume minus refunds and chargebacks. Not profit: processing fees and costs are not deducted.',
      'processing_fees', 'Not available from payment notifications. Reconcile from Midtrans settlement reports.',
      'checkout_completion_rate', 'Of payment sessions created in the period that reached a final state, the share that were paid.',
      'decoration_attachment_rate', 'Share of completed publications (paid or free) that included at least one paid decoration.',
      'campaign_impressions', 'Client-reported, approximate impression counts.'))
  into v;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Function EXECUTE allowlist. Supabase grants EXECUTE on new public functions
-- to anon/authenticated by default; revoke everything, then grant back only
-- what clients may call. Every other function is service_role only.
-- Future migrations that add functions MUST repeat this pattern.
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

-- Needed by RLS policies, CHECK constraints and invoker-rights triggers.
grant execute on function public.is_suspended(uuid), public.is_allowed_social_url(text),
  public.app_error(text, text, text),
  public.note_is_published(uuid), public.note_visible_to(uuid, uuid), public.note_is_votable(uuid, uuid),
  public.order_owned_by(uuid, uuid)
  to anon, authenticated;

-- Public read/measurement API.
grant execute on function public.quote_publication(text, text[], boolean),
  public.get_wall(text, uuid, int, int),
  public.get_promotions(text, uuid, uuid, uuid, text, text, int),
  public.record_campaign_event(uuid, text),
  public.eligible_payment_methods(bigint)
  to anon, authenticated;

-- Signed-in user API.
grant execute on function public.my_notes(), public.my_bookmarks(), public.my_referral_summary(),
  public.leaderboard(text, text, int) to authenticated;

-- Admin API: callable by signed-in users, each function enforces require_admin().
grant execute on function
  public.admin_overview(), public.admin_list_notes(text, int, int), public.admin_moderate_note(uuid, text, text),
  public.admin_list_reports(text, int), public.admin_resolve_report(uuid, text, text),
  public.admin_list_users(text, int, int), public.admin_set_user_suspension(uuid, boolean, text),
  public.admin_upsert_decoration(text, text, text, text, boolean, int), public.admin_list_catalog(),
  public.admin_upsert_payment_method(text, text, text[], text, text, boolean, int),
  public.admin_upsert_ad_product(text, text, text, text, int, text, boolean, int),
  public.admin_set_config(text, jsonb), public.admin_list_orders(text, text, boolean, int, int),
  public.admin_order_detail(text), public.admin_clear_order_review(text, text),
  public.admin_list_campaigns(text), public.admin_review_campaign(uuid, text, text),
  public.admin_upsert_location(text, text, text, text, text, boolean, text),
  public.admin_list_announcements(), public.admin_upsert_announcement(uuid, text, text, boolean),
  public.admin_set_announcement_status(uuid, text), public.admin_list_referrals(int),
  public.admin_revoke_credit(uuid, text), public.admin_audit_entries(int, int),
  public.admin_leaderboard_diagnostics(), public.admin_revenue_report(timestamptz, timestamptz)
  to authenticated;

-- Storage bucket for campaign creatives (Supabase only; skipped on plain Postgres).
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'storage' and c.relname = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('campaign-creatives', 'campaign-creatives', true, 1048576, array['image/png','image/jpeg','image/webp'])
    on conflict (id) do nothing;
    execute $p$create policy "creative upload own folder" on storage.objects for insert to authenticated
      with check (bucket_id = 'campaign-creatives' and (storage.foldername(name))[1] = (select auth.uid())::text)$p$;
    execute $p$create policy "creative read" on storage.objects for select to anon, authenticated
      using (bucket_id = 'campaign-creatives')$p$;
  end if;
end $$;
