// Wall banner: weekly campus race (gap to the next campus + reset countdown), today's pulse, and "share my week".
// Every number comes from the database. No fake counters, no invented scarcity.
// shortcut: one campus_leaderboard call per wall visit; the banner does not refresh until you leave and come back.
import { currentUser } from "./auth.js";
import { rpc } from "./supabase-client.js";
import { translate } from "./i18n.js";
import { el } from "./utils.js";
import { crownNote } from "./notes.js";
import { leftParts, msToDayEnd, msToWeekEnd, rivalry } from "./fomo-math.js";

const t = (s) => translate(el("span", {}, s)).textContent;
const plural = (n, one, many) => (n === 1 ? one : many);
const loadCard = () => import("./share-card.js"); // only paid for when someone taps Share

const sentence = (s) => {
  const votes = `${s.gap} ${plural(s.gap, "vote", "votes")}`;
  if (s.kind === "ahead") return t(`#1 this week: ${votes} ahead of ${s.rival}.`);
  if (s.kind === "tied") return t(`#1 this week: tied with ${s.rival}.`);
  return t(`#${s.rank} this week: ${votes} to pass ${s.rival}.`);
};
const resets = () => {
  const [unit, n] = leftParts(msToWeekEnd());
  return t(`Resets in ${n} ${unit === "hours" && n === 1 ? "hour" : unit}`);
};

/** Puts the banner under the daily prompt. Returns { setCampus(id) } for when the campus picker changes. */
export function mountFomo(view, { campus, signal }) {
  const main = el("strong", { class: "fomo__main" });
  const ends = el("span", { class: "fomo__ends" });
  const shareRace = el("button", { class: "btn btn--small", type: "button" }, t("Share"));
  const raceRow = el("div", { class: "fomo__row", hidden: true }, main, ends, shareRace);
  const pulse = el("p", { class: "fomo__pulse", hidden: true });
  const top = el("p", { class: "fomo__pulse", hidden: true }); // today's leading note + yesterday's winner (daily_top)
  const week = el("button", { class: "btn btn--small", type: "button", hidden: true }, t("Share my week"));
  const root = el("aside", { class: "fomo", hidden: true }, raceRow, top, pulse, week);
  const anchor = view.querySelector(".daily-prompt");
  if (anchor) anchor.after(root); else view.querySelector(".wall-view")?.prepend(root);

  const topRow = ({ today, yesterday }) => {
    crownNote(today?.id ?? null);
    const kids = [];
    if (today) {
      const [unit, n] = leftParts(msToDayEnd());
      kids.push(t(`🏆 Top note today (${today.votes} ${plural(today.votes, "upvote", "upvotes")}): `), el("a", { href: `#/note?id=${encodeURIComponent(today.id)}` }, `“${today.snippet}”`),
        t(` · Resets in ${n} ${unit === "hours" && n === 1 ? "hour" : unit}. Upvote your favourite before it does.`));
    }
    if (yesterday) {
      if (kids.length) kids.push(el("br"));
      kids.push(t(`Yesterday’s winner (${yesterday.votes} ${plural(yesterday.votes, "upvote", "upvotes")}): `), el("a", { href: `#/note?id=${encodeURIComponent(yesterday.id)}` }, `“${yesterday.snippet}”`));
    }
    top.replaceChildren(...kids);
    top.hidden = kids.length === 0;
    if (kids.length) root.hidden = false;
  };

  let standing = null;
  let board; // the weekly board, fetched once
  let req = 0;
  async function setCampus(id) {
    const mine = ++req;
    rpc("daily_top", { p_campus: id || null }).then((d) => { if (mine === req && !signal.aborted) topRow(d); }).catch(() => {});
    standing = null;
    raceRow.hidden = true;
    if (!id) return;
    try {
      board ??= rpc("campus_leaderboard", { p_period: "week" });
      const { rows } = await board;
      if (mine !== req || signal.aborted) return;
      standing = rivalry(rows, id);
      if (!standing) return;
      main.textContent = sentence(standing);
      ends.textContent = resets();
      raceRow.hidden = false;
      root.hidden = false;
    } catch (err) {
      board = undefined;
      console.warn("Campus race unavailable", err);
    }
  }

  const tick = setInterval(() => { if (standing) ends.textContent = resets(); }, 60_000);
  signal.addEventListener("abort", () => { clearInterval(tick); crownNote(null); });

  shareRace.addEventListener("click", async () => {
    if (!standing) return;
    const { shareCard } = await loadCard();
    shareCard({
      label: t("Campus race"), big: `#${standing.rank}`, text: sentence(standing), sub: `${standing.name} · ${resets()}`,
      cta: t("Is your campus winning? Vote before Monday."),
    }).catch((err) => console.warn("Share failed", err));
  }, { signal });

  if (currentUser()) {
    week.hidden = false;
    root.hidden = false;
    week.addEventListener("click", async () => {
      try {
        const [w, { shareCard }] = await Promise.all([rpc("my_week"), loadCard()]);
        const parts = [t(`${w.notes} ${plural(w.notes, "note", "notes")}`), w.streak >= 2 ? t(`${w.streak}-day streak 🔥`) : ""];
        await shareCard({ label: t("My week"), big: String(w.votes), text: t("upvotes this week"), sub: parts.filter(Boolean).join(" · "), cta: t("Think you can beat that?"), color: "#cfe8c3" });
      } catch (err) { console.warn("Share failed", err); }
    }, { signal });
  }

  rpc("today_pulse").then((p) => {
    if (signal.aborted) return;
    // 1-4 notes would make the wall look dead: say nothing until the number is worth showing.
    if (p.notes === 0) pulse.textContent = t("Nothing posted yet today. Yours would be the first.");
    else if (p.notes >= 5) pulse.textContent = t(`Today: ${p.notes} notes · ${p.votes} ${plural(p.votes, "upvote", "upvotes")}`);
    else return;
    pulse.hidden = false;
    root.hidden = false;
  }).catch(() => {});

  setCampus(campus);
  return { setCampus };
}
