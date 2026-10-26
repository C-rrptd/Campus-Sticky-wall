-- 021: polls (single / multiple choice), quizzes, and a Spotify embed on notes.
-- notes.poll        {"kind":"poll|quiz","multi":bool,"options":["…"]} (2-6 options, 0-based indexes below)
-- notes.poll_answer correct option indexes of a quiz. Not exposed to clients: select on notes is column-granted
--                   (005) and note_json only reveals it to a viewer who already answered.
-- notes.spotify     "<type>/<22 char id>"; the frontend builds the open.spotify.com/embed URL from it.
-- poll_votes        one row per (note, account). No policies and no grants: only answer_poll() writes it.
-- Idempotent: safe to re-apply.

alter table public.notes add column if not exists poll jsonb;
alter table public.notes add column if not exists poll_answer int[];
alter table public.notes add column if not exists spotify text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'notes_spotify_format') then
    alter table public.notes add constraint notes_spotify_format
      check (spotify is null or spotify ~ '^(track|album|playlist|episode|show)/[A-Za-z0-9]{22}$');
  end if;
end $$;

create table if not exists public.poll_votes (
  note_id uuid not null references public.notes (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  choices int[] not null,
  created_at timestamptz not null default now(),
  primary key (note_id, user_id)
);
alter table public.poll_votes enable row level security;
revoke all on public.poll_votes from anon, authenticated;

-- Returns {poll, answer}; raises on anything malformed (trust boundary). Null in, nulls out.
create or replace function public.validate_poll(p_poll jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  v_kind text; v_multi boolean; v_opts text[] := '{}'; v_o jsonb; v_t text; v_n int; v_ans int[];
begin
  if p_poll is null or p_poll = 'null'::jsonb then return jsonb_build_object('poll', null, 'answer', null); end if;
  v_kind := p_poll ->> 'kind';
  if jsonb_typeof(p_poll) <> 'object' or v_kind not in ('poll', 'quiz')
     or jsonb_typeof(p_poll -> 'options') <> 'array' or jsonb_typeof(coalesce(p_poll -> 'multi', 'false'::jsonb)) <> 'boolean' then
    perform public.app_error('CSW40', 'INVALID_POLL', 'Invalid poll.');
  end if;
  v_multi := coalesce((p_poll ->> 'multi')::boolean, false);
  v_n := jsonb_array_length(p_poll -> 'options');
  if v_n not between 2 and 6 then
    perform public.app_error('CSW40', 'INVALID_POLL', 'A poll needs 2 to 6 options.');
  end if;
  for v_o in select * from jsonb_array_elements(p_poll -> 'options') loop
    if jsonb_typeof(v_o) <> 'string' then perform public.app_error('CSW40', 'INVALID_POLL', 'Invalid poll option.'); end if;
    v_t := btrim(v_o #>> '{}');
    if char_length(v_t) not between 1 and 80 or public.has_control_chars(v_t) or lower(v_t) = any (v_opts) then
      perform public.app_error('CSW40', 'INVALID_POLL', 'Options must be 1-80 characters and different from each other.');
    end if;
    v_opts := v_opts || lower(v_t);
  end loop;
  if v_kind = 'quiz' then
    if jsonb_typeof(p_poll -> 'correct') <> 'array' then
      perform public.app_error('CSW40', 'INVALID_POLL', 'Mark the correct answer.');
    end if;
    select array_agg(distinct x::int order by x::int) into v_ans from jsonb_array_elements_text(p_poll -> 'correct') x
     where x ~ '^[0-9]$' and x::int < v_n;
    if v_ans is null or cardinality(v_ans) <> jsonb_array_length(p_poll -> 'correct')
       or (not v_multi and cardinality(v_ans) <> 1) then
      perform public.app_error('CSW40', 'INVALID_POLL', 'Mark the correct answer (exactly one unless multiple answers are allowed).');
    end if;
  end if;
  return jsonb_build_object(
    'poll', jsonb_build_object('kind', v_kind, 'multi', v_multi,
      'options', (select jsonb_agg(btrim(o #>> '{}')) from jsonb_array_elements(p_poll -> 'options') o)),
    'answer', to_jsonb(v_ans));
end $$;

-- What a viewer may see of a note's poll. A quiz hides counts and the answer until the viewer has answered.
create or replace function public.poll_json(n public.notes, p_viewer uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with m as (select v.choices from public.poll_votes v where v.note_id = n.id and v.user_id = p_viewer)
  select case when n.poll is null then null else
    n.poll || jsonb_build_object('mine', (select to_jsonb(choices) from m))
           || case when n.poll ->> 'kind' = 'poll' or exists (select 1 from m) then jsonb_build_object(
                'total', (select count(*) from public.poll_votes v where v.note_id = n.id),
                'counts', (select jsonb_agg((select count(*) from public.poll_votes v where v.note_id = n.id and g.i = any (v.choices)) order by g.i)
                             from generate_series(0, jsonb_array_length(n.poll -> 'options') - 1) g(i)))
              else '{}'::jsonb end
           || case when n.poll ->> 'kind' = 'quiz' and exists (select 1 from m) then jsonb_build_object('correct', to_jsonb(n.poll_answer))
              else '{}'::jsonb end
  end
$$;

create or replace FUNCTION public.note_json(n notes, p_viewer uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
  select jsonb_build_object(
    'id', n.id, 'author_name', n.author_name, 'body', n.body, 'color', n.color,
    'social_link', n.social_link,
    'amount', case when n.show_amount then n.publication_amount::text end,
    'vote_count', n.vote_count, 'published_at', n.published_at, 'campus_id', n.campus_id, 'media', n.media,
    'poll', public.poll_json(n, p_viewer), 'spotify', n.spotify,
    'decorations', coalesce((select jsonb_agg(d.decoration_id order by d.decoration_id, d.id)
                             from public.note_decorations d where d.note_id = n.id), '[]'::jsonb),
    'stickers', coalesce((select jsonb_agg(jsonb_build_object('id', d.decoration_id,
                                   'x', coalesce(d.pos_x, c.default_x), 'y', coalesce(d.pos_y, c.default_y), 'rot', d.rot) order by d.id)
                            from public.note_decorations d join public.decorations c on c.id = d.decoration_id
                           where d.note_id = n.id and c.placeable), '[]'::jsonb),
    'placements', coalesce((select jsonb_object_agg(d.decoration_id, jsonb_build_object('x', coalesce(d.pos_x, c.default_x), 'y', coalesce(d.pos_y, c.default_y), 'rot', d.rot))
                              from public.note_decorations d join public.decorations c on c.id = d.decoration_id
                             where d.note_id = n.id and c.placeable), '{}'::jsonb),
    'voted', p_viewer is not null and exists (select 1 from public.votes v where v.note_id = n.id and v.user_id = p_viewer),
    'bookmarked', p_viewer is not null and exists (select 1 from public.bookmarks b where b.note_id = n.id and b.user_id = p_viewer),
    'is_mine', p_viewer is not null and n.author_id = p_viewer)
$$;

-- Answer a poll / quiz once, signed in. Returns the viewer's view of the poll (counts, and the answer for quizzes).
create or replace function public.answer_poll(p_note uuid, p_choices int[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); n public.notes; v_n int;
begin
  if v_uid is null then perform public.app_error('CSW03', 'ACCOUNT_REQUIRED', 'Sign in to answer.'); end if;
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

-- Single entry point used by create-publication: v2 plus the poll and Spotify link, in one transaction.
create or replace function public.create_publication_order_v3(
  p_user_id uuid, p_author_name text, p_body text, p_color text, p_social_link text, p_show_amount boolean,
  p_amount text, p_decorations text[], p_use_credit boolean, p_guest_token_hash text, p_campus_id uuid,
  p_media jsonb, p_use_post_credit boolean, p_deco_credits int, p_positions jsonb,
  p_promo text, p_use_free_post boolean, p_confirmed boolean,
  p_poll jsonb, p_spotify text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_p jsonb := public.validate_poll(p_poll);
  v_sp text := nullif(btrim(coalesce(p_spotify, '')), '');
  v jsonb;
begin
  if v_sp is not null and v_sp !~ '^(track|album|playlist|episode|show)/[A-Za-z0-9]{22}$' then
    perform public.app_error('CSW40', 'INVALID_SPOTIFY', 'That is not a Spotify track, album, playlist, episode or show link.');
  end if;
  v := public.create_publication_order_v2(p_user_id, p_author_name, p_body, p_color, p_social_link, p_show_amount,
         p_amount, p_decorations, p_use_credit, p_guest_token_hash, p_campus_id, p_media,
         p_use_post_credit, p_deco_credits, p_positions, p_promo, p_use_free_post, p_confirmed);
  update public.notes
     set poll = nullif(v_p -> 'poll', 'null'::jsonb), poll_answer = case when jsonb_typeof(v_p -> 'answer') = 'array' then array(select jsonb_array_elements_text(v_p -> 'answer')::int) end,
         spotify = v_sp
   where order_id = (select id from public.orders where order_ref = v ->> 'order_ref');
  return v;
end $$;

revoke execute on function public.validate_poll(jsonb), public.poll_json(public.notes, uuid),
  public.answer_poll(uuid, int[]),
  public.create_publication_order_v3(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid, jsonb, boolean, int, jsonb, text, boolean, boolean, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.create_publication_order_v3(uuid, text, text, text, text, boolean, text, text[], boolean, text, uuid, jsonb, boolean, int, jsonb, text, boolean, boolean, jsonb, text) to service_role;
grant execute on function public.answer_poll(uuid, int[]) to authenticated;
