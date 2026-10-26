-- 022: security hardening (idempotent).
--  1. answer_poll: verified email, not suspended, 30 answers/min per member (stops multi-account / scripted vote farming).
--  2. campaign-creatives: at most 20 uploaded files per member folder (storage abuse).

create or replace function public.answer_poll(p_note uuid, p_choices int[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); n public.notes; v_n int;
begin
  if v_uid is null then perform public.app_error('CSW03', 'ACCOUNT_REQUIRED', 'Sign in to answer.'); end if;
  if public.is_suspended(v_uid) then perform public.app_error('CSW03', 'ACCOUNT_SUSPENDED', 'This account is suspended.'); end if;
  if not exists (select 1 from auth.users u where u.id = v_uid and u.email_confirmed_at is not null) then
    perform public.app_error('CSW03', 'EMAIL_NOT_VERIFIED', 'Verify your email to answer polls.');
  end if;
  if not public.check_rate_limit('answer-poll:' || v_uid::text, 30, 60) then
    perform public.app_error('CSW29', 'RATE_LIMITED', 'Slow down a little.');
  end if;
  select * into n from public.notes where id = p_note and status = 'published' and poll is not null;
  if not found then perform public.app_error('CSW40', 'INVALID_POLL', 'This poll does not exist.'); end if;
  v_n := jsonb_array_length(n.poll -> 'options');
  if p_choices is null or cardinality(p_choices) = 0 or cardinality(p_choices) > v_n
     or exists (select 1 from unnest(p_choices) c where c is null or c < 0 or c >= v_n)
     or cardinality(p_choices) <> (select count(distinct c) from unnest(p_choices) c)
     or (not (n.poll ->> 'multi')::boolean and cardinality(p_choices) <> 1) then
    perform public.app_error('CSW40', 'INVALID_POLL', 'Pick a valid answer.');
  end if;
  insert into public.poll_votes (note_id, user_id, choices)
  values (p_note, v_uid, (select array_agg(c order by c) from unnest(p_choices) c))
  on conflict do nothing;
  if not found then perform public.app_error('CSW09', 'ALREADY_ANSWERED', 'You already answered this one.'); end if;
  return public.poll_json(n, v_uid);
end $$;

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'storage' and c.relname = 'objects') then
    execute 'drop policy if exists "creative upload own folder" on storage.objects';
    execute $p$create policy "creative upload own folder" on storage.objects for insert to authenticated
      with check (bucket_id = 'campaign-creatives' and (storage.foldername(name))[1] = (select auth.uid())::text
        and (select count(*) from storage.objects o
              where o.bucket_id = 'campaign-creatives' and (storage.foldername(o.name))[1] = (select auth.uid())::text) < 20)$p$;
  end if;
end $$;
