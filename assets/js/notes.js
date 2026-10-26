// Sticky-note rendering and interactions (vote, bookmark, report) plus the
// note composer with customer-defined pricing (min/cap/presets from site_config).
// Totals shown here are ESTIMATES; the server computes the authoritative price.

import { decoPicker } from "./deco-picker.js";
import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { MEDIA_MAX_FILES, getClient, invoke, mediaProblem, mediaUrl, query, rpc, uploadNoteMedia } from "./supabase-client.js";
import { rememberReceipt } from "./checkout.js";
import { buildCampusSelect, getLocationPref } from "./location.js";
import { CREDIT_VALUE, formatMoney, isAllowedSocialUrl, pricing, setPricing, textLength, validateNote, validatePublicationAmount } from "./validation.js";
import { busy, el, errorMessage, formatRupiah, openDialog, refs, renderFilePreviews, safeUrl, setInputFiles, timeAgo, toast } from "./utils.js";

const COLORS = new Set(["yellow", "pink", "blue", "green", "orange", "purple"]);

function tilt(id) {
  let h = 0;
  for (const ch of String(id)) h = (h * 31 + ch.charCodeAt(0)) | 0;
  return ((Math.abs(h) % 7) - 3) * 0.6; // -1.8deg .. 1.8deg
}

const clampPct = (n) => Math.min(96, Math.max(4, Math.round(n * 100) / 100));

/** Make a sticker draggable (mouse, touch, pen) and movable with the arrow keys. */
function makeDraggable(node, card, id, label, onPlace, { onRotate = null, onRemove = null, rot = 0 } = {}) {
  node.classList.add("sticker--editable");
  node.removeAttribute("aria-hidden");
  node.tabIndex = 0;
  node.setAttribute("role", "group"); // contains the rotate/remove buttons
  node.setAttribute("aria-roledescription", "movable sticker");
  node.setAttribute("aria-label", `${label} sticker. Drag or use the arrow keys to move${onRotate ? ", R to rotate" : ""}${onRemove ? ", Delete to remove" : ""}.`);
  let angle = rot;
  const turn = (by) => { angle = ((angle + by + 540) % 360) - 180; node.style.setProperty("--rot", `${angle}deg`); onRotate(id, angle); };
  const button = (cls, text, verb, fn) => {
    const b = el("button", { type: "button", class: `sticker__btn ${cls}`, "aria-label": `${verb} ${label}` }, text);
    b.addEventListener("click", (e) => { e.stopPropagation(); fn(); });
    return b;
  };
  if (onRemove) node.append(button("sticker__btn--remove", "✕", "Remove", () => onRemove(id)));
  if (onRotate) node.append(button("sticker__btn--rotate", "↻", "Rotate", () => turn(15)));
  const put = (x, y) => {
    node.style.left = `${clampPct(x)}%`;
    node.style.top = `${clampPct(y)}%`;
    onPlace(id, clampPct(x), clampPct(y));
  };
  const current = () => [parseFloat(node.style.left), parseFloat(node.style.top)];
  node.addEventListener("pointerdown", (e) => {
    if (e.target.closest?.(".sticker__btn")) return; // buttons are not drag handles
    if (e.button !== undefined && e.button !== 0) return;
    e.preventDefault();
    node.setPointerCapture(e.pointerId);
    node.focus({ preventScroll: true });
    const move = (ev) => {
      const box = card.getBoundingClientRect();
      if (box.width === 0 || box.height === 0) return;
      put(((ev.clientX - box.left) / box.width) * 100, ((ev.clientY - box.top) / box.height) * 100);
    };
    const stop = () => {
      node.removeEventListener("pointermove", move);
      node.removeEventListener("pointerup", stop);
      node.removeEventListener("pointercancel", stop);
    };
    node.addEventListener("pointermove", move);
    node.addEventListener("pointerup", stop);
    node.addEventListener("pointercancel", stop);
    move(e);
  });
  node.addEventListener("keydown", (e) => {
    if (e.target !== node) return;
    if (onRotate && (e.key === "r" || e.key === "R")) { e.preventDefault(); turn(e.shiftKey ? -15 : 15); return; }
    if (onRemove && (e.key === "Delete" || e.key === "Backspace")) { e.preventDefault(); onRemove(id); return; }
    const step = e.shiftKey ? 10 : 2;
    const [x, y] = current();
    const delta = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] }[e.key];
    if (!delta) return;
    e.preventDefault();
    put(x + delta[0], y + delta[1]);
  });
}

