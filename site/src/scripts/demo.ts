/*
 * The capsule demo. A simulation: it never reads, uploads or compresses a
 * file. For a visitor's own file it uses the name and size only.
 * Every figure comes from src/data/results.ts.
 */
import { KINDS, EXT_TO_KIND, formatBytes as fmt, formatLeft, formatPct, type Mode } from '../data/results';

type OutcomeType = 'saved' | 'optimal' | 'nodata';

interface Item {
  kind: string;
  name: string;
  bytes: number | null;
  own: boolean;
  ext?: string;
}

interface Outcome {
  type: OutcomeType;
  file: string;
  mode: string;
  own: boolean;
  bytes: number | null;
  big: string;
  how: string;
  note: string;
  sample?: string;
  pct?: number;
  after?: number;
  saved?: number;
}

const $ = <T extends Element = HTMLElement>(s: string, r: ParentNode = document) => r.querySelector<T>(s)!;
const $$ = <T extends Element = HTMLElement>(s: string, r: ParentNode = document) => Array.from(r.querySelectorAll<T>(s));
const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

const VERIFIED = 'Every lossless result is verified against the original before it’s written.';

function sample(kind: string): Item {
  const k = KINDS[kind];
  return { kind, name: k.file, bytes: k.bytes, own: false };
}

/* ───────── elements ───────── */
const capsule = $('#capsule');
const slot = capsule.parentElement!;
const halvesBox = $('.halves', capsule);
const result = $('#result');
const live = $('#live');
const hint = $('.result-hint');
const chips = $$('.chip[data-kind]');
const flipBtn = $<HTMLButtonElement>('#flip');
const own = $<HTMLInputElement>('#own');
const el = {
  busyName: $('#busy-name'),
  busySub: $('#busy-sub'),
  ringV: $<SVGCircleElement>('.ring-v', capsule),
  donePill: $<HTMLButtonElement>('#done-pill'),
  doneBig: $('#done-big'),
  doneSub: $('#done-sub'),
  doneUse: $<SVGUseElement>('#done-use'),
  file: $('#rc-file'),
  mode: $('#rc-mode'),
  big: $('#rc-big'),
  bar: $('#rc-after-bar'),
  sizes: $('#rc-sizes'),
  fn: $('#rc-fn'),
  how: $('#rc-method'),
  note: $('#rc-note'),
  foot: $('#rc-foot'),
  card: $('.result-card'),
};

let current: Item = sample('png');
let running = false;
let timers: number[] = [];
let dragDepth = 0;
let raf = 0;

const halves = () => $$<HTMLButtonElement>('.half', capsule);
const later = (fn: () => void, ms: number) => { timers.push(window.setTimeout(fn, ms)); };
function clearTimers() { timers.forEach(clearTimeout); timers = []; cancelAnimationFrame(raf); }
function setState(s: string) { capsule.setAttribute('data-state', s); }

const SUB: Record<Mode, [string, string]> = { smart: ['Smallest', 'Drop to shrink'], lossless: ['Exact quality', 'Drop exact'] };
function sub(h: Element, on: boolean) {
  $('small', h).textContent = SUB[h.getAttribute('data-mode') as Mode][on ? 1 : 0];
}
function clearTarget() { halves().forEach((h) => { h.classList.remove('is-target'); sub(h, false); }); }
function inView() { const r = slot.getBoundingClientRect(); return r.top > -10 && r.bottom < window.innerHeight + 10; }
// While the capsule floats at the top of the viewport, the page hides its nav
// (see Nav.astro) so nothing covers the drop target.
function float() { capsule.classList.add('floating'); document.documentElement.classList.add('capsule-floating'); }
function unfloat() { capsule.classList.remove('floating'); document.documentElement.classList.remove('capsule-floating'); }
function setPillsHidden(busy: boolean, done: boolean) {
  $('.cpill-busy', capsule).setAttribute('aria-hidden', String(busy));
  el.donePill.setAttribute('aria-hidden', String(done));
  el.donePill.tabIndex = done ? -1 : 0;
  halves().forEach((h) => { h.tabIndex = busy && done ? 0 : -1; });
}
function toIdle() {
  clearTimers(); running = false; clearTarget(); unfloat(); setPillsHidden(true, true);
  setState('idle');
}
function arm() {
  if (running) return;
  clearTimers(); setPillsHidden(true, true);
  if (capsule.getAttribute('data-state') !== 'target') setState('armed');
}
function setHint() {
  hint.textContent = '';
  const b = document.createElement('b');
  b.textContent = current.name;
  hint.append(b, ' is picked. Now choose Smart or Lossless on the capsule.');
}

