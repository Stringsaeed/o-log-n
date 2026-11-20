// Generates the hatch tiles in src/styles/global.css: seamless, hand-ruled
// hatching as SVG data URIs, used as CSS masks.
// Run `node scripts/hatch-tiles.mjs` and paste the output over the --hatch-*
// and --stipple lines in :root.
// A line x + y = c and its partner c + T continue each other across tile
// edges, so each pair shares its jitter and width.
function rng(seed) { let s = seed; return () => (s = (s * 16807) % 2147483647) / 2147483647; }
function tile(T, n, seed, dir, w0 = 1, wj = 0.45, cj = 0.7) {
  const r = rng(seed); const p = T / n; let d = '';
  const paths = [];
  for (let k = 0; k < n; k++) {
    const c = (k + 0.5) * p + (r() - 0.5) * 2 * cj;
    const w = (w0 + (r() - 0.5) * 2 * wj).toFixed(2);
    const seg = (cc) => dir === '/' ? `M${(cc - T - 2).toFixed(1)} ${T + 2}L${(cc + 2).toFixed(1)} ${-2}` : `M${(T + 2 - cc + T).toFixed(1)} ${T + 2}L${(-2 - cc + T).toFixed(1)} ${-2}`;
    paths.push(`<path d='${seg(c)}${seg(c + T)}' stroke-width='${w}'/>`);
  }
  const svg = `<svg xmlns='http://www.w3.org/2000/svg' width='${T}' height='${T}' viewBox='0 0 ${T} ${T}'><g stroke='%23000' fill='none' stroke-linecap='round'>${paths.join('')}</g></svg>`;
  return `url("data:image/svg+xml,${svg.replace(/</g, '%3C').replace(/>/g, '%3E')}")`;
}
function stipple(T, n, seed) {
  const r = rng(seed); let c = '';
  for (let i = 0; i < n; i++) c += `<circle cx='${(r() * T).toFixed(1)}' cy='${(r() * T).toFixed(1)}' r='${(0.55 + r() * 0.45).toFixed(2)}'/>`;
  const svg = `<svg xmlns='http://www.w3.org/2000/svg' width='${T}' height='${T}' viewBox='0 0 ${T} ${T}'><g fill='%23000'>${c}</g></svg>`;
  return `url("data:image/svg+xml,${svg.replace(/</g, '%3C').replace(/>/g, '%3E')}")`;
}
const out = {
  '--hatch-1': tile(48, 6, 7, '/', 0.95),      // light tone
  '--hatch-2': tile(40, 8, 11, '/', 1.05),     // mid tone
  '--hatch-2b': tile(40, 8, 23, '\\', 1.0),    // mid tone, other hand
  '--hatch-3': tile(36, 10, 31, '/', 1.15),    // dark tone
  '--hatch-3b': tile(36, 10, 43, '\\', 1.1),
  '--stipple': stipple(40, 34, 5),
};
for (const [k, v] of Object.entries(out)) console.log(`  ${k}: ${v};`);
