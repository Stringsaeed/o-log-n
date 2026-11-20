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
