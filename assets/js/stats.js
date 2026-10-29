// Public platform statistics (views and clicks overall and per location). Refreshes every minute while visible.

import { cloneTemplate } from "./component-loader.js";
import { rpc } from "./supabase-client.js";
import { el, errorMessage, formatDate, refs } from "./utils.js";

const n = (v) => Number(v).toLocaleString("en-US");
const ctr = (views, clicks) => (Number(views) > 0 ? `${((Number(clicks) * 100) / Number(views)).toFixed(2)}%` : "—");

export async function mount(view, { signal }) {
  view.append(cloneTemplate("tpl-stats"));
  const r = refs(view);
  const load = async () => {
    if (document.hidden && r.updated.textContent) return;
    try {
      const s = await rpc("get_public_stats");
      if (signal.aborted) return;
      r.error.textContent = "";
      const none = Number(s.views_total) === 0 && Number(s.clicks_total) === 0;
      r.empty.hidden = !none;
      r.body.hidden = none;
      if (!none) {
        r.viewsTotal.textContent = n(s.views_total); r.clicksTotal.textContent = n(s.clicks_total);
        r.views30.textContent = n(s.views_30d); r.clicks30.textContent = n(s.clicks_30d);
        r.rows.replaceChildren(...s.locations.map((l) => el("tr", {},
          el("td", {}, l.label), el("td", {}, n(l.views)), el("td", {}, n(l.clicks)), el("td", {}, ctr(l.views, l.clicks)), el("td", {}, n(l.views_30d)))));
      }
      r.updated.textContent = `Updated ${formatDate(s.updated_at, true)}${s.since ? ` · counting since ${s.since}` : ""}`;
    } catch (err) {
      r.error.textContent = `Couldn’t load statistics: ${errorMessage(err)}`;
    }
  };
  await load();
  const timer = setInterval(() => { if (!document.hidden) load(); }, 60000);
  signal.addEventListener("abort", () => clearInterval(timer));
}
