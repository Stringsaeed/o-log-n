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
| `src/styles/global.css` | Paper, ink and hatching tokens (light and dark) and base styles |
| `src/components/InkIcon.astro` | The app icon redrawn in pen and ink, for the hero |
| `scripts/hatch-tiles.mjs` | Generates the hatch mask tiles |
| `src/assets/` | PNG masters, cropped from `docs/media/`. Astro makes the AVIF and WebP sizes at build time |
| `public/` | Social card, icons, `robots.txt`, `sitemap.xml`, `_headers` |

The typeface is Computer Modern throughout, the face of a LaTeX paper: roman for text, the maths italic for variables, and the typewriter face for sizes and commands. The files come from the `katex` npm package, are under the SIL Open Font License, and are self-hosted.

## Ink and paper

The site is drawn as pen and ink on paper. Tone comes from hatching, never from grey fills, gradients or blur.

- **Hatching** is a set of mask tiles (`--hatch-1` to `--hatch-3`, their mirrored `b` versions for cross-hatching, and `--stipple`) in `src/styles/global.css`. Paint with any ink by setting `background-color` on the masked element. Regenerate them with `node scripts/hatch-tiles.mjs`.
- **Shadows** are an offset copy of the shape, filled with hatching, on `::after`. The sheet itself sits on `::before` so the shadow can go behind it; see `.card` and `.btn`.
- **Engraved numerals** (`.engraved`) are an ink outline around a hatched fill. Give the element a `data-t` copy of its text. They fall back to solid ink under `forced-colors` and `prefers-contrast: more`.
- **Inline drawings** (the ink icon, the hero's shaded curve) use the `<pattern>` fills and the `#wobble` displacement filter defined in `Sprite.astro`.
- **Dark scheme** is the same drawing in chalk on a dark sheet: only `--paper`, `--ink` and `--spot` change.

The app icon in the nav, footer and install block, and every favicon and touch icon, are renders of the app's Icon Composer document (`Support/AppIcon.icon`, on the app branch). `src/assets/icon.png` and `icon-dark.png` are its default and dark appearances from `ictool`; `public/favicon.svg` is the same mark without hatching, which is only noise at 16 px. Regenerate them if the app icon changes. The larger drawing in the hero is the site's own (`InkIcon.astro`).

Rules that keep it working:

- No body text on hatching. The title block has a paper-coloured edge around its letters for this reason.
- One hatch tone per meaning. If density varied between result cards, it would read as data.
- Fig. 1's marks are plain, not hatched: in a chart, texture reads as an encoding.
- Bars are revealed by `clip-path`, never scaled, so their hatching keeps one tone.
- Never put `transform`, `filter` or `overflow: hidden` on `.stage` or an ancestor of the capsule. The capsule becomes `position: fixed` when a file is dragged in, and those properties would trap it.
- Screenshots are shown untouched, as framed plates.

## Notation

The site borrows the language of the name, O(log n). Keep it honest:

- `n` always means the size of one measured sample. `n ↦ 0.23n` restates "−77%" for that sample; it is not a law for every file.
- The curve y = log n is a nod to the name. It carries no labels about file size, because compression is not logarithmic, and the page says so ("0.23n is still O(n)").
- The four formulas in the Safety section restate the prose beside them. The prose is the rule.
- Fig. 1 plots the eight sample kinds that have a Smart figure, on a log axis. Its output sizes are derived from the measured percentages, and the caption says so.
- Wrap notation in `<span class="math">`, with `<i>` around variables. The curve itself is generated from `Math.log` in `src/lib/curve.ts`.
