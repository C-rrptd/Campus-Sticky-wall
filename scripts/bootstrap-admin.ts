// One-time administrator bootstrap. Run from a trusted machine, never in a browser:
//
//   SUPABASE_URL=https://<ref>.supabase.co \
//   SUPABASE_SECRET_KEY=sb_secret_... \
//   ADMIN_EMAIL=you@example.com \
//   deno run --allow-env --allow-net scripts/bootstrap-admin.ts [--dry-run] [--revoke] [--owner]
//
// Grants the `admin` role (public.user_roles) to an EXISTING, email-verified
// account. It does not create users, does not touch user metadata, and fails
// safely when configuration or the account is missing. Admin status lives in a
// table no client can write, so this script (or the SQL editor) is the only way
// to grant it.

import { createClient } from "npm:@supabase/supabase-js@2.117.0";

function fail(message: string): never {
  console.error(`bootstrap-admin: ${message}`);
  Deno.exit(1);
}

const url = Deno.env.get("SUPABASE_URL");
const key = Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const email = Deno.env.get("ADMIN_EMAIL")?.trim().toLowerCase();
const dryRun = Deno.args.includes("--dry-run");
const revoke = Deno.args.includes("--revoke");
// --owner grants (or with --revoke removes) the `owner` role instead of `admin`.
const role = Deno.args.includes("--owner") ? "owner" : "admin";

if (!url || !/^https?:\/\//.test(url)) fail("set SUPABASE_URL to your project URL.");
if (!key) fail("set SUPABASE_SECRET_KEY (secret/service_role key). Never commit it.");
if (!email || !email.includes("@")) fail("set ADMIN_EMAIL to the existing account's email address.");

const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

// Find the user by email (paginated admin listing).
let user: { id: string; email?: string; email_confirmed_at?: string | null } | undefined;
for (let page = 1; page <= 50 && !user; page++) {
  const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
  if (error) fail(`could not list users: ${error.message}`);
  user = data.users.find((u) => u.email?.toLowerCase() === email);
  if (data.users.length < 200) break;
}
if (!user) fail(`no account with email ${email}. Sign up on the site first, verify the email, then rerun.`);
if (!user.email_confirmed_at) fail(`${email} has not verified its email yet.`);

if (dryRun) {
  console.log(`[dry run] would ${revoke ? `revoke ${role} from` : `grant ${role} to`} ${email} (${user.id}).`);
  Deno.exit(0);
}

if (revoke) {
  const { error } = await admin.from("user_roles").delete().eq("user_id", user.id).eq("role", role);
  if (error) fail(`revoke failed: ${error.message}`);
  console.log(`${role} role revoked from ${email}.`);
} else {
  const { error } = await admin.from("user_roles")
    .upsert({ user_id: user.id, role, granted_by: "bootstrap-admin" }, { onConflict: "user_id,role", ignoreDuplicates: true });
  if (error) fail(`grant failed: ${error.message}`);
  console.log(`${role} role granted to ${email} (${user.id}). Sign out and back in to see the Admin menu.`);
}
