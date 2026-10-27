// Privacy: re-draw JPEG/PNG/WebP photos on a canvas before upload so camera
// metadata (GPS location, device, timestamps) is not published. Large images are
// scaled to 4096px. It fails closed: a photo that cannot be cleaned is not uploaded.
// GIFs and animated WebP are passed through. MP4 videos get a best-effort scrub of embedded GPS
// coordinates; other video metadata is not touched.

const REDRAW = new Set(["image/jpeg", "image/png", "image/webp"]);
const ISO6709 = /[+-]\d{2,3}\.\d{2,}[+-]\d{2,3}\.\d{2,}(?:[+-]\d+(?:\.\d+)?)?\/?/g;

async function redraw(file) {
  const bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });
  try {
    const scale = Math.min(1, 4096 / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, file.type, 0.92));
    if (!blob || blob.size === 0) throw new Error("re-encode failed");
    return new File([blob], file.name, { type: file.type });
  } finally {
    bitmap.close?.();
  }
}

// shortcut: only the first and last 2 MB are scanned (camera apps put the location atom in moov/udta at either end),
// so a 25 MB video is never decoded into one giant string; a coordinate cut by a window edge survives. Upgrade: walk the atoms.
const WINDOW = 2 * 1024 * 1024;

/** Zero ISO 6709 coordinates ("+37.7749-122.4194/") in a chunk, same length. Returns the new bytes, or null if nothing matched. */
async function scrubChunk(blob) {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const text = new TextDecoder("latin1").decode(bytes); // 1 byte = 1 char, so indexes line up
  let changed = false;
  for (const m of text.matchAll(ISO6709)) {
    changed = true;
    bytes.fill(0x30, m.index, m.index + m[0].length); // "0"
  }
  return changed ? bytes : null;
}

async function scrubLocation(file) {
  if (file.size <= 2 * WINDOW) {
    const bytes = await scrubChunk(file);
    return bytes ? new File([bytes], file.name, { type: file.type }) : file;
  }
  const tailAt = file.size - WINDOW;
  const [head, tail] = await Promise.all([scrubChunk(file.slice(0, WINDOW)), scrubChunk(file.slice(tailAt))]);
  if (!head && !tail) return file;
  return new File([head ?? file.slice(0, WINDOW), file.slice(WINDOW, tailAt), tail ?? file.slice(tailAt)], file.name, { type: file.type });
}

/** RIFF/WEBP with the VP8X "animation" flag. A canvas redraw would keep only its first frame, so these pass through like GIFs. */
async function isAnimatedWebp(file) {
  const b = new Uint8Array(await file.slice(0, 32).arrayBuffer());
  const tag = (from, to) => String.fromCharCode(...b.slice(from, to));
  return b.length >= 21 && tag(8, 12) === "WEBP" && tag(12, 16) === "VP8X" && (b[20] & 0x02) !== 0;
}

/** Returns a File that is safe to publish, or throws. */
export async function cleanForUpload(file) {
  if (file.type === "image/webp" && (await isAnimatedWebp(file))) return file;
  if (REDRAW.has(file.type)) return redraw(file);
  if (file.type === "video/mp4") return scrubLocation(file);
  return file;
}
