// Checkout + receipt. This page NEVER decides that a payment succeeded: it only
// displays the status stored by the server (set by verified Midtrans
// notifications). Returning from Midtrans just triggers a status re-check.

import { cloneTemplate } from "./component-loader.js";
import { currentUser } from "./auth.js";
import { config } from "./config.js";
import { getClient, invoke, query } from "./supabase-client.js";
import { busy, copyText, el, errorMessage, formatRupiah, local, openDialog, refs, toast } from "./utils.js";

const TOKEN_KEY = (ref) => `csw.receipt.${ref}`;
const PAYMENT_HOSTS = new Set(["app.midtrans.com", "app.sandbox.midtrans.com"]);

/** Keep the guest access token for this order on this device (convenience only). */
export function rememberReceipt(orderRef, token) {
  if (orderRef && token) local.set(TOKEN_KEY(orderRef), token);
}
export function receiptToken(orderRef) {
  return local.get(TOKEN_KEY(orderRef), null);
}
export function receiptLink(orderRef, token) {
  const base = (config.siteUrl || window.location.origin).replace(/\/$/, "");
  return `${base}/#/receipt?order=${encodeURIComponent(orderRef)}&token=${encodeURIComponent(token)}`;
}

const STATUS = {
  awaiting_payment: { kind: "info", text: "Waiting for payment." },
  challenge: { kind: "info", text: "Your payment is being reviewed by the payment provider. We’ll update this page when it’s confirmed." },
  paid: { kind: "success", text: "Payment confirmed. Thank you!" },
  completed_free: { kind: "success", text: "Completed with your free credit — no payment needed." },
  failed: { kind: "error", text: "The payment failed. Nothing was charged for this order; you can create a new one." },
  canceled: { kind: "error", text: "This order was cancelled." },
  expired: { kind: "error", text: "This order expired before payment. Please create it again." },
  partially_refunded: { kind: "info", text: "Part of this payment was refunded." },
  refunded: { kind: "info", text: "This payment was refunded." },
  reversed: { kind: "error", text: "This payment was reversed." },
};
const NOTE_STATUS = {
  awaiting_payment: "Your note will appear after payment is confirmed.",
  pending_moderation: "Your note is waiting for a quick moderation check.",
  published: "Your note is live on the wall!",
  rejected: "Your note was not approved by moderators.",
  removed: "Your note was removed by moderators.",
  withdrawn: "You took this note down.",
  payment_failed: "Your note was not published because payment did not complete.",
  refunded: "Your note was unpublished after a refund.",
};
const TITLES = { publication: "Your sticky note", donation: "Your donation", advertising: "Your campaign" };

