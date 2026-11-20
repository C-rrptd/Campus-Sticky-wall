# Skins

The site has two skins. **Classic** (`paper`) is the default and is untouched. **Neo** is opt-in: Neo-Japanese digital culture x editorial zine x game HUD (掲示板 notice board).

Switch: Settings page (`#/settings`), opened from the cog in the header (guests too) or the Settings tab in Account. It also holds Theme (light/dark, `csw-theme`) and Language. Skin is saved in `localStorage` key `csw-skin`; the page reloads on switch. Dark/light works in both skins.

## How it loads
`assets/js/theme-init.js` reads `csw-skin`, sets `<html data-skin>`, and `document.write`s only that skin's stylesheets (parser-blocking, so no flash). The other skin's CSS is never downloaded. `index.html` keeps the Classic set in `<noscript>`. Every stylesheet gets the `?v=` of `theme-init.js`, so one version bump (the build does it) busts them all.

| Skin | Stylesheets, in cascade order |
|---|---|
| paper | base, components, decorations, pages, advertise, engagement, responsive |
| neo | neo-tokens, neo-base, neo-components, decorations, neo-pages, advertise, neo-engagement, neo-responsive, neo-signature |

`decorations.css` and `advertise.css` are shared. Class names and markup are the same in both skins, so no JS depends on the look.

## Add a skin
1. Add its file list to `SKIN_CSS` in `theme-init.js`.
2. Add a button with `data-value="<name>"` to the Skin group in `components/settings.html`.
3. Add the skin's colours to `THEME_COLOR` in `settings.js` and, if you want, to `share-card.js`.

## Neo skin files
- `neo-tokens.css`: every colour, font, shadow, radius, space, plus `@font-face` (fonts in `assets/fonts`, self-hosted and subset; CSP stays `font-src 'self'`).
- `neo-base.css`, `neo-components.css`, `neo-pages.css`, `neo-engagement.css`, `neo-responsive.css`: same roles as Classic's files.
- `neo-signature.css`: wall masthead with obi ribbon (a `::before`, no extra markup), leaderboard ranks, the note pin-down load animation.
- Hierarchy by shadow depth: buttons 2-3px, cards 3px, panels 6px, masthead and dialogs 8px. Header, footer and table heads are always dark (`--bar`).
- Type: Dela Gothic One (headings, big numbers), Zen Kaku Gothic New (body), DotGothic16 (counters, times, badges only).
- Motion: one orchestrated moment (notes pin down on load) plus press feedback. `prefers-reduced-motion` turns all off.
- To use a new kanji, re-subset `assets/fonts/dela.woff2` with `pyftsubset`.
