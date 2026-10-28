// Background jobs for advertising: end-of-campaign report emails (Phase 1), waitlist holds and notifications (Phase 2),
// auction settlement (Phase 3). One entry point, runAdJobs, called by the ad-maintenance function (cron) and by the
// admin "Run ad jobs now" button. Every job is idempotent: running it twice does nothing extra.

import type { Deps } from "./auth.ts";
import { rpc } from "./security.ts";
import { sendEmail } from "./email.ts";

const rp = (n: unknown) => `Rp${Number(n).toLocaleString("id-ID")}`;

interface DueReport { id: string; title: string; contact_email: string; impressions: number; clicks: number }

/** Emails a summary to advertisers whose campaign has ended. Marks a campaign done only after the email was accepted. */
export async function sendCampaignReports(deps: Deps): Promise<{ due: number; sent: number }> {
  const due = (await rpc<DueReport[]>(deps.db, "campaigns_due_report", {})) ?? [];
  const site = (deps.env("SITE_URL") ?? "").replace(/\/$/, "");
  const sent: string[] = [];
  for (const c of due) {
    const ctr = c.impressions > 0 ? `${((c.clicks * 100) / c.impressions).toFixed(2)}%` : "n/a";
    const ok = await sendEmail(deps.env, deps.fetch, c.contact_email, `Your campaign report: "${c.title}"`,
      `Your campaign "${c.title}" has ended.\n\nViews: ${c.impressions}\nClicks: ${c.clicks}\nClick-through rate: ${ctr}\n\n` +
      `Daily numbers, referrers and a CSV download are in your dashboard:\n${site}/#/advertise\n`);
    if (ok) sent.push(c.id);
  }
  if (sent.length) await rpc(deps.db, "mark_report_emailed", { p_ids: sent });
  return { due: due.length, sent: sent.length };
}

interface OutboxRow { id: string; kind: string; to_email: string; payload: Record<string, unknown> }

/** Subject + text for each queued mail kind. Unknown kinds are skipped (and retried up to the attempts cap). */
export function renderOutbox(row: OutboxRow, site: string): { subject: string; text: string } | null {
  const p = row.payload;
  const link = `${site}/#/advertise`;
  if (row.kind === "waitlist_slot_free") {
    const until = new Date(String(p.hold_expires_at)).toLocaleString("en-GB", { timeZone: "Asia/Jakarta", dateStyle: "medium", timeStyle: "short" });
    return {
      subject: `A featured slot is free: ${p.location}`,
      text: `A featured slot just opened for ${p.location} (${p.duration} days, ${rp(p.price)}).\n\n` +
        `We are holding it for you until ${until} (WIB). Submit your campaign before then:\n${link}\n\n` +
        `After that the slot goes to the next person on the waitlist.\n`,
    };
  }
  const when = (x: unknown) => new Date(String(x)).toLocaleString("en-GB", { timeZone: "Asia/Jakarta", dateStyle: "medium", timeStyle: "short" });
  if (row.kind === "auction_outbid") {
    return { subject: `You were outbid: ${p.location}`,
      text: `Someone placed a higher bid (${rp(p.amount)}) on the ${p.location} featured slot.\nThe auction ends ${when(p.ends_at)} (WIB).\n\nBid again:\n${link}\n` };
  }
  if (row.kind === "auction_ending") {
    return { subject: `Auction ending within the hour: ${p.location}`,
      text: `The auction for ${p.location} ends ${when(p.ends_at)} (WIB). You have placed a bid.\n\n${link}\n` };
  }
  if (row.kind === "auction_won") {
    return { subject: `You won the ${p.location} slot`,
      text: `You won the featured slot for ${p.location} at ${rp(p.amount)}, starting ${p.period_start}.\n\n` +
        `Pay before ${when(p.pay_by)} (WIB) to keep it. If it is not paid in time the slot goes to the next bidder and your account gets a strike.\n\n${link}\n` };
  }
  if (row.kind === "auction_lost") {
    return { subject: `Auction result: ${p.location}`,
      text: p.final
        ? `The auction for ${p.location} ended without a winner. Your ad stays approved.\n\n${link}\n`
        : `You did not win the ${p.location} auction. If the winner does not pay in time, the slot may be offered to you next.\n\n${link}\n` };
  }
  if (row.kind === "auction_pay_reminder") {
    return { subject: `Reminder: pay for your ${p.location} slot`,
      text: `Your winning bid of ${rp(p.amount)} for ${p.location} must be paid before ${when(p.pay_by)} (WIB).\n\n${link}\n` };
  }
  if (row.kind === "auction_canceled") {
    return { subject: `Auction canceled: ${p.location}`,
      text: `The auction for ${p.location} was canceled. Nothing was charged and your ad stays approved.\n\n${link}\n` };
  }
  return null;
}

/** Sends queued mail. A row is marked sent only after the email service accepted it. */
export async function sendOutbox(deps: Deps): Promise<{ queued: number; sent: number }> {
  const rows = (await rpc<OutboxRow[]>(deps.db, "ad_outbox_claim", { p_limit: 25 })) ?? [];
  const site = (deps.env("SITE_URL") ?? "").replace(/\/$/, "");
  let sent = 0;
  for (const r of rows) {
    const m = renderOutbox(r, site);
    if (m && await sendEmail(deps.env, deps.fetch, r.to_email, m.subject, m.text)) {
      await rpc(deps.db, "ad_outbox_mark_sent", { p_id: r.id });
      sent++;
    }
  }
  return { queued: rows.length, sent };
}

export { rp };

export async function runAdJobs(deps: Deps): Promise<Record<string, unknown>> {
  const out: Record<string, unknown> = {};
  out.reports = await sendCampaignReports(deps);
  out.waitlist = await rpc(deps.db, "process_ad_waitlist", {});
  out.proposals = await rpc(deps.db, "generate_price_proposals", {});
  out.auctions = await rpc(deps.db, "run_auction_jobs", {});
  out.mail = await sendOutbox(deps);
  return out;
}