/** Render one note. `interactive` enables vote/bookmark/report. */
export function renderNote(note, { interactive = true, signal, onPlace = null, onRotate = null, onRemove = null, names = {} } = {}) {
  const frag = cloneTemplate("tpl-note-card");
  const r = refs(frag);
  const color = COLORS.has(note.color) ? note.color : "yellow";
  r.root.classList.add(`note--${color}`);
  r.root.style.setProperty("--tilt", `${tilt(note.id ?? note.body)}deg`);
  // Stickers are placed copies: `stickers` (one entry per copy), or `placements` keyed by id on older data.
  const older = note.placements && typeof note.placements === "object" ? note.placements : {};
  const stickers = (Array.isArray(note.stickers) ? note.stickers : Object.entries(older).map(([id, p]) => ({ id, ...p })))
    .filter((t) => t && typeof t.id === "string" && /^[a-z0-9-]{2,40}$/.test(t.id) && Number.isFinite(Number(t.x)) && Number.isFinite(Number(t.y)));
  const placed = new Set(stickers.map((t) => t.id));
  for (const d of note.decorations ?? []) {
    if (/^[a-z0-9-]{2,40}$/.test(d) && !placed.has(d)) r.root.classList.add(`deco-${d}`);
  }
  for (const t of stickers) {
    // A real element placed by percentages, so the author can drag it.
    const sticker = el("span", { class: `sticker deco-${t.id}`, "aria-hidden": "true" });
    sticker.style.left = `${clampPct(Number(t.x))}%`;
    sticker.style.top = `${clampPct(Number(t.y))}%`;
    const rot = Number.isFinite(Number(t.rot)) ? Number(t.rot) : 0;
    sticker.style.setProperty("--rot", `${rot}deg`);
    if (onPlace) makeDraggable(sticker, r.root, t.key ?? t.id, names[t.id] ?? t.id, onPlace, { onRotate, onRemove, rot });
    r.root.append(sticker);
  }
  if (note.id) r.root.dataset.noteId = note.id;
  const hasMedia = Array.isArray(note.media) && note.media.length > 0;
  r.body.textContent = truncateBody(note.body ?? "");
  if (r.body.textContent.endsWith("…")) r.body.dataset.cut = "1";
  // A note with media shows only a "Contains media" badge on the wall; the viewer shows everything.
  r.body.hidden = hasMedia;
  r.mediaBadge.hidden = !hasMedia;
  if (hasMedia) {
    const first = note.media[0];
    const src = mediaUrl(first.path);
    if (src) {
      const video = first.kind === "video";
      const thumb = video
        ? el("video", { class: "note__thumb", src: `${src}#t=0.1`, preload: "metadata", muted: "", playsinline: "", "aria-hidden": "true" })
        : el("img", { class: "note__thumb", src, alt: "", loading: "lazy" });
      r.mediaBadge.replaceChildren(thumb, el("span", { class: "note__media-label" },
        `${video ? "▶ Video" : "Photo"}${note.media.length > 1 ? ` +${note.media.length - 1} more` : ""}`));
      r.mediaBadge.classList.add("note__media--thumb");
    }
  }
  r.author.textContent = note.author_name ?? "";
  const social = note.social_link && isAllowedSocialUrl(note.social_link) ? safeUrl(note.social_link, false) : null;
  if (social) {
    r.social.href = social;
    r.social.hidden = false;
  }
  if (note.amount) {
    r.amount.textContent = formatRupiah(note.amount);
    r.amount.hidden = false;
  }
  if (note.published_at) {
    r.time.dateTime = note.published_at;
    r.time.textContent = timeAgo(note.published_at);
  }
  r.votes.textContent = String(note.vote_count ?? 0);
  setPressed(r.vote, note.voted);
  setPressed(r.bookmark, note.bookmarked);
  r.bookmark.textContent = note.bookmarked ? "★" : "☆";

  if (!interactive || !note.id) {
    r.vote.disabled = true;
    r.bookmark.hidden = true;
    r.report.hidden = true;
    r.body.removeAttribute("role"); r.body.removeAttribute("tabindex"); r.body.removeAttribute("title");
    r.mediaBadge.removeAttribute("role"); r.mediaBadge.removeAttribute("tabindex"); r.mediaBadge.removeAttribute("title");
    return frag;
  }
  const open = () => openNoteViewer(note);
  for (const t of [r.body, r.mediaBadge]) {
    t.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open(); } }, { signal });
  }
  r.root.addEventListener("click", (e) => { if (!e.target.closest("button, a")) open(); }, { signal });
  if (note.is_mine) {
    r.vote.disabled = true;
    r.vote.title = "You can’t vote for your own note";
  }
  r.vote.addEventListener("click", () => toggleVote(note, r), { signal });
  r.bookmark.addEventListener("click", () => toggleBookmark(note, r), { signal });
  r.report.addEventListener("click", () => reportNote(note), { signal });
  return frag;
}

