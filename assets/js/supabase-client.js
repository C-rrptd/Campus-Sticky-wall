// Browser Supabase client (publishable key only) plus thin, normalised wrappers
// for RPC and Edge Function calls. Errors become ApiError {code, message, status}.

import { config } from "./config.js";
import { cleanForUpload, makeAvatar, makeThumb } from "./media-clean.js";

let client = null;

export class ApiError extends Error {
  constructor(code, message, status = 0) {
    super(message || code);
    this.code = code;
    this.status = status;
  }
}

export function getClient() {
  if (client) return client;
  if (!window.supabase?.createClient) {
    throw new ApiError("CLIENT_MISSING", "The Supabase library failed to load. Check your connection and reload.");
  }
  client = window.supabase.createClient(config.supabaseUrl, config.supabasePublishableKey, {
    auth: { flowType: "pkce", detectSessionInUrl: true, persistSession: true, autoRefreshToken: true },
  });
  return client;
}

function fromPostgrest(error) {
  if (!error) return null;
  if (typeof error.code === "string" && error.code.startsWith("CSW")) {
    return new ApiError(error.message, error.hint || error.message, 400);
  }
  if (error.code === "42501") return new ApiError("FORBIDDEN", "You are not allowed to do that.", 403);
  if (error.code === "23505") return new ApiError("DUPLICATE", "That was already done.", 409);
  if (error.message?.includes("Failed to fetch")) return new ApiError("NETWORK", "Can’t reach the server. Check your connection.", 0);
  return new ApiError("REQUEST_FAILED", "The request failed. Please try again.", 0);
}

/** Call a SQL function exposed to the browser (public/user functions only). */
export async function rpc(fn, args = {}) {
  const { data, error } = await getClient().rpc(fn, args);
  if (error) throw fromPostgrest(error);
  return data;
}

/** Run a PostgREST query builder and unwrap. */
export async function query(builder) {
  const { data, error } = await builder;
  if (error) throw fromPostgrest(error);
  return data;
}

/** Call an Edge Function with a JSON body. */
export async function invoke(name, body) {
  let result;
  try {
    result = await getClient().functions.invoke(name, { body });
  } catch {
    throw new ApiError("NETWORK", "Can’t reach the server. Check your connection.", 0);
  }
  const { data, error } = result;
  if (!error) return data;
  const response = error.context;
  if (response && typeof response.json === "function") {
    let payload = null;
    try {
      payload = await response.json();
    } catch {
      /* not JSON */
    }
    if (payload?.error) throw new ApiError(payload.error.code, payload.error.message, response.status);
    throw new ApiError("REQUEST_FAILED", "The request failed. Please try again.", response.status ?? 0);
  }
  throw new ApiError("NETWORK", "Can’t reach the server. Check your connection.", 0);
}

/** Public URL of a campaign creative stored in Supabase Storage. */
export function creativeUrl(path) {
  if (!path || !/^[0-9a-f-]{36}\/[0-9a-f-]{36}\.(png|jpe?g|webp)$/.test(path)) return null;
  return `${config.supabaseUrl}/storage/v1/object/public/${config.creativeBucket}/${path}`;
}

const MEDIA_EXT = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif", "video/mp4": "mp4", "video/webm": "webm" };
export const MEDIA_MAX_FILES = 4;
export const MEDIA_MAX_BYTES = 25 * 1024 * 1024;
const VIDEO_MAX_BYTES = 10 * 1024 * 1024; // checked after compression
const IMAGE_MAX_BYTES = 5 * 1024 * 1024; // checked after cleaning: only bites GIFs and animated WebP, which pass through untouched

/** Error text for a file that can't be attached, or null when it is fine. */
export function mediaProblem(file) {
  if (!MEDIA_EXT[file.type]) return `${file.name}: use JPG, PNG, WebP, GIF, MP4 or WebM.`;
  if (file.size > MEDIA_MAX_BYTES) return `${file.name}: files can be at most 25 MB.`;
  return null;
}

/** Storage path of the optional thumbnail of an image path (see makeThumb). */
export const thumbPath = (path) => path.replace(/\.[A-Za-z0-9]+$/, "-t.webp");

