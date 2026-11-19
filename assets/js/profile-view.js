// Public member profile (#/u?id=<uuid>) and the achievements list shared with the account dashboard.
// A profile is public only while the member has a live note linked to it (get_public_profile enforces that).
// Public achievements count linked notes only, so a badge never reveals how many anonymous notes someone wrote.

import { avatarUrl, rpc } from "./supabase-client.js";
import { renderNote } from "./notes.js";
import { translate } from "./i18n.js";
import { el, errorMessage, formatDate } from "./utils.js";
import { isAllowedSocialUrl } from "./validation.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SOCIALS = { instagram: "Instagram", x: "X", tiktok: "TikTok", linkedin: "LinkedIn", github: "GitHub", youtube: "YouTube", facebook: "Facebook", threads: "Threads" };

// id (from achievements_for in migration 044) -> [icon, title, how to earn it]
export const ACHIEVEMENTS = {
  "first-note": ["📝", "First note", "Post your first sticky note."],
  "notes-10": ["🗒️", "Note regular", "Have 10 notes on the wall."],
  "notes-50": ["📚", "Wall legend", "Have 50 notes on the wall."],
  "votes-10": ["👍", "Getting noticed", "Collect 10 votes on your notes."],
  "votes-100": ["🔥", "Crowd favourite", "Collect 100 votes on your notes."],
  "votes-500": ["🏆", "Campus star", "Collect 500 votes on your notes."],
  "referral-1": ["🤝", "Friend bringer", "Refer a friend who joins."],
  "referral-5": ["🎉", "Community builder", "Refer 5 friends who join."],
  "member-30": ["📅", "One month in", "Be a member for 30 days."],
  "member-365": ["🎂", "One year in", "Be a member for a year."],
  "streak-7": ["⚡", "Week streak", "Visit 7 days in a row."],
  "streak-30": ["🌟", "Month streak", "Visit 30 days in a row."],
};

/** Fills an .avatar element with the member's picture, or their initial when they have none. `path` is profiles.avatar_url. */
export function paintAvatar(node, path, name) {
  const src = avatarUrl(path);
  if (src) node.replaceChildren(el("img", { src, alt: "", loading: "lazy", decoding: "async" }));
  else node.replaceChildren(Array.from(name ?? "?")[0] ?? "?");
}

/** The first achievement not yet earned, for a "next milestone" line. */
export const nextMilestone = (list) => list.find((a) => !a.earned && ACHIEVEMENTS[a.id]);

export function renderAchievements(list, { earnedOnly = false } = {}) {
  const shown = list.filter((a) => ACHIEVEMENTS[a.id] && (a.earned || !earnedOnly));
  if (!shown.length) return el("p", { class: "muted" }, "No achievements yet.");
  return translate(el("ul", { class: "achievements" }, ...shown.map((a) => {
    const [icon, title, how] = ACHIEVEMENTS[a.id];
    return el("li", { class: `achievement${a.earned ? " is-earned" : ""}` },
      el("span", { class: "achievement__icon", "aria-hidden": "true" }, icon),
      el("div", {},
        el("strong", {}, title),
        el("p", { class: "small muted" }, how),
        a.earned
          ? el("span", { class: "achievement__done" }, "Earned ✓")
          : el("span", { class: "small" }, el("progress", { max: a.target, value: a.progress, "aria-label": title }), ` ${a.progress}/${a.target}`)));
  })));
}

export async function mount(view, { params, signal }) {
  const root = el("section", { class: "public-profile" });
  view.append(root);
  const fail = (text) => root.append(translate(el("div", {}, el("h1", { class: "page-title" }, "Profile not found"), el("p", {}, text, " ", el("a", { href: "#/" }, "Back to the wall.")))));
  const id = params.get("id") ?? "";
  if (!UUID.test(id)) return fail("That profile link is not valid.");
  let p;
  try {
    p = await rpc("get_public_profile", { p_id: id });
  } catch (err) {
    return fail(err?.code === "NOT_FOUND" ? "This member has no public profile." : errorMessage(err));
  }
  if (signal.aborted) return;
  const links = Object.entries(p.social_links ?? {}).filter(([k, v]) => SOCIALS[k] && isAllowedSocialUrl(v))
    .map(([k, v]) => el("a", { class: "chip", href: v, target: "_blank", rel: "noopener noreferrer nofollow" }, `${SOCIALS[k]} ↗`));
  const earned = (p.achievements ?? []).filter((a) => a.earned).length;
  root.append(
    el("div", { class: "card profile__head" },
      paintAvatar(el("span", { class: "avatar", "aria-hidden": "true" }), p.avatar_url, p.name),
      el("div", {},
        el("h1", { class: "page-title" }, p.name),
        el("p", { class: "muted small" }, `Member since ${formatDate(p.member_since)} · ${earned} achievement${earned === 1 ? "" : "s"}`),
        links.length ? el("p", { class: "row row--tight" }, ...links) : null)),
    el("h2", {}, "Achievements"),
    renderAchievements(p.achievements ?? [], { earnedOnly: true }),
    el("h2", {}, "Notes"),
    el("div", { class: "mini-wall" }, ...(p.notes ?? []).map((n) => renderNote(n, { signal }))));
  translate(root);
}
