import test from "node:test";
import assert from "node:assert/strict";
import { decoChecks, isOtp } from "../assets/js/validation.js";

test("OTP is exactly six digits", () => {
  assert.ok(isOtp("123456") && isOtp(" 000001 "));
  for (const bad of ["12345", "1234567", "12345a", "", null, "12 456"]) assert.ok(!isOtp(bad), String(bad));
});

const good = { type: "image/png", size: 10_000, width: 512, height: 512, cornersClear: true };
const failed = (info) => decoChecks({ ...good, ...info }).filter((c) => !c.ok).length;

test("a transparent 512px PNG passes every decoration check", () => assert.equal(failed({}), 0));
test("decoration checks reject each broken rule", () => {
  assert.equal(failed({ type: "image/jpeg" }), 1);
  assert.equal(failed({ size: 512 * 1024 + 1 }), 1);
  assert.equal(failed({ height: 400 }), 1);
  assert.equal(failed({ width: 100, height: 100 }), 1);
  assert.equal(failed({ width: 600, height: 600 }), 1);
  assert.equal(failed({ cornersClear: false }), 1);
});