const PREVIEW_CHARS = 140;
const PREVIEW_LINES = 4;

/** Short wall preview: "text that is too long…". The full text is shown in the viewer. */
function truncateBody(text) {
  const lines = text.split("\n");
  let out = lines.slice(0, PREVIEW_LINES).join("\n");
  const cut = lines.length > PREVIEW_LINES || out.length > PREVIEW_CHARS;
  if (out.length > PREVIEW_CHARS) out = out.slice(0, PREVIEW_CHARS);
  return cut ? `${out.trimEnd()}…` : out;
}

/** Enlarged view: full text plus any attached images / GIFs / videos. */
function openNoteViewer(note) {
  const color = COLORS.has(note.color) ? note.color : "yellow";
  const media = (note.media ?? []).map((m) => {
    const src = mediaUrl(m.path);
    if (!src) return null;
    return m.kind === "video"
      // "#t=0.1" makes the browser show the first frame as the thumbnail before play.
      ? el("video", { class: "viewer__media", src: `${src}#t=0.1`, controls: "", preload: "metadata", playsinline: "", "aria-label": "Video attached to this note" })
      : el("img", { class: "viewer__media", src, alt: "Attached image", loading: "lazy" });
  }).filter(Boolean);
  const close = el("button", { type: "button", class: "btn btn--primary" }, "Close");
  const dialog = el("dialog", { class: `dialog viewer note--${color}`, "aria-label": `Note by ${note.author_name ?? ""}` },
    el("div", { class: "viewer__body" }, note.body ?? ""),
    ...media,
    el("p", { class: "viewer__by" }, `— ${note.author_name ?? ""}`),
    close);
  const done = () => { for (const v of dialog.querySelectorAll("video")) v.pause(); dialog.close(); };
  close.addEventListener("click", done);
  dialog.addEventListener("click", (e) => { if (e.target === dialog) done(); }); // backdrop click
  dialog.addEventListener("close", () => dialog.remove(), { once: true });
  document.body.append(dialog);
  dialog.showModal();
  close.focus();
}

function setPressed(button, on) {
  button.setAttribute("aria-pressed", on ? "true" : "false");
}

function requireAccount(action) {
  const user = currentUser();
  if (!user) {
    toast(`Sign in to ${action}. Posting notes never needs an account.`, "info");
    return null;
  }
  return user;
}

async function toggleVote(note, r) {
  const user = requireAccount("vote");
  if (!user || r.vote.dataset.busy === "1") return;
  await busy(r.vote, async () => {
    const was = Boolean(note.voted);
    note.voted = !was;
    note.vote_count = Math.max(0, (note.vote_count ?? 0) + (was ? -1 : 1));
    r.votes.textContent = String(note.vote_count);
    setPressed(r.vote, note.voted);
    try {
      const table = getClient().from("votes");
      if (was) await query(table.delete().eq("note_id", note.id).eq("user_id", user.id));
      else await query(table.insert({ note_id: note.id, user_id: user.id }));
    } catch (err) {
      note.voted = was;
      note.vote_count = Math.max(0, note.vote_count + (was ? 1 : -1));
      r.votes.textContent = String(note.vote_count);
      setPressed(r.vote, was);
      if (err.code !== "DUPLICATE") toast(errorMessage(err), "error");
    }
  });
}

