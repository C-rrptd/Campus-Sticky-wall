// Run with: node --test tests/
import test from "node:test";
import assert from "node:assert/strict";

globalThis.localStorage = { getItem: () => JSON.stringify("id"), setItem() {} };
const { t } = await import("../assets/js/i18n.js");

test("t: exact matches, keeping surrounding whitespace", () => {
  assert.equal(t("Save"), "Simpan");
  assert.equal(t("  Check notes "), "  Periksa catatan ");
});

test("t: sentences with numbers and names", () => {
  assert.equal(t("Waiting list (3 waiting)"), "Daftar tunggu (3 menunggu)");
  assert.equal(t("Note approved."), "Catatan disetujui.");
  assert.equal(t("Delete note"), "Hapus catatan");
  assert.equal(t("5 min ago"), "5 menit lalu");
});

test("t: unknown text stays as it is", () => {
  assert.equal(t("Some text nobody translated"), "Some text nobody translated");
});

test("every admin status word has an Indonesian text", async () => {
  const { ID_EXTRA } = await import("../assets/js/i18n-extra.js");
  for (const k of ["Waiting for your review", "Live on the wall", "Running now", "Paid", "All money returned", "Full: every slot is sold", "Too empty: few slots sold"]) {
    assert.ok(ID_EXTRA[k], k);
  }
});
