import assert from "node:assert/strict";
import { renderOutbox } from "./ad_jobs.ts";

Deno.test("waitlist mail names the location, price and hold deadline", () => {
  const m = renderOutbox({
    id: "1", kind: "waitlist_slot_free", to_email: "a@b.co",
    payload: { location: "Campus X", duration: 7, price: "60000", hold_expires_at: "2026-11-01T10:00:00Z" },
  }, "https://site.test");
  assert.ok(m);
  assert.match(m.subject, /Campus X/);
  assert.match(m.text, /7 days/);
  assert.match(m.text, /https:\/\/site\.test\/#\/advertise/);
});

Deno.test("unknown mail kind is not rendered", () => {
  assert.equal(renderOutbox({ id: "1", kind: "nope", to_email: "a@b.co", payload: {} }, ""), null);
});

Deno.test("auction mails say what happened and never name another bidder", () => {
  const base = { id: "1", to_email: "a@b.co" };
  const won = renderOutbox({ ...base, kind: "auction_won", payload: { location: "Campus X", amount: "200000", pay_by: "2026-11-01T10:00:00Z", period_start: "2026-11-05" } }, "https://s.test");
  assert.ok(won && /won/.test(won.subject) && /next bidder/.test(won.text));
  const out = renderOutbox({ ...base, kind: "auction_outbid", payload: { location: "Campus X", amount: "80000", ends_at: "2026-11-01T10:00:00Z" } }, "https://s.test");
  assert.ok(out && /higher bid/.test(out.text));
  for (const k of ["auction_ending", "auction_lost", "auction_pay_reminder", "auction_canceled"]) {
    assert.ok(renderOutbox({ ...base, kind: k, payload: { location: "L", amount: "1", pay_by: "2026-11-01T10:00:00Z", ends_at: "2026-11-01T10:00:00Z" } }, ""), k);
  }
});
