-- Applies on top of 035. Idempotent.
-- 036 — Security hardening:
--  * Storage: anonymous clients could LIST every object (user ids + file names) in the two public buckets. Public
--    bucket files are served from /object/public/ without any policy, so the anon SELECT policies are not needed for
--    display. Authenticated users keep SELECT on their OWN folder only; the upload quota policies (count of own
--    objects in the last hour) read storage.objects as the caller and need exactly that.
--  * join_ad_waitlist: rate limit keyed on the first x-forwarded-for entry, which a client can set. Use cf-connecting-ip,
--    else the LAST x-forwarded-for entry (added by the proxy), the same rule as clientIp() in the Edge Functions.

do $$ begin
  if to_regclass('storage.objects') is not null then
    drop policy if exists "note media read" on storage.objects;
    drop policy if exists "creative read" on storage.objects;
    drop policy if exists "note media read own" on storage.objects;
    drop policy if exists "creative read own" on storage.objects;
    execute $p$create policy "note media read own" on storage.objects for select to authenticated
      using (bucket_id = 'note-media' and (storage.foldername(name))[1] = (select auth.uid())::text)$p$;
    execute $p$create policy "creative read own" on storage.objects for select to authenticated
      using (bucket_id = 'campaign-creatives' and (storage.foldername(name))[1] = (select auth.uid())::text)$p$;
  end if;
end $$;

create or replace function public.join_ad_waitlist(p_email text, p_spot text, p_scope_level text, p_target_key text, p_duration int,
  p_max_budget bigint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_h jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
        v_ip text := coalesce(nullif(btrim(v_h ->> 'cf-connecting-ip'), ''), nullif(btrim(regexp_replace(v_h ->> 'x-forwarded-for', '^.*,', '')), ''), 'none');
        v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.check_rate_limit('waitlist:' || public.visitor_hash(v_ip, ''), 10, 3600)
     or not public.check_rate_limit('waitlist:all', 300, 3600) then
    perform public.app_error('CSW29', 'RATE_LIMITED', 'Too many requests. Try again later.');
  end if;
  if v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 200 then
    perform public.app_error('CSW40', 'INVALID_EMAIL', 'Enter a valid email address.');
  end if;
  if p_spot not in ('featured','random') or p_scope_level not in ('global','country','region','city','campus')
     or p_duration is null or p_duration not between 1 and 365 then
    perform public.app_error('CSW40', 'INVALID_WAITLIST', 'Choose a placement, reach and duration.');
  end if;
  if p_max_budget is not null and p_max_budget < 1 then
    perform public.app_error('CSW40', 'INVALID_BUDGET', 'Maximum budget must be more than zero, or empty.');
  end if;
  insert into public.ad_waitlist (email, user_id, spot, scope_level, target_key, desired_duration, max_budget)
  values (v_email, (select auth.uid()), p_spot, p_scope_level, nullif(p_target_key, ''), p_duration, p_max_budget)
  on conflict (lower(email), spot, scope_level, coalesce(target_key, ''), desired_duration) where status = 'waiting'
  do update set max_budget = excluded.max_budget;
  return jsonb_build_object('ok', true);
end $$;


