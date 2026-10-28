// Ad click tracking helpers. Clicks are counted on the SERVER: the "Learn more" link goes through the ad-click Edge
// Function, which records the click (with where the visitor came from) and then redirects to the advertiser's own link.
// An ad blocker cannot hide a normal link. The destination is read from the database, never from this URL.

import { config } from "./config.js";
import { currentUser, isAdmin } from "./auth.js";
import { getLocationPref, promotionArgs } from "./location.js";
import { session } from "./utils.js";

const LANDING = "csw.landing";

/** Remember how this visit started (referrer host + UTM tags), once per browser tab. */
export function captureLanding() {
  if (session.get(LANDING)) return;
  try {
    const q = new URLSearchParams(window.location.search);
    let ref = "";
    if (document.referrer) {
      const h = new URL(document.referrer).hostname;
      if (h && h !== window.location.hostname) ref = h;
    }
    session.set(LANDING, { us: q.get("utm_source") ?? "", um: q.get("utm_medium") ?? "", uc: q.get("utm_campaign") ?? "", ref });
  } catch { /* tracking must never break the page */ }
}

/** URL of the counting redirect for one campaign, for the visitor's current location. */
export function clickUrl(campaignId, loc = getLocationPref()) {
  const a = promotionArgs(loc);
  const l = session.get(LANDING, {});
  const q = new URLSearchParams({ c: campaignId });
  const add = (k, v) => { if (v) q.set(k, String(v)); };
  add("country", a.p_country); add("region", a.p_region); add("city", a.p_city); add("campus", a.p_campus);
  add("ref", l.ref); add("us", l.us); add("um", l.um); add("uc", l.uc);
  return `${config.supabaseUrl}/functions/v1/ad-click?${q}`;
}

/** Point a link at the counting redirect. Signed-in admins add adm=1 so their own clicks are not counted. */
export function trackLink(link, campaignId) {
  captureLanding();
  link.href = clickUrl(campaignId);
  if (currentUser()) isAdmin().then((yes) => { if (yes) link.href = `${clickUrl(campaignId)}&adm=1`; }).catch(() => {});
}
