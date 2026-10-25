// Sticky-note rendering and interactions (vote, bookmark, report) plus the
// note composer with customer-defined pricing (minimum Rp5.000, no maximum).
// Totals shown here are ESTIMATES; the server computes the authoritative price.

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { MEDIA_MAX_FILES, getClient, invoke, mediaProblem, mediaUrl, query, rpc, uploadNoteMedia } from "./supabase-client.js";
import { rememberReceipt } from "./checkout.js";
import { buildCampusSelect, getLocationPref } from "./location.js";
import { CREDIT_VALUE, isAllowedSocialUrl, textLength, validateNote, validatePublicationAmount } from "./validation.js";
import { busy, el, errorMessage, formatRupiah, openDialog, refs, safeUrl, timeAgo, toast } from "./utils.js";

const COLORS = new Set(["yellow", "pink", "blue", "green", "orange", "purple"]);

function tilt(id) {
  let h = 0;
  for (const ch of String(id)) h = (h * 31 + ch.charCodeAt(0)) | 0;
  return ((Math.abs(h) % 7) - 3) * 0.6; // -1.8deg .. 1.8deg
}

const clampPct = (n) => Math.min(96, Math.max(4, Math.round(n * 100) / 100));

/** Make a sticker draggable (mouse, touch, pen) and movable with the arrow keys. */
function makeDraggable(node, card, id, label, onPlace) {
  node.classList.add("sticker--editable");
  node.removeAttribute("aria-hidden");
  node.tabIndex = 0;
  node.setAttribute("role", "button");
  node.setAttribute("aria-roledescription", "movable sticker");
  node.setAttribute("aria-label", `${label} sticker. Drag to move, or use the arrow keys.`);
  const put = (x, y) => {
    node.style.left = `${clampPct(x)}%`;
    node.style.top = `${clampPct(y)}%`;
    onPlace(id, clampPct(x), clampPct(y));
  };
  const current = () => [parseFloat(node.style.left), parseFloat(node.style.top)];
  node.addEventListener("pointerdown", (e) => {
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
    const step = e.shiftKey ? 10 : 2;
    const [x, y] = current();
    const delta = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] }[e.key];
    if (!delta) return;
    e.preventDefault();
    put(x + delta[0], y + delta[1]);
  });
}

