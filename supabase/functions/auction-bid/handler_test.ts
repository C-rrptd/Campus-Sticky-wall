// deno test supabase/functions/auction-bid/
import { strictEqual as eq } from "node:assert";
import { handler } from "./handler.ts";
import type { Deps } from "../_shared/auth.ts";

const AUCTION = "11111111-2222-3333-4444-555555555555";
const CAMPAIGN = "66666666-7777-8888-9999-000000000000";

function deps(calls: Array<[string, Record<string, unknown>]>): Deps {
  const db = {
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.push([name, args]);
      return Promise.resolve({ data: name === "check_rate_limit" ? true : { ok: true }, error: null });
    },
  };
  return {
    db, userDb: () => db, fetch, env: () => undefined,
    verifyJwt: () => Promise.resolve({ id: "user-1", email: "a@b.co" }),
    // deno-lint-ignore no-explicit-any
  } as any as Deps;
}
const req = (body: unknown) => new Request("https://x.test/auction-bid", {
  method: "POST", headers: { authorization: "Bearer aaa.bbb.ccc", "content-type": "application/json", "cf-connecting-ip": "9.9.9.9" },
  body: JSON.stringify(body),
});

Deno.test("passes the authenticated user, IP and amount to place_bid", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const res = await handler(req({ auction_id: AUCTION, campaign_id: CAMPAIGN, amount: 70000 }), deps(calls));
  eq(res.status, 200);
  const bid = calls.find(([n]) => n === "place_bid")![1];
  eq(bid.p_bidder, "user-1");
  eq(bid.p_ip, "9.9.9.9");
  eq(String(bid.p_amount), "70000");
  eq(bid.p_buy_now, false);
});

Deno.test("client cannot choose the bidder", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  await handler(req({ auction_id: AUCTION, campaign_id: CAMPAIGN, amount: 70000, bidder: "someone-else", p_bidder: "x" }), deps(calls));
  eq(calls.find(([n]) => n === "place_bid")![1].p_bidder, "user-1");
});

Deno.test("rate limits before placing the bid", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  await handler(req({ auction_id: AUCTION, campaign_id: CAMPAIGN, amount: 70000 }), deps(calls));
  eq(calls[0][0], "check_rate_limit");
});
