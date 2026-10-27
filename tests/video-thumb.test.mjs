// Run with: node --test tests/
import test from "node:test";
import assert from "node:assert/strict";
import { makeThumb } from "../assets/js/media-clean.js";
import { compressVideo } from "../assets/js/video-compress.js";

test("no thumbnail for GIFs or videos (they are shown as they are)", async () => {
  assert.equal(await makeThumb(new File(["GIF89a"], "a.gif", { type: "image/gif" })), null);
  assert.equal(await makeThumb(new File(["x"], "a.mp4", { type: "video/mp4" })), null);
});

test("video compression steps aside when the browser has no WebCodecs (the original is uploaded)", async () => {
  assert.equal(await compressVideo(new File(["x"], "a.mp4", { type: "video/mp4" })), null);
});
