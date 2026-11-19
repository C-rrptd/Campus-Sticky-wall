import test from "node:test";
import assert from "node:assert/strict";
import { leftParts, msToWeekEnd, rivalry } from "../assets/js/fomo-math.js";
import { wrapLines } from "../assets/js/share-card.js";

const wib = (y, mo, d, h = 0, mi = 0) => Date.UTC(y, mo - 1, d, h - 7, mi); // a WIB wall-clock time

test("week ends Monday 00:00 WIB", () => {
  assert.equal(msToWeekEnd(wib(2026, 11, 22, 20)), 4 * 3600e3);          // Sunday 20:00
  assert.equal(msToWeekEnd(wib(2026, 11, 23, 0)), 7 * 864e5);            // the reset moment starts a full week
  assert.equal(msToWeekEnd(wib(2026, 11, 23, 0, 1)), 7 * 864e5 - 6e4);
  assert.equal(msToWeekEnd(wib(2026, 11, 19, 12)), 3.5 * 864e5);         // Thursday noon (today)
});

test("countdown units", () => {
  assert.deepEqual(leftParts(3.5 * 864e5), ["days", 3]);
  assert.deepEqual(leftParts(30 * 3600e3), ["hours", 30]);
  assert.deepEqual(leftParts(90 * 6e4), ["hours", 1]);
  assert.deepEqual(leftParts(5 * 6e4), ["min", 5]);
  assert.deepEqual(leftParts(-5), ["min", 0]);
});

const row = (rank, id, value) => ({ rank, campus_id: id, display_name: id.toUpperCase(), value: String(value) });
test("rivalry", () => {
  const rows = [row(1, "a", 40), row(2, "b", 30), row(2, "c", 30), row(4, "d", 5)];
  assert.deepEqual(rivalry(rows, "a"), { name: "A", rank: 1, rival: "B", gap: 10, kind: "ahead" });
  assert.deepEqual(rivalry(rows, "b"), { name: "B", rank: 2, rival: "A", gap: 11, kind: "behind" });
  assert.equal(rivalry(rows, "c").gap, 1);                                // tied with the campus above: one vote passes it
  assert.equal(rivalry(rows, "d").gap, 26);
  assert.equal(rivalry([row(1, "a", 3), row(1, "b", 3)], "a").kind, "tied");
  assert.equal(rivalry(rows, "zzz"), null);                               // not on the board
  assert.equal(rivalry([row(1, "a", 3)], "a"), null);                     // alone: no rival to show
});

test("wrapLines", () => {
  const m = (s) => s.length * 10;
  assert.deepEqual(wrapLines(m, "aa bb cc", 50), ["aa bb", "cc"]);
  assert.deepEqual(wrapLines(m, "abcdefghij", 40), ["abcd", "efgh", "ij"]); // one long word is split
  assert.deepEqual(wrapLines(m, "ab  \n cd", 100), ["ab cd"]);
  assert.deepEqual(wrapLines(m, "", 100), []);
});

import { msToDayEnd } from "../assets/js/fomo-math.js";
test("daily top resets at 00:00 WIB", () => {
  assert.equal(msToDayEnd(wib(2026, 11, 19, 20)), 4 * 3600e3);
  assert.equal(msToDayEnd(wib(2026, 11, 20, 0)), 864e5);
});
