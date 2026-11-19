// Header bell: unread badge + dropdown with the newest notifications. Opening the dropdown marks what it shows as read.
// Also records the daily visit (touch_streak) and shows the streak chip next to the bell.
// The server writes notifications (migration 050); this file only lists them and marks them read.
// shortcut: polls the unread count every 60 s while the tab is visible; switch to Supabase Realtime if that load matters.
import { currentUser } from "./auth.js";
import { rpc } from "./supabase-client.js";
import { translate } from "./i18n.js";
import { clear, el, timeAgo, toast } from "./utils.js";

const POLL_MS = 60_000;
const t = (s) => translate(el("span", {}, s)).textContent;

const titleOf = (n) => {
  if (n.kind === "streak") return t(`${n.count}-day streak 🔥`);
  if (n.kind !== "upvote") return t("New activity");
  return n.count === 1 ? t("1 new upvote on your note") : t(`${n.count} new upvotes on your note`);
};

function item(n) {
  const cls = `notif__item${n.read ? "" : " is-unread"}`;
  const inner = [
    el("span", { class: "notif__title" }, titleOf(n)),
    n.note?.snippet ? el("span", { class: "notif__snippet" }, n.note.snippet) : null,
    el("time", { class: "notif__time", datetime: n.at }, timeAgo(n.at)),
  ];
  return el("li", {}, n.note ? el("a", { class: cls, href: `#/note?id=${encodeURIComponent(n.note.id)}` }, inner) : el("div", { class: cls }, inner));
}

/** Adds the bell to `host` (the signed-in account menu). Returns { refresh } for sign-in/out changes. */
export function mountNotifications(host) {
  const badge = el("span", { class: "notif__badge", hidden: true });
  const list = el("ul", { class: "notif__list" });
  const root = el("details", { class: "dropdown notif", hidden: true },
    el("summary", { class: "dropdown__tab notif__tab", "aria-label": t("Notifications") }, el("span", { "aria-hidden": "true" }, "🔔"), badge),
    el("div", { class: "dropdown__panel notif__panel" }, el("strong", {}, t("Notifications")), list));
  const chip = el("button", { class: "streak", type: "button", hidden: true, title: t("Share your streak") });
  let streak = 0;
  chip.addEventListener("click", async () => {
    const { shareCard } = await import("./share-card.js");
    shareCard({ label: t("Streak"), big: String(streak), text: t("days in a row"), cta: t("How long is your streak?"), color: "#ffd1a1" }).catch((err) => console.warn("Share failed", err));
  });
  host.prepend(root);
  root.after(chip);

  const paint = (n) => { badge.hidden = !n; badge.textContent = n > 9 ? "9+" : String(n); };

  let touched = ""; // local date of the last streak check; the server decides what counts as a new day
  async function refresh() {
    root.hidden = !currentUser();
    if (root.hidden) { root.open = false; chip.hidden = true; touched = ""; return paint(0); }
    const day = new Date().toDateString();
    if (touched !== day) {
      touched = day;
      try {
        const s = await rpc("touch_streak");
        streak = s.streak;
        chip.textContent = `🔥 ${s.streak}`;
        chip.hidden = s.streak < 2;
        if (s.lost > 0) toast(t(`Your ${s.lost}-day streak ended. Start a new one today.`), undefined, 8000); // only the first visit after the break sees this
      } catch (err) { console.warn("Streak unavailable", err); }
    }
    try { paint(await rpc("unread_notification_count")); } catch (err) { console.warn("Notifications unavailable", err); }
  }

  root.addEventListener("toggle", async () => {
    if (!root.open) return;
    try {
      const { items } = await rpc("my_notifications", { p_limit: 20 });
      clear(list);
      if (items.length) list.append(...items.map(item));
      else list.append(el("li", { class: "notif__empty" }, t("No notifications yet. Upvotes on your notes show up here.")));
      const unseen = items.filter((n) => !n.read).map((n) => n.id);
      if (unseen.length) { await rpc("mark_notifications_read", { p_ids: unseen }); refresh(); }
    } catch (err) {
      console.warn("Notifications unavailable", err);
    }
  });
  list.addEventListener("click", (e) => { if (e.target.closest("a")) root.open = false; });

  setInterval(() => { if (!document.hidden) refresh(); }, POLL_MS);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
  return { refresh };
}
