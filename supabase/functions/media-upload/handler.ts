// POST /functions/v1/media-upload   { files: [{ type, size, thumb? }] }   (signed-in members)
// Returns, per file, presigned R2 upload URLs plus a receipt that create-publication checks. 501 when R2 is not configured,
// so the site falls back to Supabase Storage.

import { type Deps, type Handler, requireUser } from "../_shared/auth.ts";
import { HttpError, json, rateLimit, readJson } from "../_shared/security.ts";
import { MEDIA_MAX_BYTES, MEDIA_TYPES, mediaReceipt } from "../_shared/r2.ts";

const URL_TTL = 15 * 60;       // upload window
const RECEIPT_TTL = 3 * 3600;  // time allowed to finish the order

export const handler: Handler = async (req: Request, deps: Deps) => {
  const { user } = await requireUser(req, deps);
  const secret = deps.env("MEDIA_TOKEN_SECRET") ?? "";
  if (!deps.r2 || secret.length < 32) throw new HttpError(501, "R2_NOT_CONFIGURED", "Cloudflare storage is not set up.");
  await rateLimit(deps.db, `media-upload:user:${user.id}`, 40, 600);
  const body = await readJson(req);
  const files = Array.isArray(body.files) ? body.files : [];
  if (files.length < 1 || files.length > 4) throw new HttpError(400, "INVALID_MEDIA", "Attach 1 to 4 files.");
  const exp = Math.floor(Date.now() / 1000) + RECEIPT_TTL;
  const out = [];
  for (const f of files as { type?: string; size?: number; thumb?: boolean }[]) {
    const meta = MEDIA_TYPES[String(f?.type)];
    if (!meta || !Number.isInteger(f.size) || (f.size as number) < 1 || (f.size as number) > MEDIA_MAX_BYTES) {
      throw new HttpError(400, "INVALID_MEDIA", "Use JPG, PNG, WebP, GIF, MP4 or WebM up to 25 MB.");
    }
    const path = `${crypto.randomUUID()}/${crypto.randomUUID()}.${meta.ext}`;
    out.push({
      path, kind: meta.kind, exp, token: await mediaReceipt(secret, user.id, path, exp),
      put: await deps.r2.presignPut(`tmp/${path}`, URL_TTL),
      thumb_put: meta.kind === "image" && meta.ext !== "gif" && f.thumb ? await deps.r2.presignPut(`tmp/${path.replace(/\.[A-Za-z0-9]+$/, "-t.webp")}`, URL_TTL) : null,
    });
  }
  return json(req, 200, { data: out }, deps.env);
};
