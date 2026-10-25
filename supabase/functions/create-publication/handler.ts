// POST /functions/v1/create-publication
// Validates a sticky-note request, lets the database price it (customer-chosen
// amount >= Rp5.000, no maximum, plus decorations, minus an optional credit),
// creates the pending order + note and returns the order summary together with
// a one-time access token for the guest receipt. Zero-total orders (credit
// covers everything) complete here without any payment.

import { type Deps, type Handler, optionalUser } from "../_shared/auth.ts";
import { clientIp, json, randomToken, rateLimit, readJson, rpc, sha256Hex } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

const COLORS = ["yellow", "pink", "blue", "green", "orange", "purple"] as const;

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user } = await optionalUser(req, deps);

  await rateLimit(deps.db, `create-publication:ip:${clientIp(req)}`, 20, 600);
  if (user) await rateLimit(deps.db, `create-publication:user:${user.id}`, 20, 600);

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
  };
  // Uploads need a session (storage policy) and must sit in the caller's own folder.
  if (input.media.length && (!user || input.media.some((m) => !m.path.startsWith(`${user.id}/`)))) {
    return json(req, 400, { error: { code: "INVALID_MEDIA", message: "Sign in to attach files." } }, deps.env);
  }
  if (body.confirm_amount !== input.amount) {
    // The customer must explicitly confirm the exact amount they chose.
    return json(req, 400, { error: { code: "AMOUNT_NOT_CONFIRMED", message: "Please confirm the amount you want to pay." } }, deps.env);
  }

  const accessToken = randomToken();
  const useReferral = input.use_post_credit || input.deco_credits > 0;
  if (useReferral && input.use_credit) {
    return json(req, 400, { error: { code: "CREDIT_CONFLICT", message: "Choose either the old Rp5.000 credit or referral credits, not both." } }, deps.env);
  }
  // One transaction: order, referral credits (free post / free decorations), media and sticker positions.
  const order = await rpc(deps.db, "create_publication_order_full", {
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
    p_media: input.media,
    p_use_post_credit: input.use_post_credit,
    p_deco_credits: input.deco_credits,
    p_positions: input.positions,
  });
  return json(req, 201, { order, access_token: accessToken }, deps.env);
};

