// Public leaderboards: guests see them too ("you" highlighting only when signed in).

import { cloneTemplate } from "./component-loader.js";
import { invoke } from "./supabase-client.js";
import { el, errorMessage, formatRupiah, local, refs } from "./utils.js";

const EXPLAIN = {
  referrals: "Friends who joined with your link and verified their email.",
  donations: "Successful voluntary donations, only for donors who chose to be shown (Profile → donor leaderboard). Note payments and ads don’t count.",
};
const HEADER = { referrals: "Referrals", donations: "Donated" };

export async function mount(view, { signal }) {
  view.append(cloneTemplate("tpl-leaderboard"));
  const r = refs(view);
  const state = { kind: local.get("csw.lbKind", "referrals"), period: "all", req: 0 };
  if (!EXPLAIN[state.kind]) state.kind = "referrals";

  const load = async () => {
    const id = ++state.req;
    r.tabs.querySelectorAll("[data-kind]").forEach((t) => t.setAttribute("aria-selected", String(t.dataset.kind === state.kind)));
    r.explain.textContent = `${EXPLAIN[state.kind]} Weeks start Monday 00:00 WIB (Asia/Jakarta).`;
    r.valueHeader.textContent = HEADER[state.kind];
    r.rows.replaceChildren(el("tr", {}, el("td", { colspan: "3", class: "muted" }, "Loading…")));
    try {
      const data = await invoke("leaderboard-data", { kind: state.kind, period: state.period });
      if (id !== state.req || signal.aborted) return;
      r.rows.replaceChildren(...(data.rows.length ? data.rows.map((row) => el("tr", { class: row.is_me ? "is-me" : null },
        el("td", {}, String(row.rank)),
        el("td", {}, row.display_name, row.is_me ? " (you)" : ""),
        el("td", {}, state.kind === "donations" ? formatRupiah(row.value) : row.value)))
        : [el("tr", {}, el("td", { colspan: "3", class: "muted" }, "Nobody here yet."))]));
    } catch (err) {
      if (id !== state.req) return;
      r.rows.replaceChildren(el("tr", {}, el("td", { colspan: "3", class: "wall-error" }, errorMessage(err))));
    }
  };

  r.tabs.addEventListener("click", (e) => {
    const tab = e.target.closest("[data-kind]");
    if (!tab) return;
    state.kind = tab.dataset.kind;
    local.set("csw.lbKind", state.kind);
    load();
  }, { signal });
  view.querySelectorAll("input[name=period]").forEach((input) => input.addEventListener("change", () => {
    state.period = input.value;
    load();
  }, { signal }));
  await load();
}