/** Public URL of a note attachment. `item` is a media entry {path, s?} (or a bare legacy path). `width` asks Cloudflare for a smaller image when resizing is on. */
export function mediaUrl(item, width) {
  const m = typeof item === "string" ? { path: item } : item;
  if (!m?.path || !/^[0-9a-f-]{36}\/[A-Za-z0-9._-]{1,100}$/.test(m.path)) return null;
  if (m.s !== "r2" || !config.mediaBase) return `${config.supabaseUrl}/storage/v1/object/public/note-media/${m.path}`;
  const resize = width && config.mediaResize && m.kind !== "video" && /\.(jpg|png|webp|gif)$/.test(m.path);
  return resize ? `${config.mediaBase}/cdn-cgi/image/width=${width},quality=80,format=auto/${m.path}` : `${config.mediaBase}/${m.path}`;
}
/** Small picture for the wall: a resized copy when Cloudflare resizing is on, else the uploaded "-t.webp" thumbnail. */
export const thumbUrl = (item) => (config.mediaResize && item.s === "r2" ? mediaUrl(item, 400) : mediaUrl({ ...item, path: thumbPath(item.path) }));

const AVATAR_PATH = /^[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|png|webp|gif)$/;
const AVATAR_MAX_BYTES = 1024 * 1024; // same as the bucket limit (migration 053)
/** Public URL of a profile picture. profiles.avatar_url holds the storage path, so anything else (old links) gives null. */
export const avatarUrl = (path) => (AVATAR_PATH.test(path ?? "") ? `${config.supabaseUrl}/storage/v1/object/public/avatars/${path}` : null);

/** Shrinks a picked image and uploads it to the avatars bucket. Resolves to the storage path to save in profiles.avatar_url. */
export async function uploadAvatar(original, userId) {
  if (!["image/jpeg", "image/png", "image/webp", "image/gif"].includes(original.type)) throw new ApiError("UPLOAD_FAILED", "Use a JPG, PNG, WebP or GIF picture.", 0);
  let file;
  try { file = await makeAvatar(original); } catch { throw new ApiError("UPLOAD_FAILED", "Couldn’t read that picture. Try a different file.", 0); }
  if (file.size > AVATAR_MAX_BYTES) throw new ApiError("UPLOAD_FAILED", "Animated pictures can be at most 1 MB. Try a shorter or smaller GIF.", 0);
  const path = `${userId}/${crypto.randomUUID()}.${MEDIA_EXT[file.type]}`;
  const { error } = await getClient().storage.from("avatars").upload(path, file, { contentType: file.type, cacheControl: "31536000" }); // new name every time: cache for a year
  if (error) throw new ApiError("UPLOAD_FAILED", "Couldn’t upload your picture. Please try again.", 0);
  return path;
}
/** Best effort: a leftover file is harmless, so failures are ignored. */
export const deleteAvatar = (path) => (AVATAR_PATH.test(path ?? "") ? getClient().storage.from("avatars").remove([path]).catch(() => {}) : Promise.resolve());

/** Community decorations are ids "u-<12 hex>" whose image sits at decoration-art/<id>.png. */
export const isUserDeco = (id) => /^u-[0-9a-f]{12}$/.test(id ?? "");
export const decoArtUrl = (id) => (isUserDeco(id) ? `${config.supabaseUrl}/storage/v1/object/public/decoration-art/${id}.png` : null);

/** Paid upvote sounds are decorations "snd-<12 hex>" whose mp3 sits at sound-effects/<id>.mp3. */
export const isSoundDeco = (id) => /^snd-[0-9a-f]{12}$/.test(id ?? "");
export const SOUND_MAX_MS = 5000;
let nowPlaying;
/** Play a note's sound for the member who just upvoted it. Always cut at 5 s, whatever the file holds. */
export function playSound(id) {
  if (!isSoundDeco(id)) return;
  try {
    nowPlaying?.pause();
    const a = new Audio(`${config.supabaseUrl}/storage/v1/object/public/sound-effects/${id}.mp3`);
    a.volume = 0.6;
    nowPlaying = a;
    a.play().catch(() => {}); // blocked or missing file: stay silent
    setTimeout(() => a.pause(), SOUND_MAX_MS);
  } catch { /* no audio support */ }
}

