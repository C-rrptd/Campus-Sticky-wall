// "Today's prompt" banner on the wall: one question a day, the same for everyone, cycling through the list in daily-prompts.js (Asia/Jakarta day).
// shortcut: the list lives in code; move it to site_config if you want to edit prompts without a deploy.
import { lang, translate } from "./i18n.js";
import { el } from "./utils.js";
import { PROMPTS } from "./daily-prompts.js";

/** Index for a moment in time; the day rolls over at 00:00 WIB (UTC+7). */
export const promptIndex = (now = Date.now()) => Math.floor((now + 7 * 3600e3) / 864e5) % PROMPTS.length;

export function mountDailyPrompt(view) {
  const t = (s) => translate(el("span", {}, s)).textContent;
  const [en, id] = PROMPTS[promptIndex()];
  view.querySelector(".wall-view")?.prepend(el("aside", { class: "daily-prompt" },
    el("span", { class: "daily-prompt__label" }, t("Today’s prompt")),
    el("strong", {}, lang === "id" ? id : en),
    el("a", { class: "btn btn--small", href: "#/compose" }, t("Write a note"))));
}
