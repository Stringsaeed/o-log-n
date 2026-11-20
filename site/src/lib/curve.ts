/**
 * The curve y = log n as an SVG path, computed from Math.log (no hand-drawn
 * Béziers). n runs from 1 to `max` across `width`; log 1 = 0 sits on the
 * baseline and log max touches the top.
 */
export function logCurve(width: number, height: number, max = 128, steps = 120): string {
  const top = Math.log(max);
  let d = '';
  for (let i = 0; i <= steps; i++) {
    // Sample more densely near n = 1, where the curve bends hardest.
    const t = (i / steps) ** 2;
    const n = 1 + (max - 1) * t;
    const x = width * t;
    const y = height - (height * Math.log(n)) / top;
    d += (i === 0 ? 'M' : 'L') + x.toFixed(1) + ' ' + y.toFixed(2);
  }
  return d;
}

/**
 * A band hanging under the curve, to be filled with hatching. Its lower edge
 * is ragged on purpose: pen strokes of uneven length, not a ruled border.
 */
export function logBand(width: number, height: number, depth: number, max = 128, steps = 120, seed = 9, from = 0.26): string {
  const top = Math.log(max);
  let s = seed;
  const rnd = () => (s = (s * 16807) % 2147483647) / 2147483647;
  const pts: Array<[number, number]> = [];
  for (let i = 0; i <= steps; i++) {
    const t = (i / steps) ** 2;
    if (t < from) continue; // start where the curve has flattened
    const n = 1 + (max - 1) * t;
    pts.push([width * t, height - (height * Math.log(n)) / top]);
  }
  let d = pts.map(([x, y], i) => (i === 0 ? 'M' : 'L') + x.toFixed(1) + ' ' + y.toFixed(2)).join('');
  for (let i = pts.length - 1; i >= 0; i--) {
    const [x, y] = pts[i];
    // Thinner where the curve is steep, so the band keeps an even optical depth.
    const steep = i === 0 ? 1 : Math.min(1, Math.abs(pts[i][1] - pts[i - 1][1]) / Math.max(0.01, pts[i][0] - pts[i - 1][0]) / 4);
    // Taper in from nothing at the start of the band.
    const ease = Math.min(1, i / 14);
    const dep = depth * (0.62 + 0.38 * rnd()) * (1 - 0.55 * steep) * ease;
    d += 'L' + (x + dep * 0.35 * steep).toFixed(1) + ' ' + Math.min(height, y + dep).toFixed(2);
  }
  return d + 'Z';
}
