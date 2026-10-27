-- 027 — Leaderboards are public: guests (anon) may read them. v_uid stays null for guests, so is_me is false.
-- Same body as 008 minus the sign-in guard. Names shown are display names only; donors still need donor_recognition.

create or replace function public.leaderboard(p_kind text, p_period text default 'all', p_limit int default 25)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_since timestamptz;
  v_limit int := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_rows jsonb;
  v_me jsonb;
begin
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
                    'value', r.value::text, 'is_me', coalesce(r.user_id = v_uid, false)) order by r.rank, r.display_name), '[]'::jsonb)
    into v_rows
    from (select * from ranked order by rank, display_name limit v_limit) r;

  return jsonb_build_object('kind', p_kind, 'period', p_period, 'since', case when p_period = 'week' then v_since end,
                            'timezone', 'Asia/Jakarta', 'rows', v_rows);
end $$;

grant execute on function public.leaderboard(text, text, int) to anon, authenticated;