export async function mount(view, { params, signal, navigate }) {
  view.append(cloneTemplate("tpl-checkout"));
  const r = refs(view);
  const ref = params.get("order") ?? "";
  const user = currentUser();

  // A receipt link carries the token: store it, then remove it from the address bar.
  const linkToken = params.get("token");
  if (linkToken && /^[A-Za-z0-9_-]{32,64}$/.test(linkToken)) {
    rememberReceipt(ref, linkToken);
    window.history.replaceState(null, "", `${window.location.pathname}#/checkout?order=${encodeURIComponent(ref)}`);
  }
  const token = receiptToken(ref);
  r.ref.textContent = ref;

  if (!/^[A-Za-z0-9_.~-]{8,50}$/.test(ref) || (!token && !user)) {
    r.banner.className = "status-banner status-banner--error";
    r.banner.textContent = "We couldn’t find this order. Open your receipt link, or sign in with the account that placed it.";
    return;
  }

  let order = null;
  let polls = 0;
  let timer = null;
  signal.addEventListener("abort", () => clearTimeout(timer));

  async function load() {
    const res = await invoke("manage-guest-publication", { action: "receipt", order_ref: ref, access_token: token ?? undefined });
    order = res.order;
    render();
  }

  async function availableCredits() {
    if (!user) return 0;
    try {
      return (await query(getClient().from("credits").select("id").eq("status", "available"))).length;
    } catch {
      return 0;
    }
  }

  async function render() {
    r.title.textContent = TITLES[order.kind] ?? "Your order";
    const s = STATUS[order.status] ?? { kind: "info", text: order.status };
    r.banner.className = `status-banner status-banner--${s.kind}`;
    r.banner.textContent = s.text;
    if (order.kind === "publication" && order.note) {
      r.banner.append(el("br"), NOTE_STATUS[order.note.status] ?? "");
    }
    if (order.campaign && order.status === "paid") {
      r.banner.append(el("br"), order.campaign.status === "active" ? "Your campaign is live." : "Your campaign is being reviewed before it goes live.");
    }

    r.items.replaceChildren(...order.items.map((i) => el("tr", {},
      el("th", { scope: "row" }, i.quantity > 1 ? `${i.name} × ${i.quantity}` : i.name),
      el("td", {}, formatRupiah(BigInt(i.unit_amount) * BigInt(i.quantity))))));
    r.total.textContent = formatRupiah(order.total_amount);

    if (order.note) {
      const preview = el("div", { class: `note note--${["yellow", "pink", "blue", "green", "orange", "purple"].includes(order.note.color) ? order.note.color : "yellow"} note--static` },
        el("p", { class: "note__body" }, order.note.body), el("footer", { class: "note__meta" }, `— ${order.note.author_name}`));
      r.notePreview.replaceChildren(preview);
    }

    const payable = order.status === "awaiting_payment" && order.total_amount !== "0";
    const editable = payable && !order.payment_started;
    r.pay.hidden = !payable;
    r.pay.textContent = order.payment_started ? "Continue payment" : "Pay securely with Midtrans";
    r.refresh.hidden = !(order.status === "awaiting_payment" || order.status === "challenge");
    r.withdraw.hidden = !(order.note && ["published", "pending_moderation"].includes(order.note.status));

    r.methods.hidden = !(payable && order.payment_methods.length);
    r.methodList.replaceChildren(...order.payment_methods.map((m) => el("li", {}, m.label)));
    if (payable && order.payment_methods.length === 0) {
      r.error.textContent = "No enabled payment method can process this total right now. Your amount was not changed — please contact us.";
      r.pay.hidden = true;
    }

    const hasCredit = order.discount_amount !== "0";
    if (user && order.kind === "publication" && editable && (hasCredit || (await availableCredits()) > 0)) {
      r.creditRow.hidden = false;
      r.useCredit.checked = hasCredit;
    } else r.creditRow.hidden = true;

    if (!user && token) {
      r.receipt.hidden = false;
      r.receiptLink.value = receiptLink(ref, token);
    }
  }

  function poll() {
    if (signal.aborted || !order || order.status !== "awaiting_payment" || polls >= 20) return;
    polls += 1;
    timer = setTimeout(async () => {
      try {
        await load();
      } catch { /* keep polling */ }
      poll();
    }, 3000);
  }

  r.pay.addEventListener("click", () => busy(r.pay, async () => {
    r.error.textContent = "";
    try {
      const res = await invoke("create-payment", { order_ref: ref, access_token: token ?? undefined });
      const target = new URL(res.redirect_url);
      if (target.protocol !== "https:" || !PAYMENT_HOSTS.has(target.hostname)) throw new Error("Unexpected payment page address.");
      window.location.assign(target.href);
    } catch (err) {
      r.error.textContent = errorMessage(err);
    }
  }), { signal });

  r.refresh.addEventListener("click", () => busy(r.refresh, async () => {
    try {
      await load();
      toast("Status updated.", "info", 2000);
    } catch (err) {
      r.error.textContent = errorMessage(err);
    }
  }), { signal });

  r.useCredit.addEventListener("change", () => busy(r.useCredit, async () => {
    r.error.textContent = "";
    try {
      const res = await invoke("redeem-referral-credit", { order_ref: ref, apply: r.useCredit.checked });
      order = res.order;
      await render();
      if (order.status === "completed_free") toast("Published with your free credit!", "success");
    } catch (err) {
      r.useCredit.checked = !r.useCredit.checked;
      r.error.textContent = errorMessage(err);
    }
  }), { signal });

  r.withdraw.addEventListener("click", async () => {
    const ok = await openDialog({ title: "Take your note down?", body: el("p", {}, "The note will be removed from the wall. This can’t be undone and is not a refund."), okLabel: "Take it down", danger: true });
    if (!ok) return;
    await busy(r.withdraw, async () => {
      try {
        const res = await invoke("manage-guest-publication", { action: "withdraw", order_ref: ref, access_token: token ?? undefined });
        order = res.order;
        await render();
      } catch (err) {
        r.error.textContent = errorMessage(err);
      }
    });
  }, { signal });

  r.copyReceipt.addEventListener("click", () => copyText(r.receiptLink.value), { signal });

  try {
    await load();
    if (params.get("returned")) {
      r.banner.append(el("br"), "Checking your payment with the provider…");
      poll();
    }
  } catch (err) {
    r.banner.className = "status-banner status-banner--error";
    r.banner.textContent = err.status === 404 || err.status === 401
      ? "We couldn’t find this order. Open your receipt link, or sign in with the account that placed it."
      : `Couldn’t load the order: ${errorMessage(err)}`;
    r.pay.hidden = true;
    void navigate;
  }
}
