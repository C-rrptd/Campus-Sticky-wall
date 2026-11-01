// TEMPORARY diagnostic. Deploy, call once, then DELETE it.
// Never returns the server key. Shows which User-Agent (if any) gets past the 403,
// the function's egress IP, and the response headers that reveal who is blocking.
const SNAP = "https://app.sandbox.midtrans.com/snap/v1/transactions";

Deno.serve(async () => {
  const key = Deno.env.get("MIDTRANS_SERVER_KEY") ?? "";
  const auth = "Basic " + btoa(`${key}:`);
  const uas: Array<string | null> = [
    null, // Deno default
    "CampusStickyWall/1.0 (+https://campusstickywall.app)", // what payments.ts sends now
    "CampusStickyWall/1.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
  ];
  const ip = await fetch("https://api.ipify.org?format=json").then((r) => r.text()).catch(() => "ipify failed");
  const out: unknown[] = [];
  for (let i = 0; i < uas.length; i++) {
    const headers: Record<string, string> = {
      Accept: "application/json",
      "Content-Type": "application/json",
      Authorization: auth,
    };
    if (uas[i]) headers["User-Agent"] = uas[i]!;
    try {
      const r = await fetch(SNAP, {
        method: "POST",
        headers,
        body: JSON.stringify({ transaction_details: { order_id: `probe-${Date.now()}-${i}`, gross_amount: 2500 } }),
        signal: AbortSignal.timeout(15000),
      });
      const t = await r.text();
      out.push({
        ua: uas[i] ?? "(deno default)",
        status: r.status,
        server: r.headers.get("server"),
        cf_ray: r.headers.get("cf-ray"),
        content_type: r.headers.get("content-type"),
        body: t.slice(0, 200).replace(/SB-Mid-server-\S+/g, "[key]"),
      });
    } catch (e) {
      out.push({ ua: uas[i] ?? "(deno default)", error: String(e) });
    }
  }
  return new Response(JSON.stringify({ key_prefix: key.slice(0, 14), key_len: key.length, egress_ip: ip, results: out }, null, 2), {
    headers: { "Content-Type": "application/json" },
  });
});
