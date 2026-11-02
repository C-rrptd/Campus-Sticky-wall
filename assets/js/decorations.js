// Upload a community decoration (a transparent PNG sticker). The checks here only save the user a rejected upload:
// the bucket enforces PNG and 512 KB, RLS enforces "your own pending id", and an admin reviews every picture.

import { cloneTemplate } from "./component-loader.js";
import { currentUser, isAdmin } from "./auth.js";
import { getClient, invoke, paintArt, query, rpc } from "./supabase-client.js";
import { busy, el, errorMessage, formatDate, refs, toast } from "./utils.js";
import { decoChecks, parseRupiah } from "./validation.js";

const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/** Read the picked file: real PNG bytes, pixel size, and whether the four corners are see-through. */
async function inspect(file) {
  const info = { type: file.type, size: file.size, width: 0, height: 0, cornersClear: false };
  const head = new Uint8Array(await file.slice(0, 8).arrayBuffer());
  if (!PNG_MAGIC.every((b, i) => head[i] === b)) return { ...info, type: "not-png" }; // the browser's file.type comes from the extension only
  const bmp = await createImageBitmap(file);
  info.width = bmp.width;
  info.height = bmp.height;
  const c = new OffscreenCanvas(bmp.width, bmp.height);
  const ctx = c.getContext("2d", { willReadFrequently: true });
  ctx.drawImage(bmp, 0, 0);
  const { width: w, height: h } = bmp;
  info.cornersClear = [[0, 0], [w - 1, 0], [0, h - 1], [w - 1, h - 1]].every(([x, y]) => ctx.getImageData(x, y, 1, 1).data[3] < 250);
  bmp.close();
  return info;
}

const STATUS = { pending: "Unfinished (no image or not approved)", approved: "Live", rejected: "Rejected" };

export async function mount(view, { signal }) {
  if (!currentUser()) { view.append(cloneTemplate("tpl-signin-required")); return; }
  // UI gate only: submit_decoration, the storage policy and admin_review_decoration each re-check admin on the server.
  if (!(await isAdmin())) { view.append(el("p", { class: "notice" }, "Administrators only.")); return; }
  view.append(cloneTemplate("tpl-decorations"));
  const r = refs(view);
  const client = getClient();
  let picked = null;      // the file that passed every check
  let retry = null;       // { id, uploaded }: a row exists but a later step failed; resume from there instead of creating another

  const paintMine = async () => {
    try {
      const rows = await query(client.from("decoration_submissions").select("id,name,status,created_at").eq("user_id", currentUser().id).order("created_at", { ascending: false }));
      r.mine.replaceChildren(...(rows.length ? rows.map((s) => el("tr", {},
        el("td", {}, paintArt(el("span", { class: `deco-swatch deco-${s.id}`, "aria-hidden": "true" }), s.id)),
        el("td", {}, s.name), el("td", {}, `${STATUS[s.status] ?? s.status} · ${formatDate(s.created_at)}`), el("td", {}, "")))
        : [el("tr", {}, el("td", { colspan: "4", class: "muted" }, "You have not uploaded anything yet."))]));
    } catch (err) {
      r.mine.replaceChildren(el("tr", {}, el("td", { colspan: "4", class: "field__error" }, errorMessage(err))));
    }
  };
  paintMine();

  r.form.file.addEventListener("change", async () => {
    picked = null;
    r.send.disabled = true;
    r.error.textContent = "";
    r.preview.style.removeProperty("--deco-img");
    const file = r.form.file.files[0];
    if (!file) { r.checks.replaceChildren(); return; }
    let checks;
    try {
      checks = decoChecks(await inspect(file));
    } catch {
      checks = [{ ok: false, text: "This file could not be read as a picture" }];
    }
    r.checks.replaceChildren(...checks.map((c) => el("li", { class: c.ok ? "is-ok" : "is-bad" }, c.text)));
    if (checks.every((c) => c.ok)) {
      picked = file;
      r.send.disabled = false;
      r.preview.style.setProperty("--deco-img", `url("${URL.createObjectURL(file)}")`); // small, freed when the page unloads
    }
  }, { signal });

  r.form.addEventListener("submit", (e) => {
    e.preventDefault();
    const name = r.form.name.value.trim();
    if (name.length < 2 || name.length > 50) { r.error.textContent = "Name must be 2–50 characters."; return; }
    if (!picked) { r.error.textContent = "Choose a PNG that passes every check."; return; }
    const price = parseRupiah(r.form.price.value || "0");
    if (!price.ok) { r.error.textContent = price.error; return; }
    busy(r.send, async () => {
      r.error.textContent = "";
      try {
        retry ??= { id: await rpc("submit_decoration", { p_name: name }), uploaded: false };
        if (!retry.uploaded) {
          const { error } = await client.storage.from("decoration-art").upload(`${retry.id}.png`, picked, { contentType: "image/png", cacheControl: "31536000" });
          if (error) throw new Error("The upload failed. Press the button again to retry.");
          retry.uploaded = true;
        }
        await invoke("admin-api", { action: "review_decoration", params: { id: retry.id, approve: true, name, price: price.digits } });
        retry = null;
        toast("Added to the catalog.", "success");
        r.form.reset();
        picked = null;
        r.send.disabled = true;
        r.checks.replaceChildren();
        r.preview.style.removeProperty("--deco-img");
        paintMine();
      } catch (err) {
        r.error.textContent = errorMessage(err);
      }
    });
  }, { signal });
}
