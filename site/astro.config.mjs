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
    // Computer Modern, from the KaTeX package (SIL OFL): the typeface of a
    // LaTeX paper. Roman for text, the maths italic for variables, and the
    // typewriter face for file sizes and commands.
    {
      provider: fontProviders.local(),
      name: 'Logn Serif',
      cssVariable: '--font-serif',
      fallbacks: ['Iowan Old Style', 'Palatino Linotype', 'Georgia', 'serif'],
      options: {
        variants: [
          { src: ['katex/dist/fonts/KaTeX_Main-Regular.woff2'], weight: '400', style: 'normal' },
          { src: ['katex/dist/fonts/KaTeX_Main-Italic.woff2'], weight: '400', style: 'italic' },
          { src: ['katex/dist/fonts/KaTeX_Main-Bold.woff2'], weight: '700', style: 'normal' },
        ],
      },
    },
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
      name: 'Logn Mono',
      cssVariable: '--font-mono',
      fallbacks: ['ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
      options: {
        variants: [{ src: ['katex/dist/fonts/KaTeX_Typewriter-Regular.woff2'], weight: '400', style: 'normal' }],
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
