// Create an email-less (username) account, e.g. for test accounts. Run from a trusted machine:
//
//   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SECRET_KEY=sb_secret_... \
//   NEW_USERNAME=tester1 NEW_PASSWORD='Str0ngPassw0rd' [DISPLAY_NAME="Tester One"] \
//   deno run --allow-env --allow-net scripts/create-username-user.ts
//
// The account is marked email-verified (there is no mailbox to verify), so it passes the
// email-verified checks. That is why there is deliberately NO public username sign-up.
// It signs in on the site with the username; password reset by email is not possible.

import { createClient } from "npm:@supabase/supabase-js@2.117.0";
import { isUsername, loginToEmail } from "../assets/js/validation.js";

function fail(message: string): never {
  console.error(`create-username-user: ${message}`);
  Deno.exit(1);
}

const url = Deno.env.get("SUPABASE_URL");
const key = Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const username = Deno.env.get("NEW_USERNAME")?.trim() ?? "";
const password = Deno.env.get("NEW_PASSWORD") ?? "";
const displayName = (Deno.env.get("DISPLAY_NAME") ?? username).trim();

if (!url || !/^https?:\/\//.test(url)) fail("set SUPABASE_URL to your project URL.");
if (!key) fail("set SUPABASE_SECRET_KEY (secret/service_role key). Never commit it.");
if (!isUsername(username)) fail("NEW_USERNAME must be 3-30 characters: letters, digits, _ . -");
if (password.length < 10 || !/[a-z]/.test(password) || !/[A-Z]/.test(password) || !/[0-9]/.test(password)) {
  fail("NEW_PASSWORD needs 10+ characters with lower case, upper case and a digit.");
}
if (displayName.length < 2 || displayName.length > 40) fail("DISPLAY_NAME must be 2-40 characters.");

const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
const { data, error } = await admin.auth.admin.createUser({
  email: loginToEmail(username),
  password,
  email_confirm: true,
  user_metadata: { display_name: displayName },
});
if (error) fail(error.message);
console.log(`created "${username}" (${data.user.id}). Sign in on the site with that username.`);
