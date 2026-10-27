-- 025: performance (idempotent).
--  1. get_wall: pinned notes are fetched separately (a tiny set) and the rest are ordered by plain
--     indexed columns, so notes_published_idx / notes_top_idx serve the page instead of a full sort.
--  2. record_campaign_event: stops updating the hot campaigns row; campaign_daily_stats is the one
--     source of truth. campaigns.impressions/clicks stay in the table, frozen at their old values.
--     Readers sum campaign_daily_stats instead (admin_list_campaigns below, advertise.js).

-- 1 ---------------------------------------------------------------------------------------------
create or replace function public.get_wall(p_sort text default 'newest', p_campus uuid default null,
  p_limit int default 24, p_offset int default 0, p_q text default null, p_color text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_viewer uuid := auth.uid();
  v_limit int := least(greatest(coalesce(p_limit, 24), 1), 50);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_q text := nullif(btrim(left(coalesce(p_q, ''), 60)), '');
  v_like text := case when v_q is null then null
    else '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
  v_pinned_n int := 0;
  v_a jsonb := '[]'::jsonb;  -- pinned part of the page
  v_b jsonb := '[]'::jsonb;  -- the rest
begin
  if p_sort not in ('newest','top') then
    perform public.app_error('CSW40', 'INVALID_SORT');
  end if;
  if p_color is not null and p_color not in ('yellow','pink','blue','green','orange','purple') then
    perform public.app_error('CSW40', 'INVALID_COLOR');
  end if;
  if v_offset > 5000 then return '[]'::jsonb; end if;  -- the client stops paging at 5000

  -- Full order = pinned notes (newest sort only), then everything else.
  if p_sort = 'newest' then
    select count(*) into v_pinned_n from public.notes n
     where n.status = 'published' and n.pin_until > now()
       and (p_campus is null or n.campus_id = p_campus) and (p_color is null or n.color = p_color)
       and (v_like is null or n.body ilike v_like escape '\' or n.author_name ilike v_like escape '\');
    select coalesce(jsonb_agg(public.note_json(n, v_viewer) order by n.published_at desc, n.id), '[]'::jsonb) into v_a
      from (select * from public.notes n
             where n.status = 'published' and n.pin_until > now()
               and (p_campus is null or n.campus_id = p_campus) and (p_color is null or n.color = p_color)
               and (v_like is null or n.body ilike v_like escape '\' or n.author_name ilike v_like escape '\')
             order by n.published_at desc, n.id limit v_limit offset v_offset) n;
  end if;

  if jsonb_array_length(v_a) < v_limit then
    if p_sort = 'newest' then
      select coalesce(jsonb_agg(public.note_json(n, v_viewer) order by n.published_at desc, n.id), '[]'::jsonb) into v_b
        from (select * from public.notes n
               where n.status = 'published' and (n.pin_until is null or n.pin_until <= now())
                 and (p_campus is null or n.campus_id = p_campus) and (p_color is null or n.color = p_color)
                 and (v_like is null or n.body ilike v_like escape '\' or n.author_name ilike v_like escape '\')
               order by n.published_at desc, n.id
               limit v_limit - jsonb_array_length(v_a) offset greatest(v_offset - v_pinned_n, 0)) n;
    else
      select coalesce(jsonb_agg(public.note_json(n, v_viewer) order by n.vote_count desc, n.published_at desc, n.id), '[]'::jsonb) into v_b
        from (select * from public.notes n
               where n.status = 'published'
                 and (p_campus is null or n.campus_id = p_campus) and (p_color is null or n.color = p_color)
                 and (v_like is null or n.body ilike v_like escape '\' or n.author_name ilike v_like escape '\')
               order by n.vote_count desc, n.published_at desc, n.id
               limit v_limit offset v_offset) n;
    end if;
  end if;
  return v_a || v_b;
end $$;

-- 2 ---------------------------------------------------------------------------------------------
create or replace function public.record_campaign_event(p_campaign_id uuid, p_kind text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_c public.campaigns;
begin
  if p_kind not in ('impression','click') then
    perform public.app_error('CSW40', 'INVALID_EVENT');
  end if;
  select * into v_c from public.campaigns where id = p_campaign_id;
  if not found or not public.campaign_is_live(v_c) then
    return;
  end if;
  if not public.check_rate_limit('campaign-event:' || p_kind || ':' || p_campaign_id::text,
                                 case p_kind when 'click' then 30 else 300 end, 60) then
    return;
  end if;
  insert into public.campaign_daily_stats (campaign_id, day, impressions, clicks)
  values (p_campaign_id, (now() at time zone 'Asia/Jakarta')::date,
          (p_kind = 'impression')::int, (p_kind = 'click')::int)
  on conflict (campaign_id, day) do update
    set impressions = public.campaign_daily_stats.impressions + excluded.impressions,
        clicks = public.campaign_daily_stats.clicks + excluded.clicks;
end $$;

-- Same as 013 except impressions/clicks are summed from campaign_daily_stats (campaigns.* is frozen now).
create or replace function public.admin_list_campaigns(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select c.id, c.title, c.description, c.advertiser_name, c.contact_email, c.category, c.placement, c.scope_level,
           c.duration_days, c.destination_url, c.creative_path, c.status, c.requested_start, c.starts_at, c.ends_at,
           c.price_snapshot::text as price,
           (select coalesce(sum(s.impressions), 0) from public.campaign_daily_stats s where s.campaign_id = c.id) as impressions,
           (select coalesce(sum(s.clicks), 0) from public.campaign_daily_stats s where s.campaign_id = c.id) as clicks,
           c.created_at, c.moderation_reason,
           o.status as payment_status, o.order_ref,
           (select jsonb_agg(t.target_key) from public.campaign_targets t where t.campaign_id = c.id) as targets
      from public.campaigns c left join public.orders o on o.id = c.order_id
     where p_status is null or c.status = p_status
     order by c.created_at desc limit 200) x), '[]'::jsonb);
end $$;

-- Totals for the advertiser's own campaigns. SECURITY INVOKER: campaign_stats_owner_read (RLS) limits
-- the rows to campaigns the caller owns, so ids belonging to others simply return nothing.
create or replace function public.campaign_totals(p_ids uuid[])
returns table (campaign_id uuid, impressions bigint, clicks bigint)
language sql stable security invoker set search_path = '' as $$
  select s.campaign_id, sum(s.impressions)::bigint, sum(s.clicks)::bigint
    from public.campaign_daily_stats s
   where s.campaign_id = any (p_ids[1:50])
   group by s.campaign_id
$$;
revoke execute on function public.campaign_totals(uuid[]) from public, anon;
grant execute on function public.campaign_totals(uuid[]) to authenticated;
