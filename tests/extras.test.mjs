// Run with: node --test tests/
import test from "node:test";
import assert from "node:assert/strict";
import { buildPoll, spotifyRef } from "../assets/js/validation.js";

const ID = "4uLU6hMCjMI75M1A2tKUQC";

test("spotifyRef: links, localized links, share params and URIs", () => {
  assert.equal(spotifyRef(`https://open.spotify.com/track/${ID}`), `track/${ID}`);
  assert.equal(spotifyRef(`https://open.spotify.com/intl-id/album/${ID}?si=abc#x`), `album/${ID}`);
  assert.equal(spotifyRef(`spotify:playlist:${ID}`), `playlist/${ID}`);
});

test("spotifyRef: rejects other hosts, user/artist pages, http and bad ids", () => {
  for (const bad of [`https://evil.com/track/${ID}`, `https://open.spotify.com.evil.com/track/${ID}`, `http://open.spotify.com/track/${ID}`,
    `https://open.spotify.com/artist/${ID}`, "https://open.spotify.com/track/short", `https://open.spotify.com/track/${ID}x`, "", null]) {
    assert.equal(spotifyRef(bad), null, String(bad));
  }
});

test("buildPoll: no poll, plain poll, quiz", () => {
  assert.deepEqual(buildPoll("none", false, []), { poll: null });
  assert.deepEqual(buildPoll("poll", true, [{ text: " A " }, { text: "B" }]).poll, { kind: "poll", multi: true, options: ["A", "B"] });
  assert.deepEqual(buildPoll("quiz", false, [{ text: "3" }, { text: "4", correct: true }]).poll, { kind: "quiz", multi: false, options: ["3", "4"], correct: [1] });
});

test("buildPoll: rejects too few, duplicate, missing or surplus correct answers", () => {
  assert.ok(buildPoll("poll", false, [{ text: "A" }, { text: " " }]).error);
  assert.ok(buildPoll("poll", false, [{ text: "A" }, { text: "a" }]).error);
  assert.ok(buildPoll("quiz", false, [{ text: "A" }, { text: "B" }]).error);
  assert.ok(buildPoll("quiz", false, [{ text: "A", correct: true }, { text: "B", correct: true }]).error);
  assert.ok(!buildPoll("quiz", true, [{ text: "A", correct: true }, { text: "B", correct: true }]).error);
});
