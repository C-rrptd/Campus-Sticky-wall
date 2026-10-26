-- 023: store notes.author_id again (private). Reverses the author_id clearing of 012 for new posts.
--      Enables "(You)" on own notes and the self-vote block. Guests still have no owner. Not backfillable:
--      orders.user_id was cleared at fulfilment, so notes posted since 012 stay ownerless.

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
  -- 023: keep the poster as the private owner (own-note marker, no self-vote). author_id is not column-readable by clients and never appears in note_json.
  update public.notes set author_id = p_user_id
   where p_user_id is not null and order_id = (select id from public.orders where order_ref = v ->> 'order_ref');
  return v;
end $$;
