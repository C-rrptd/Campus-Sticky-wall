// Promotions feed: sponsored listings by location. The advertiser form lives in advertise.js.

import { cloneTemplate } from "./component-loader.js";
import { creativeUrl, rpc } from "./supabase-client.js";
import { buildLocationPicker, getLocationPref, promotionArgs, setLocationPref } from "./location.js";
import { errorMessage, formatDate, refs, safeUrl, session } from "./utils.js";

const CATEGORY_LABELS = {
  local_business: "Local business", student_discount: "Student discount", campus_event: "Campus event",
  workshop: "Workshop", competition: "Competition", recruitment: "Internship / jobs",
  student_service: "Student service", club_event: "Club event", other: "Promotion",
};

/** Featured Placement: up to two pinned spots above the feed (also used on the wall). */
export async function loadFeatured(container, loc, signal, category = null) {
  try {
    const items = await rpc("get_promotions", { ...promotionArgs(loc), p_placement: "featured", p_category: category, p_limit: 2 });
    if (!signal?.aborted) container.replaceChildren(...items.map((p) => renderPromotion(p)));
  } catch {
    container.replaceChildren();
  }
}

let observer = null;
function trackImpression(node, id) {
  const key = `csw.seen.${id}`;
  if (session.get(key)) return;
  if (!("IntersectionObserver" in window)) return;
  observer ??= new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const cid = entry.target.dataset.campaignId;
      observer.unobserve(entry.target);
      if (session.get(`csw.seen.${cid}`)) continue;
      session.set(`csw.seen.${cid}`, true);
      rpc("record_campaign_event", { p_campaign_id: cid, p_kind: "impression" }).catch(() => {});
    }
  }, { threshold: 0.5 });
  observer.observe(node);
}

/** Render one sponsored listing (always labelled "Sponsored"). */
export function renderPromotion(p, { compact = false } = {}) {
  const frag = cloneTemplate("tpl-promotion-card");
  const r = refs(frag);
  r.root.dataset.campaignId = p.id;
  if (compact) r.root.classList.add("promo--inline");
  r.category.textContent = CATEGORY_LABELS[p.category] ?? "Promotion";
  r.title.textContent = p.title;
  r.description.textContent = p.description;
  r.advertiser.textContent = p.advertiser_name;
  r.ends.textContent = p.ends_at ? `until ${formatDate(p.ends_at)}` : "";
  const img = creativeUrl(p.creative_path);
  if (img) {
    r.image.src = img;
    r.image.alt = p.title;
    r.image.hidden = false;
  }
  const href = safeUrl(p.destination_url, false);
  if (href) {
    r.link.href = href;
    r.link.addEventListener("click", () => {
      rpc("record_campaign_event", { p_campaign_id: p.id, p_kind: "click" }).catch(() => {});
    });
  } else r.link.hidden = true;
  trackImpression(r.root, p.id);
  return frag;
}

export async function mount(view, { signal }) {
  view.append(cloneTemplate("tpl-promotions"));
  const r = refs(view);
  let loc = getLocationPref();
  let requestId = 0;

  const load = async () => {
    const id = ++requestId;
    r.grid.setAttribute("aria-busy", "true");
    r.error.hidden = true;
    try {
      const items = await rpc("get_promotions", {
        ...promotionArgs(loc), p_placement: "random", p_category: r.category.value || null, p_limit: 48,
      });
      if (id !== requestId || signal.aborted) return;
      r.grid.replaceChildren(...items.map((p) => renderPromotion(p)));
      r.empty.hidden = items.length > 0;
      await loadFeatured(r.featured, loc, signal, r.category.value || null);
    } catch (err) {
      if (id !== requestId) return;
      r.error.textContent = `Couldn’t load promotions: ${errorMessage(err)}`;
      r.error.hidden = false;
    } finally {
      if (id === requestId) r.grid.setAttribute("aria-busy", "false");
    }
  };

  signal.addEventListener("abort", () => { observer?.disconnect(); observer = null; }, { once: true });
  r.location.append(buildLocationPicker({ value: loc, compact: true, signal, onChange: (v) => { loc = v; setLocationPref(v); load(); } }));
  r.category.addEventListener("change", load, { signal });
  await load();
}