async function toggleBookmark(note, r) {
  const user = requireAccount("bookmark notes");
  if (!user) return;
  await busy(r.bookmark, async () => {
    const was = Boolean(note.bookmarked);
    try {
      const table = getClient().from("bookmarks");
      if (was) await query(table.delete().eq("note_id", note.id).eq("user_id", user.id));
      else await query(table.insert({ note_id: note.id, user_id: user.id }));
      note.bookmarked = !was;
      setPressed(r.bookmark, note.bookmarked);
      r.bookmark.textContent = note.bookmarked ? "★" : "☆";
    } catch (err) {
      if (err.code === "DUPLICATE") return;
      toast(errorMessage(err), "error");
    }
  });
}

async function reportNote(note) {
  const user = requireAccount("report notes (or email us)");
  if (!user) return;
  const data = await openDialog({ title: "Report this note", body: cloneTemplate("tpl-report-form"), okLabel: "Send report", danger: true });
  if (!data) return;
  try {
    await query(getClient().from("reports").insert({
      note_id: note.id, reporter_id: user.id, reason: data.get("reason"), details: String(data.get("details") ?? "").trim() || null,
    }));
    toast("Thanks — a moderator will review it.", "success");
  } catch (err) {
    toast(err.code === "DUPLICATE" ? "You already reported this note." : errorMessage(err), err.code === "DUPLICATE" ? "info" : "error");
  }
}

// ------------------------------------------------------------------ composer

