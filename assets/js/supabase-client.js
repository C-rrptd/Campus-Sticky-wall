// Browser Supabase client (publishable key only) plus thin, normalised wrappers
// for RPC and Edge Function calls. Errors become ApiError {code, message, status}.

import { config } from "./config.js";
import { cleanForUpload, makeThumb } from "./media-clean.js";

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
const VIDEO_MAX_BYTES = 10 * 1024 * 1024; // checked after compression; the bucket still allows 25 MB

/** Error text for a file that can't be attached, or null when it is fine. */
export function mediaProblem(file) {
  if (!MEDIA_EXT[file.type]) return `${file.name}: use JPG, PNG, WebP, GIF, MP4 or WebM.`;
  if (file.size > MEDIA_MAX_BYTES) return `${file.name}: files can be at most 25 MB.`;
  return null;
}

/** Storage path of the optional thumbnail of an image path (see makeThumb). */
export const thumbPath = (path) => path.replace(/\.[A-Za-z0-9]+$/, "-t.webp");

/** Public URL of an uploaded note attachment (path is "<user-id>/<file>"). */
export function mediaUrl(path) {
  if (!path || !/^[0-9a-f-]{36}\/[A-Za-z0-9._-]{1,100}$/.test(path)) return null;
  return `${config.supabaseUrl}/storage/v1/object/public/note-media/${path}`;
}

/** Upload files into the signed-in user's folder; resolves to [{path, kind}]. */
export async function uploadNoteMedia(files, userId) {
  const out = [];
  for (const original of files) {
    let file;
    try {
      file = await cleanForUpload(original); // strips photo metadata; fails closed
    } catch {
      throw new ApiError("UPLOAD_FAILED", `Couldn’t prepare ${original.name}. Try a different file.`, 0);
    }
    const problem = mediaProblem(file);
    if (problem) throw new ApiError("UPLOAD_FAILED", problem, 0);
    if (file.type.startsWith("video/") && file.size > VIDEO_MAX_BYTES) {
      throw new ApiError("UPLOAD_FAILED", `${original.name}: videos can be at most 10 MB after compression. Trim it or use a shorter clip.`, 0);
    }
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
