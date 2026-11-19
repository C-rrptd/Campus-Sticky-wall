// Account dashboard (my notes, bookmarks, payments) and profile settings.
// All reads are RLS-scoped to the signed-in user.

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { deleteAvatar, getClient, query, rpc, uploadAvatar } from "./supabase-client.js";
import { renderNote } from "./notes.js";
import { ACHIEVEMENTS, nextMilestone, paintAvatar, renderAchievements } from "./profile-view.js";
import { buildLocationPicker, setLocationPref } from "./location.js";
import { isAllowedSocialUrl, isUsername, loginLabel } from "./validation.js";
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
  r.name.textContent = user.user_metadata?.display_name || loginLabel(user.email);

  const tasks = [
    (async () => {
      const notes = await rpc("my_notes");
      r.notes.replaceChildren(...(notes.length ? notes.map((n) => {
        // Link or unlink the note from my public profile (set_note_profile). Unlinking turns the name back to Anonymous.
        const toggle = el("button", { type: "button", class: "link-button" }, n.show_profile ? "Unlink my profile" : "Link my profile");
        toggle.addEventListener("click", () => busy(toggle, async () => {
          try {
            await rpc("set_note_profile", { p_note: n.id, p_show: !n.show_profile });
            n.show_profile = !n.show_profile;
            toggle.textContent = n.show_profile ? "Unlink my profile" : "Link my profile";
            toast(n.show_profile ? "Your profile is now on this note." : "Profile removed from this note.", "success");
          } catch (err) { toast(errorMessage(err), "error"); }
        }), { signal });
        return el("li", {},
          el("span", { class: `badge badge--${n.status}` }, NOTE_STATUS[n.status] ?? n.status), " ",
          el("span", {}, n.body.length > 60 ? `${n.body.slice(0, 60)}…` : n.body), " · ",
          el("a", { href: `#/checkout?order=${encodeURIComponent(n.order_ref)}` }, "Receipt"), " · ", toggle);
      }) : [el("li", { class: "muted" }, "You haven’t posted any notes yet.")]));
    })().catch((err) => r.notes.replaceChildren(el("li", { class: "wall-error" }, errorMessage(err)))),
    (async () => {
      const list = await rpc("my_achievements");
      const next = nextMilestone(list);
      r.milestone.textContent = next ? `Next milestone: ${ACHIEVEMENTS[next.id][1]} (${next.progress}/${next.target})` : "You have earned every achievement. Nice.";
      r.achievements.replaceChildren(renderAchievements(list));
    })().catch((err) => r.achievements.replaceChildren(el("p", { class: "wall-error" }, errorMessage(err)))),
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
      .select("display_name,username,avatar_url,social_links,donor_recognition,country_code,region_id,city_id,campus_id,suspended_at").eq("id", user.id));
  } catch (err) {
    r.error.textContent = errorMessage(err);
    return;
  }
  if (!profile) { r.error.textContent = "Profile not found."; return; }
  if (profile.suspended_at) r.error.textContent = "This account is suspended; profile changes are disabled.";

  form.display_name.value = profile.display_name;
  form.username.value = profile.username ?? "";
  // Avatar: `saved` is the storage path now on the profile; `picked` a new file waiting for Save; `cleared` means Remove was pressed.
  let saved = profile.avatar_url ?? null;
  let picked = null, previewUrl = null, cleared = false;
  const paintHead = () => {
    const n = form.display_name.value.trim();
    r.headName.textContent = n || "Your name";
    if (previewUrl) { const img = document.createElement("img"); img.src = previewUrl; img.alt = ""; r.avatar.replaceChildren(img); } // blob: URL, local only
    else paintAvatar(r.avatar, cleared ? null : saved, n);
    r.avatarClear.hidden = !(previewUrl || (saved && !cleared));
  };
  paintHead();
  r.headEmail.textContent = loginLabel(user.email);
  form.display_name.addEventListener("input", paintHead, { signal });
  form.avatar_file.addEventListener("change", () => {
    const f = form.avatar_file.files[0];
    r.error.textContent = "";
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    previewUrl = null; picked = null;
    if (f) {
      if (!["image/jpeg", "image/png", "image/webp", "image/gif"].includes(f.type)) { r.error.textContent = "Use a JPG, PNG, WebP or GIF picture."; form.avatar_file.value = ""; }
      else if (f.size > 10 * 1024 * 1024) { r.error.textContent = "That picture is too large (10 MB at most)."; form.avatar_file.value = ""; }
      else { picked = f; previewUrl = URL.createObjectURL(f); cleared = false; }
    }
    paintHead();
  }, { signal });
  r.avatarClear.addEventListener("click", () => {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    previewUrl = null; picked = null; cleared = true; form.avatar_file.value = "";
    paintHead();
  }, { signal });
  form.donor_recognition.checked = profile.donor_recognition;
  const digestWas = (await rpc("my_digest").catch(() => true)) !== false;
  form.email_digest.checked = digestWas;
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
      const username = form.username.value.trim();
      if (username && !isUsername(username)) { r.error.textContent = "Username must be 3–30 characters: letters, digits, _ . -"; return; }
      const social_links = {};
      for (const [key, label] of SOCIALS) {
        const v = form[`social_${key}`].value.trim();
        if (!v) continue;
        const host = (() => { try { return new URL(v).hostname.replace(/^www\./, ""); } catch { return ""; } })();
        if (!isAllowedSocialUrl(v) || !SOCIAL_HOST[key].includes(host)) { r.error.textContent = `${label} link must be an https link on ${SOCIAL_HOST[key][0]}.`; return; }
        social_links[key] = v;
      }
      let avatar = cleared ? null : saved;
      const old = saved;
      try {
        if (picked) avatar = await uploadAvatar(picked, user.id);
        await query(client.from("profiles").update({
          display_name: name, username: username || null, avatar_url: avatar, social_links, donor_recognition: form.donor_recognition.checked,
        }).eq("id", user.id));
        saved = avatar; // the profile now points at it: from here on a later failure must not delete it
        if (old && old !== avatar) deleteAvatar(old); // the old file is no longer referenced
        if (form.email_digest.checked !== digestWas) await rpc("set_my_digest", { p_on: form.email_digest.checked });
        await setLocationPref(location);
        await client.auth.updateUser({ data: { display_name: name } });
        picked = null; cleared = false; form.avatar_file.value = "";
        if (previewUrl) URL.revokeObjectURL(previewUrl);
        previewUrl = null;
        paintHead();
        toast("Profile saved.", "success");
      } catch (err) {
        if (picked && avatar && avatar !== saved) deleteAvatar(avatar); // uploaded but the profile update failed: drop the new file
        r.error.textContent = err?.code === "DUPLICATE" ? "That username is taken." : errorMessage(err);
      }
    });
  }, { signal });
}
