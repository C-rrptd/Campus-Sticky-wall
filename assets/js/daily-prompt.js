// "Today's prompt" banner on the wall: one question a day, the same for everyone, cycling through a fixed list (Asia/Jakarta day).
// shortcut: the list lives in code; move it to site_config if you want to edit prompts without a deploy.
import { lang, translate } from "./i18n.js";
import { el } from "./utils.js";

const PROMPTS = [
  ["What is one thing you wish every freshman knew?", "Satu hal yang kamu harap diketahui semua mahasiswa baru?"],
  ["Best cheap meal near campus: where, and how much?", "Makanan murah terbaik dekat kampus: di mana dan berapa harganya?"],
  ["Shout out someone who helped you this week.", "Beri apresiasi untuk seseorang yang membantumu minggu ini."],
  ["Your best study spot on campus?", "Tempat belajar terbaikmu di kampus?"],
  ["One tip that saved your semester.", "Satu tips yang menyelamatkan semestermu."],
  ["A small win from today.", "Satu kemenangan kecil hari ini."],
  ["What song gets you through exam week?", "Lagu apa yang menemanimu selama minggu ujian?"],
  ["Which class do you recommend, and why?", "Kelas mana yang kamu rekomendasikan, dan kenapa?"],
  ["Ask the wall: what should I try this weekend?", "Tanya dinding: apa yang sebaiknya kucoba akhir pekan ini?"],
  ["A campus tradition you love.", "Tradisi kampus yang kamu suka."],
  ["Coffee or tea, and where do you get it?", "Kopi atau teh, dan belinya di mana?"],
  ["What do you wish you had started earlier?", "Apa yang kamu sesali tidak dimulai lebih awal?"],
  ["One thing you are grateful for today.", "Satu hal yang kamu syukuri hari ini."],
  ["Best way to meet new people on campus?", "Cara terbaik berkenalan dengan orang baru di kampus?"],
  ["A book, show or video you keep recommending.", "Buku, tontonan, atau video yang terus kamu rekomendasikan."],
  ["Your go-to cheap study snack?", "Camilan murah andalanmu untuk belajar?"],
  ["Advice for whoever sits next to you in class.", "Pesan untuk siapa pun yang duduk di sebelahmu di kelas."],
  ["A skill you are learning outside class.", "Keahlian yang sedang kamu pelajari di luar kelas."],
  ["Rainy day on campus: what do you do?", "Hari hujan di kampus: kamu ngapain?"],
  ["Name the best spot to watch the sunset.", "Sebutkan tempat terbaik melihat matahari terbenam."],
  ["Leave a good-luck note for everyone with exams this week.", "Tinggalkan catatan semangat untuk semua yang ujian minggu ini."],
];

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
