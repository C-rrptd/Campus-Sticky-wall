// Share cards: one canvas template for every card (note, streak, campus race, week). No dependency, no server render.
// Story size 1080x1920: Instagram stories and WhatsApp status are where students share. Key content stays clear of the
// ~270px top and ~250px bottom areas those apps cover with their own UI.
// A card never shows an author name: notes can be anonymous.
// This file imports nothing, so the pure helpers can be unit-tested in Node (tests/fomo.test.mjs).

const W = 1080;
const H = 1920;
const INK = "#2a2418";
const NIGHT = "#0f1424";
const PAPER = "#ece3b0"; // the site's theme-color
const NOTE_COLORS = { yellow: PAPER, pink: "#f6c6d0", blue: "#c5dcf2", green: "#cfe8c3", orange: "#ffd1a1", purple: "#dccaf0" }; // notes.js COLORS
// Neo skin (tokens in neo-tokens.css): same card, drawn with the neo look. The skin comes from <html data-skin>.
const NEO_NOTE_COLORS = { yellow: "#ffe45e", pink: "#ffb3d1", blue: "#a9dcff", green: "#b9f0a8", orange: "#ffc58a", purple: "#d2bfff" };
const NEO_DISPLAY = "'Dela Gothic One', 'Zen Kaku Gothic New', system-ui, sans-serif";
const NEO_FONT = "'Zen Kaku Gothic New', system-ui, sans-serif";
const isNeo = () => typeof document !== "undefined" && document.documentElement.dataset.skin === "neo";
const FONT = "system-ui, -apple-system, 'Segoe UI', Roboto, 'Noto Color Emoji', sans-serif";

/** Greedy word wrap. `measure(str)` returns pixel width. A word wider than the line is split by character. */
export function wrapLines(measure, text, maxW) {
  const lines = [];
  let line = "";
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const next = line ? `${line} ${word}` : word;
    if (measure(next) <= maxW) { line = next; continue; }
    if (line) lines.push(line);
    line = "";
    for (const ch of Array.from(word)) {
      if (line && measure(line + ch) > maxW) { lines.push(line); line = ""; }
      line += ch;
    }
  }
  if (line) lines.push(line);
  return lines;
}

/** Largest font size (max down to min) whose wrapped text fits maxW x (maxLines lines and maxH pixels at 1.25 line height).
 *  Past min it cuts the last line that fits with an ellipsis. */
function fit(ctx, text, { maxW, maxLines = Infinity, maxH = Infinity, max, min, weight = 700 }) {
  const wrap = () => wrapLines((s) => ctx.measureText(s).width, text, maxW);
  const cap = (size) => Math.max(1, Math.min(maxLines, Math.floor(maxH / (size * 1.25))));
  for (let size = max; size >= min; size -= 4) {
    ctx.font = `${weight} ${size}px ${FONT}`;
    const lines = wrap();
    if (lines.length <= cap(size)) return { size, lines };
  }
  ctx.font = `${weight} ${min}px ${FONT}`;
  const n = cap(min);
  const lines = wrap().slice(0, n);
  lines[n - 1] = `${Array.from(lines[n - 1]).slice(0, -1).join("")}…`;
  return { size: min, lines };
}

/** Paints one card on a 1080x1920 canvas context. label: small caps title. big: giant number (optional). text: body.
 *  sub: one line at the foot of the paper. cta: the line viewers read. url: shown under the cta. */
