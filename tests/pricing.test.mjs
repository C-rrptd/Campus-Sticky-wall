// Run with: node --test tests/
import test from "node:test";
import assert from "node:assert/strict";
import { pricing, setPricing, validatePublicationAmount } from "../assets/js/validation.js";

test("Rp2.499 rejected, Rp2.500 accepted", () => {
  assert.equal(validatePublicationAmount("2499").ok, false);
  assert.equal(validatePublicationAmount("2.500").ok, true);
  assert.equal(validatePublicationAmount("Rp 2500").digits, "2500");
});
test("cap, decimals, signs, exponents", () => {
  assert.equal(validatePublicationAmount("1000000").ok, true);
  assert.equal(validatePublicationAmount("1000001").ok, false);
  for (const bad of ["25,5", "2500.5x", "-3000", "1e5", "", "abc"]) assert.equal(validatePublicationAmount(bad).ok, false, bad);
});
test("pricing comes from config rows and ignores junk", () => {
  setPricing([{ key: "min_publication_price", value: 3000 }, { key: "price_presets", value: [3000, "x", 6000] }, { key: "max_publication_price", value: "nope" }]);
  assert.equal(pricing.min, 3000n);
  assert.deepEqual(pricing.presets, [3000n, 6000n]);
  assert.equal(pricing.max, 1000000n);
  setPricing([{ key: "min_publication_price", value: 2500 }]);
});
