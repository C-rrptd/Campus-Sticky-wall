-- 008_part1_followups.sql
-- Follow-ups to 006/007. Additive; safe to re-run.
--   1. owner_delete_preview: what an Owner delete would also remove (shown in the confirm dialog)
--   2. Leaderboard keeps counting qualified referrals whose entry the Owner deleted (tombstones)
--   3. News list returns the last editor's display name

create or replace function public.owner_delete_preview(p_kind text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_fx text[] := '{}'; v_n bigint; v_s text; v_o text;
begin
  perform public.require_owner();
  if p_kind not in ('report','note','announcement','campaign','referral','audit_entry','country','region','city','campus') then
    perform public.app_error('CSW40', 'INVALID_KIND');
  end if;
  if p_kind not in ('country', 'audit_entry')
     and p_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    perform public.app_error('CSW40', 'INVALID_ID');
  end if;
  if p_kind = 'note' then
    select count(*) into v_n from public.reports where note_id = p_id::uuid;
    v_fx := v_fx || format('%s report(s) on this note will be removed with it.', v_n);
    select count(*) into v_n from public.votes where note_id = p_id::uuid;
    v_fx := v_fx || format('%s vote(s) will be removed.', v_n);
    select count(*) into v_n from public.bookmarks where note_id = p_id::uuid;
    v_fx := v_fx || format('%s bookmark(s) will be removed.', v_n);
    select o.status into v_s from public.notes n join public.orders o on o.id = n.order_id where n.id = p_id::uuid;
    v_fx := v_fx || format('The order and payment record stay%s.', coalesce(' (status: ' || v_s || ')', ''));
  elsif p_kind = 'report' then
    v_fx := v_fx || 'The report is removed; the note itself is not changed.';
  elsif p_kind = 'announcement' then
    select status into v_s from public.announcements where id = p_id::uuid;
    v_fx := v_fx || format('Status is %s. It disappears from the News page if published.', coalesce(v_s, 'unknown'));
  elsif p_kind = 'campaign' then
    select status into v_s from public.campaigns where id = p_id::uuid;
    v_fx := v_fx || format('Status is %s; its targets and daily stats are removed. The order and payment record stay.', coalesce(v_s, 'unknown'));
    if v_s in ('active', 'awaiting_payment') then v_fx := v_fx || 'Blocked: cancel or pause the campaign first.'; end if;
  elsif p_kind = 'referral' then
    select count(*) into v_n from public.referral_credits where source_ref = p_id::uuid;
    v_fx := v_fx || format('The entry is removed but a record is kept. %s referral credit(s) already issued are NOT touched.', v_n);
  elsif p_kind = 'audit_entry' then
    v_fx := v_fx || 'The entry is removed. A permanent record of this deletion is kept in the Security log.';
  elsif p_kind = 'country' then
    select count(*) into v_n from public.regions where country_code = upper(p_id);
    v_fx := v_fx || format('%s region(s) still belong to this country; deletion is blocked until they are removed.', v_n);
  elsif p_kind = 'region' then
    select count(*) into v_n from public.cities where region_id = p_id::uuid;
    v_fx := v_fx || format('%s city(ies) still belong to this region; deletion is blocked until they are removed.', v_n);
  elsif p_kind = 'city' then
    select count(*) into v_n from public.campuses where city_id = p_id::uuid;
    v_fx := v_fx || format('%s campus(es) still belong to this city; deletion is blocked until they are removed.', v_n);
  else
    select count(*) into v_n from public.notes where campus_id = p_id::uuid;
    v_fx := v_fx || format('%s note(s) use this campus; deletion is blocked while any do.', v_n);
  end if;
  return jsonb_build_object('effects', to_jsonb(v_fx));
end $$;

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
      from (select referred_user_id, referrer_id, status, qualified_at from public.referral_attributions
            union all
            select referred_user_id, referrer_id, status, qualified_at from public.referral_tombstones
             where status = 'qualified') a
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

create or replace function public.admin_list_announcements() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(to_jsonb(a) || jsonb_build_object('updated_by_name',
            (select p.display_name from public.profiles p where p.id = a.updated_by))
          order by a.pinned desc, a.created_at desc) from public.announcements a), '[]');
end $$;

revoke execute on function public.owner_delete_preview(text, text) from public, anon, authenticated;
grant execute on function public.owner_delete_preview(text, text) to service_role, authenticated;
