# Performance

## How caching works
`scripts/build-site.sh` stamps one hash (`?v=<hash>`) on every local JS, CSS and component URL, so `_headers` caches them for a year. A deploy changes the hash, so visitors get new files. Do not hand-edit `?v=` in `index.html`: the build replaces it. Local dev (`local.html`) has no stamping and no caching headers.

## Checks to run after a deploy
Nothing here can run from CI; each needs the live site or a phone.

- **Compression:** `curl -sI -H 'accept-encoding: br' https://campusstickywall.app/assets/js/app.js | grep -i content-encoding` → `br`.
- **Lighthouse (mobile, Slow 4G, 4x CPU):** `npx lighthouse https://campusstickywall.app --preset=perf --form-factor=mobile --view`. Targets: LCP under 2.5 s, CLS under 0.1, TBT under 200 ms.
- **Low-end phone:** open the site on a real budget Android over mobile data, with Chrome DevTools remote debugging, and record a trace of the first load.
- **Supabase region:** Dashboard → Project Settings → General. Users are in Indonesia, so `ap-southeast-1` (Singapore) is closest. Moving a project needs a new project and a data migration.
- **Real-user speed (optional):** Cloudflare Web Analytics measures Core Web Vitals without cookies. To enable it: turn it on for the Pages project, add `https://static.cloudflareinsights.com` to `script-src` and `https://cloudflareinsights.com` to `connect-src` in `_headers`, and change the "no third-party scripts" line in `PRIVACY.md`. It is not enabled today.

## Known limit
"Load more" can put up to 5,000 notes in the page. `content-visibility: auto` would cut that cost, but sticker decorations overhang the note box and would be clipped. Test it visually before adding it.
