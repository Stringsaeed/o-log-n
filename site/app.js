/* Logn — ologn.app. No dependencies, no network calls. */
(function () {
  "use strict";
  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ───────── launch switches (config.js) ───────── */
  var cfg = window.LOGN || {};
  var dlLive = typeof cfg.DOWNLOAD_URL === "string" && /^https?:\/\//.test(cfg.DOWNLOAD_URL);
  var brewLive = cfg.BREW_LIVE === true;
  if (dlLive) {
    $$("[data-download]").forEach(function (a) {
      a.setAttribute("href", cfg.DOWNLOAD_URL);
      $("[data-download-label]", a).textContent = "Download for macOS";
    });
    $$("[data-dl-badge]").forEach(function (b) { b.textContent = "Available"; b.classList.add("live"); });
  }
  var copyBtn = $("#brew-copy");
  if (brewLive) {
    $$("[data-brew-badge]").forEach(function (b) { b.textContent = "Live"; b.classList.add("live"); });
    $$("[data-brew-note]").forEach(function (n) { n.hidden = true; });
    copyBtn.disabled = false;
  }
  if (dlLive || brewLive) {
    $$("[data-soon-copy]").forEach(function (p) {
      p.textContent = dlLive && brewLive ? "Two ways in. Pick whichever you like." : "One route is live. The other is on its way.";
    });
  }
  copyBtn.addEventListener("click", function () {
    var text = $("#brew-cmd").textContent;
    var done = function () { copyBtn.textContent = "Copied"; setTimeout(function () { copyBtn.textContent = "Copy"; }, 1600); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () {});
  });

  /* ───────── hero: click the wordmark to squeeze it again ───────── */
  var squeeze = $("#squeeze");
  squeeze.addEventListener("click", function () {
    squeeze.classList.add("replay");
    void squeeze.offsetWidth;
    squeeze.classList.remove("replay");
  });

  /* ───────── results table: bars squeeze when they scroll in ───────── */
  if ("IntersectionObserver" in window && !reduced) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.remove("pre"); io.unobserve(e.target); }
      });
    }, { threshold: 0.4 });
    $$(".res tbody tr").forEach(function (tr) {
      if (tr.getBoundingClientRect().top > window.innerHeight) { tr.classList.add("pre"); io.observe(tr); }
    });
  }

  /* ───────── demo data: the measured figures, and nothing else ───────── */
  var VERIFIED = "Every lossless result is verified against the original before it’s written.";
  var KINDS = {
    png:    { label: "PNG", smart: { pct: 77, how: "Oklab palette quantiser" }, lossless: { pct: 35, how: "Logn’s own PNG optimiser, with libdeflate" } },
    jpeg:   { label: "JPEG", smart: { pct: 24, how: "SSIM-targeted re-encode, saved as progressive" }, lossless: { pct: 1.7, how: "Huffman tables optimised. Pixel-identical.", note: "With the progressive option switched on, this sample saves 8%." } },
    heic:   { label: "HEIC", smart: { pct: 23, how: "SSIM-targeted HEIC re-encode" } },
    pdf:    { label: "PDF", smart: { pct: 93, how: "Quartz filter that downsamples the embedded images" } },
    video:  { label: "video", smart: { pct: 56, how: "Hardware HEVC, through VideoToolbox", ownNote: "Assumes a high-bitrate source like our sample. Already-compressed video comes back as “Already optimal”." } },
    wav:    { label: "WAV", smart: { pct: 87, how: "Encoded to AAC" }, lossless: { pct: 50, how: "Encoded to FLAC" } },
    json:   { label: "JSON", smart: { pct: 95, how: "Packed as .xz" }, lossless: { pct: 95, how: "Packed as .xz" } },
    folder: { label: "folder", smart: { pct: 87, how: "Packed as .tar.xz" }, lossless: { pct: 87, how: "Packed as .tar.xz" } },
    zip:    { label: "zip", optimal: true }
  };
  var SAMPLES = {
    png: { name: "Screenshot.png", bytes: 1467040 }, jpeg: { name: "Photo.jpg", bytes: 1450776 },
    heic: { name: "Photo.heic", bytes: 1428979 }, pdf: { name: "Report.pdf", bytes: 8652724 },
    video: { name: "Clip.mp4", bytes: 32993884 }, wav: { name: "Take.wav", bytes: 5760078 },
    json: { name: "server-logs.json", bytes: 12461023 }, folder: { name: "Source folder", bytes: 7999988 },
    zip: { name: "Archive.zip", bytes: 880944 }
  };
  var EXT = { png: "png", jpg: "jpeg", jpeg: "jpeg", heic: "heic", heif: "heic", pdf: "pdf", mp4: "video", mov: "video", m4v: "video", wav: "wav", zip: "zip" };

  function fmt(b) {
    var u = ["B", "KB", "MB", "GB", "TB"], i = 0, v = b;
    while (v >= 999.5 && i < u.length - 1) { v /= 1000; i++; }
    return (i === 0 ? String(Math.round(v)) : v.toPrecision(3)) + " " + u[i];
  }
  function pctText(p) { return "−" + p + "%"; }

  /* ───────── demo elements ───────── */
  var capsule = $("#capsule"), slot = capsule.parentNode, halvesBox = $(".halves", capsule);
  var result = $("#result"), live = $("#live"), hint = $(".result-hint");
  var chips = $$(".chip"), flipBtn = $("#flip"), own = $("#own");
  var el = {
    busyName: $("#busy-name"), busySub: $("#busy-sub"), ringV: $(".ring-v", capsule),
    donePill: $("#done-pill"), doneBig: $("#done-big"), doneSub: $("#done-sub"), doneUse: $("#done-use"),
    file: $("#rc-file"), mode: $("#rc-mode"), big: $("#rc-big"), bar: $("#rc-after-bar"),
    sizes: $("#rc-sizes"), how: $("#rc-method"), note: $("#rc-note"), foot: $("#rc-foot"), card: $(".result-card")
  };
  var current = { kind: "png", name: SAMPLES.png.name, bytes: SAMPLES.png.bytes, own: false };
  var running = false, timers = [], dragDepth = 0, raf = 0;

  function halves() { return $$(".half", capsule); }
  function later(fn, ms) { timers.push(setTimeout(fn, ms)); }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; cancelAnimationFrame(raf); }
  function setState(s) { capsule.setAttribute("data-state", s); }
  function clearTarget() { halves().forEach(function (h) { h.classList.remove("is-target"); }); }
  function inView() { var r = slot.getBoundingClientRect(); return r.top > -10 && r.bottom < window.innerHeight + 10; }
  function unfloat() { capsule.classList.remove("floating"); }
  function setPillsHidden(busy, done) {
    $(".pill-busy", capsule).setAttribute("aria-hidden", String(busy));
    el.donePill.setAttribute("aria-hidden", String(done));
    el.donePill.tabIndex = done ? -1 : 0;
    halves().forEach(function (h) { h.tabIndex = busy && done ? 0 : -1; });
  }
  function toIdle() {
    clearTimers(); running = false; clearTarget(); unfloat(); setPillsHidden(true, true);
    setState("idle");
  }
  function arm() {
    if (running) return;
    clearTimers(); setPillsHidden(true, true);
    if (capsule.getAttribute("data-state") !== "target") setState("armed");
  }
  function setHint() {
    hint.innerHTML = "";
    var b = document.createElement("b"); b.textContent = current.name;
    hint.appendChild(b);
    hint.appendChild(document.createTextNode(" is picked. Now choose Smart or Lossless on the capsule above."));
  }

  function pick(item) {
    current = item;
    chips.forEach(function (c) { c.setAttribute("aria-pressed", String(!item.own && c.getAttribute("data-kind") === item.kind)); });
    setHint();
    if (running) toIdle();
    if (result.getAttribute("data-state") !== "shown") result.setAttribute("data-state", "empty");
    arm();
  }

  /* Work out what to show. Only measured figures are ever used. */
  function outcome(item, mode) {
    var k = KINDS[item.kind], modeName = mode === "smart" ? "Smart" : "Lossless";
    var o = { file: item.name, mode: modeName, own: item.own, bytes: item.bytes, note: "" };
    if (!k) {
      o.type = "nodata"; o.big = "No figure";
      o.how = "There’s no measured figure for " + (item.ext ? "." + item.ext + " files" : "this kind of file") + ".";
      o.note = "Logn packs anything it has no codec for as .xz. On our samples, a 12 MB JSON log shrank 95% and a source-code folder 87%. Yours will differ.";
      return o;
    }
    if (k.optimal) {
      o.type = "optimal"; o.big = "Already optimal";
      o.how = "It’s already compressed, so there’s nothing left to take out.";
      o.note = "Logn reports this in milliseconds and keeps your file as it is.";
      return o;
    }
    var m = k[mode];
    if (!m) {
      o.type = "nodata"; o.big = "No figure";
      o.how = "There’s no measured Lossless figure for " + k.label + " in our sample set.";
      o.note = "Lossless only keeps a result that is verified identical and smaller. Otherwise Logn says “Already optimal”. Try Smart for this one.";
      return o;
    }
    o.type = "saved"; o.pct = m.pct; o.big = pctText(m.pct); o.how = m.how;
    o.note = (item.own && m.ownNote) || m.note || (mode === "lossless" ? VERIFIED : "");
    if (item.bytes != null) { o.after = Math.round(item.bytes * (1 - m.pct / 100)); o.saved = item.bytes - o.after; }
    return o;
  }

  function render(o) {
    result.setAttribute("data-kind", o.type);
    el.file.textContent = o.file; el.mode.textContent = o.mode; el.big.textContent = o.big;
    el.how.textContent = o.how; el.note.textContent = o.note;
    var left = o.type === "saved" ? 1 - o.pct / 100 : 1;
    el.bar.style.setProperty("--left", String(left));
    var approx = o.own ? "≈ " : "";
    if (o.type === "saved" && o.bytes != null) el.sizes.textContent = fmt(o.bytes) + " → " + approx + fmt(o.after);
    else if (o.type === "optimal" && o.bytes != null) el.sizes.textContent = fmt(o.bytes) + " → " + fmt(o.bytes) + " · 0 B saved";
    else if (o.type === "saved") el.sizes.textContent = "Folder sizes aren’t read in this demo.";
    else el.sizes.textContent = o.bytes != null ? fmt(o.bytes) : "";
    el.foot.innerHTML = "";
    if (o.own && o.type === "saved" && o.bytes != null) {
      var b = document.createElement("b"); b.textContent = "Estimate. ";
      el.foot.appendChild(b);
      el.foot.appendChild(document.createTextNode("Your file’s size, times the figure measured on our sample. Real results depend on the file. It wasn’t read, uploaded or compressed."));
    } else if (o.own) {
      el.foot.textContent = "Simulated here. Your file wasn’t read, uploaded or compressed.";
    } else {
      el.foot.textContent = "Simulated here. The figure was measured on this sample in our 13-file test set.";
    }
    // capsule done pill
    el.doneUse.setAttribute("href", o.type === "saved" ? "#i-check" : "#i-equal");
    el.doneBig.textContent = o.big;
    el.doneSub.textContent = o.type === "saved"
      ? (o.saved != null ? "Saved " + approx + fmt(o.saved) + " · " : "") + o.file
      : o.type === "optimal" ? "0 B saved · Original kept" : "See the note below";
    // screen readers
    live.textContent = o.type === "saved"
      ? o.file + ", " + o.mode + ": " + (o.own ? "estimated " : "") + o.pct + " percent smaller" + (o.after != null ? ", " + fmt(o.bytes) + " to " + fmt(o.after) : "") + ". " + o.how.replace(/\.$/, "") + ". Simulated."
      : o.file + ", " + o.mode + ": " + o.big + ". " + o.how + " Simulated.";
  }

  function run(mode) {
    if (running) return;
    var item = current, o = outcome(item, mode);
    clearTimers(); running = true; clearTarget();
    el.busyName.textContent = item.name;
    var modeName = o.mode, dur = reduced ? 200 : o.type === "optimal" ? 280 : o.type === "nodata" ? 350 : 1150;
    setPillsHidden(false, true); setState("busy");
    result.setAttribute("data-state", "busy");
    el.card.setAttribute("aria-hidden", "true");
    var t0 = performance.now();
    (function tick(now) {
      var p = Math.min(1, (now - t0) / dur), eased = 1 - Math.pow(1 - p, 2);
      el.ringV.style.setProperty("--p", String(Math.round(eased * 100)));
      el.busySub.textContent = modeName + " · " + Math.round(eased * 100) + "%";
      if (p < 1) raf = requestAnimationFrame(tick);
    })(t0);
    later(function () {
      render(o);
      setPillsHidden(true, false);
      setState(o.type === "saved" ? "done" : o.type);
      result.setAttribute("data-state", "shown");
      el.card.setAttribute("aria-hidden", "false");
      running = false;
      later(function dwell() {
        if (capsule.matches(":hover") || capsule.contains(document.activeElement)) return later(dwell, 1500);
        toIdle();
      }, 5200);
    }, dur + 60);
  }

  /* ───────── clicks / keyboard ───────── */
  chips.forEach(function (chip) {
    chip.addEventListener("click", function () {
      var kind = chip.getAttribute("data-kind");
      pick({ kind: kind, name: SAMPLES[kind].name, bytes: SAMPLES[kind].bytes, own: false });
    });
    chip.addEventListener("dragstart", function (e) {
      chip.click();
      chip.classList.add("dragging");
      try { e.dataTransfer.setData("text/plain", "logn-sample"); e.dataTransfer.effectAllowed = "copy"; } catch (_) {}
    });
    chip.addEventListener("dragend", function () {
      chip.classList.remove("dragging"); clearTarget();
      if (!running && capsule.getAttribute("data-state") === "target") setState("armed");
    });
  });
  capsule.addEventListener("click", function (e) {
    var half = e.target.closest(".half");
    if (half) run(half.getAttribute("data-mode"));
  });
  el.donePill.addEventListener("click", function () {
    var wasFloating = capsule.classList.contains("floating");
    toIdle();
    if (wasFloating) result.scrollIntoView({ behavior: reduced ? "auto" : "smooth", block: "center" });
  });
  flipBtn.addEventListener("click", function () {
    var on = flipBtn.getAttribute("aria-pressed") !== "true";
    flipBtn.setAttribute("aria-pressed", String(on));
    var hs = halves(), seam = $(".seam", capsule);
    halvesBox.insertBefore(hs[1], hs[0]);
    halvesBox.insertBefore(seam, hs[0]);
    live.textContent = "Halves flipped. " + $("b", halves()[0]).textContent + " is now on the left.";
  });

  function describe(file, isDir) {
    var name = file.name || "Your file", dot = name.lastIndexOf(".");
    var ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
    if (isDir) return { kind: "folder", name: name, bytes: null, own: true, ext: "" };
    return { kind: EXT[ext] || "other", name: name, bytes: typeof file.size === "number" ? file.size : null, own: true, ext: ext };
  }
  own.addEventListener("change", function () {
    if (!own.files || !own.files[0]) return;
    pick(describe(own.files[0], false));
    own.value = "";
    if (!inView()) slot.scrollIntoView({ behavior: reduced ? "auto" : "smooth", block: "center" });
    halves()[0].focus({ preventScroll: true });
  });

  /* ───────── drag and drop ───────── */
  function hasFiles(e) {
    var t = e.dataTransfer && e.dataTransfer.types;
    return !!t && Array.prototype.indexOf.call(t, "Files") !== -1;
  }
  function isOurs(e) { return hasFiles(e) || $(".chip.dragging") !== null; }

  // Dragging a real file anywhere over the page summons the capsule, like the app does.
  window.addEventListener("dragenter", function (e) {
    if (!hasFiles(e)) return;
    dragDepth++;
    if (running) return;
    if (dragDepth === 1) {
      if (!inView()) capsule.classList.add("floating");
      arm();
    }
  });
  window.addEventListener("dragleave", function (e) {
    if (!hasFiles(e)) return;
    dragDepth = Math.max(0, dragDepth - 1);
    if (dragDepth === 0 && !running) toIdle();
  });
  window.addEventListener("dragover", function (e) {
    if (!isOurs(e)) return;
    e.preventDefault(); // never let the browser open a dropped file
    if (!e.target.closest || !e.target.closest(".half")) { e.dataTransfer.dropEffect = "none"; }
  });
  window.addEventListener("drop", function (e) {
    if (!isOurs(e)) return;
    e.preventDefault();
    dragDepth = 0;
    if (!e.target.closest || !e.target.closest(".half")) { if (!running) toIdle(); }
  });

  function aimed(half, e) {
    // Holding ⌥ flips which half is targeted, without moving the pointer.
    if (!e.altKey) return half;
    var hs = halves();
    return hs[0] === half ? hs[1] : hs[0];
  }
  capsule.addEventListener("dragover", function (e) {
    var half = e.target.closest(".half");
    if (!half || running || !isOurs(e)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
    var t = aimed(half, e);
    if (!t.classList.contains("is-target")) { clearTarget(); t.classList.add("is-target"); setState("target"); }
  });
  capsule.addEventListener("dragleave", function (e) {
    if (capsule.contains(e.relatedTarget)) return;
    clearTarget();
    if (!running && capsule.getAttribute("data-state") === "target") setState("armed");
  });
  capsule.addEventListener("drop", function (e) {
    var half = e.target.closest(".half");
    if (!half || running || !isOurs(e)) return;
    e.preventDefault();
    dragDepth = 0;
    var mode = aimed(half, e).getAttribute("data-mode");
    if (hasFiles(e)) {
      var f = e.dataTransfer.files && e.dataTransfer.files[0], isDir = false;
      try {
        var it = e.dataTransfer.items && e.dataTransfer.items[0];
        var entry = it && it.webkitGetAsEntry && it.webkitGetAsEntry();
        isDir = !!(entry && entry.isDirectory);
      } catch (_) {}
      if (!f) return toIdle();
      current = describe(f, isDir);
      chips.forEach(function (c) { c.setAttribute("aria-pressed", "false"); });
      setHint();
    }
    run(mode);
  });

  setPillsHidden(true, true);
})();
