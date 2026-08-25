/* Miles — ambient hero canvas + reveal choreography.
   A port of the app's EmberBackground (mobile/lib/core/widgets/
   ember_background.dart): one 36s loop — a drifting candle-glow radial,
   twinkling stars in the top 70% (a quarter of them celestial violet), and
   embers rising on a sine sway. Same math, same seeded randomness
   (mulberry32(11) standing in for Dart's Random(11)), different renderer:
   every gradient is pre-rendered to a sprite once per resize, so the frame
   loop is pure drawImage — zero gradient allocations per frame. 30fps cap,
   DPR capped at 2, pauses when the tab is hidden or the hero is scrolled
   off, and a frame-time governor that sheds load rather than jank.
   Counts are tuned below app parity (20 stars / 8 embers desktop) because
   the hero shares the room with type; the app's background sits alone.
   Under prefers-reduced-motion this file draws NOTHING moving: the static
   CSS ambient gradient beneath the canvas is the finished state. */
(function () {
  "use strict";

  var reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---- hero load sequence trigger (runs even under reduced motion:
     the CSS reduced-motion block turns these into finished states).
     rAF does not fire in a hidden/background tab, so a timeout backstop
     guarantees the page never sticks at opacity 0 — if the tab is opened
     in the background, the finished state simply greets the reader. ---- */
  function go() { document.documentElement.classList.add("hero-go"); }
  requestAnimationFrame(function () { requestAnimationFrame(go); });
  setTimeout(go, 400);

  /* ---- scroll reveals: one per section, once ---- */
  var revealed = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && revealed.length) {
    var ro = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); ro.unobserve(e.target); }
      });
    }, { threshold: 0.2 });
    revealed.forEach(function (el) { ro.observe(el); });
  } else {
    revealed.forEach(function (el) { el.classList.add("in"); });
  }

  /* ---- ambient canvas ---- */
  var canvas = document.getElementById("ember-canvas");
  if (!canvas || reduced) return;

  function mulberry32(a) {
    return function () {
      a |= 0; a = (a + 0x6D2B79F5) | 0;
      var t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  var ctx = canvas.getContext("2d");
  var small = matchMedia("(max-width: 640px)").matches;
  var N_STARS = small ? 14 : 20;
  var N_EMBERS = small ? 6 : 8;
  var LOOP = 36000;                       /* ms — app parity */
  var TWO_PI = Math.PI * 2;

  /* Seeded field, app-style: stars live in the top 70%. */
  var rnd = mulberry32(11);
  var stars = [], embers = [], i;
  for (i = 0; i < N_STARS; i++) {
    stars.push({ x: rnd(), y: rnd() * 0.7, r: 0.8 + rnd() * 1.6,
                 ph: rnd() * TWO_PI, sp: 0.5 + rnd() * 1.2,
                 violet: rnd() < 0.25 });
  }
  for (i = 0; i < N_EMBERS; i++) {
    embers.push({ x: rnd(), off: rnd(), amp: 0.015 + rnd() * 0.03,
                  ph: rnd() * TWO_PI, r: 1.5 + rnd() * 2.2,
                  dur: 0.6 + rnd() * 0.4 });
  }

  /* Sprites — regenerated on resize only. */
  var glowS, starWarmS, starVioletS, emberS, W = 0, H = 0, DPR = 1;

  function makeRadialSprite(size, stops) {
    var c = document.createElement("canvas");
    c.width = c.height = size;
    var g = c.getContext("2d");
    var grad = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    stops.forEach(function (s) { grad.addColorStop(s[0], s[1]); });
    g.fillStyle = grad;
    g.fillRect(0, 0, size, size);
    return c;
  }

  function rebuild() {
    DPR = Math.min(devicePixelRatio || 1, 2);
    W = canvas.clientWidth; H = canvas.clientHeight;
    canvas.width = Math.round(W * DPR);
    canvas.height = Math.round(H * DPR);
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    /* Candle glow at quarter resolution — one big drawImage per frame. */
    var gs = Math.max(64, Math.round(Math.max(W, H) * 0.75));
    glowS = makeRadialSprite(gs, [
      [0, "rgba(58,22,34,0.9)"], [0.55, "rgba(28,10,16,0.45)"], [1, "rgba(10,5,6,0)"]
    ]);
    starWarmS   = makeRadialSprite(16, [[0, "rgba(251,239,214,1)"], [1, "rgba(251,239,214,0)"]]);
    starVioletS = makeRadialSprite(16, [[0, "rgba(139,124,240,1)"], [1, "rgba(139,124,240,0)"]]);
    emberS      = makeRadialSprite(32, [[0, "rgba(242,149,111,1)"], [0.5, "rgba(242,149,111,0.5)"], [1, "rgba(242,149,111,0)"]]);
  }

  var running = false, inView = true, visible = !document.hidden;
  var last = 0, acc = 0, FRAME = 1000 / 30;
  var meanFrame = 16, degraded = 0;

  function frame(now) {
    if (!running) return;
    requestAnimationFrame(frame);
    var dt = now - last; last = now;
    acc += dt;
    if (acc < FRAME) return;              /* 30fps cap */
    /* Frame-time governor: shed load, never jank. */
    meanFrame = meanFrame * 0.95 + Math.min(dt, 100) * 0.05;
    if (meanFrame > 48 && degraded === 0) { degraded = 1; stars.length >>= 1; embers.length >>= 1; }
    else if (meanFrame > 64 && degraded === 1) { stop(); canvas.remove(); return; }
    acc %= FRAME;

    var t = (now % LOOP) / LOOP;          /* 0..1 over 36s */
    ctx.clearRect(0, 0, W, H);

    /* 1. candle glow — app math: x 0.5±0.03 sin, y 0.32±0.02 cos, pulse radius */
    var gx = (0.5 + 0.03 * Math.sin(TWO_PI * t)) * W;
    var gy = (0.32 + 0.02 * Math.cos(TWO_PI * t)) * H;
    var pulse = 0.95 + 0.08 * (0.5 + 0.5 * Math.sin(TWO_PI * t * 3));
    var gr = Math.max(W, H) * 1.05 * pulse;
    ctx.drawImage(glowS, gx - gr / 2, gy - gr / 2, gr, gr);

    /* 2. stars — per-star sine twinkle 0.45 + 0.55 sin */
    var s, a, k;
    for (k = 0; k < stars.length; k++) {
      s = stars[k];
      a = 0.45 + 0.55 * Math.sin(s.ph + TWO_PI * t * s.sp * 4);
      if (a <= 0.02) continue;
      ctx.globalAlpha = a * 0.8;
      ctx.drawImage(s.violet ? starVioletS : starWarmS,
        s.x * W - s.r * 3, s.y * H - s.r * 3, s.r * 6, s.r * 6);
    }

    /* 3. embers — rise bottom→top, sine sway, fade at both edges */
    var e, p, ex, ey;
    for (k = 0; k < embers.length; k++) {
      e = embers[k];
      p = ((t / e.dur) + e.off) % 1;
      ex = (e.x + e.amp * Math.sin(e.ph + p * TWO_PI * 2)) * W;
      ey = (1 - p) * (H + 40) - 20;
      ctx.globalAlpha = Math.sin(p * Math.PI) * 0.5;   /* ≤50%, app parity */
      ctx.drawImage(emberS, ex - e.r * 4, ey - e.r * 4, e.r * 8, e.r * 8);
    }
    ctx.globalAlpha = 1;
  }

  function start() {
    if (running || !inView || !visible) return;
    running = true; last = performance.now(); acc = 0;
    requestAnimationFrame(frame);
  }
  function stop() { running = false; }
  function sync() { (inView && visible) ? start() : stop(); }

  addEventListener("resize", function () { rebuild(); }, { passive: true });
  document.addEventListener("visibilitychange", function () {
    visible = !document.hidden; sync();
  });
  new IntersectionObserver(function (entries) {
    inView = entries[0].isIntersecting; sync();
  }, { threshold: 0.01 }).observe(canvas);

  rebuild();
  start();
})();
