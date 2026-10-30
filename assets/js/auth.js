// Session state (Supabase Auth) and the sign-in / register / reset view.
// The session only identifies the user; every permission is enforced by the
// database and Edge Functions.

import { config } from "./config.js";
import { getClient, query } from "./supabase-client.js";
import { pendingReferralCode } from "./referrals.js";
import { isEmail, isUsername, loginLabel, loginToEmail, validatePassword } from "./validation.js";
import { cloneTemplate } from "./component-loader.js";
import { busy, errorMessage, refs, toast } from "./utils.js";

const state = { user: null, adminChecked: null, isAdmin: false, isOwner: false };
const listeners = new Set();

export async function initAuth() {
  const client = getClient();
  // Subscribe BEFORE awaiting init: a PKCE recovery link emits PASSWORD_RECOVERY
  // while detectSessionInUrl exchanges the code, and a late listener misses it.
  client.auth.onAuthStateChange((event, session) => {
    const changed = (session?.user?.id ?? null) !== (state.user?.id ?? null);
    state.user = session?.user ?? null;
    if (changed) {
      state.adminChecked = null;
      state.isAdmin = false;
      state.isOwner = false;
    }
    if (event === "PASSWORD_RECOVERY") window.location.hash = "#/auth?mode=update";
    if (changed || event === "USER_UPDATED") listeners.forEach((cb) => cb(state.user));
  });
  // getSession() waits for detectSessionInUrl (PKCE code exchange) to finish.
  const { data, error } = await client.auth.getSession();
  if (error) console.warn("Session restore failed", error.message);
  state.user = data?.session?.user ?? null;
  return state.user;
}

export function currentUser() {
  return state.user;
}

export function onUserChange(cb) {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

/** UI hint only (shows the Admin link). The server re-checks every admin action. */
export async function isAdmin() {
  if (!state.user) return false;
  if (state.adminChecked === state.user.id) return state.isAdmin;
  try {
    const rows = await query(getClient().from("user_roles").select("role").eq("user_id", state.user.id));
    state.isAdmin = rows.some((r) => r.role === "admin" || r.role === "owner");
    state.isOwner = rows.some((r) => r.role === "owner");
  } catch {
    state.isAdmin = false;
    state.isOwner = false;
  }
  state.adminChecked = state.user.id;
  return state.isAdmin;
}

/** UI hint only; the server re-checks every owner action. */
export async function isOwner() {
  await isAdmin();
  return state.isOwner;
}

export async function signOut() {
  await getClient().auth.signOut();
  toast("Signed out.", "success");
  window.location.hash = "#/";
}

const MESSAGES = {
  "Invalid login credentials": "Email or password is incorrect.",
  "Email not confirmed": "Please verify your email first — check your inbox for the confirmation link.",
};
const friendly = (err) => MESSAGES[err?.message] ?? errorMessage(err);

export async function mountAuthView(view, { params, signal }) {
  view.append(cloneTemplate("tpl-auth"));
  const r = refs(view);
  const client = getClient();
  const forms = { login: r.login, register: r.register, forgot: r.forgotForm, update: r.updateForm };

  const show = (mode) => {
    Object.entries(forms).forEach(([key, form]) => { form.hidden = key !== mode; });
    r.tabLogin.setAttribute("aria-selected", String(mode === "login"));
    r.tabRegister.setAttribute("aria-selected", String(mode === "register"));
    r.error.textContent = "";
    r.notice.hidden = true;
  };
  const notice = (text) => { r.notice.textContent = text; r.notice.hidden = false; };

  const mode = params.get("mode");
  if (mode === "update" && state.user) show("update");
  else if (state.user) {
    notice(`You are signed in as ${loginLabel(state.user.email)}.`);
    Object.values(forms).forEach((f) => { f.hidden = true; });
  } else show(mode === "register" || pendingReferralCode() ? "register" : "login");

  const code = pendingReferralCode();
  if (code) r.refCode.value = code;

  r.tabLogin.addEventListener("click", () => show("login"), { signal });
  r.tabRegister.addEventListener("click", () => show("register"), { signal });
  r.forgot.addEventListener("click", () => show("forgot"), { signal });
  r.backToLogin.addEventListener("click", () => show("login"), { signal });

  r.login.addEventListener("submit", (e) => {
    e.preventDefault();
    const data = new FormData(r.login);
    busy(r.login.querySelector("button[type=submit]"), async () => {
      r.error.textContent = "";
      const login = String(data.get("email")).trim();
      if (!isEmail(login) && !isUsername(login)) { r.error.textContent = "Email or password is incorrect."; return; }
      const { error } = await client.auth.signInWithPassword({ email: loginToEmail(login), password: String(data.get("password")) });
      if (error) { r.error.textContent = friendly(error); return; }
      toast("Welcome back!", "success");
      window.location.hash = params.get("next") && /^\/[a-z/-]*$/.test(params.get("next")) ? `#${params.get("next")}` : "#/";
    });
  }, { signal });

  r.register.addEventListener("submit", (e) => {
    e.preventDefault();
    const data = new FormData(r.register);
    const email = String(data.get("email")).trim();
    const displayName = String(data.get("display_name")).trim();
    const referral = String(data.get("referral_code") ?? "").trim().toUpperCase();
    const pwError = validatePassword(data.get("password"));
    if (displayName.length < 2 || displayName.length > 40) { r.error.textContent = "Display name must be 2–40 characters."; return; }
    if (!isEmail(email)) { r.error.textContent = "Enter a valid email address."; return; }
    if (pwError) { r.error.textContent = pwError; return; }
    if (referral && !/^[A-Z2-9]{8}$/.test(referral)) { r.error.textContent = "Referral codes have 8 letters/digits."; return; }
    busy(r.register.querySelector("button[type=submit]"), async () => {
      r.error.textContent = "";
      const { data: res, error } = await client.auth.signUp({
        email,
        password: String(data.get("password")),
        options: { emailRedirectTo: config.siteUrl, data: { display_name: displayName, referral_code: referral || undefined } },
      });
      if (error) { r.error.textContent = friendly(error); return; }
      if (res.session) {
        toast("Account created!", "success");
        window.location.hash = "#/";
      } else {
        Object.values(forms).forEach((f) => { f.hidden = true; });
        notice(`Almost done! We sent a confirmation link to ${email}. Open it on this device to activate your account${referral ? " and unlock your referral credit" : ""}.`);
      }
    });
  }, { signal });

  r.forgotForm.addEventListener("submit", (e) => {
    e.preventDefault();
    const email = String(new FormData(r.forgotForm).get("email")).trim();
    if (!isEmail(email)) { r.error.textContent = "Enter a valid email address."; return; }
    busy(r.forgotForm.querySelector("button[type=submit]"), async () => {
      const { error } = await client.auth.resetPasswordForEmail(email, { redirectTo: config.siteUrl });
      // Same message either way: don't reveal whether an account exists.
      if (error) console.warn("Reset request failed", error.message);
      notice("If an account exists for that email, a reset link is on its way.");
    });
  }, { signal });

  r.updateForm.addEventListener("submit", (e) => {
    e.preventDefault();
    const password = String(new FormData(r.updateForm).get("password"));
    const pwError = validatePassword(password);
    if (pwError) { r.error.textContent = pwError; return; }
    busy(r.updateForm.querySelector("button[type=submit]"), async () => {
      const { error } = await client.auth.updateUser({ password });
      if (error) { r.error.textContent = friendly(error); return; }
      toast("Password updated.", "success");
      window.location.hash = "#/account";
    });
  }, { signal });
}
