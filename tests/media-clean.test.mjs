// Run with: node --test tests/
import test from "node:test";
import assert from "node:assert/strict";
import { cleanForUpload } from "../assets/js/media-clean.js";

const enc = (s) => new TextEncoder().encode(s);
function mp4With(location) {
  const head = Uint8Array.from([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6d, 0x70, 0x34, 0x32]); // "....ftypmp42"
  const payload = enc(`\u00a9xyz\u0000\u0012\u15c7${location}`);
  return new File([head, payload, new Uint8Array(64).fill(7)], "clip.mp4", { type: "video/mp4" });
}

test("MP4: embedded GPS coordinates are overwritten, length unchanged", async () => {
  const input = mp4With("+37.7749-122.4194+012.000/");
  const out = await cleanForUpload(input);
  const text = new TextDecoder("latin1").decode(new Uint8Array(await out.arrayBuffer()));
  assert.equal(out.size, input.size);
  assert.ok(!/37\.7749|122\.4194/.test(text), "coordinates must be gone");
  assert.ok(text.includes("ftypmp42"), "file structure kept");
});

test("MP4 without coordinates is returned unchanged", async () => {
  const input = new File([enc("....ftypmp42"), new Uint8Array(100).fill(9)], "a.mp4", { type: "video/mp4" });
  assert.equal(await cleanForUpload(input), input);
});

test("large MP4: coordinates in the first and last chunk are scrubbed, middle untouched", async () => {
  const MB = 1024 * 1024;
  const head = mp4With("+37.7749-122.4194+012.000/");
  const middle = new Uint8Array(5 * MB).fill(7);
  const tail = enc("©xyz\u0000\u0012ᗇ+01.2345-103.9876/");
  const input = new File([head, middle, tail], "big.mp4", { type: "video/mp4" });
  const out = await cleanForUpload(input);
  const bytes = new Uint8Array(await out.arrayBuffer());
  const text = new TextDecoder("latin1").decode(bytes);
  assert.equal(out.size, input.size);
  assert.ok(!/37\.7749|122\.4194|01\.2345|103\.9876/.test(text), "coordinates must be gone");
  assert.equal(bytes[3 * MB], 7, "middle kept");
});

test("animated WebP passes through (a canvas redraw would keep one frame)", async () => {
  const riff = (flags) => {
    const b = new Uint8Array(30);
    b.set(enc("RIFF"), 0); b.set(enc("WEBP"), 8); b.set(enc("VP8X"), 12);
    b[20] = flags;
    return new File([b], "a.webp", { type: "image/webp" });
  };
  const animated = riff(0x02);
  assert.equal(await cleanForUpload(animated), animated);
  await assert.rejects(() => cleanForUpload(riff(0))); // still image: re-drawn, which needs a browser canvas
});

test("GIF and WebM pass through untouched", async () => {
  const gif = new File([enc("GIF89a-----------")], "a.gif", { type: "image/gif" });
  assert.equal(await cleanForUpload(gif), gif);
  const webm = new File([Uint8Array.from([0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0, 0, 0, 0, 0])], "a.webm", { type: "video/webm" });
  assert.equal(await cleanForUpload(webm), webm);
});

test("a photo that cannot be re-drawn is rejected (fails closed)", async () => {
  const jpg = new File([Uint8Array.from([0xff, 0xd8, 0xff, 0xe0])], "a.jpg", { type: "image/jpeg" });
  await assert.rejects(() => cleanForUpload(jpg)); // no canvas/createImageBitmap outside a browser
});
