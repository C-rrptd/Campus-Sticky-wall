// Re-encodes a video in the browser (WebCodecs via vendored mediabunny, loaded only when a video is attached)
// to MP4 H.264, longest side 960px, 800 kbps, 30 fps max. Output has no input metadata (GPS, device), so it is also a scrub.
// Returns a smaller MP4 File, or null when it cannot or should not (unsupported browser, audio would be lost, no size gain).
// The caller then falls back to the original file.

const MAX_SIDE = 960;
const VIDEO_BPS = 800_000;
const AUDIO_BPS = 64_000;

export async function compressVideo(file) {
  if (typeof VideoEncoder === "undefined" || typeof VideoDecoder === "undefined") return null;
  const mb = await import("../vendor/mediabunny-1.62.1.min.js");
  if (!(await mb.canEncodeVideo("avc"))) return null;
  const aac = await mb.canEncodeAudio("aac");

  const input = new mb.Input({ source: new mb.BlobSource(file), formats: [mb.MP4, mb.WEBM] });
  const output = new mb.Output({ format: new mb.Mp4OutputFormat({ fastStart: "in-memory" }), target: new mb.BufferTarget() });
  try {
    const conv = await mb.Conversion.init({
      input,
      output,
      tags: () => ({}),
      video: (track) => {
        const w = track.displayWidth, h = track.displayHeight;
        const s = Math.min(1, MAX_SIDE / Math.max(w, h));
        // H.264 needs even sizes.
        return { codec: "avc", width: Math.max(2, Math.round((w * s) / 2) * 2), height: Math.max(2, Math.round((h * s) / 2) * 2), fit: "fill", frameRate: 30, bitrate: VIDEO_BPS };
      },
      audio: aac ? { codec: "aac", numberOfChannels: 1, bitrate: AUDIO_BPS } : undefined,
    });
    // A track that cannot be carried over would silently mute or drop the video: keep the original instead.
    if (!conv.isValid || conv.discardedTracks.length > 0) return null;
    await conv.execute();
    const buffer = output.target.buffer;
    if (!buffer || buffer.byteLength === 0 || buffer.byteLength >= file.size) return null;
    return new File([buffer], file.name.replace(/\.[^.]+$/, "") + ".mp4", { type: "video/mp4" });
  } finally {
    input.dispose?.();
  }
}
