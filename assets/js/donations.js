// Voluntary donations: explicit amount + confirmation, never bundled into a
// purchase. Donor recognition is opt-in via the profile setting.

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { getClient, invoke, query } from "./supabase-client.js";
import { rememberReceipt } from "./checkout.js";
import { parseRupiah } from "./validation.js";
import { busy, errorMessage, formatRupiah, refs } from "./utils.js";

export async function mount(view, { signal, navigate }) {
  view.append(cloneTemplate("tpl-donations"));
  const r = refs(view);
  const user = currentUser();
  const limits = { min: 1000n, max: null };

  try {
    const rows = await query(getClient().from("site_config").select("key,value").in("key", ["donation_min_amount", "donation_max_amount"]));
    for (const row of rows) {
      if (row.key === "donation_min_amount") limits.min = BigInt(String(row.value));
      if (row.key === "donation_max_amount") limits.max = BigInt(String(row.value));
    }
  } catch { /* defaults */ }
  r.limits.textContent = `Between ${formatRupiah(limits.min)} and ${limits.max ? formatRupiah(limits.max) : "any amount"}.`;

  if (user) {
    r.recognitionRow.hidden = false;
    r.guestNote.hidden = true;
    try {
      const [profile] = await query(getClient().from("profiles").select("donor_recognition").eq("id", user.id));
      r.recognition.checked = Boolean(profile?.donor_recognition);
      r.recognition.dataset.initial = String(r.recognition.checked);
    } catch {
      r.recognitionRow.hidden = true;
    }
  }

  const update = () => {
    const p = parseRupiah(r.amount.value);
    r.confirmAmount.textContent = p.ok ? formatRupiah(p.value) : "—";
    if (r.confirm.dataset.amount !== (p.ok ? p.digits : "")) {
      r.confirm.checked = false;
      r.confirm.dataset.amount = p.ok ? p.digits : "";
    }
  };
  r.amount.addEventListener("input", update, { signal });
  r.chips.addEventListener("click", (e) => {
    const chip = e.target.closest("[data-amount]");
    if (!chip) return;
    r.amount.value = chip.dataset.amount;
    update();
  }, { signal });
  update();

  r.form.addEventListener("submit", (e) => {
    e.preventDefault();
    busy(r.form.querySelector("button[type=submit]"), async () => {
      r.error.textContent = "";
      const p = parseRupiah(r.amount.value);
      if (!p.ok) { r.error.textContent = p.error; return; }
      if (p.value < limits.min || (limits.max && p.value > limits.max)) { r.error.textContent = r.limits.textContent; return; }
      if (!r.confirm.checked) { r.error.textContent = "Please confirm your donation amount."; return; }
      try {
        if (user && !r.recognitionRow.hidden && String(r.recognition.checked) !== r.recognition.dataset.initial) {
          await query(getClient().from("profiles").update({ donor_recognition: r.recognition.checked }).eq("id", user.id));
        }
        const res = await invoke("create-donation", { amount: p.digits, confirm_amount: p.digits });
        rememberReceipt(res.order.order_ref, res.access_token);
        navigate("/checkout", { order: res.order.order_ref });
      } catch (err) {
        r.error.textContent = errorMessage(err);
      }
    });
  }, { signal });
}
