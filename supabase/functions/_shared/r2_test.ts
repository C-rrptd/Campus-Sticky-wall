// Run with: deno test supabase/functions/_shared/r2_test.ts
import { magicOk, mediaReceipt, promoteUpload, type R2, verifyReceipt } from "./r2.ts";

function eq(a: unknown, b: unknown, msg: string) {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg}: got ${JSON.stringify(a)}`);
}
const bytes = (s: string, at = 0) => { const b = new Uint8Array(16); [...s].forEach((c, i) => (b[at + i] = c.charCodeAt(0))); return b; };

function fakeR2(files: Record<string, { size: number; head: Uint8Array }>) {
  const log: string[] = [];
  const r2: R2 = {
    presignPut: () => Promise.resolve("https://x"),
    head: (k) => Promise.resolve(files[k] ? { size: files[k].size, etag: '"e1"' } : null),
    first: (k) => Promise.resolve(files[k]?.head ?? null),
    copy: (f, t, type, etag) => { log.push(`copy ${f} -> ${t} ${type} ${etag}`); return Promise.resolve(); },
    remove: (ks) => { log.push(`remove ${ks.join(",")}`); return Promise.resolve(); },
  };
  return { r2, log };
}

Deno.test("magic bytes", () => {
  eq(magicOk("jpg", new Uint8Array([0xff, 0xd8, 0xff, 0])), true, "jpg");
  eq(magicOk("png", new Uint8Array([0x89, 0x50, 0x4e, 0x47])), true, "png");
  eq(magicOk("gif", bytes("GIF89a")), true, "gif");
  eq(magicOk("webp", (() => { return bytes("RIFFxxxxWEBP"); })()), true, "webp");
  eq(magicOk("mp4", bytes("ftyp", 4)), true, "mp4");
  eq(magicOk("jpg", bytes("<html>")), false, "html is not a jpg");
});

Deno.test("receipt binds user, path and expiry", async () => {
  const secret = "s".repeat(40), exp = Math.floor(Date.now() / 1000) + 600;
  const t = await mediaReceipt(secret, "u1", "a/b.jpg", exp);
  eq(await verifyReceipt(secret, "u1", "a/b.jpg", exp, t), true, "valid");
  eq(await verifyReceipt(secret, "u2", "a/b.jpg", exp, t), false, "other user");
  eq(await verifyReceipt(secret, "u1", "a/c.jpg", exp, t), false, "other path");
  eq(await verifyReceipt(secret, "u1", "a/b.jpg", exp - 1000, await mediaReceipt(secret, "u1", "a/b.jpg", exp - 1000)), false, "expired");
  eq(await verifyReceipt("short", "u1", "a/b.jpg", exp, t), false, "weak secret");
});

Deno.test("promoteUpload verifies then copies; bad files are deleted", async () => {
  const jpg = new Uint8Array([0xff, 0xd8, 0xff, 0]);
  const ok = fakeR2({ "tmp/a/b.jpg": { size: 1000, head: jpg } });
  await promoteUpload(ok.r2, "a/b.jpg");
  eq(ok.log, ["copy tmp/a/b.jpg -> a/b.jpg image/jpeg \"e1\""], "copied with server-chosen type, only if unchanged since the check");

  const fake = fakeR2({ "tmp/a/b.jpg": { size: 1000, head: bytes("<html>") } });
  let failed = false;
  try { await promoteUpload(fake.r2, "a/b.jpg"); } catch { failed = true; }
  eq(failed, true, "html renamed .jpg rejected");
  eq(fake.log, ["remove tmp/a/b.jpg"], "rejected file deleted");

  const big = fakeR2({ "tmp/a/b.mp4": { size: 30 * 1024 * 1024, head: bytes("ftyp", 4) } });
  failed = false;
  try { await promoteUpload(big.r2, "a/b.mp4"); } catch { failed = true; }
  eq(failed, true, "oversize rejected");

  failed = false;
  try { await promoteUpload(fakeR2({}).r2, "a/b.jpg"); } catch { failed = true; }
  eq(failed, true, "missing upload rejected");
});
