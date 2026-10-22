// Public announcements list and the pinned banner shown on the wall.
// Admin editing lives in admin.js (through admin-api).

import { cloneTemplate } from "./component-loader.js";
import { getClient, query } from "./supabase-client.js";
import { formatDate, refs } from "./utils.js";

function fetchPublished(limit = 50, pinnedOnly = false) {
  let q = getClient().from("announcements").select("id,title,body,pinned,published_at")
    .order("pinned", { ascending: false }).order("published_at", { ascending: false }).limit(limit);
  if (pinnedOnly) q = q.eq("pinned", true);
  return query(q);
}

function renderAnnouncement(a) {
  const frag = cloneTemplate("tpl-announcement");
  const r = refs(frag);
  r.title.textContent = a.title;
  r.body.textContent = a.body;
  r.pinned.hidden = !a.pinned;
  if (a.published_at) {
    r.time.dateTime = a.published_at;
    r.time.textContent = formatDate(a.published_at);
  }
  return frag;
}

export async function mount(view) {
  view.append(cloneTemplate("tpl-announcements"));
  const r = refs(view);
  try {
    const items = await fetchPublished();
    r.list.replaceChildren(...items.map(renderAnnouncement));
    r.empty.hidden = items.length > 0;
  } catch (err) {
    r.error.textContent = err.message;
    r.error.hidden = false;
  } finally {
    r.list.removeAttribute("aria-busy");
  }
}

/** Pinned announcements on top of the wall (silently omitted on failure). */
export async function renderPinned(container) {
  try {
    const items = await fetchPublished(2, true);
    container.replaceChildren(...items.map((a) => {
      const node = renderAnnouncement(a);
      node.firstElementChild?.classList.add("announcement--pinned");
      return node;
    }));
  } catch {
    container.replaceChildren();
  }
}
