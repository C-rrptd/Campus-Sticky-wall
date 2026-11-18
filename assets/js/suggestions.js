// Suggestion box. Decoration ideas may attach one requirements file (private bucket, own folder, 2 MB).

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { getClient, rpc } from "./supabase-client.js";
import { busy, el, errorMessage, formatDate, refs, toast } from "./utils.js";

const EXT = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "application/pdf": "pdf", "text/plain": "txt" };
const MAX_BYTES = 2 * 1024 * 1024;
const STATUS = { new: "Received", reviewing: "Being reviewed", planned: "Planned", done: "Done", declined: "Not planned" };
const KIND = { feature: "New feature", improvement: "Improvement", decoration: "New decoration", bug: "Bug", other: "Other" };

export async function mount(view, { signal }) {
  const user = currentUser();
  if (!user) {
    const frag = cloneTemplate("tpl-signin-required");
    refs(frag).message.textContent = "Sign in to send a suggestion.";
    view.append(frag);
    return;
  }
  view.append(cloneTemplate("tpl-suggestions"));
  const r = refs(view);

  const loadList = async () => {
    try {
      const rows = (await rpc("my_suggestions")) ?? [];
      r.list.replaceChildren(...(rows.length
        ? rows.map((s) => el("li", {}, `${formatDate(s.created_at)} · ${KIND[s.kind] ?? s.kind} · ${s.title} · ${STATUS[s.status] ?? s.status}${s.admin_note ? ` — ${s.admin_note}` : ""}`))
        : [el("li", { class: "muted" }, "Nothing sent yet.")]));
    } catch (err) {
      r.list.replaceChildren(el("li", { class: "wall-error" }, errorMessage(err)));
    }
  };

  r.kind.addEventListener("change", () => { r.fileBox.hidden = r.kind.value !== "decoration"; if (r.fileBox.hidden) r.file.value = ""; }, { signal });

  r.form.addEventListener("submit", async (e) => {
    e.preventDefault();
    r.error.textContent = "";
    const f = new FormData(r.form);
    const file = r.kind.value === "decoration" ? r.file.files?.[0] : null;
    if (file && (!EXT[file.type] || file.size > MAX_BYTES)) { r.error.textContent = "The file must be PNG, JPG, WebP, PDF or TXT and at most 2 MB."; return; }
    await busy(r.send, async () => {
      try {
        let path = null;
        if (file) {
          path = `${user.id}/${crypto.randomUUID()}.${EXT[file.type]}`;
          const { error } = await getClient().storage.from("suggestion-files").upload(path, file, { contentType: file.type });
          if (error) throw error;
        }
        await rpc("submit_suggestion", { p_kind: r.kind.value, p_title: f.get("title"), p_body: f.get("body"), p_attachment: path });
        r.form.reset();
        r.fileBox.hidden = true;
        toast("Thank you! Your suggestion was sent.", "success");
        loadList();
      } catch (err) { r.error.textContent = errorMessage(err); }
    });
  }, { signal });

  loadList();
}
