-- Minimal stand-ins for the Supabase roles and auth schema, so migrations can run on plain Postgres in CI.
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}', email_confirmed_at timestamptz, created_at timestamptz default now(), banned_until timestamptz, last_sign_in_at timestamptz, raw_app_meta_data jsonb default '{}', is_anonymous boolean default false);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
