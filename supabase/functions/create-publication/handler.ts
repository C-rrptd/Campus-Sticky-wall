// POST /functions/v1/create-publication
// Validates a sticky-note request, lets the database price it (customer-chosen
// amount between the configured minimum and cap, plus decorations, minus an
// optional free weekly post / promo code / credits), creates the pending order +
// note and returns the order summary together with a one-time access token for
// the guest receipt. Zero-total orders complete here without any payment.
// The database (create_publication_order_v2) enforces every rule; the account
// is NOT stored on the note.

import { type Deps, type Handler, optionalUser } from "../_shared/auth.ts";
import { clientIp, HttpError, json, randomToken, rateLimit, readJson, rpc, sha256Hex } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

const COLORS = ["yellow", "pink", "blue", "green", "orange", "purple"] as const;

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user } = await optionalUser(req, deps);

  // Post creation / purchases: 10 per 10 minutes per IP and per account.
  await rateLimit(deps.db, `create-publication:ip:${clientIp(req)}`, 10, 600);
  if (user) await rateLimit(deps.db, `create-publication:user:${user.id}`, 10, 600);

  const input = {
    author_name: v.str(body.author_name, "Author name", { max: 40 }),
    body: v.str(body.body, "Note text", { max: 500, multiline: true }),
    color: v.oneOf(body.color ?? "yellow", "Colour", COLORS),
    social_link: v.socialUrl(body.social_link, "Social link"),
    show_amount: v.bool(body.show_amount, "show_amount", true),
    amount: v.amount(body.amount),
    decorations: v.idList(body.decorations, "Decorations", 10),
    use_credit: v.bool(body.use_credit, "use_credit", false),
    use_post_credit: v.bool(body.use_post_credit, "use_post_credit", false),
    deco_credits: typeof body.deco_credits === "number" && Number.isInteger(body.deco_credits) && body.deco_credits >= 0 && body.deco_credits <= 10 ? body.deco_credits : 0,
    campus_id: v.uuid(body.campus_id, "Campus", true),
    media: v.mediaList(body.media, "Media", 4),
    positions: v.positionMap(body.decoration_positions),
    promo: v.promoCode(body.promo_code),
    use_free_post: v.bool(body.use_free_post, "use_free_post", false),
  };
  // Promo guesses are throttled separately from posting (same buckets as check-promo).
  if (input.promo) {
    await rateLimit(deps.db, `promo:ip:${clientIp(req)}`, 15, 600);
    if (user) await rateLimit(deps.db, `promo:user:${user.id}`, 15, 600);
  }
  // Uploads need a session (storage policy) and must sit in the caller's own folder.
  if (input.media.length && (!user || input.media.some((m) => !m.path.startsWith(`${user.id}/`)))) {
    return json(req, 400, { error: { code: "INVALID_MEDIA", message: "Sign in to attach files." } }, deps.env);
  }
  // Amounts above the configured threshold (default Rp100.000) need the customer to confirm the exact amount.
  // The database decides whether confirmation is required; we only report whether it was given.
  const confirmed = body.confirm_amount === input.amount;

  const accessToken = randomToken();
  const useReferral = input.use_post_credit || input.deco_credits > 0;
  if (useReferral && input.use_credit) {
    return json(req, 400, { error: { code: "CREDIT_CONFLICT", message: "Choose either the old Rp5.000 credit or referral credits, not both." } }, deps.env);
  }
  // Uploads land in <user-id>/…; the public URL would reveal the account. Move them to a random folder first.
  const media = await anonymiseMediaPaths(deps, input.media);
  // One transaction: order, discounts, referral credits (free post / free decorations), media and sticker positions.
  const order = await rpc(deps.db, "create_publication_order_v2", {
    p_user_id: user?.id ?? null,
    p_author_name: input.author_name,
    p_body: input.body,
    p_color: input.color,
    p_social_link: input.social_link,
    p_show_amount: input.show_amount,
    p_amount: input.amount,
    p_decorations: input.decorations,
    p_use_credit: input.use_credit,
    p_guest_token_hash: await sha256Hex(accessToken),
    p_campus_id: input.campus_id,
    p_media: media,
    p_use_post_credit: input.use_post_credit,
    p_deco_credits: input.deco_credits,
    p_positions: input.positions,
    p_promo: input.promo,
    p_use_free_post: input.use_free_post,
    p_confirmed: confirmed,
  });
  return json(req, 201, { order, access_token: accessToken }, deps.env);
};


/** <user-id>/<file> -> <random uuid>/<file>. Fails closed: if the move fails the order is not created. */
async function anonymiseMediaPaths(deps: Deps, media: { path: string; kind: "image" | "video" }[]) {
  if (media.length === 0 || !deps.storage?.move) return media;
  const out: { path: string; kind: "image" | "video" }[] = [];
  for (const m of media) {
    const to = `${crypto.randomUUID()}/${m.path.split("/")[1]}`;
    try {
      await deps.storage.move(m.path, to);
    } catch {
      throw new HttpError(502, "MEDIA_MOVE_FAILED", "Could not prepare your attachment. Please try again.");
    }
    out.push({ path: to, kind: m.kind });
  }
  return out;
}
