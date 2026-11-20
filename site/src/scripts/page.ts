/* Small page behaviours: reveal on scroll, nav shadow, copy button. */
const root = document.documentElement;

if ('IntersectionObserver' in window && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
  // Anything already on screen stays visible; only content below the fold animates in.
  for (const el of document.querySelectorAll('[data-reveal]')) {
    if (el.getBoundingClientRect().top < window.innerHeight) el.classList.add('in');
    else io.observe(el);
  }
  root.classList.add('js');
}

const nav = document.querySelector('.nav');
if (nav) {
  const onScroll = () => nav.classList.toggle('scrolled', window.scrollY > 8);
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });
}

const copyBtn = document.querySelector<HTMLButtonElement>('#brew-copy');
const cmd = document.querySelector('#brew-cmd');
if (copyBtn && cmd && !copyBtn.disabled) {
  const label = copyBtn.querySelector('span')!;
  copyBtn.addEventListener('click', () => {
    navigator.clipboard?.writeText(cmd.textContent ?? '').then(() => {
      label.textContent = 'Copied';
      setTimeout(() => { label.textContent = 'Copy'; }, 1600);
    }, () => {});
  });
}

// Fig. 1: hovering or focusing a row shows its sizes in the readout. The same
// values are in each row's own text, so the readout never gates anything.
const readout = document.querySelector<HTMLElement>('#fig-readout');
if (readout) {
  const rest = readout.dataset.default ?? '';
  for (const row of document.querySelectorAll<HTMLElement>('.fig .rows li')) {
    const show = () => { readout.textContent = row.dataset.readout ?? rest; };
    const clear = () => { readout.textContent = rest; };
    row.addEventListener('pointerenter', show);
    row.addEventListener('focus', show);
    row.addEventListener('pointerleave', clear);
    row.addEventListener('blur', clear);
  }
}
