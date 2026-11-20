# ologn.app

The product site for Logn. Plain static files: no build step, no dependencies, no third-party requests.

## Run it

```sh
python3 -m http.server 4173 -d site   # then open http://localhost:4173
```

Paths are root-relative (`/styles.css`), so serve `site/` as the web root.

## Going live with downloads

Edit `config.js`. Nothing else needs to change.

| Value | Effect |
|---|---|
| `DOWNLOAD_URL: "https://…/Logn.dmg"` | Every "Coming soon" button becomes "Download for macOS". |
| `BREW_LIVE: true` | The Homebrew card drops its "Not live yet" badge and enables Copy. |

Without JavaScript the page stays in its "coming soon" state.

## Rules for the copy

- Every percentage comes from the 13-file sample set. The same figures live in three places: the results table and ticker in `index.html`, and `KINDS` in `app.js`. Change them together.
- The demo is a simulation. It never reads, uploads or compresses a file; for a visitor's own file it uses only the name and size, and labels the result an estimate.
- The screenshots in `assets/` come from the app's demo mode, so the numbers inside them are placeholders. Don't quote them.

## Files

| Path | What |
|---|---|
| `index.html`, `styles.css`, `app.js` | The page, its styles, and the demo |
| `config.js` | Launch switches |
| `fonts/archivo-var.woff2` | Archivo variable (OFL), subset to Latin, self-hosted |
| `assets/` | Screenshots cropped from `docs/media/`, as AVIF and WebP |
| `og.png`, `favicon.*`, `icon-*.png`, `apple-touch-icon.png`, `site.webmanifest` | Social card and icons |
| `_headers` | Security and cache headers, in the format Cloudflare Pages and Netlify read |
