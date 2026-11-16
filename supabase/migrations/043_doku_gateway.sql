-- Payment gateway moved from Midtrans to DOKU.
-- (1) DOKU's invoice_number is limited to 30 characters when cards are enabled, so new order refs are
--     'CSW-X-' + 24 hex (30 chars, 96 random bits). Old 46-char refs stay valid; they only matter while unpaid.
-- (2) payment_methods.midtrans_codes keeps its (now historical) name but holds DOKU payment_method_types in
--     lower case; the Edge Function upper-cases them. Limits (min_amount / max_amount) are NOT touched:
--     check them against your DOKU agreement in Admin > Payment methods.

create or replace function public.new_order_ref(p_kind text) returns text
language sql volatile set search_path = '' as $$
  select 'CSW-' || upper(left(p_kind, 1)) || '-' || left(replace(gen_random_uuid()::text, '-', ''), 24)
$$;

update public.payment_methods set midtrans_codes = array['qris'] where code = 'qris';
update public.payment_methods set midtrans_codes = array['emoney_ovo','emoney_dana','emoney_shopeepay'] where code = 'ewallet';
update public.payment_methods set midtrans_codes = array['virtual_account_bca','virtual_account_bank_mandiri','virtual_account_bni','virtual_account_bri'] where code = 'virtual_account';
update public.payment_methods set midtrans_codes = array['credit_card'] where code = 'credit_card';
update public.payment_methods set midtrans_codes = array['online_to_offline_alfa'] where code = 'convenience_store';
