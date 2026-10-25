// Small, non-privileged helpers: safe DOM construction, money/date formatting,
// toasts, guarded browser storage. Never insert user content with innerHTML.

/** Create an element. Children may be nodes or strings (inserted as text). */
export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === null || value === undefined || value === false) continue;
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key === "dataset") Object.assign(node.dataset, value);
    else if (key === "href" || key === "src") {
      const safe = safeUrl(value, key === "href");
      if (safe) node.setAttribute(key, safe);
    } else if (key.startsWith("on")) {
      throw new Error("Use addEventListener instead of inline handlers");
    } else node.setAttribute(key, value === true ? "" : String(value));
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

/** Allow https (and same-site hash/relative links for href); reject javascript:, data:, etc. */
export function safeUrl(value, allowRelative = true) {
  if (typeof value !== "string") return null;
  if (allowRelative && (value.startsWith("#") || value.startsWith("mailto:"))) return value;
  try {
    const url = new URL(value, window.location.href);
    if (url.protocol === "https:") return url.href;
    if (url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname)) return url.href;
  } catch {
    /* invalid */
  }
  return null;
}

/** Map of [data-ref] elements inside a fragment or element. */
export function refs(root) {
  const map = {};
  root.querySelectorAll("[data-ref]").forEach((node) => {
    map[node.dataset.ref] = node;
  });
  return map;
}

export function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

const rupiah = new Intl.NumberFormat("id-ID", { maximumFractionDigits: 0 });

/** Format a whole-rupiah value given as a digit string (or bigint/safe number). */
export function formatRupiah(value) {
  if (value === null || value === undefined || value === "") return "—";
  let big;
  try {
    big = typeof value === "bigint" ? value : BigInt(String(value));
  } catch {
    return "—";
  }
  const negative = big < 0n;
  const text = rupiah.format(negative ? -big : big);
  return `${negative ? "−" : ""}Rp${text}`;
}

const dateFmt = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric" });
const dateTimeFmt = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

export function formatDate(value, withTime = false) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return (withTime ? dateTimeFmt : dateFmt).format(date);
}

export function timeAgo(value) {
  const date = new Date(value);
  const seconds = Math.round((Date.now() - date.getTime()) / 1000);
  if (Number.isNaN(seconds)) return "";
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} h ago`;
  if (seconds < 7 * 86400) return `${Math.floor(seconds / 86400)} d ago`;
  return formatDate(value);
}

/** Show a transient message. type: info | success | error */
export function toast(message, type = "info", timeout = 5000) {
  const host = document.getElementById("toasts");
  if (!host) return;
  const item = el("div", { class: `toast toast--${type}`, role: type === "error" ? "alert" : "status" }, message);
  host.append(item);
  setTimeout(() => item.remove(), timeout);
}

/** Storage that never throws (private mode, blocked storage). Values are JSON. */
function guarded(kind) {
  return {
    get(key, fallback = null) {
      try {
        const raw = window[kind].getItem(key);
        return raw === null ? fallback : JSON.parse(raw);
      } catch {
        return fallback;
      }
    },
    set(key, value) {
      try {
        window[kind].setItem(key, JSON.stringify(value));
        return true;
      } catch {
        return false;
      }
    },
    remove(key) {
      try {
        window[kind].removeItem(key);
      } catch {
        /* ignore */
      }
    },
  };
}
export const local = guarded("localStorage");
export const session = guarded("sessionStorage");

/** Guard a form/button against double submission while `fn` runs. */
export async function busy(button, fn) {
  if (button.dataset.busy === "1") return undefined;
  button.dataset.busy = "1";
  const wasDisabled = button.disabled;
  button.disabled = true;
  button.setAttribute("aria-busy", "true");
  try {
    return await fn();
  } finally {
    button.dataset.busy = "";
    button.disabled = wasDisabled;
    button.removeAttribute("aria-busy");
  }
}

export async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast("Copied to clipboard", "success", 2500);
  } catch {
    toast("Copy failed — select the text and copy it manually.", "error");
  }
}

/** Human message for an ApiError or unknown error. */
export function errorMessage(err) {
  if (err && typeof err === "object" && "message" in err && err.message) return String(err.message);
  return "Something went wrong. Please try again.";
}

/**
 * Modal dialog built from tpl-dialog (components/core.html).
 * `body` is a Node; resolves to FormData on OK, or null on cancel/escape.
 */
export function openDialog({ title, body, okLabel = "OK", cancelLabel = "Cancel", danger = false }) {
  const tpl = document.getElementById("tpl-dialog");
  if (!(tpl instanceof HTMLTemplateElement)) return Promise.resolve(window.confirm(title) ? new FormData() : null);
  const frag = tpl.content.cloneNode(true);
  const r = refs(frag);
  r.title.textContent = title;
  if (body) r.body.append(body);
  r.ok.textContent = okLabel;
  r.cancel.textContent = cancelLabel;
  if (danger) r.ok.classList.add("btn--danger");
  document.body.append(frag);
  const dialog = r.dialog;
  return new Promise((resolve) => {
    let result = null;
    r.form.addEventListener("submit", (e) => {
      const submitter = e.submitter;
      if (submitter?.value === "ok") {
        if (!r.form.reportValidity()) { e.preventDefault(); return; }
        result = new FormData(r.form);
      }
    });
    dialog.addEventListener("close", () => {
      dialog.remove();
      resolve(result);
    }, { once: true });
    dialog.showModal();
  });
}

/** Ask for an optional/required reason text. Resolves to the string or null if cancelled. */
export async function promptReason(title, { required = false, okLabel = "Confirm", danger = false } = {}) {
  const input = el("textarea", { name: "reason", rows: "3", maxlength: "500", required: required || null });
  const body = el("label", { class: "field" }, el("span", { class: "field__label" }, required ? "Reason" : "Reason (optional)"), input);
  const data = await openDialog({ title, body, okLabel, danger });
  return data ? String(data.get("reason") ?? "").trim() : null;
}

/** Replace an <input type=file>'s selection (browsers only allow this through DataTransfer). */
export function setInputFiles(input, files) {
  const dt = new DataTransfer();
  files.forEach((f) => dt.items.add(f));
  input.files = dt.files;
}

/**
 * Show a local preview (image, GIF or video) of each chosen file with a remove button.
 * Object URLs are revoked on the next render. `problem(file)` may return an error text per file.
 */
export function renderFilePreviews(container, files, onRemove, problem = () => null) {
  (container._urls ?? []).forEach((u) => URL.revokeObjectURL(u));
  container._urls = [];
  container.replaceChildren(...files.map((file, i) => {
    const url = URL.createObjectURL(file);
    container._urls.push(url);
    const video = file.type.startsWith("video/");
    const media = document.createElement(video ? "video" : "img");
    media.src = url; // blob: URLs are local, so this bypasses el()'s https-only safeUrl on purpose
    media.className = "file-preview__media";
    if (video) Object.assign(media, { muted: true, controls: true, preload: "metadata", playsInline: true });
    else media.alt = `Preview of ${file.name}`;
    const remove = el("button", { type: "button", class: "file-preview__remove", "aria-label": `Remove ${file.name}` }, "×");
    remove.addEventListener("click", () => onRemove(i));
    const bad = problem(file);
    return el("figure", { class: `file-preview${bad ? " file-preview--bad" : ""}` }, media,
      el("figcaption", { class: "small" }, `${file.name} · ${(file.size / 1048576).toFixed(1)} MB`, bad ? el("span", { class: "field__error" }, ` ${bad}`) : null),
      remove);
  }));
}
