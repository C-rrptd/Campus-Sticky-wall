// Account dashboard (my notes, bookmarks, payments) and profile settings.
// All reads are RLS-scoped to the signed-in user.

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { getClient, query, rpc } from "./supabase-client.js";
import { renderNote } from "./notes.js";
import { buildLocationPicker, setLocationPref } from "./location.js";
import { isAllowedSocialUrl, isHttpsUrl } from "./validation.js";
import { busy, el, errorMessage, formatDate, formatRupiah, refs, toast } from "./utils.js";

const NOTE_STATUS = {
  awaiting_payment: "Awaiting payment", pending_moderation: "In moderation", published: "Live", rejected: "Not approved",
  removed: "Removed", withdrawn: "Taken down", payment_failed: "Payment failed", refunded: "Refunded",
};
const ORDER_STATUS = {
  awaiting_payment: "Awaiting payment", challenge: "Under review", paid: "Paid", completed_free: "Free (credit)", failed: "Failed",
  canceled: "Cancelled", expired: "Expired", partially_refunded: "Partly refunded", refunded: "Refunded", reversed: "Reversed",
};
const KIND = { publication: "Sticky note", donation: "Donation", advertising: "Advertising" };

function signInRequired(view) {
  view.append(cloneTemplate("tpl-signin-required"));
}

export async function mount(view, { signal }) {
  const user = currentUser();
  if (!user) return signInRequired(view);
  view.append(cloneTemplate("tpl-account"));
  const r = refs(view);
  r.name.textContent = user.user_metadata?.display_name || user.email;

  const tasks = [
    (async () => {
      const notes = await rpc("my_notes");
      r.notes.replaceChildren(...(notes.length ? notes.map((n) => el("li", {},
        el("span", { class: `badge badge--${n.status}` }, NOTE_STATUS[n.status] ?? n.status), " ",
        el("span", {}, n.body.length > 60 ? `${n.body.slice(0, 60)}…` : n.body), " · ",
        el("a", { href: `#/checkout?order=${encodeURIComponent(n.order_ref)}` }, "Receipt"))) : [el("li", { class: "muted" }, "You haven’t posted any notes yet.")]));
    })().catch((err) => r.notes.replaceChildren(el("li", { class: "wall-error" }, errorMessage(err)))),
    (async () => {
      const marks = await rpc("my_bookmarks");
      r.bookmarks.replaceChildren(...(marks.length ? marks.map((n) => renderNote(n, { signal })) : [el("p", { class: "muted" }, "No bookmarks yet.")]));
    })().catch((err) => r.bookmarks.replaceChildren(el("p", { class: "wall-error" }, errorMessage(err)))),
    (async () => {
      const orders = await query(getClient().from("orders").select("order_ref,kind,status,total_amount::text,created_at")
        .order("created_at", { ascending: false }).limit(50));
      r.payments.replaceChildren(...(orders.length ? orders.map((o) => el("tr", {},
        el("td", {}, formatDate(o.created_at)),
        el("td", {}, el("a", { href: `#/checkout?order=${encodeURIComponent(o.order_ref)}` }, o.order_ref)),
        el("td", {}, KIND[o.kind] ?? o.kind),
        el("td", {}, formatRupiah(String(o.total_amount))),
        el("td", {}, ORDER_STATUS[o.status] ?? o.status))) : [el("tr", {}, el("td", { colspan: "5", class: "muted" }, "No payments yet."))]));
    })().catch((err) => r.payments.replaceChildren(el("tr", {}, el("td", { colspan: "5", class: "wall-error" }, errorMessage(err))))),
  ];
  await Promise.all(tasks);
}

const SOCIALS = [
  ["instagram", "Instagram"], ["x", "X"], ["tiktok", "TikTok"], ["linkedin", "LinkedIn"],
  ["github", "GitHub"], ["youtube", "YouTube"], ["facebook", "Facebook"], ["threads", "Threads"],
];
const SOCIAL_HOST = { instagram: ["instagram.com"], x: ["x.com", "twitter.com"], tiktok: ["tiktok.com"], linkedin: ["linkedin.com"],
  github: ["github.com"], youtube: ["youtube.com"], facebook: ["facebook.com"], threads: ["threads.net"] };

export async function mountProfile(view, { signal }) {
  const user = currentUser();
  if (!user) return signInRequired(view);
  view.append(cloneTemplate("tpl-profile"));
  const r = refs(view);
  const client = getClient();
  const form = r.form;

  let profile;
  try {
    [profile] = await query(client.from("profiles")
      .select("display_name,avatar_url,social_links,donor_recognition,country_code,region_id,city_id,campus_id,suspended_at").eq("id", user.id));
  } catch (err) {
    r.error.textContent = errorMessage(err);
    return;
  }
  if (!profile) { r.error.textContent = "Profile not found."; return; }
  if (profile.suspended_at) r.error.textContent = "This account is suspended; profile changes are disabled.";

  form.display_name.value = profile.display_name;
  form.avatar_url.value = profile.avatar_url ?? "";
  form.donor_recognition.checked = profile.donor_recognition;
  r.socials.replaceChildren(...SOCIALS.map(([key, label]) => el("label", { class: "field" },
    el("span", { class: "field__label" }, label),
    el("input", { name: `social_${key}`, type: "url", maxlength: "300", value: profile.social_links?.[key] ?? "", placeholder: `https://${SOCIAL_HOST[key][0]}/…` }))));

  let location = { country: profile.country_code ?? "", region: profile.region_id ?? "", city: profile.city_id ?? "", campus: profile.campus_id ?? "" };
  r.location.append(el("p", { class: "field__label" }, "My area (used to show nearby promotions)"),
    buildLocationPicker({ value: location, signal, onChange: (v) => { location = v; } }));

  const contact = await query(client.from("site_config").select("value").eq("key", "contact_email")).catch(() => []);
  const email = contact[0]?.value;
  if (typeof email === "string" && email.includes("@")) {
    r.deleteMail.href = `mailto:${email}?subject=${encodeURIComponent("Account deletion request")}&body=${encodeURIComponent(`Please delete my account (${user.email}).`)}`;
  } else r.deleteMail.hidden = true;

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    busy(form.querySelector("button[type=submit]"), async () => {
      r.error.textContent = "";
      const name = form.display_name.value.trim();
      if (name.length < 2 || name.length > 40) { r.error.textContent = "Display name must be 2–40 characters."; return; }
      const avatar = form.avatar_url.value.trim();
      if (avatar && !isHttpsUrl(avatar)) { r.error.textContent = "Avatar must be an https link."; return; }
      const social_links = {};
      for (const [key, label] of SOCIALS) {
        const v = form[`social_${key}`].value.trim();
        if (!v) continue;
        const host = (() => { try { return new URL(v).hostname.replace(/^www\./, ""); } catch { return ""; } })();
        if (!isAllowedSocialUrl(v) || !SOCIAL_HOST[key].includes(host)) { r.error.textContent = `${label} link must be an https link on ${SOCIAL_HOST[key][0]}.`; return; }
        social_links[key] = v;
      }
      try {
        await query(client.from("profiles").update({
          display_name: name, avatar_url: avatar || null, social_links, donor_recognition: form.donor_recognition.checked,
        }).eq("id", user.id));
        await setLocationPref(location);
        await client.auth.updateUser({ data: { display_name: name } });
        toast("Profile saved.", "success");
      } catch (err) {
        r.error.textContent = errorMessage(err);
      }
    });
  }, { signal });
}
