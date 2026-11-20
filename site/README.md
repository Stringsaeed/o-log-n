# ologn.app

The product site for Logn. An [Astro](https://astro.build) project that builds to plain static files: one page, no client framework, no third-party requests.

## Run it

```sh
cd site
npm install
npm run dev        # http://localhost:4321, with live reload
npm run build      # type-checks, then writes the static site to site/dist
npm run preview    # serves site/dist, as it will be deployed
```

Needs Node 22.23 or later. Astro's anonymous telemetry can be turned off with `ASTRO_TELEMETRY_DISABLED=1`.

## Deploy

The output is `site/dist`, not `site`. Build first, then publish that folder:

```sh
cd site && npm run build
npx wrangler pages deploy dist --project-name ologn
```

`public/_headers` carries the security and cache headers in the format Cloudflare Pages and Netlify read.

## Going live with downloads

Edit `src/config.ts`, then rebuild. Nothing else needs to change.

| Value | Effect |
|---|---|
| `DOWNLOAD_URL = "https://…/Logn.dmg"` | Every "Coming soon" button becomes "Download for macOS", and the hero badge reads "Out now". |
| `BREW_LIVE = true` | The Homebrew card drops its "Not live yet" badge and enables Copy. |

The switches are applied at build time, so the page is correct without JavaScript.

## Rules for the copy

- Every percentage comes from the 13-file sample set and lives in one place: `src/data/results.ts`. The results grid and the demo both read it. Don't type a figure anywhere else.
- The demo is a simulation. It never reads, uploads or compresses a file; for a visitor's own file it uses only the name and size, and labels the result an estimate.
- The screenshots in `src/assets/` come from the app's demo mode, so the numbers inside them are placeholders. Don't quote them.
- No testimonials, user counts, ratings or press logos unless they are real.

## Files

| Path | What |
|---|---|
| `astro.config.mjs` | Static output, self-hosted fonts, and the Content-Security-Policy (Astro adds the script and style hashes) |
| `src/config.ts` | Launch switches |
| `src/data/results.ts` | The measured figures and sample files |
| `src/pages/index.astro` | The page: one component per section |
| `src/components/Stage.astro`, `src/scripts/demo.ts` | The interactive capsule demo |
| `src/components/*.astro` | Nav, Hero, Results, App, Safety, How, Install, Footer |
| `src/components/Figure.astro`, `NumberLine.astro`, `HeroPlot.astro` | The log-axis figure, the 0-to-n number lines, and the hero's plotted curve |
| `src/styles/global.css` | Design tokens (light and dark) and base styles |
| `src/assets/` | PNG masters, cropped from `docs/media/`. Astro makes the AVIF and WebP sizes at build time |
| `public/` | Social card, icons, `robots.txt`, `sitemap.xml`, `_headers` |

Fonts are Instrument Sans and Geist Mono, read from the `@fontsource-variable` npm packages, and the Computer Modern faces from the `katex` package for notation. All are under the SIL Open Font License and self-hosted.

## Notation

The site borrows the language of the name, O(log n). Keep it honest:

- `n` always means the size of one measured sample. `n ↦ 0.23n` restates "−77%" for that sample; it is not a law for every file.
- The curve y = log n is a nod to the name. It carries no labels about file size, because compression is not logarithmic, and the page says so ("0.23n is still O(n)").
- The four formulas in the Safety section restate the prose beside them. The prose is the rule.
- Fig. 1 plots the eight sample kinds that have a Smart figure, on a log axis. Its output sizes are derived from the measured percentages, and the caption says so.
- Wrap notation in `<span class="math">`, with `<i>` around variables. The curve itself is generated from `Math.log` in `src/lib/curve.ts`.
