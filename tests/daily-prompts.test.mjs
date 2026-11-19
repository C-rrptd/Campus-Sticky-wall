import test from "node:test";
import assert from "node:assert/strict";
import { PROMPTS } from "../assets/js/daily-prompts.js";

test("daily prompts: enough of them, all filled, none repeated", () => {
  assert.ok(PROMPTS.length >= 150);
  for (const p of PROMPTS) {
    assert.equal(p.length, 2);
    for (const s of p) assert.ok(s.trim() && s.length <= 100, `bad prompt: ${s}`);
  }
  for (const i of [0, 1]) assert.equal(new Set(PROMPTS.map((p) => p[i].toLowerCase())).size, PROMPTS.length, "duplicate text in column " + i);
});