/** Give a swatch or sticker element its picture when `id` is a community decoration; other ids are CSS-only. */
export function paintArt(node, id) {
  const url = decoArtUrl(id);
  if (!url) return node;
  node.classList.add("deco-art");
  node.style.setProperty("--deco-img", `url("${url}")`);
  return node;
}

async function putToR2(url, body, type) {
  let res;
  try { res = await fetch(url, { method: "PUT", body, headers: { "content-type": type } }); } catch { res = null; }
  return !!res?.ok;
}

/** Upload files; resolves to [{path, kind, ...}]. With Cloudflare R2 configured the browser uploads straight to R2 using
 *  short-lived URLs from the media-upload function; otherwise (or if R2 is not set up server-side) files go to Supabase Storage. */
export async function uploadNoteMedia(files, userId) {
  const cleaned = [];
  for (const original of files) {
    let file;
    try {
      file = await cleanForUpload(original); // strips photo metadata; fails closed
    } catch {
      throw new ApiError("UPLOAD_FAILED", `Couldn’t prepare ${original.name}. Try a different file.`, 0);
    }
    const problem = mediaProblem(file);
    if (problem) throw new ApiError("UPLOAD_FAILED", problem, 0);
    if (file.type.startsWith("image/") && file.size > IMAGE_MAX_BYTES) {
      throw new ApiError("UPLOAD_FAILED", `${original.name}: images and GIFs can be at most 5 MB. Use a shorter GIF or attach it as a video instead.`, 0);
    }
    if (file.type.startsWith("video/") && file.size > VIDEO_MAX_BYTES) {
      throw new ApiError("UPLOAD_FAILED", `${original.name}: videos can be at most 10 MB after compression. Trim it or use a shorter clip.`, 0);
    }
    cleaned.push({ original, file });
  }
  if (config.mediaBase && cleaned.length) {
    try {
      // Only the first attachment is shown on the wall, so only it gets a thumbnail (best effort).
      const thumb0 = cleaned[0].file.type.startsWith("image/") && cleaned[0].file.type !== "image/gif" ? await makeThumb(cleaned[0].file).catch(() => null) : null;
      const { data } = await invoke("media-upload", { files: cleaned.map(({ file }, i) => ({ type: file.type, size: file.size, thumb: i === 0 && !!thumb0 })) });
      const out = [];
      for (let i = 0; i < cleaned.length; i++) {
        const slot = data[i], { original, file } = cleaned[i];
        if (!(await putToR2(slot.put, file, file.type))) throw new ApiError("UPLOAD_FAILED", `Couldn’t upload ${original.name}. Please try again.`, 0);
        if (i === 0 && thumb0 && slot.thumb_put) await putToR2(slot.thumb_put, thumb0, "image/webp"); // no thumbnail is fine
        out.push({ path: slot.path, kind: slot.kind, token: slot.token, exp: slot.exp });
      }
      return out;
    } catch (err) {
      if (err?.code !== "R2_NOT_CONFIGURED") throw err; // not set up server-side: fall through to Supabase Storage
    }
  }
  const out = [];
  for (const { original, file } of cleaned) {
    const path = `${userId}/${crypto.randomUUID()}.${MEDIA_EXT[file.type]}`;
    const { error } = await getClient().storage.from("note-media").upload(path, file, { contentType: file.type, cacheControl: "31536000" }); // uuid path, never overwritten: cache for a year
    if (error) throw new ApiError("UPLOAD_FAILED", `Couldn’t upload ${original.name}. Please try again.`, 0);
    // Only the first attachment is shown on the wall, so only it gets a thumbnail. Best effort: no thumbnail is fine.
    if (out.length === 0 && file.type !== "image/gif" && !file.type.startsWith("video/")) {
      try {
        const thumb = await makeThumb(file);
        if (thumb) await getClient().storage.from("note-media").upload(thumbPath(path), thumb, { contentType: "image/webp", cacheControl: "31536000" });
      } catch { /* the wall falls back to the full image */ }
    }
    out.push({ path, kind: file.type.startsWith("video/") ? "video" : "image" });
  }
  return out;
}
