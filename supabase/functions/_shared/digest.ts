// Daily "top note of yesterday" email. digest_claim (SQL) decides who is due (local 8 AM) and marks them sent first,
// so a crash can skip a day for someone but never double-sends. Unsubscribe links are HMAC-signed with CRON_SECRET.

import type { Deps } from "./auth.ts";
import { rpc } from "./security.ts";
import { sendEmail } from "./email.ts";

export async function unsubToken(secret: string, uid: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode("digest:" + uid)));
  return [...sig].map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface Claim { user_id: string; email: string; display_name: string | null; note_id: string; body: string; author_name: string | null; votes: number; campus_scoped: boolean }

export async function sendDigests(deps: Deps): Promise<{ claimed: number; sent: number }> {
  const secret = deps.env("CRON_SECRET") ?? "";
  const site = (deps.env("SITE_URL") ?? "").replace(/\/$/, "");
  const api = (deps.env("SUPABASE_URL") ?? "").replace(/\/$/, "");
  const rows = (await rpc<Claim[]>(deps.db, "digest_claim", { p_limit: 100 })) ?? [];
  let sent = 0;
  for (const c of rows) {
    const excerpt = c.body.length > 280 ? c.body.slice(0, 277) + "…" : c.body;
    const unsub = `${api}/functions/v1/digest-unsubscribe?u=${c.user_id}&t=${await unsubToken(secret, c.user_id)}`;
    const where = c.campus_scoped ? "on your campus" : "on Campus Sticky Wall";
    const ok = await sendEmail(deps.env, deps.fetch, c.email, `Yesterday's top note ${where}`,
      `Hi${c.display_name ? " " + c.display_name : ""},\n\nThe most upvoted note ${where} yesterday (${c.votes} upvote${Number(c.votes) === 1 ? "" : "s"}):\n\n"${excerpt}"\n— ${c.author_name || "Anonymous"}\n\n` +
      `See it: ${site}/#/note?id=${c.note_id}\n\nStop these emails: ${unsub}\n`,
      { "List-Unsubscribe": `<${unsub}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" });
    if (ok) sent++;
  }
  return { claimed: rows.length, sent };
}