function pick(item: Item) {
  current = item;
  chips.forEach((c) => c.setAttribute('aria-pressed', String(!item.own && c.getAttribute('data-kind') === item.kind)));
  setHint();
  if (running) toIdle();
  if (result.getAttribute('data-state') !== 'shown') result.setAttribute('data-state', 'empty');
  arm();
}

/* Work out what to show. Only measured figures are ever used. */
function outcome(item: Item, mode: Mode): Outcome {
  const k = KINDS[item.kind];
  const o: Outcome = {
    type: 'nodata', file: item.name, mode: mode === 'smart' ? 'Smart' : 'Lossless',
    own: item.own, bytes: item.bytes, big: 'No figure', how: '', note: '',
  };
  if (!k) {
    o.how = 'There’s no measured figure for ' + (item.ext ? '.' + item.ext + ' files' : 'this kind of file') + '.';
    o.note = 'So no estimate here. For scale, on our samples a 12 MB JSON log shrank ' + KINDS.json.smart!.pct + '% and a source-code folder ' + KINDS.folder.smart!.pct + '%.';
    return o;
  }
  if (k.optimal) {
    o.type = 'optimal'; o.big = 'Already optimal';
    o.how = 'It’s already compressed, so there’s nothing left to take out.';
    o.note = 'Logn reports this in milliseconds and keeps your file as it is.';
    return o;
  }
  const m = k[mode];
  if (!m) {
    o.how = 'There’s no measured Lossless figure for ' + k.label + ' in our sample set.';
    o.note = 'Lossless only keeps a result that is verified identical and smaller. Otherwise Logn says “Already optimal”. Try Smart for this one.';
    return o;
  }
  o.type = 'saved'; o.sample = k.sample; o.pct = m.pct; o.big = formatPct(m.pct); o.how = m.how;
  o.note = (item.own && m.ownNote) || m.note || (mode === 'lossless' ? VERIFIED : '');
  if (item.bytes != null) {
    o.after = Math.round(item.bytes * (1 - m.pct / 100));
    o.saved = item.bytes - o.after;
  }
  return o;
}

function render(o: Outcome) {
  result.setAttribute('data-kind', o.type);
  el.file.textContent = o.file; el.mode.textContent = o.mode; el.big.textContent = o.big;
  el.big.dataset.t = o.big; // the hatched fill is drawn from this copy
  el.how.textContent = o.how; el.note.textContent = o.note;
  const left = o.type === 'saved' ? 1 - o.pct! / 100 : 1;
  el.bar.style.setProperty('--left', String(left));
  const approx = o.own ? '≈ ' : '';
  if (o.type === 'saved' && o.bytes != null) el.sizes.textContent = fmt(o.bytes) + ' → ' + approx + fmt(o.after!);
  else if (o.type === 'optimal' && o.bytes != null) el.sizes.textContent = fmt(o.bytes) + ' → ' + fmt(o.bytes) + ' · 0 B saved';
  else if (o.type === 'saved') el.sizes.textContent = 'Folder sizes aren’t read in this demo.';
  else el.sizes.textContent = o.bytes != null ? fmt(o.bytes) : '';

  // The same result as notation: n ↦ 0.23n, where n is the file's size.
  el.fn.textContent = '';
  if (o.type === 'saved') {
    const n1 = document.createElement('i'); n1.textContent = 'n';
    const n2 = document.createElement('i'); n2.textContent = 'n';
    el.fn.append(n1, ' ↦ ' + (o.own ? '≈ ' : '') + formatLeft(o.pct!), n2);
  }

  el.foot.textContent = '';
  if (o.own && o.type === 'saved' && o.bytes != null) {
    const b = document.createElement('b');
    b.textContent = 'Estimate. ';
    el.foot.append(b, 'Your file’s size, times the figure measured on our ' + o.sample + ' sample. Real results depend on the file. It wasn’t read, uploaded or compressed.');
  } else if (o.own) {
    el.foot.textContent = 'Simulated here. Your file wasn’t read, uploaded or compressed.';
  } else {
    el.foot.textContent = 'Simulated here. The figure was measured on this sample in our 13-file test set.';
  }

  // capsule done pill
  el.doneUse.setAttribute('href', o.type === 'saved' ? '#i-check' : '#i-equal');
  el.doneBig.textContent = o.big;
  el.doneSub.textContent = o.type === 'saved'
    ? (o.saved != null ? 'Saved ' + approx + fmt(o.saved) + ' · ' : '') + o.file
    : o.type === 'optimal' ? '0 B saved · Original kept' : 'See the note';

  // screen readers
  live.textContent = o.type === 'saved'
    ? o.file + ', ' + o.mode + ': ' + (o.own ? 'estimated ' : '') + o.pct + ' percent smaller'
      + (o.after != null && o.bytes != null ? ', ' + fmt(o.bytes) + ' to ' + fmt(o.after) : '') + '. ' + o.how.replace(/\.$/, '') + '. Simulated.'
    : o.file + ', ' + o.mode + ': ' + o.big + '. ' + o.how + ' Simulated.';
}

