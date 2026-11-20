// @ts-check
import { defineConfig, fontProviders } from 'astro/config';

// https://astro.build/config
export default defineConfig({
  site: 'https://ologn.app',
  output: 'static',
  devToolbar: { enabled: false },
  // One page, so its CSS is inlined: no render-blocking request. The CSP below
  // still covers it, because Astro hashes every inline style it emits.
  build: { inlineStylesheets: 'always' },
  // Fonts are read from npm packages and self-hosted. Nothing is fetched at
  // build time or at run time.
  fonts: [
    {
      provider: fontProviders.local(),
      name: 'Instrument Sans',
      cssVariable: '--font-sans',
      fallbacks: ['ui-sans-serif', 'system-ui', 'sans-serif'],
      options: {
        variants: [
          {
            src: ['@fontsource-variable/instrument-sans/files/instrument-sans-latin-wdth-normal.woff2'],
            weight: '400 700',
            stretch: '75% 100%',
            style: 'normal',
          },
        ],
      },
    },
    // Notation: the Computer Modern faces from KaTeX (SIL OFL). Upright for
    // digits, operators and "log"; italic for variables.
    {
      provider: fontProviders.local(),
      name: 'Logn Math',
      cssVariable: '--font-math',
      fallbacks: ['STIX Two Text', 'Cambria Math', 'Times New Roman', 'serif'],
      options: {
        variants: [
          { src: ['katex/dist/fonts/KaTeX_Main-Regular.woff2'], weight: '400', style: 'normal' },
          { src: ['katex/dist/fonts/KaTeX_Math-Italic.woff2'], weight: '400', style: 'italic' },
        ],
      },
    },
    {
      provider: fontProviders.local(),
      name: 'Geist Mono',
      cssVariable: '--font-mono',
      fallbacks: ['ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
      options: {
        variants: [
          {
            src: ['@fontsource-variable/geist-mono/files/geist-mono-latin-wght-normal.woff2'],
            weight: '400 700',
            style: 'normal',
          },
        ],
      },
    },
  ],
  // Hash-based Content-Security-Policy. Astro adds the script-src and
  // style-src hashes for everything it bundles.
  security: {
    csp: {
      directives: [
        "default-src 'self'",
        "img-src 'self' data:",
        "font-src 'self'",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'none'",
      ],
    },
  },
});
