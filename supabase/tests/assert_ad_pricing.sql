-- Migration 019: ad_price(base, pct, locations). Run after 001-019.
\set ON_ERROR_STOP on
do $$ begin
  assert public.ad_price(60000, 100, 3) = 180000, '100% keeps price x locations';
  assert public.ad_price(60000, 50, 3) = 120000, '50% extra';
  assert public.ad_price(60000, 0, 5) = 60000, '0% extra = flat fee';
  assert public.ad_price(60000, 33, 2) = 79800, '33% extra';
  assert public.ad_price(1, 50, 2) = 2, 'rounds half up';
  assert public.ad_price(60000, 50, 0) = 60000, 'never below the base fee';
end $$;
select 'ad pricing ok';
