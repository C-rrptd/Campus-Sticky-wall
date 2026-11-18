// Cloudflare R2 (S3-compatible) for note attachments. Browsers upload straight to R2 with a short-lived presigned URL
// into the `tmp/` prefix (an R2 lifecycle rule deletes `tmp/` after 1 day). create-publication then verifies each file
// (size, real file type) and copies it to its final key. A signed receipt (HMAC of user + path + expiry) proves who
// uploaded what without storing any user id next to the file.

import { AwsClient } from "npm:aws4fetch@1.0.20";
import { HttpError } from "./security.ts";

export const MEDIA_TYPES: Record<string, { ext: string; kind: "image" | "video" }> = {
  "image/jpeg": { ext: "jpg", kind: "image" }, "image/png": { ext: "png", kind: "image" },
  "image/webp": { ext: "webp", kind: "image" }, "image/gif": { ext: "gif", kind: "image" },
  "video/mp4": { ext: "mp4", kind: "video" }, "video/webm": { ext: "webm", kind: "video" },
};
export const EXT_TYPE: Record<string, string> = Object.fromEntries(Object.entries(MEDIA_TYPES).map(([t, m]) => [m.ext, t]));
export const MEDIA_MAX_BYTES = 25 * 1024 * 1024;
export const THUMB_MAX_BYTES = 200 * 1024;
const CACHE = "public, max-age=31536000, immutable";

export interface R2 {
  presignPut(key: string, expiresSeconds: number): Promise<string>;
  head(key: string): Promise<{ size: number; etag: string } | null>;
  first(key: string, n: number): Promise<Uint8Array | null>;
  /** `etag`: copy only if the source is still the object that was verified (the uploader's URL stays valid for 15 minutes). */
  copy(from: string, to: string, contentType: string, etag?: string): Promise<void>; 
  remove(keys: string[]): Promise<void>;
}

export function r2FromEnv(env: (k: string) => string | undefined): R2 | null {
  const acct = env("R2_ACCOUNT_ID"), id = env("R2_ACCESS_KEY_ID"), secret = env("R2_SECRET_ACCESS_KEY"), bucket = env("R2_BUCKET");
  if (!acct || !id || !secret || !bucket) return null;
  const aws = new AwsClient({ accessKeyId: id, secretAccessKey: secret, service: "s3", region: "auto" });
  const url = (key: string) => `https://${acct}.r2.cloudflarestorage.com/${bucket}/${key.split("/").map(encodeURIComponent).join("/")}`;
  return {
    async presignPut(key, expires) {
      const signed = await aws.sign(new Request(`${url(key)}?X-Amz-Expires=${expires}`, { method: "PUT" }), { aws: { signQuery: true } });
      return signed.url;
    },
    async head(key) {
      const res = await aws.fetch(url(key), { method: "HEAD" });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`R2 HEAD ${res.status}`);
      return { size: Number(res.headers.get("content-length") ?? 0), etag: res.headers.get("etag") ?? "" };
    },
    async first(key, n) {
      const res = await aws.fetch(url(key), { headers: { range: `bytes=0-${n - 1}` } });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`R2 GET ${res.status}`);
      return new Uint8Array(await res.arrayBuffer());
    },
    async copy(from, to, contentType, etag) {
      const res = await aws.fetch(url(to), {
        method: "PUT",
        headers: {
          "x-amz-copy-source": `/${bucket}/${from.split("/").map(encodeURIComponent).join("/")}`,
          "x-amz-metadata-directive": "REPLACE", "content-type": contentType, "cache-control": CACHE,
          ...(etag ? { "x-amz-copy-source-if-match": etag } : {}),
        },
      });
      if (!res.ok) throw new Error(`R2 copy ${res.status}`);
    },
    async remove(keys) {
      for (const k of keys) {
        const res = await aws.fetch(url(k), { method: "DELETE" });
        if (!res.ok && res.status !== 404) throw new Error(`R2 delete ${res.status}`);
      }
    },
  };
}

/** Does the start of the file match the declared type? (Content-Type alone is chosen by the uploader.) */
export function magicOk(ext: string, b: Uint8Array): boolean {
  const s = (from: number, text: string) => text.split("").every((c, i) => b[from + i] === c.charCodeAt(0));
  switch (ext) {
    case "jpg": return b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
    case "png": return b[0] === 0x89 && s(1, "PNG");
    case "gif": return s(0, "GIF8");
    case "webp": return s(0, "RIFF") && s(8, "WEBP");
    case "mp4": return s(4, "ftyp");
    case "webm": return b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3;
    default: return false;
  }
}

async function hmac(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("");
}
export const mediaReceipt = (secret: string, uid: string, path: string, exp: number) => hmac(secret, `media|${uid}|${path}|${exp}`);

export async function verifyReceipt(secret: string, uid: string, path: string, exp: number, token: string): Promise<boolean> {
  if (!secret || secret.length < 32 || !Number.isFinite(exp) || exp < Date.now() / 1000) return false;
  const want = await mediaReceipt(secret, uid, path, exp);
  if (want.length !== token.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ token.charCodeAt(i);
  return diff === 0;
}

/** Verify one uploaded file and publish it under its final key. Throws HttpError; never leaves a bad file public. */
export async function promoteUpload(r2: R2, path: string): Promise<void> {
  const ext = path.split(".").pop() ?? "";
  const type = EXT_TYPE[ext];
  const bad = (m: string) => new HttpError(400, "INVALID_MEDIA", m);
  if (!type) throw bad("Unsupported file type.");
  const tmp = `tmp/${path}`;
  const head = await r2.head(tmp);
  if (!head) throw bad("An attachment was not uploaded. Please try again.");
  if (head.size <= 0 || head.size > MEDIA_MAX_BYTES) { await r2.remove([tmp]); throw bad("An attachment is too large."); }
  const bytes = await r2.first(tmp, 16);
  if (!bytes || !magicOk(ext, bytes)) { await r2.remove([tmp]); throw bad("An attachment is not a valid file."); }
  await r2.copy(tmp, path, type, head.etag);
  // Optional thumbnail "<name>-t.webp"; missing or bad is fine (the wall falls back to the full image).
  const t = path.replace(/\.[A-Za-z0-9]+$/, "-t.webp");
  try {
    const th = await r2.head(`tmp/${t}`);
    const tb = th && th.size > 0 && th.size <= THUMB_MAX_BYTES ? await r2.first(`tmp/${t}`, 16) : null;
    if (tb && magicOk("webp", tb)) await r2.copy(`tmp/${t}`, t, "image/webp", th!.etag);
  } catch { /* no thumbnail */ }
}
