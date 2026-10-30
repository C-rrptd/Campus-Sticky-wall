import test from "node:test";
import assert from "node:assert/strict";
import { isUsername, loginLabel, loginToEmail } from "../assets/js/validation.js";

test("username maps to placeholder email and back", () => {
  assert.equal(loginToEmail(" Tester1 "), "tester1@users.csw.invalid");
  assert.equal(loginLabel("tester1@users.csw.invalid"), "tester1");
});
test("real emails pass through unchanged", () => {
  assert.equal(loginToEmail(" a@b.co "), "a@b.co");
  assert.equal(loginLabel("a@b.co"), "a@b.co");
});
test("username rules", () => {
  assert.ok(isUsername("ab_c.d-1"));
  for (const bad of ["ab", "a b c", "x".repeat(31), "a@b"]) assert.ok(!isUsername(bad), bad);
});