/** Render one note. `interactive` enables vote/bookmark/report. */
export function renderNote(note, { interactive = true, signal, onPlace = null, names = {} } = {}) {
  const frag = cloneTemplate("tpl-note-card");
  const r = refs(frag);
  const color = COLORS.has(note.color) ? note.color : "yellow";
  r.root.classList.add(`note--${color}`);
  r.root.style.setProperty("--tilt", `${tilt(note.id ?? note.body)}deg`);
  const placements = note.placements && typeof note.placements === "object" ? note.placements : {};
  for (const d of note.decorations ?? []) {
    if (!/^[a-z0-9-]{2,40}$/.test(d)) continue;
    const p = placements[d];
    if (p && Number.isFinite(Number(p.x)) && Number.isFinite(Number(p.y))) {
      // Sticker: a real element placed by percentages, so the author can drag it.
      const sticker = el("span", { class: `sticker deco-${d}`, "aria-hidden": "true" });
      sticker.style.left = `${clampPct(Number(p.x))}%`;
      sticker.style.top = `${clampPct(Number(p.y))}%`;
      if (onPlace) makeDraggable(sticker, r.root, d, names[d] ?? d, onPlace);
      r.root.append(sticker);
    } else {
      r.root.classList.add(`deco-${d}`);
    }
  }
  if (note.id) r.root.dataset.noteId = note.id;
  const hasMedia = Array.isArray(note.media) && note.media.length > 0;
  r.body.textContent = truncateBody(note.body ?? "");
  // A note with media shows only a "Contains media" badge on the wall; the viewer shows everything.
  r.body.hidden = hasMedia;
  r.mediaBadge.hidden = !hasMedia;
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
  const state = { decorations: [], credits: 0, freePosts: 0, freeDecos: 0, positions: {} };

  // Optional campus tag
  const campus = buildCampusSelect({ value: getLocationPref().campus ?? "", signal });
  r.campusField.append(campus.element);

  const updatePreview = () => {
    const data = new FormData(r.form);
    const amount = validatePublicationAmount(r.amount.value);
    const note = {
      body: String(data.get("body") || "Your note will look like this."),
      author_name: String(data.get("author_name") || "You"),
      color: String(data.get("color") || "yellow"),
      decorations: data.getAll("decorations").map(String),
      placements: {},
      amount: amount.ok && r.showAmount.checked ? amount.digits : null,
      vote_count: 0,
    };
    const names = {};
    for (const d of state.decorations) {
      if (!d.placeable || !note.decorations.includes(d.id)) continue;
      names[d.id] = d.name;
      note.placements[d.id] = state.positions[d.id] ?? { x: Number(d.default_x), y: Number(d.default_y) };
    }
    r.stickerHint.hidden = Object.keys(note.placements).length === 0;
    r.preview.replaceChildren(renderNote(note, { interactive: false, names, onPlace: (id, x, y) => { state.positions[id] = { x, y }; } }));
  };

  const recompute = () => {
    const amount = validatePublicationAmount(r.amount.value);
    r.amountError.textContent = amount.ok ? "" : amount.error;
    r.amount.setAttribute("aria-invalid", amount.ok ? "false" : "true");
    const chosen = new Set(new FormData(r.form).getAll("decorations").map(String));
    let decos = 0n;
    for (const d of state.decorations) if (chosen.has(d.id)) decos += BigInt(String(d.price));
    // Referral credits are optional: one master checkbox, then fine-tuning.
    r.refOptions.hidden = !r.useRefCredits.checked;
    if (!r.useRefCredits.checked) { r.usePostCredit.checked = false; r.decoCredits.value = "0"; delete r.decoCredits.dataset.manual; }
    // Old Rp5.000 credit and referral credits are mutually exclusive.
    if (r.useRefCredits.checked && r.useCredit.checked) r.useCredit.checked = false;
    const paidDecos = state.decorations.filter((d) => chosen.has(d.id) && BigInt(String(d.price)) > 0n)
      .map((d) => BigInt(String(d.price))).sort((a, b) => (a < b ? 1 : a > b ? -1 : 0));
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
    r.sumCreditRow.hidden = credit === 0n;
    r.sumCredit.textContent = formatRupiah(-credit);
    const total = amount.ok ? amount.value + decos - credit : null;
    r.sumTotal.textContent = total === null ? "—" : formatRupiah(total);
    r.confirmAmount.textContent = total === null ? "—" : formatRupiah(total);
    r.submit.textContent = total === 0n ? "Publish with my free credits" : "Continue to payment";
    const key = `${amount.ok ? amount.digits : ""}|${[...chosen].sort()}|${credit}`;
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
    r.decorations.replaceChildren(...state.decorations.map((d) => {
      const opt = cloneTemplate("tpl-decoration-option");
      const o = refs(opt);
      o.input.value = d.id;
      o.name.textContent = d.name;
      o.cat.textContent = d.category ?? "";
      if (/^[a-z0-9-]{2,40}$/.test(d.id)) o.swatch.classList.add(`deco-${d.id}`);
      o.price.textContent = String(d.price) === "0" ? "Free" : `+${formatRupiah(String(d.price))}`;
      if (d.description) o.name.title = d.description;
      return opt;
    }));
    if (state.decorations.length === 0) r.decorations.replaceChildren(el("p", { class: "muted" }, "No decorations available right now."));
  } catch {
    r.decorations.replaceChildren(el("p", { class: "muted" }, "Decorations couldn’t be loaded. You can still post a plain note."));
  }

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
    if (!r.author.value) r.author.value = user.user_metadata?.display_name ?? "";
  }
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
    if (!r.confirm.checked) { r.formError.textContent = "Please confirm the amount you want to pay."; r.confirm.focus(); return; }
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
        confirm_amount: amount.digits,
        decorations: data.getAll("decorations").map(String),
        use_credit: r.useCredit.checked,
        use_post_credit: r.usePostCredit.checked,
        deco_credits: Math.max(0, Math.floor(Number(r.decoCredits.value) || 0)),
        decoration_positions: Object.fromEntries(Object.entries(state.positions).filter(([id]) => data.getAll("decorations").includes(id))),
        campus_id: campus.select.value || null,
        media,
      });
      rememberReceipt(res.order.order_ref, res.access_token);
      if (res.order.status === "completed_free") toast("Published with your free credits!", "success");
      navigate("/checkout", { order: res.order.order_ref });
    } catch (err) {
      r.formError.textContent = errorMessage(err);
    }
  }), { signal });
}
