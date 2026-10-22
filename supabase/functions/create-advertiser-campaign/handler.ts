// POST /functions/v1/create-advertiser-campaign
// Creates or updates a DRAFT campaign (content, schedule, targeting). Status,
// price, payment and approval are never accepted from the client.

import { type Deps, type Handler, requireUser } from "../_shared/auth.ts";
import { HttpError, json, rateLimit, readJson, rpc } from "../_shared/security.ts";
import * as v from "../_shared/validation.ts";

const CATEGORIES = [
  "local_business", "student_discount", "campus_event", "workshop", "competition",
  "recruitment", "student_service", "club_event", "other",
] as const;
const LEVELS = ["global", "country", "region", "city", "campus"] as const;

function targets(raw: unknown) {
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > 20) {
    throw new HttpError(400, "INVALID_TARGETS", "Choose between 1 and 20 target locations.");
  }
  return raw.map((t) => {
    if (!t || typeof t !== "object") throw new HttpError(400, "INVALID_TARGETS", "Invalid target.");
    const level = v.oneOf((t as Record<string, unknown>).level, "Target level", LEVELS);
    const id = (t as Record<string, unknown>).id;
    if (level === "global") return { level };
    if (level === "country") {
      if (typeof id !== "string" || !/^[A-Za-z]{2}$/.test(id)) throw new HttpError(400, "INVALID_TARGETS", "Invalid country.");
      return { level, id: id.toUpperCase() };
    }
    return { level, id: v.uuid(id, "Target") };
  });
}

export const handler: Handler = async (req: Request, deps: Deps) => {
  const body = await readJson(req);
  const { user } = await requireUser(req, deps);
  await rateLimit(deps.db, `create-advertiser-campaign:user:${user.id}`, 30, 600);

  const creativePath = body.creative_path == null || body.creative_path === "" ? null : body.creative_path;
  if (creativePath !== null) {
    // Must be an object the caller uploaded into their own storage folder.
    if (typeof creativePath !== "string" ||
        !new RegExp(`^${user.id}/[0-9a-f-]{36}\\.(png|jpg|jpeg|webp)$`).test(creativePath)) {
      throw new HttpError(400, "INVALID_CREATIVE", "Upload the image again.");
    }
  }

  const result = await rpc(deps.db, "upsert_campaign_draft", {
    p_owner: user.id,
    p_campaign_id: v.uuid(body.campaign_id, "Campaign", true),
    p_advertiser_name: v.str(body.advertiser_name, "Advertiser name", { min: 2, max: 80 }),
    p_contact_email: v.email(body.contact_email, "Contact email"),
    p_title: v.str(body.title, "Title", { min: 3, max: 80 }),
    p_description: v.str(body.description, "Description", { max: 500, multiline: true }),
    p_category: v.oneOf(body.category, "Category", CATEGORIES),
    p_creative_path: creativePath,
    p_destination_url: v.httpsUrl(body.destination_url, "Destination link"),
    p_product_id: v.str(body.product_id, "Package", { min: 2, max: 60 }),
    p_requested_start: v.isoDate(body.requested_start, "Start date"),
    p_targets: targets(body.targets),
  });
  return json(req, 200, result, deps.env);
};

