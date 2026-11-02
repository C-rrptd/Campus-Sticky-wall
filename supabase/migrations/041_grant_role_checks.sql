-- 041_grant_role_checks.sql
-- RLS policies (e.g. decoration_submissions_read in 039) call is_admin() as the signed-in user.
-- 005 revoked EXECUTE on all public functions from authenticated and nothing re-granted these two,
-- so the admin "Prices & settings" tab failed with 42501 "permission denied for function is_admin".
-- Both functions are SECURITY DEFINER and only return a boolean. Safe to re-run.
grant execute on function public.is_admin(uuid), public.is_owner(uuid) to authenticated;
