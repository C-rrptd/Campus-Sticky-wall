// Cloudflare Pages Function: /n/<note id>. Gives WhatsApp / Instagram / X a preview (title, text, image)
// for one note, then sends people on to the app's #/note view. Reads the note through the public get_note RPC.
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

export async function onRequestGet({ params, env, request }) {
  const id = String(params.id ?? "");
  const site = (env.PUBLIC_SITE_URL || new URL(request.url).origin).replace(/\/$/, "");
  let note = null;
  if (ID.test(id)) {
    try {
      const res = await fetch(`${env.PUBLIC_SUPABASE_URL}/rest/v1/rpc/get_note`, {
        method: "POST",
        headers: { apikey: env.PUBLIC_SUPABASE_PUBLISHABLE_KEY, "content-type": "application/json" },
        body: JSON.stringify({ p_id: id }),
      });
      if (res.ok) note = await res.json();
    } catch { /* fall through to the generic preview */ }
  }
  const text = note ? [...String(note.body)].slice(0, 160).join("") : "A sticky note on Campus Sticky Wall.";
  const title = note ? `Note by ${note.author_name}` : "Campus Sticky Wall";
  const target = `${site}/#/note?id=${ID.test(id) ? id : ""}`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${esc(title)}</title>
<meta property="og:type" content="article"><meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(text)}"><meta property="og:url" content="${esc(`${site}/n/${id}`)}">
<meta property="og:image" content="${esc(`${site}/assets/images/og.png`)}"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta http-equiv="refresh" content="0;url=${esc(target)}"></head>
<body><p><a href="${esc(target)}">Open this note</a></p></body></html>`;
  return new Response(html, { status: note ? 200 : 404, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=300" } });
}
