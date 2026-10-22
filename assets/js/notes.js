// Sticky-note rendering and interactions (vote, bookmark, report) plus the
// note composer with customer-defined pricing (minimum Rp5.000, no maximum).
// Totals shown here are ESTIMATES; the server computes the authoritative price.

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { getClient, invoke, query } from "./supabase-client.js";
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

/** Render one note. `interactive` enables vote/bookmark/report. */
export function renderNote(note, { interactive = true, signal } = {}) {
  const frag = cloneTemplate("tpl-note-card");
  const r = refs(frag);
  const color = COLORS.has(note.color) ? note.color : "yellow";
  r.root.classList.add(`note--${color}`);
  r.root.style.setProperty("--tilt", `${tilt(note.id ?? note.body)}deg`);
  for (const d of note.decorations ?? []) {
    if (/^[a-z0-9-]{2,40}$/.test(d)) r.root.classList.add(`deco-${d}`);
  }
  if (note.id) r.root.dataset.noteId = note.id;
  r.body.textContent = note.body ?? "";
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
    return frag;
  }
  if (note.is_mine) {
    r.vote.disabled = true;
    r.vote.title = "You can’t vote for your own note";
  }
  r.vote.addEventListener("click", () => toggleVote(note, r), { signal });
  r.bookmark.addEventListener("click", () => toggleBookmark(note, r), { signal });
  r.report.addEventListener("click", () => reportNote(note), { signal });
  return frag;
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
  const state = { decorations: [], credits: 0 };

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
      amount: amount.ok && r.showAmount.checked ? amount.digits : null,
      vote_count: 0,
    };
    r.preview.replaceChildren(renderNote(note, { interactive: false }));
  };

  const recompute = () => {
    const amount = validatePublicationAmount(r.amount.value);
    r.amountError.textContent = amount.ok ? "" : amount.error;
    r.amount.setAttribute("aria-invalid", amount.ok ? "false" : "true");
    const chosen = new Set(new FormData(r.form).getAll("decorations").map(String));
    let decos = 0n;
    for (const d of state.decorations) if (chosen.has(d.id)) decos += BigInt(String(d.price));
    const credit = r.useCredit.checked && amount.ok ? (amount.value < CREDIT_VALUE ? amount.value : CREDIT_VALUE) : 0n;
    r.sumAmount.textContent = amount.ok ? formatRupiah(amount.value) : "—";
    r.sumDecos.textContent = formatRupiah(decos);
    r.sumCreditRow.hidden = credit === 0n;
    r.sumCredit.textContent = formatRupiah(-credit);
    const total = amount.ok ? amount.value + decos - credit : null;
    r.sumTotal.textContent = total === null ? "—" : formatRupiah(total);
    r.confirmAmount.textContent = total === null ? "—" : formatRupiah(total);
    r.submit.textContent = total === 0n ? "Publish with my free credit" : "Continue to payment";
    const key = `${amount.ok ? amount.digits : ""}|${[...chosen].sort()}|${credit}`;
    if (r.confirm.dataset.key !== key) {
      // The customer must re-confirm whenever the amount changes.
      r.confirm.checked = false;
      r.confirm.dataset.key = key;
    }
    updatePreview();
  };

  r.form.addEventListener("input", recompute, { signal });
  r.form.addEventListener("change", recompute, { signal });
  r.body.addEventListener("input", () => { r.count.textContent = String(textLength(r.body.value)); }, { signal });
  r.form.addEventListener("submit", (e) => e.preventDefault(), { signal });

  // Decorations (enabled only, prices from the database)
  try {
    state.decorations = await query(getClient().from("decorations").select("id,name,description,price::text").order("sort_order"));
    r.decorations.replaceChildren(...state.decorations.map((d) => {
      const opt = cloneTemplate("tpl-decoration-option");
      const o = refs(opt);
      o.input.value = d.id;
      o.name.textContent = d.name;
      o.price.textContent = `+${formatRupiah(String(d.price))}`;
      if (d.description) o.name.title = d.description;
      return opt;
    }));
    if (state.decorations.length === 0) r.decorations.replaceChildren(el("p", { class: "muted" }, "No decorations available right now."));
  } catch {
    r.decorations.replaceChildren(el("p", { class: "muted" }, "Decorations couldn’t be loaded. You can still post a plain note."));
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
    try {
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
        campus_id: campus.select.value || null,
      });
      rememberReceipt(res.order.order_ref, res.access_token);
      if (res.order.status === "completed_free") toast("Published with your free credit!", "success");
      navigate("/checkout", { order: res.order.order_ref });
    } catch (err) {
      r.formError.textContent = errorMessage(err);
    }
  }), { signal });
}