export async function mountComposer(view, { signal, navigate }) {
  view.append(cloneTemplate("tpl-note-composer"));
  const r = refs(view);
  const user = currentUser();
  const state = { decorations: [], stickers: [], credits: 0, freePosts: 0, freeDecos: 0, positions: {}, rotations: {}, promo: null };
  const MAX_DECOS = 200; // same sanity ceiling as the server (create-publication, check-promo, migration 018)
  let singles = [], adder = null; // pickers: one per whole-note category, one that adds stickers
  let nextKey = 0;
  const priceLabel = (d) => (String(d.price) === "0" ? "Free" : `+${formatRupiah(String(d.price))}`);
  // Whole-note decorations come from one dropdown per category. Stickers are copies in state.stickers, each with its own key.
  const picked = () => singles.map((p) => p.value).filter(Boolean).concat(state.stickers.map((t) => t.id));
  const say = (text) => { r.decoLive.textContent = text; };
  const copiesOf = (id) => state.stickers.filter((t) => t.id === id).length;
  const nameOf = (id) => state.decorations.find((d) => d.id === id)?.name ?? id;
  const removeDecoration = (key) => {
    const gone = state.stickers.find((t) => t.key === key);
    if (!gone) return;
    state.stickers = state.stickers.filter((t) => t.key !== key);
    delete state.positions[key];
    delete state.rotations[key];
    say(`Removed ${nameOf(gone.id)}. ${copiesOf(gone.id)} left on your note.`);
    renderStickerList();
    recompute();
  };
  const addSticker = (id) => {
    const d = state.decorations.find((x) => x.id === id);
    if (!d?.placeable || picked().length >= MAX_DECOS) return;
    // Each extra copy starts one step further in from its corner so it does not hide the copy before it.
    const x = Number(d.default_x), y = Number(d.default_y), step = 8 * copiesOf(id);
    const key = `s${++nextKey}`;
    state.stickers.push({ key, id });
    state.positions[key] = { x: clampPct(x > 50 ? x - step : x + step), y: clampPct(y > 50 ? y - step : y + step) };
    say(`Added ${d.name}. ${copiesOf(id)} on your note.`);
    renderStickerList();
    recompute();
  };
  // What the server stores for stickers: one entry per copy.
  const placementsFor = () => state.stickers.map((t) => ({ id: t.id, ...state.positions[t.key], rot: state.rotations[t.key] ?? 0 }));
  // One row per kind of sticker, with a copy counter.
  const renderStickerList = () => {
    const counts = new Map();
    for (const t of state.stickers) counts.set(t.id, (counts.get(t.id) ?? 0) + 1);
    const full = picked().length >= MAX_DECOS;
    const refocus = (id, act) => (r.stickerList.querySelector(`[data-id="${id}"][data-act="${act}"]:not(:disabled)`)
      ?? r.stickerList.querySelector(`[data-id="${id}"][data-act="less"]`) ?? { focus: () => adder.focus() }).focus();
    const button = (id, act, text, label, fn) => {
      const b = el("button", { type: "button", class: "stepper__btn", "data-id": id, "data-act": act, "aria-label": label }, text);
      b.disabled = act === "more" && full;
      b.addEventListener("click", () => { fn(); refocus(id, act); }, { signal });
      return b;
    };
    r.stickerList.replaceChildren(...[...counts].map(([id, n]) => {
      const d = state.decorations.find((x) => x.id === id);
      return el("li", { class: "sticker-row" },
        el("span", { class: `deco-swatch deco-${id}`, "aria-hidden": "true" }),
        el("span", { class: "sticker-row__name" }, d.name, el("small", {}, ` ${priceLabel(d)} each`)),
        el("span", { class: "stepper" },
          button(id, "less", "−", `Remove one ${d.name}`, () => removeDecoration([...state.stickers].reverse().find((t) => t.id === id).key)),
          el("output", { "aria-label": `${d.name} copies` }, String(n)),
          button(id, "more", "+", `Add another ${d.name}`, () => addSticker(id))));
    }));
    r.stickerList.hidden = counts.size === 0;
    if (adder) adder.disabled = full;
    r.adderHint.textContent = full ? `You have ${MAX_DECOS} decorations, the most a note can have.` : "Pick the same sticker again to add another copy, as many as you like.";
  };

  // Pricing config (public site_config rows). Failure keeps the built-in defaults; the server still decides.
  try {
    setPricing(await query(getClient().from("site_config").select("key,value")
      .in("key", ["min_publication_price", "max_publication_price", "price_presets", "confirm_above_amount"])));
  } catch { /* defaults */ }
  r.minText.textContent = formatMoney(pricing.min);
  r.amount.value = String(pricing.presets[0]);
  r.amountHint.textContent = `Minimum ${formatMoney(pricing.min)}, maximum ${formatMoney(pricing.max)}. Anything above the minimum is a tip. Digits only (dots are fine, e.g. 25.000).`;
  r.presets.replaceChildren(...pricing.presets.map((p) => {
    const b = el("button", { type: "button", class: "chip" }, formatMoney(p));
    b.addEventListener("click", () => { r.amount.value = String(p); recompute(); }, { signal });
    return b;
  }));

  // Optional campus tag
  const campus = buildCampusSelect({ value: getLocationPref().campus ?? "", signal });
  r.campusField.append(campus.element);

  let lastPreview = ""; // skip identical rebuilds: a blur-triggered "change" must not replace the sticker under the pointer
  const updatePreview = () => {
    const data = new FormData(r.form);
    const amount = validatePublicationAmount(r.amount.value);
    const note = {
      body: String(data.get("body") || "Your note will look like this."),
      author_name: String(data.get("author_name") || "You"),
      color: String(data.get("color") || "yellow"),
      decorations: picked(),
      stickers: state.stickers.map((t) => ({ key: t.key, id: t.id, ...state.positions[t.key], rot: state.rotations[t.key] ?? 0 })),
      amount: amount.ok && r.showAmount.checked ? amount.digits : null,
      vote_count: 0,
    };
    const names = Object.fromEntries(state.decorations.map((d) => [d.id, d.name]));
    r.stickerHint.hidden = note.stickers.length === 0;
    const key = JSON.stringify(note);
    if (key === lastPreview) return;
    lastPreview = key;
    r.preview.replaceChildren(renderNote(note, { interactive: false, names, onPlace: (id, x, y) => { state.positions[id] = { x, y }; },
      onRotate: (id, rot) => { state.rotations[id] = rot; }, onRemove: removeDecoration }));
  };

  const recompute = () => {
    const amount = validatePublicationAmount(r.amount.value);
    r.amountError.textContent = amount.ok ? "" : amount.error;
    r.amount.setAttribute("aria-invalid", amount.ok ? "false" : "true");
    const ids = picked();
    const prices = ids.map((id) => BigInt(String(state.decorations.find((d) => d.id === id)?.price ?? 0))); // one per copy
    const decos = prices.reduce((a, b) => a + b, 0n);
    // Referral credits are optional: one master checkbox, then fine-tuning.
    r.refOptions.hidden = !r.useRefCredits.checked;
    if (!r.useRefCredits.checked) { r.usePostCredit.checked = false; r.decoCredits.value = "0"; delete r.decoCredits.dataset.manual; }
    // Old Rp5.000 credit and referral credits are mutually exclusive.
    if (r.useRefCredits.checked && r.useCredit.checked) r.useCredit.checked = false;
    const paidDecos = prices.filter((p) => p > 0n).sort((a, b) => (a < b ? 1 : a > b ? -1 : 0));
    const decoMax = Math.min(state.freeDecos, paidDecos.length);
    // Until the author changes the number themselves, use as many free decorations as possible.
    if (r.useRefCredits.checked && !r.decoCredits.dataset.manual) r.decoCredits.value = String(decoMax);
    const decoUse = Math.max(0, Math.min(Number(r.decoCredits.value) || 0, decoMax));
    r.decoCredits.max = String(decoMax);
    if (String(decoUse) !== r.decoCredits.value && r.decoCredits.value !== "") r.decoCredits.value = String(decoUse);
    let refCredit = 0n;
    if (r.usePostCredit.checked && amount.ok) refCredit += amount.value;
    for (let i = 0; i < decoUse; i++) refCredit += paidDecos[i];
    const credit = (r.useCredit.checked && amount.ok ? (amount.value < CREDIT_VALUE ? amount.value : CREDIT_VALUE) : 0n) + refCredit;
    const used = [r.usePostCredit.checked ? "1 free post" : "", decoUse > 0 ? `${decoUse} free decoration${decoUse === 1 ? "" : "s"}` : ""].filter(Boolean);
    r.refSummary.textContent = r.useRefCredits.checked ? (used.length ? `Using ${used.join(" and ")}.` : "No credits will be used for this note.") : "";
    r.sumAmount.textContent = amount.ok ? formatRupiah(amount.value) : "—";
    r.sumDecos.textContent = formatRupiah(decos);
    // Free weekly post / verified promo: applies to the minimum part only (tips are never discounted).
    const sig = `${amount.ok ? amount.digits : ""}|${[...ids].sort()}`;
    if (state.promo && state.promo.sig !== sig) { state.promo = null; r.promoMsg.textContent = ""; }
    r.promo.disabled = r.useFree.checked;
    r.applyPromo.disabled = r.useFree.checked;
    let discount = 0n;
    if (amount.ok && r.useFree.checked) discount = amount.value < pricing.min ? amount.value : pricing.min;
    else if (state.promo) discount = state.promo.discount;
    r.sumPromoRow.hidden = discount === 0n;
    r.sumPromoLabel.textContent = r.useFree.checked ? "Free weekly post" : "Promo";
    r.sumPromo.textContent = formatRupiah(-discount);
    r.sumCreditRow.hidden = credit === 0n;
    r.sumCredit.textContent = formatRupiah(-credit);
    const total = amount.ok ? amount.value + decos - credit - discount : null;
    r.sumTotal.textContent = total === null ? "—" : formatRupiah(total);
    r.confirmAmount.textContent = total === null ? "—" : formatRupiah(total);
    r.submit.textContent = total === 0n ? "Publish for free" : "Continue to payment";
    const needConfirm = amount.ok && amount.value > pricing.confirmAbove;
    r.confirmRow.hidden = !needConfirm;
    const key = `${amount.ok ? amount.digits : ""}|${[...ids].sort()}|${credit}|${discount}`;
    if (r.confirm.dataset.key !== key) {
      // The customer must re-confirm whenever the amount changes.
      r.confirm.checked = false;
      r.confirm.dataset.key = key;
    }
    updatePreview();
  };

  r.decoCredits.addEventListener("input", () => { r.decoCredits.dataset.manual = "1"; }, { signal });
  r.useRefCredits.addEventListener("change", () => {
    if (r.useRefCredits.checked) {
      r.usePostCredit.checked = state.freePosts > 0;
      delete r.decoCredits.dataset.manual;
    }
  }, { signal });
  r.form.addEventListener("input", recompute, { signal });
  r.form.addEventListener("change", recompute, { signal });
  r.body.addEventListener("input", () => { r.count.textContent = String(textLength(r.body.value)); }, { signal });
  r.form.addEventListener("submit", (e) => e.preventDefault(), { signal });

  // Decorations (enabled only, prices from the database)
  try {
    state.decorations = await query(getClient().from("decorations").select("id,name,description,category,placeable,default_x,default_y,price::text").order("sort_order"));
    // Whole-note decorations (frames, tapes, papers, themes): one dropdown per category, one choice each.
    // Stickers, stamps and badges: one dropdown that adds a copy; pick the same one again for more copies.
    // Only decoration ids are sent; the server re-checks them.
    const ORDER = ["Borders", "Tapes", "Stickers", "Stamps & badges", "Backgrounds", "Themes"];
    const rank = (c) => (ORDER.includes(c) ? ORDER.indexOf(c) : ORDER.length);
    const option = (d) => ({ value: d.id, name: d.name, price: priceLabel(d), desc: d.description, cat: d.category || "Other" });
    const byCategory = (list) => {
      const groups = new Map();
      for (const d of list) groups.set(d.category || "Other", [...(groups.get(d.category || "Other") ?? []), d]);
      return [...groups].sort((a, b) => rank(a[0]) - rank(b[0]));
    };
    const usable = state.decorations.filter((d) => /^[a-z0-9-]{2,40}$/.test(d.id));
    const wholeNote = byCategory(usable.filter((d) => !d.placeable));
    singles = wholeNote.map(([, list]) => decoPicker({ options: list.map((d) => ({ ...option(d), cat: undefined })), placeholder: "None", label: list[0].category || "Other", signal,
      onChange: () => { renderStickerList(); recompute(); } }));
    r.decoSingles.replaceChildren(...singles.map((p, i) => el("div", { class: "field" }, el("span", { class: "field__label" }, wholeNote[i][0]), p.element)));
    const stickers = byCategory(usable.filter((d) => d.placeable));
    adder = decoPicker({ options: stickers.flatMap(([, list]) => list.map(option)), placeholder: "Choose a sticker…", label: "Stickers, stamps and badges", signal,
      onChange: (id) => { adder.value = ""; if (id) addSticker(id); } });
    r.adder.replaceChildren(adder.element);
    r.stickerBox.hidden = stickers.length === 0;
    renderStickerList();
    r.decoMsg.hidden = state.decorations.length > 0;
    r.decoMsg.textContent = "No decorations available right now.";
  } catch {
    r.decoMsg.textContent = "Decorations couldn’t be loaded. You can still post a plain note.";
  }

  const showMediaPreview = () => {
    const files = [...(r.media.files ?? [])];
    renderFilePreviews(r.mediaPreview, files, (i) => { setInputFiles(r.media, files.filter((_, j) => j !== i)); showMediaPreview(); }, mediaProblem);
    if (files.length > MEDIA_MAX_FILES) r.mediaPreview.append(el("p", { class: "field__error", role: "alert" }, `Attach at most ${MEDIA_MAX_FILES} files.`));
  };
  r.media.addEventListener("change", showMediaPreview, { signal });
  signal.addEventListener("abort", () => renderFilePreviews(r.mediaPreview, [], () => {}), { once: true });

  if (!user) {
    r.media.disabled = true;
    r.mediaHint.textContent = "Sign in to attach photos, GIFs or videos.";
  }

  // Referral credits (signed-in users)
  if (user) {
    try {
      const rows = await query(getClient().from("credits").select("id").eq("status", "available"));
      state.credits = rows.length;
      r.creditCount.textContent = String(state.credits);
      r.creditRow.hidden = state.credits === 0;
    } catch {
      r.creditRow.hidden = true;
    }
    try {
      const s = await rpc("my_referral_summary");
      state.freePosts = Number(s?.free_posts_left ?? 0);
      state.freeDecos = Number(s?.free_decorations_left ?? 0);
      r.postLeft.textContent = String(state.freePosts);
      r.decoLeft.textContent = String(state.freeDecos);
      r.refRow.hidden = state.freePosts + state.freeDecos === 0;
      r.usePostCredit.disabled = state.freePosts === 0;
      r.decoCredits.disabled = state.freeDecos === 0;
      r.useRefCredits.disabled = state.freePosts + state.freeDecos === 0;
    } catch {
      r.refRow.hidden = true;
    }
    r.discountRow.hidden = false;
    try {
      state.freeAvailable = Boolean(await rpc("my_free_post_available"));
      r.freeRow.hidden = !state.freeAvailable;
    } catch { r.freeRow.hidden = true; }
    // Not prefilled with the account name: custom names must not match registered members anyway.
  }
  r.applyPromo.addEventListener("click", () => busy(r.applyPromo, async () => {
    const amount = validatePublicationAmount(r.amount.value);
    const code = r.promo.value.trim();
    r.promoMsg.textContent = "";
    state.promo = null;
    if (!code) { recompute(); return; }
    if (!amount.ok) { r.promoMsg.textContent = amount.error; return; }
    const chosen = picked();
    try {
      const res = await invoke("check-promo", { amount: amount.digits, decorations: chosen, promo_code: code });
      const discount = BigInt(res.quote.discount);
      state.promo = { discount, sig: `${amount.digits}|${[...chosen].sort()}` };
      r.promoMsg.textContent = `Code accepted: ${formatRupiah(-discount)}. New total ${formatRupiah(res.quote.total_amount)}.`;
    } catch (err) {
      r.promoMsg.textContent = errorMessage(err);
    }
    recompute();
  }), { signal });
  recompute();

  r.submit.addEventListener("click", () => busy(r.submit, async () => {
    r.formError.textContent = "";
    const data = new FormData(r.form);
    const fields = { body: String(data.get("body") ?? ""), author_name: String(data.get("author_name") ?? "") };
    const errors = validateNote(fields);
    const amount = validatePublicationAmount(r.amount.value);
    const social = String(data.get("social_link") ?? "").trim();
    if (errors.body || errors.author_name) { r.formError.textContent = errors.body || errors.author_name; return; }
    if (!amount.ok) { r.formError.textContent = amount.error; r.amount.focus(); return; }
    if (social && !isAllowedSocialUrl(social)) { r.formError.textContent = "Social links must be https links on a supported platform."; return; }
    if (amount.value > pricing.confirmAbove && !r.confirm.checked) { r.formError.textContent = "Please confirm the amount you want to pay."; r.confirm.focus(); return; }
    if (picked().length > MAX_DECOS) { r.formError.textContent = `You can add at most ${MAX_DECOS} decorations.`; return; }
    const files = [...(r.media.files ?? [])];
    if (files.length > MEDIA_MAX_FILES) { r.formError.textContent = `Attach at most ${MEDIA_MAX_FILES} files.`; return; }
    const bad = files.map(mediaProblem).find(Boolean);
    if (bad) { r.formError.textContent = bad; return; }
    try {
      // shortcut: files uploaded before a failed order stay orphaned in storage, add a cleanup job if it matters.
      const media = files.length ? await uploadNoteMedia(files, user.id) : [];
      const res = await invoke("create-publication", {
        author_name: fields.author_name.trim(),
        body: fields.body.trim(),
        color: String(data.get("color") ?? "yellow"),
        social_link: social || null,
        show_amount: r.showAmount.checked,
        amount: amount.digits,
        confirm_amount: amount.value > pricing.confirmAbove && r.confirm.checked ? amount.digits : null,
        promo_code: r.useFree.checked ? null : (r.promo.value.trim() || null),
        use_free_post: r.useFree.checked,
        decorations: picked(),
        use_credit: r.useCredit.checked,
        use_post_credit: r.usePostCredit.checked,
        deco_credits: Math.max(0, Math.floor(Number(r.decoCredits.value) || 0)),
        decoration_positions: placementsFor(),
        campus_id: campus.select.value || null,
        media,
      });
      rememberReceipt(res.order.order_ref, res.access_token);
      if (res.order.status === "completed_free") toast("Published for free!", "success");
      navigate("/checkout", { order: res.order.order_ref });
    } catch (err) {
      r.formError.textContent = errorMessage(err);
    }
  }), { signal });
}
