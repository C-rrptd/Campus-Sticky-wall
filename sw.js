// Network-first service worker: pages load from the network and fall back to the last copy when offline.
// Only same-origin GET requests are cached, so Supabase and payment traffic is never touched.
const CACHE = "csw-v1";
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(
  caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== self.location.origin || url.pathname.startsWith("/n/")) return;
  e.respondWith(fetch(e.request).then((res) => {
    // Only plain 200 responses for static files: no 206 ranges (cache.put throws) and no query strings
    // (Midtrans returns to /?order_id=…, which must not be stored on the device). ?v=… asset URLs are cached.
    const cacheable = res.status === 200 && (!url.search || /^\?v=\d+$/.test(url.search));
    if (cacheable) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {}); }
    return res;
  }).catch(() => caches.match(e.request)));
});
