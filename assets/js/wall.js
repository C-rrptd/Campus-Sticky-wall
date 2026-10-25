// The public wall: sorting, campus filter, pagination, pinned announcements
// and a few clearly labelled sponsored placements.

import { cloneTemplate } from "./component-loader.js";
import { rpc } from "./supabase-client.js";
import { renderNote } from "./notes.js";
import { renderPinned } from "./announcements.js";
import { loadFeatured, renderPromotion } from "./promotions.js";
import { buildLocationPicker, getLocationPref, promotionArgs, setLocationPref } from "./location.js";
import { errorMessage, local, refs } from "./utils.js";

const PAGE = 24;
const SPONSOR_EVERY = 8;
const MAX_SPONSORED = 2;

export async function mount(view, { signal }) {
  view.append(cloneTemplate("tpl-wall"));
  const r = refs(view);
  const state = { offset: 0, sort: local.get("csw.wallSort", "newest"), loc: getLocationPref(), sponsored: [], requestId: 0 };
  if (!["newest", "top", "contribution"].includes(state.sort)) state.sort = "newest";
  r.sort.value = state.sort;

  renderPinned(r.pinned);
  r.location.append(buildLocationPicker({
    value: state.loc,
    compact: true,
    signal,
    onChange: (loc) => {
      state.loc = loc;
      setLocationPref(loc);
      reload();
    },
  }));

  async function loadSponsored() {
    try {
      state.sponsored = await rpc("get_promotions", { ...promotionArgs(state.loc), p_placement: "random", p_category: null, p_limit: MAX_SPONSORED });
    } catch {
      state.sponsored = [];
    }
  }

  async function loadPage(reset) {
    const id = ++state.requestId;
    r.grid.setAttribute("aria-busy", "true");
    r.error.hidden = true;
    r.more.hidden = true;
    try {
      if (reset) await Promise.all([loadSponsored(), loadFeatured(r.featured, state.loc, signal)]);
      const notes = await rpc("get_wall", { p_sort: state.sort, p_campus: state.loc.campus || null, p_limit: PAGE, p_offset: state.offset });
      if (id !== state.requestId || signal.aborted) return; // stale response
      if (reset) r.grid.replaceChildren();
      notes.forEach((note, i) => {
        r.grid.append(renderNote(note, { signal }));
        const position = state.offset + i + 1;
        const slot = position / SPONSOR_EVERY - 1;
        if (position % SPONSOR_EVERY === 0 && state.sponsored[slot]) r.grid.append(renderPromotion(state.sponsored[slot], { compact: true }));
      });
      if (reset && notes.length > 0 && notes.length < SPONSOR_EVERY && state.sponsored[0]) {
        r.grid.append(renderPromotion(state.sponsored[0], { compact: true }));
      }
      state.offset += notes.length;
      r.empty.hidden = state.offset > 0;
      r.more.hidden = notes.length < PAGE;
    } catch (err) {
      if (id !== state.requestId) return;
      r.error.textContent = `Couldn’t load notes: ${errorMessage(err)}`;
      r.error.hidden = false;
    } finally {
      if (id === state.requestId) r.grid.setAttribute("aria-busy", "false");
    }
  }

  function reload() {
    state.offset = 0;
    loadPage(true);
  }

  r.sort.addEventListener("change", () => {
    state.sort = r.sort.value;
    local.set("csw.wallSort", state.sort);
    reload();
  }, { signal });
  r.more.addEventListener("click", () => loadPage(false), { signal });

  await loadPage(true);
}
