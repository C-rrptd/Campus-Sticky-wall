// Referral code capture (from ?ref=CODE links) and the referral dashboard.
// Capture is only a convenience: the code is checked, attributed and rewarded
// by the database when the account is created and its email verified.

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { config } from "./config.js";
import { rpc } from "./supabase-client.js";
import { copyText, el, errorMessage, formatDate, local, refs } from "./utils.js";

const KEY = "csw.ref";
const MAX_AGE_MS = 30 * 24 * 3600 * 1000;
const CODE = /^[A-Z2-9]{8}$/;

export function captureReferral(href = window.location.href) {
  const url = new URL(href);
  const raw = url.searchParams.get("ref");
  if (raw === null) return;
  const code = raw.trim().toUpperCase();
  if (CODE.test(code)) local.set(KEY, { code, at: Date.now() });
  url.searchParams.delete("ref");
  window.history.replaceState(null, "", `${url.pathname}${url.search}${url.hash || "#/auth?mode=register"}`);
}

export function pendingReferralCode() {
  const saved = local.get(KEY, null);
  if (!saved || !CODE.test(saved.code ?? "") || Date.now() - Number(saved.at) > MAX_AGE_MS) return null;
  return saved.code;
}

export function referralLink(code) {
  const base = (config.siteUrl || window.location.origin).replace(/\/$/, "");
  return `${base}/?ref=${encodeURIComponent(code)}#/auth?mode=register`;
}

const STATUS = { pending_verification: "Waiting for email verification", qualified: "Successful", rejected: "Not eligible" };

export async function mount(view, { signal }) {
  const user = currentUser();
  if (!user) {
    const frag = cloneTemplate("tpl-signin-required");
    refs(frag).message.textContent = "Create an account to get your referral link.";
    view.append(frag);
    return;
  }
  view.append(cloneTemplate("tpl-referrals"));
  const r = refs(view);
  let data;
  try {
    data = await rpc("my_referral_summary");
  } catch (err) {
    r.history.replaceChildren(el("li", { class: "wall-error" }, errorMessage(err)));
    return;
  }
  if (!data?.code) {
    r.history.replaceChildren(el("li", { class: "wall-error" }, "Your referral code isn’t ready yet. Try again shortly."));
    return;
  }
  const link = referralLink(data.code);
  r.link.value = link;
  r.code.textContent = data.code;
  r.successful.textContent = String(data.successful_referrals);
  r.pending.textContent = String(data.pending_referrals);
  r.available.textContent = String(data.credits_available);
  r.redeemed.textContent = String(data.credits_redeemed);

  r.copy.addEventListener("click", () => copyText(link), { signal });
  if (navigator.share) {
    r.share.hidden = false;
    r.share.addEventListener("click", () => {
      navigator.share({ title: "Campus Sticky Wall", text: "Join me on Campus Sticky Wall — your first note gets Rp5.000 off.", url: link }).catch(() => {});
    }, { signal });
  }

  r.history.replaceChildren(...(data.referred_by_you_recent.length
    ? data.referred_by_you_recent.map((a) => el("li", {}, `${formatDate(a.created_at)} · ${STATUS[a.status] ?? a.status}`))
    : [el("li", { class: "muted" }, "No referrals yet — share your link!")]));
  r.credits.replaceChildren(...(data.credit_history.length
    ? data.credit_history.map((c) => el("li", {}, `${formatDate(c.created_at)} · ${c.status}${c.redeemed_at ? ` (used ${formatDate(c.redeemed_at)})` : ""}`))
    : [el("li", { class: "muted" }, "You have no credits. Join through a friend’s link to get one.")]));
}