function run(mode: Mode) {
  if (running) return;
  const item = current;
  const o = outcome(item, mode);
  const hadFocus = capsule.contains(document.activeElement);
  clearTimers(); running = true; clearTarget();
  el.busyName.textContent = item.name;
  const dur = reduced ? 200 : o.type === 'optimal' ? 280 : o.type === 'nodata' ? 350 : 1150;
  setPillsHidden(false, true); setState('busy');
  result.setAttribute('data-state', 'busy');
  el.card.setAttribute('aria-hidden', 'true');
  const t0 = performance.now();
  const tick = (now: number) => {
    const p = Math.min(1, (now - t0) / dur);
    const eased = 1 - Math.pow(1 - p, 2);
    el.ringV.style.setProperty('--p', String(Math.round(eased * 100)));
    el.busySub.textContent = o.mode + ' · ' + Math.round(eased * 100) + '%';
    if (p < 1) raf = requestAnimationFrame(tick);
  };
  tick(t0);
  later(() => {
    render(o);
    setPillsHidden(true, false);
    setState(o.type === 'saved' ? 'done' : o.type);
    result.setAttribute('data-state', 'shown');
    el.card.setAttribute('aria-hidden', 'false');
    running = false;
    if (hadFocus) el.donePill.focus({ preventScroll: true });
    // On a narrow screen the result sits below the files, so bring it into view.
    if (!capsule.classList.contains('floating')) {
      const r = result.getBoundingClientRect();
      if (r.bottom > window.innerHeight || r.top < 0) result.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'nearest' });
    }
    const dwell = () => {
      if (capsule.matches(':hover') || capsule.contains(document.activeElement)) return later(dwell, 1500);
      toIdle();
    };
    later(dwell, 5200);
  }, dur + 60);
}

/* ───────── clicks and keyboard ───────── */
chips.forEach((chip) => {
  chip.addEventListener('click', () => pick(sample(chip.getAttribute('data-kind')!)));
  chip.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); chip.click(); }
  });
  chip.addEventListener('dragstart', (e) => {
    chip.click();
    chip.classList.add('dragging');
    try { e.dataTransfer!.setData('text/plain', 'logn-sample'); e.dataTransfer!.effectAllowed = 'copy'; } catch { /* ignore */ }
  });
  chip.addEventListener('dragend', () => {
    chip.classList.remove('dragging'); clearTarget();
    if (!running && capsule.getAttribute('data-state') === 'target') setState('armed');
  });
});
capsule.addEventListener('click', (e) => {
  const half = (e.target as Element).closest('.half');
  if (half) run(half.getAttribute('data-mode') as Mode);
});
el.donePill.addEventListener('click', () => {
  const wasFloating = capsule.classList.contains('floating');
  toIdle();
  if (!wasFloating) halves()[0].focus({ preventScroll: true });
  if (wasFloating) result.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'center' });
});
flipBtn.addEventListener('click', () => {
  const on = flipBtn.getAttribute('aria-pressed') !== 'true';
  flipBtn.setAttribute('aria-pressed', String(on));
  const hs = halves();
  const seam = $('.seam', capsule);
  halvesBox.insertBefore(hs[1], hs[0]);
  halvesBox.insertBefore(seam, hs[0]);
  live.textContent = 'Halves flipped. ' + $('b', halves()[0]).textContent + ' is now on the left.';
});

