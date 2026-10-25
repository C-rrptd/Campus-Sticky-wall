// Privacy: re-draw JPEG/PNG/WebP photos on a canvas before upload so camera
// metadata (GPS location, device, timestamps) is not published. Large images are
// scaled to 4096px. It fails closed: a photo that cannot be cleaned is not uploaded.
// GIFs are passed through. MP4 videos get a best-effort scrub of embedded GPS
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

/** Overwrite ISO 6709 coordinates ("+37.7749-122.4194/") inside an MP4 with zeros, same length. */
async function scrubLocation(file) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const text = new TextDecoder("latin1").decode(bytes); // 1 byte = 1 char, so indexes line up
  let changed = false;
  for (const m of text.matchAll(ISO6709)) {
    changed = true;
    for (let i = m.index; i < m.index + m[0].length; i++) bytes[i] = 0x30; // "0"
  }
  return changed ? new File([bytes], file.name, { type: file.type }) : file;
}

/** Returns a File that is safe to publish, or throws. */
export async function cleanForUpload(file) {
  if (REDRAW.has(file.type)) return redraw(file);
  if (file.type === "video/mp4") return scrubLocation(file);
  return file;
}