export function drawCard(ctx, { label = "", big = "", text = "", sub = "", cta = "", url = "", color = PAPER, neo = false }) {
  const ink = neo ? "#15112e" : INK;
  const paper = /^#[0-9a-f]{6}$/i.test(color) ? color : PAPER; // the color may come from a note row: never feed it to the canvas unchecked
  const font = neo ? NEO_FONT : FONT;
  const display = neo ? NEO_DISPLAY : FONT;
  const say = (str, x, y, size, fill, align = "left", weight = 700, family = font) => {
    ctx.font = `${weight} ${size}px ${family}`;
    ctx.fillStyle = fill;
    ctx.textAlign = align;
    ctx.fillText(str, x, y);
  };
  ctx.textBaseline = "alphabetic";
  ctx.fillStyle = neo ? "#0b0920" : NIGHT;
  ctx.fillRect(0, 0, W, H);
  if (neo) {
    ctx.fillStyle = "rgba(120,110,240,.13)"; // board grid
    for (let g = 0; g <= W; g += 90) ctx.fillRect(g, 0, 2, H);
    for (let g = 0; g <= H; g += 90) ctx.fillRect(0, g, W, 2);
    ["#ff4f9a", "#29d9f5", "#ffd21f"].forEach((c, i) => { // marquee stripe, as in the site header
      ctx.fillStyle = c;
      for (let x = i * 60; x < W; x += 180) { ctx.fillRect(x, 0, 60, 22); ctx.fillRect(x, H - 22, 60, 22); }
    });
    say("Campus Sticky Wall", W / 2, 330, 52, "#f6f3ff", "center", 400, display);
  } else {
    say("Campus Sticky Wall", W / 2, 330, 44, "#f4efd8", "center");
  }

  ctx.save(); // the sticky note, slightly crooked, with tape
  ctx.translate(W / 2, 920);
  ctx.rotate(-0.03);
  if (neo) {
    ctx.fillStyle = "#5a44e0"; // hard offset shadow, no blur
    ctx.fillRect(-406, -476, 860, 1000);
    ctx.fillStyle = paper;
    ctx.fillRect(-430, -500, 860, 1000);
    ctx.strokeStyle = ink;
    ctx.lineWidth = 10;
    ctx.strokeRect(-430, -500, 860, 1000);
    ctx.fillStyle = "#d4115f"; // push-pin
    ctx.beginPath(); ctx.arc(0, -500, 34, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    say(label, -360, -400, 40, `${ink}cc`);
  } else {
    ctx.shadowColor = "rgba(0,0,0,.5)";
    ctx.shadowBlur = 60;
    ctx.shadowOffsetY = 28;
    ctx.fillStyle = paper;
    ctx.fillRect(-430, -500, 860, 1000);
    ctx.shadowColor = "transparent";
    ctx.fillStyle = "rgba(255,255,255,.4)";
    ctx.fillRect(-100, -540, 200, 72);
    say(label.toUpperCase(), -360, -400, 36, `${INK}99`);
  }
  if (big) {
    let size = 380; // one line, as large as the paper allows
    const bw = neo ? 400 : 800;
    ctx.font = `${bw} ${size}px ${display}`;
    while (size > 100 && ctx.measureText(big).width > 720) { size -= 10; ctx.font = `${bw} ${size}px ${display}`; }
    say(big, 0, 20, size, ink, "center", bw, display);
    const body = fit(ctx, text, { maxW: 720, maxH: 280, max: 60, min: 40 });
    body.lines.forEach((l, i) => say(l, 0, 150 + i * body.size * 1.25, body.size, ink, "center"));
  } else {
    const body = fit(ctx, text, { maxW: 720, maxH: 660, max: 84, min: 44 });
    body.lines.forEach((l, i) => say(l, -360, -300 + body.size + i * body.size * 1.25, body.size, ink));
  }
  if (sub) {
    const foot = fit(ctx, sub, { maxW: 720, maxLines: 1, max: 40, min: 28, weight: 600 });
    say(foot.lines[0], 0, 440, foot.size, `${ink}cc`, "center", 600);
  }
  ctx.restore();

  if (cta) {
    const line = fit(ctx, cta, { maxW: 880, maxLines: 2, max: 60, min: 40 });
    line.lines.forEach((l, i) => say(l, W / 2, 1530 + i * line.size * 1.2, line.size, "#ffffff", "center"));
  }
  if (url) say(url, W / 2, 1660, 40, neo ? "#ffd21f" : paper, "center", 600);
}

/** Draws a card and opens the share sheet with it (phones), or downloads the PNG (desktop). Resolves "shared", "cancelled" or "downloaded". */
export async function shareCard(card, { url = location.origin, filename = "campus-sticky-wall.png", title = "Campus Sticky Wall" } = {}) {
  const neo = isNeo();
  if (neo) await Promise.all([document.fonts?.load("40px 'Dela Gothic One'"), document.fonts?.load("700 40px 'Zen Kaku Gothic New'")]).catch(() => {}); // canvas only uses fonts already loaded
  const canvas = Object.assign(document.createElement("canvas"), { width: W, height: H });
  drawCard(canvas.getContext("2d"), { ...card, neo, url: new URL(url, location.href).host }); // the card shows the host; the full link travels as the caption
  const blob = await new Promise((done) => canvas.toBlob(done, "image/png"));
  if (!blob) throw new Error("Could not draw the card.");
  const file = new File([blob], filename, { type: "image/png" });
  if (navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file], title, text: url }); // text, not url: WhatsApp keeps text as the caption
      return "shared";
    } catch (err) {
      if (err?.name === "AbortError") return "cancelled";
      // any other failure: fall through to the download
    }
  }
  const a = Object.assign(document.createElement("a"), { href: URL.createObjectURL(blob), download: filename });
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
  return "downloaded";
}

/** Card for one note; the caption link is the /n/<id> preview page (functions/n/[id].js). */
export const shareNote = (note, t = (s) => s) => shareCard({
  label: t("Sticky note"),
  text: note.body ?? "",
  sub: note.vote_count > 0 ? `▲ ${note.vote_count}` : "",
  cta: t("Today’s prompt is live. Post yours."),
  color: (isNeo() ? NEO_NOTE_COLORS : NOTE_COLORS)[note.color],
}, { url: `${location.origin}/n/${note.id}`, filename: "sticky-note.png" });
