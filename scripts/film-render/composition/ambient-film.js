/* Film port of web/assets/miles-ambient.js: same field (mulberry32(11), stars in
   the top 70%, a quarter violet, embers rising on a sine), but the loop is gone -
   drawAt(tSec) is a pure function of time, called once per seeked frame by
   film.js. Sprites are pre-rendered once at boot; no gradients in the draw path.
   Counts are the film's own (denser than the site hero: the frame is the whole
   stage here, and 1080p eats sparse fields). */
"use strict";

function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const AMBIENT = (() => {
  const TWO_PI = Math.PI * 2;
  const LOOP = 36;                 // seconds, app parity
  const N_STARS = 44, N_EMBERS = 12;
  const W = 1920, H = 1080;

  const rnd = mulberry32(11);
  const stars = [], embers = [];
  for (let i = 0; i < N_STARS; i++) {
    stars.push({ x: rnd(), y: rnd() * 0.7, r: 1.0 + rnd() * 2.0,
                 ph: rnd() * TWO_PI, sp: 0.5 + rnd() * 1.2, violet: rnd() < 0.25 });
  }
  for (let i = 0; i < N_EMBERS; i++) {
    embers.push({ x: rnd(), off: rnd(), amp: 0.015 + rnd() * 0.03,
                  ph: rnd() * TWO_PI, r: 1.8 + rnd() * 2.6, dur: 0.6 + rnd() * 0.4 });
  }

  function radialSprite(size, stops) {
    const c = document.createElement("canvas");
    c.width = c.height = size;
    const g = c.getContext("2d");
    const grad = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    for (const [o, col] of stops) grad.addColorStop(o, col);
    g.fillStyle = grad;
    g.fillRect(0, 0, size, size);
    return c;
  }

  let ctx, glowS, warmS, violetS, emberS;
  function init(canvas) {
    canvas.width = W; canvas.height = H;
    ctx = canvas.getContext("2d");
    glowS = radialSprite(1440, [
      [0, "rgba(58,22,34,0.9)"], [0.55, "rgba(28,10,16,0.45)"], [1, "rgba(10,5,6,0)"]]);
    warmS   = radialSprite(16, [[0, "rgba(251,239,214,1)"], [1, "rgba(251,239,214,0)"]]);
    violetS = radialSprite(16, [[0, "rgba(139,124,240,1)"], [1, "rgba(139,124,240,0)"]]);
    emberS  = radialSprite(32, [
      [0, "rgba(242,149,111,1)"], [0.5, "rgba(242,149,111,0.5)"], [1, "rgba(242,149,111,0)"]]);
  }

  /* master: overall opacity of the field (film.js fades the night in/out);
     glowLift: 0..1 raises the candle glow's intensity for the opening bloom. */
  function drawAt(tSec, master, glowLift) {
    const t = (tSec % LOOP) / LOOP;
    ctx.clearRect(0, 0, W, H);
    if (master <= 0) return;

    const gx = (0.5 + 0.03 * Math.sin(TWO_PI * t)) * W;
    const gy = (0.32 + 0.02 * Math.cos(TWO_PI * t)) * H;
    const pulse = 0.95 + 0.08 * (0.5 + 0.5 * Math.sin(TWO_PI * t * 3));
    const gr = Math.max(W, H) * 1.05 * pulse;
    ctx.globalAlpha = master * (0.55 + 0.45 * glowLift);
    ctx.drawImage(glowS, gx - gr / 2, gy - gr / 2, gr, gr);

    for (const s of stars) {
      const a = 0.45 + 0.55 * Math.sin(s.ph + TWO_PI * t * s.sp * 4);
      if (a <= 0.02) continue;
      ctx.globalAlpha = master * a * 0.8;
      ctx.drawImage(s.violet ? violetS : warmS,
        s.x * W - s.r * 3, s.y * H - s.r * 3, s.r * 6, s.r * 6);
    }

    for (const e of embers) {
      const p = ((t / e.dur) + e.off) % 1;
      const ex = (e.x + e.amp * Math.sin(e.ph + p * TWO_PI * 2)) * W;
      const ey = (1 - p) * (H + 40) - 20;
      ctx.globalAlpha = master * Math.sin(p * Math.PI) * 0.5;
      ctx.drawImage(emberS, ex - e.r * 4, ey - e.r * 4, e.r * 8, e.r * 8);
    }
    ctx.globalAlpha = 1;
  }

  return { init, drawAt };
})();
