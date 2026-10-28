// Run with: node --test tests/
import test from "node:test";
import assert from "node:assert/strict";
import { ID } from "../assets/js/i18n-id.js";

// translate() looks text up after trimming and collapsing whitespace, so a key that is not already in that form can never match.
test("dictionary keys are normalized and values are non-empty", () => {
  for (const [k, v] of Object.entries(ID)) {
    assert.equal(k, k.trim().replace(/\s+/g, " "), `key not normalized: ${JSON.stringify(k)}`);
    assert.ok(typeof v === "string" && v.trim(), `empty translation for ${JSON.stringify(k)}`);
  }
});

test("admin console strings are present", () => {
  for (const k of ["Overview", "Pending approval", "Save auction settings", "Administrators only"]) assert.ok(Object.hasOwn(ID, k), k);
});
