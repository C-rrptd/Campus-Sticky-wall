// Session state (Supabase Auth) and the sign-in / register / reset view.
// The session only identifies the user; every permission is enforced by the
// database and Edge Functions.

import { config } from "./config.js";
import { getClient, invoke, query, rpc } from "./supabase-client.js";
import { pendingReferralCode } from "./referrals.js";
import { isEmail, isOtp, isUsername, loginLabel, validatePassword } from "./validation.js";
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
    const rows = await query(getClient().from("profiles").select("role").eq("id", state.user.id));
    const role = rows[0]?.role;
    state.isAdmin = role === "admin" || role === "owner";
    state.isOwner = role === "owner";
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
  "Email not confirmed": "Please verify your email first — enter the 6-digit code we sent you.",
  "Token has expired or is invalid": "That code is wrong or has expired. Only the newest code works — older codes stop working when you ask for a new one.",
};
const friendly = (err) => MESSAGES[err?.message] ?? errorMessage(err);

export async function mountAuthView(view, { params, signal }) {
  view.append(cloneTemplate("tpl-auth"));
  const r = refs(view);
  const client = getClient();
  const forms = { login: r.login, register: r.register, otp: r.otpForm, forgot: r.forgotForm, update: r.updateForm };
  let otpEmail = ""; // the address the sign-up code was sent to
  let cooldown = null;
  signal.addEventListener("abort", () => clearInterval(cooldown));

  const show = (mode) => {
    Object.entries(forms).forEach(([key, form]) => { form.hidden = key !== mode; });
    r.tabLogin.setAttribute("aria-selected", String(mode === "login"));
    r.tabRegister.setAttribute("aria-selected", String(mode === "register"));
    r.error.textContent = "";
    r.notice.hidden = true;
  };
  const notice = (text) => { r.notice.textContent = text; r.notice.hidden = false; };

  // Supabase keeps ONE signup code per user: sending a new one replaces the old, so earlier codes stop working.
  const COOLDOWN_S = 60; // same as max_frequency in supabase/config.toml
  const startCooldown = () => {
    let left = COOLDOWN_S;
    clearInterval(cooldown);
    r.resend.disabled = true;
    const tick = () => {
      r.resend.textContent = left > 0 ? `Send a new code (${left}s)` : "Send a new code";
      if (left-- <= 0) { clearInterval(cooldown); r.resend.disabled = false; }
    };
    tick();
    cooldown = setInterval(tick, 1000);
  };
  const showOtp = (email, text) => {
    otpEmail = email;
    show("otp");
    r.otpHelp.textContent = `We sent a 6-digit code to ${email}. It expires in 10 minutes. If you ask for a new code, the old one stops working.`;
    if (text) notice(text);
    startCooldown();
    r.otpForm.token.focus();
  };

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
      const password = String(data.get("password"));
      let error;
      if (isEmail(login)) ({ error } = await client.auth.signInWithPassword({ email: login, password }));
      else {
        try {
          const session = await invoke("username-login", { username: login, password });
          ({ error } = await client.auth.setSession({ access_token: session.access_token, refresh_token: session.refresh_token }));
        } catch (err) { error = err; }
      }
      if (error?.message === "Email not confirmed" && isEmail(login)) {
        const { error: sendError } = await client.auth.resend({ type: "signup", email: login });
        if (!sendError) { showOtp(login, "Your email is not verified yet. We sent you a new code."); return; }
      }
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
    const username = String(data.get("username")).trim();
    if (!isUsername(username)) { r.error.textContent = "Username must be 3–30 characters: letters, digits, _ . -"; return; }
    if (!isEmail(email)) { r.error.textContent = "Enter a valid email address."; return; }
    if (pwError) { r.error.textContent = pwError; return; }
    if (referral && !/^[A-Z2-9]{8}$/.test(referral)) { r.error.textContent = "Referral codes have 8 letters/digits."; return; }
    busy(r.register.querySelector("button[type=submit]"), async () => {
      r.error.textContent = "";
      if (!(await rpc("username_available", { p_username: username }))) { r.error.textContent = "That username is taken."; return; }
      const { data: res, error } = await client.auth.signUp({
        email,
        password: String(data.get("password")),
        options: { data: { display_name: displayName, username, referral_code: referral || undefined } },
      });
      if (error) { r.error.textContent = friendly(error); return; }
      if (res.session) {
        toast("Account created!", "success");
        window.location.hash = "#/";
      } else {
        showOtp(email, `Almost done! Enter the code to activate your account${referral ? " and unlock your referral credit" : ""}.`);
      }
    });
  }, { signal });

  r.otpBack.addEventListener("click", () => show("register"), { signal });
  r.resend.addEventListener("click", async () => {
    r.resend.disabled = true; // not busy(): that would re-enable the button and break the cooldown
    r.error.textContent = "";
    const { error } = await client.auth.resend({ type: "signup", email: otpEmail });
    if (error) { r.error.textContent = friendly(error); r.resend.disabled = false; return; }
    notice("A new code is on its way. The previous code no longer works.");
    startCooldown();
  }, { signal });
  r.otpForm.addEventListener("submit", (e) => {
    e.preventDefault();
    const token = String(new FormData(r.otpForm).get("token")).trim();
    if (!isOtp(token)) { r.error.textContent = "Enter the 6-digit code."; return; }
    busy(r.otpForm.querySelector("button[type=submit]"), async () => {
      r.error.textContent = "";
      const { data: res, error } = await client.auth.verifyOtp({ email: otpEmail, token, type: "signup" });
      if (error || !res?.session) { r.error.textContent = friendly(error ?? new Error("Token has expired or is invalid")); return; }
      toast("Account created!", "success");
      window.location.hash = "#/";
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
