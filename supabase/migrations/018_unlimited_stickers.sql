-- 018 — Raise the per-note decoration cap from 10 to 200 (a sanity ceiling, not a product limit).
-- Each copy is still priced and paid for. Redefines two functions from 017; run after 017. Idempotent.

-- 2. Quote: copies are allowed for placeable decorations only, at most 200 decorations in total.
create or replace function public.quote_publication(p_amount text, p_decorations text[] default '{}',
  p_use_credit boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_amount bigint := public.parse_amount(p_amount);
  v_min bigint := public.min_publication_price();
  v_max bigint := public.max_publication_price();
  v_decos text[] := coalesce(p_decorations, '{}');
  v_deco_total bigint; v_deco_count int; v_discount bigint := 0; v_subtotal bigint; v_total bigint;
  v_lines jsonb;
begin
  if v_amount < v_min then
    perform public.app_error('CSW40', 'PRICE_BELOW_MINIMUM', format('The minimum publication price is Rp%s.', v_min));
  end if;
  if v_amount > v_max then
    perform public.app_error('CSW40', 'PRICE_ABOVE_MAXIMUM', format('The maximum publication price is Rp%s.', v_max));
  end if;
  if cardinality(v_decos) > 200 then
    perform public.app_error('CSW40', 'TOO_MANY_DECORATIONS', 'You can add at most 200 decorations.');
  end if;
  if exists (select 1 from unnest(v_decos) as u(did) group by did having count(*) > 1
                and did not in (select id from public.decorations where placeable)) then
    perform public.app_error('CSW40', 'DUPLICATE_DECORATION', 'Only stickers, stamps and badges can be added more than once.');
  end if;
  -- join (not "id = any") so that every copy is a line and is priced
  select coalesce(sum(c.price), 0), count(*),
         coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'price', c.price::text) order by c.sort_order, c.id), '[]')
    into v_deco_total, v_deco_count, v_lines
    from unnest(v_decos) as u(did) join public.decorations c on c.id = u.did and c.enabled;
  if v_deco_count <> cardinality(v_decos) then
    perform public.app_error('CSW40', 'INVALID_DECORATION', 'A selected decoration is not available.');
  end if;
  v_subtotal := v_amount + v_deco_total;
  if p_use_credit then
    v_discount := least(public.referral_credit_value(), v_amount);
  end if;
  v_total := v_subtotal - v_discount;
  return jsonb_build_object(
    'publication_amount', v_amount::text,
    'decorations', v_lines,
    'decorations_amount', v_deco_total::text,
    'subtotal_amount', v_subtotal::text,
    'credit_discount', v_discount::text,
    'total_amount', v_total::text,
    'payment_required', v_total > 0,
    'payment_methods', public.eligible_payment_methods(v_total));
end $$;

-- 3. Positions: a list [{"id","x","y","rot"?}], one entry per copy, in the order the copies are stored.
-- The old object form {"<id>": {x,y,rot}} still works (one copy per id), so clients cached from before 017 keep posting.
create or replace function public.apply_decoration_positions(p_order_ref text, p_decorations text[], p_positions jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_note uuid; v_list jsonb; r record; vx numeric; vy numeric; vr numeric;
begin
  if p_positions is null or p_positions in ('null'::jsonb, '{}'::jsonb, '[]'::jsonb) then return; end if;
  if jsonb_typeof(p_positions) = 'object' then
    select jsonb_agg(e.value || jsonb_build_object('id', e.key)) into v_list from jsonb_each(p_positions) e;
  else
    v_list := p_positions;
  end if;
  if jsonb_typeof(v_list) <> 'array' or jsonb_array_length(v_list) > 200 then
    perform public.app_error('CSW40', 'INVALID_POSITION', 'Invalid sticker positions.');
  end if;
  select n.id into v_note from public.notes n join public.orders o on o.id = n.order_id where o.order_ref = p_order_ref;
  if v_note is null then perform public.app_error('CSW04', 'NOT_FOUND'); end if;
  for r in select e.value as v, e.value ->> 'id' as k,
                  row_number() over (partition by e.value ->> 'id' order by e.ord) as n
             from jsonb_array_elements(v_list) with ordinality e(value, ord) loop
    if jsonb_typeof(r.v) <> 'object' or r.k is null
       or not exists (select 1 from public.decorations c where c.id = r.k and c.placeable)
       or r.n > (select count(*) from unnest(coalesce(p_decorations, '{}')) as u(did) where u.did = r.k) then
      perform public.app_error('CSW40', 'INVALID_POSITION', 'That decoration cannot be placed.');
    end if;
    if jsonb_typeof(r.v -> 'x') <> 'number' or jsonb_typeof(r.v -> 'y') <> 'number' then
      perform public.app_error('CSW40', 'INVALID_POSITION', 'Invalid sticker positions.');
    end if;
    vx := (r.v ->> 'x')::numeric; vy := (r.v ->> 'y')::numeric;
    if vx < 0 or vx > 100 or vy < 0 or vy > 100 then
      perform public.app_error('CSW40', 'INVALID_POSITION', 'Stickers must stay on the note.');
    end if;
    vr := 0;
    if r.v ? 'rot' then
      if jsonb_typeof(r.v -> 'rot') <> 'number' or abs((r.v ->> 'rot')::numeric) > 360 then
        perform public.app_error('CSW40', 'INVALID_POSITION', 'Invalid sticker rotation.');
      end if;
      vr := (r.v ->> 'rot')::numeric;
    end if;
    update public.note_decorations
       set pos_x = round(vx, 2), pos_y = round(vy, 2), rot = ((round(vr)::int + 540) % 360) - 180   -- stored as -180..179 degrees
     where id = (select nd.id from public.note_decorations nd
                  where nd.note_id = v_note and nd.decoration_id = r.k order by nd.id offset r.n - 1 limit 1);
  end loop;
end $$;