function describe(file: File, isDir: boolean): Item {
  const name = file.name || 'Your file';
  const dot = name.lastIndexOf('.');
  const ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
  if (isDir) return { kind: 'folder', name, bytes: null, own: true, ext: '' };
  return { kind: EXT_TO_KIND[ext] || 'other', name, bytes: typeof file.size === 'number' ? file.size : null, own: true, ext };
}
own.addEventListener('change', () => {
  if (!own.files || !own.files[0]) return;
  pick(describe(own.files[0], false));
  own.value = '';
  if (!inView()) slot.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'center' });
  halves()[0].focus({ preventScroll: true });
});

/* ───────── drag and drop ───────── */
function hasFiles(e: DragEvent) {
  const t = e.dataTransfer && e.dataTransfer.types;
  return !!t && Array.prototype.indexOf.call(t, 'Files') !== -1;
}
const isOurs = (e: DragEvent) => hasFiles(e) || document.querySelector('.chip.dragging') !== null;
const overHalf = (e: Event) => (e.target instanceof Element ? e.target.closest<HTMLElement>('.half') : null);

// Dragging a real file anywhere over the page summons the capsule, like the app does.
window.addEventListener('dragenter', (e) => {
  if (!hasFiles(e)) return;
  dragDepth++;
  if (running) return;
  if (dragDepth === 1) {
    if (!inView()) float();
    arm();
  }
});
window.addEventListener('dragleave', (e) => {
  if (!hasFiles(e)) return;
  dragDepth = Math.max(0, dragDepth - 1);
  if (dragDepth === 0 && !running) toIdle();
});
window.addEventListener('dragover', (e) => {
  if (!isOurs(e)) return;
  e.preventDefault(); // never let the browser open a dropped file
  if (!overHalf(e)) e.dataTransfer!.dropEffect = 'none';
});
window.addEventListener('drop', (e) => {
  if (!isOurs(e)) return;
  e.preventDefault();
  dragDepth = 0;
  if (!overHalf(e) && !running) toIdle();
});

function inside(e: DragEvent) {
  const r = capsule.getBoundingClientRect();
  return e.clientX > r.left && e.clientX < r.right && e.clientY > r.top && e.clientY < r.bottom;
}
// Holding ⌥ flips which half is targeted, without moving the pointer.
function aimed(half: HTMLElement, e: DragEvent): HTMLElement {
  if (!e.altKey) return half;
  const hs = halves();
  return hs[0] === half ? hs[1] : hs[0];
}
capsule.addEventListener('dragover', (e) => {
  const half = overHalf(e);
  if (!half || running || !isOurs(e)) return;
  e.preventDefault();
  e.dataTransfer!.dropEffect = 'copy';
  const t = aimed(half, e);
  if (!t.classList.contains('is-target')) { clearTarget(); t.classList.add('is-target'); sub(t, true); setState('target'); }
});
capsule.addEventListener('dragleave', (e) => {
  if (e.relatedTarget instanceof Node ? capsule.contains(e.relatedTarget) : inside(e)) return;
  clearTarget();
  if (!running && capsule.getAttribute('data-state') === 'target') setState('armed');
});
capsule.addEventListener('drop', (e) => {
  const half = overHalf(e);
  if (!half || running || !isOurs(e)) return;
  e.preventDefault();
  dragDepth = 0;
  const mode = aimed(half, e).getAttribute('data-mode') as Mode;
  if (hasFiles(e)) {
    const f = e.dataTransfer!.files && e.dataTransfer!.files[0];
    let isDir = false;
    try {
      const it = e.dataTransfer!.items && e.dataTransfer!.items[0];
      const entry = it && it.webkitGetAsEntry && it.webkitGetAsEntry();
      isDir = !!(entry && entry.isDirectory);
    } catch { /* ignore */ }
    if (!f) return toIdle();
    current = describe(f, isDir);
    chips.forEach((c) => c.setAttribute('aria-pressed', 'false'));
    setHint();
  }
  run(mode);
});

setPillsHidden(true, true);
// A sample is picked from the start, so the capsule is ready for a tap.
arm();
