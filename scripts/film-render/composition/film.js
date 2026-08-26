/* Miles intro film - the timeline. Everything on screen is a pure function of
   tSec applied as inline styles by window.seek(t); the renderer steps t frame
   by frame. Nothing here reads a clock: CSS animations are killed, lottie is
   stepped, and verify.js's fresh-browser hash gate is the determinism proof.
   Motion grammar is the app's: 0.42s easeOutCubic entries, the two slow
   reveals on easeOutQuart, rises small, one thing moving at a time. */
"use strict";

/* ---------- easing + helpers ---------- */
const outCubic = p => 1 - Math.pow(1 - p, 3);
const outQuart = p => 1 - Math.pow(1 - p, 4);
const inOut    = p => p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2;
const clamp01  = v => Math.min(1, Math.max(0, v));
/* progress 0..1 of t across [t0,t1] under ease e */
const ramp = (t, t0, t1, e = outCubic) => e(clamp01((t - t0) / (t1 - t0)));
/* 1 inside [in..out] with eased edges of width w */
const window01 = (t, tin, tout, w = 0.42, e = outCubic) =>
  Math.min(ramp(t, tin, tin + w, e), 1 - ramp(t, tout - w, tout, e));

const $ = id => document.getElementById(id);
const style = (el, s) => { for (const k in s) el.style[k] = s[k]; };

/* rise+fade entrance: returns style for an element entering at te */
function enter(t, te, dur = 0.42, rise = 26, e = outCubic) {
  const p = ramp(t, te, te + dur, e);
  return { opacity: String(p), transform: `translateY(${(1 - p) * rise}px)` };
}
/* entrance that also exits (fade only) at tx */
function enterExit(t, te, tx, dur = 0.42, rise = 26) {
  const s = enter(t, te, dur, rise);
  const out = 1 - ramp(t, tx, tx + 0.42);
  s.opacity = String(Number(s.opacity) * out);
  return s;
}

/* ---------- beat windows (sum exactly 60.0) ---------- */
const BEAT = {
  mark:      [0.0,  5.0],
  hero:      [5.0, 11.0],
  fortwo:    [11.0, 16.5],
  talk:      [16.5, 22.0],
  distance:  [22.0, 29.0],
  rituals:   [29.0, 35.0],
  keepsakes: [35.0, 41.5],
  security:  [41.5, 48.0],
  closing:   [48.0, 54.0],
  endcard:   [54.0, 60.0],
};

/* ---------- boot: element refs, word splitting, lottie, ambient ---------- */
let els = {}, threadLen = 52, lotties = [];

function splitWords(el) {
  const words = el.textContent.split(" ");
  el.textContent = "";
  return words.map((w, i) => {
    const s = document.createElement("span");
    s.className = "w";
    s.textContent = w + (i < words.length - 1 ? " " : "");
    el.appendChild(s);
    return s;
  });
}

window.bootStage = { dom: false, fonts: false, plates: false, lottie: false };
window.filmReady = (async () => {
  els = {
    black: $("black"), grain: $("grain"), ambient: $("ambient"),
    Lmark: $("l-mark"), Lhero: $("l-hero"), Lfortwo: $("l-fortwo"),
    Ltalk: $("l-talk"), Ldist: $("l-distance"), Lrit: $("l-rituals"),
    Lkeep: $("l-keepsakes"), Lsec: $("l-security"), Lclose: $("l-closing"),
    Lend: $("l-endcard"),
    markWrap: $("mark-wrap"), thread: $("thread"),
    near: $("near-g"), far: $("far-g"),
    wordmark: $("wordmark"), heroH1: $("hero-h1"), heroSub: $("hero-sub"),
  };
  threadLen = els.thread.getTotalLength();
  els.thread.style.strokeDasharray = String(threadLen);

  els.heroWords = splitWords(els.heroH1);
  window.bootStage.dom = true;

  /* fonts: load the five faces explicitly - document.fonts.ready alone
     resolves before unused faces arrive */
  await Promise.all([
    "300 100px Fraunces", "400 100px Fraunces", "italic 400 100px Fraunces",
    "400 30px Inter", "600 30px Inter",
  ].map(f => document.fonts.load(f)));
  window.bootStage.fonts = true;

  /* plates decoded before frame 0 */
  await Promise.all([...document.querySelectorAll("img[data-plate]")].map(i => i.decode()));
  window.bootStage.plates = true;

  /* lottie accents: deterministic stepped playback */
  /* Lottie accents are CUT: even with per-frame markup caching, Chromium's
     rasterization of freshly-inserted SVG raced the capture on ~2% of frames
     (33/1800 differed across two full passes; every miss inside an accent
     window). The film reads complete without them, and the determinism gate
     outranks a decorative flourish. To restore: repopulate this list and
     solve rasterization first (pre-render to <img> data-URLs + await decode). */
  const defs = [];
  /* Lottie's SVG for frame f depends on the PATH taken to reach f (stepped vs
     jumped) - verified: an isolated goToAndStop(78) hashes differently from
     one reached by stepping 0..78. So each animation is stepped ONCE here,
     sequentially, and every frame's SVG markup is cached; seek() swaps cached
     markup in. Pixels become independent of seek order by construction. */
  lotties = await Promise.all(defs.map(d => new Promise((res, rej) => {
    const anim = lottie.loadAnimation({
      container: $(d.slot), renderer: "svg", loop: false, autoplay: false,
      path: `emoji/${d.id}.json`,
      rendererSettings: { progressiveLoad: false },
    });
    anim.addEventListener("DOMLoaded", () => {
      const slot = $(d.slot), frames = [];
      for (let f = 0; f < anim.totalFrames; f++) {
        anim.goToAndStop(f, true);
        frames.push(slot.innerHTML);
      }
      anim.destroy();
      slot.innerHTML = "";
      res({ ...d, frames, op: frames.length });
    });
    anim.addEventListener("data_failed", () => rej(new Error("lottie load failed: " + d.id)));
  })));

  window.bootStage.lottie = true;
  AMBIENT.init(els.ambient);
  return "ready";
})();

/* ---------- the timeline ---------- */
window.seek = async function (tSec) {
  const t = tSec;

  /* global: fade from black 0-0.8s; grain tile cycle; ambient level */
  style(els.black, { opacity: String(1 - ramp(t, 0, 0.8, inOut)) });
  els.grain.style.backgroundImage = `url(grain/g${Math.round(t * 30) % 4}.png)`;

  /* ambient master: full under type-only beats, dimmed under plate beats */
  const plateDim =
    Math.max(window01(t, BEAT.talk[0], BEAT.talk[1]),
             window01(t, BEAT.distance[0], BEAT.distance[1]),
             window01(t, BEAT.keepsakes[0], BEAT.keepsakes[1]));
  const master = ramp(t, 0.2, 2.6, inOut) * (1 - 0.6 * plateDim);
  const glowLift = window01(t, 0.8, 5.4, 1.2, inOut);
  AMBIENT.drawAt(t, master, glowLift);

  /* ---- beat layer opacities (0.42s crossfades) ---- */
  const L = (el, [a, b], lead = 0) =>
    style(el, { opacity: String(window01(t, a + lead, b)) });
  L(els.Lmark,  [0, BEAT.hero[1]]);          /* mark persists under hero text */
  L(els.Lhero,  BEAT.hero, 0.2);
  L(els.Lfortwo, BEAT.fortwo);
  L(els.Ltalk,  BEAT.talk);
  L(els.Ldist,  BEAT.distance);
  L(els.Lrit,   BEAT.rituals);
  L(els.Lkeep,  BEAT.keepsakes);
  L(els.Lsec,   BEAT.security);
  L(els.Lclose, BEAT.closing);
  /* endcard fades in and HOLDS to the last frame */
  style(els.Lend, { opacity: String(ramp(t, BEAT.endcard[0], BEAT.endcard[0] + 0.6)) });

  /* ---- beat 1+2: the mark ---- */
  {
    const nearP = ramp(t, 0.9, 1.7);
    const farP  = ramp(t, 1.7, 2.4);
    style(els.near, { opacity: String(nearP), transform: `scale(${0.92 + 0.08 * nearP})` });
    style(els.far,  { opacity: String(farP),  transform: `scale(${0.92 + 0.08 * farP})` });
    /* THE reveal: thread draws 2.6->4.6s, easeOutQuart */
    els.thread.style.strokeDashoffset = String(threadLen * (1 - ramp(t, 2.6, 4.6, outQuart)));
    /* mark clears the stage upward before the hero type arrives: deep lift,
       halved scale, finished by 6.2s (words start 6.4s) */
    const lift = ramp(t, 5.0, 6.2, inOut);
    style(els.markWrap, {
      transform: `translateY(${-330 * lift}px) scale(${1 - 0.5 * lift})`,
      opacity: String(1 - ramp(t, BEAT.hero[1] - 0.6, BEAT.hero[1])),
    });
  }

  /* ---- beat: hero ---- */
  {
    style(els.wordmark, enter(t, 5.4, 0.6, 20));
    els.heroWords.forEach((w, i) => style(w, enter(t, 6.4 + i * 0.09, 0.42)));
    style(els.heroSub, enter(t, 8.2, 0.5));
  }

  /* ---- fortwo ---- */
  style($("ft-eyebrow"), enter(t, 11.4));
  style($("ft-h2"),      enter(t, 11.6));
  style($("ft-accent"),  enter(t, 12.4, 0.5));

  /* ---- talk (hero plate card) ---- */
  {
    const p = window01(t, BEAT.talk[0], BEAT.talk[1]);
    const push = 1.02 + 0.08 * ramp(t, BEAT.talk[0], BEAT.talk[1], inOut);
    style($("talk-plate-img"), { transform:
      `translate(-50%,-50%) scale(${push}) translateY(${-8 * p}px)` });
    style($("talk-eyebrow"), enter(t, 16.9));
    style($("talk-h2"),   enter(t, 17.1));
    style($("talk-l1"),   enter(t, 18.0));
    style($("talk-chip"), enter(t, 18.9, 0.42, 14));
    style($("talk-l2"),   enter(t, 19.7));
  }

  /* ---- distance ---- */
  {
    const push = 1.0 + 0.08 * ramp(t, BEAT.distance[0], BEAT.distance[1], inOut);
    style($("dist-plate-img"), { transform: `translate(-50%,-50%) scale(${push})` });
    style($("dist-scrim"), { transform:
      `translateY(${-6 * ramp(t, BEAT.distance[0], BEAT.distance[1], inOut)}px)` });
    style($("dist-eyebrow"), enter(t, 22.5));
    style($("dist-h2"), enter(t, 22.7));
    style($("dist-l1"), enter(t, 23.8));
    style($("dist-l2"), enter(t, 25.6));
    /* gilt arc draws between the two town glows */
    const arc = $("dist-arc");
    const alen = Number(arc.dataset.len);
    arc.style.strokeDasharray = String(alen);
    arc.style.strokeDashoffset = String(alen * (1 - ramp(t, 24.4, 26.6, outQuart)));
  }

  /* ---- rituals: triptych + the frame breathes on the app's 4s curve ---- */
  {
    const b = 1 + 0.014 * Math.sin((t - BEAT.rituals[0]) / 4 * 2 * Math.PI);
    const active = window01(t, BEAT.rituals[0], BEAT.rituals[1]);
    style(els.Lrit, { transform: `scale(${1 + (b - 1) * active})` });
    style($("rit-eyebrow"), enter(t, 29.4));
    style($("rit-h2"), enter(t, 29.6));
    style($("rit-c1"), enter(t, 30.4));
    style($("rit-c2"), enter(t, 30.9));
    style($("rit-c3"), enter(t, 31.4));
  }

  /* ---- keepsakes ---- */
  {
    const push = 1.0 + 0.09 * ramp(t, BEAT.keepsakes[0], BEAT.keepsakes[1], inOut);
    style($("keep-plate-img"), { transform: `translate(-50%,-50%) scale(${push})` });
    style($("keep-eyebrow"), enter(t, 35.5));
    style($("keep-h2"), enter(t, 35.7));
    style($("keep-l1"), enter(t, 36.6));
    style($("keep-l2"), enter(t, 38.4, 0.5));
  }

  /* ---- security ---- */
  style($("sec-h2"), enter(t, 42.0));
  style($("sec-l1"), enter(t, 43.0));
  style($("sec-l2"), enter(t, 44.0));
  style($("sec-l3"), enter(t, 45.0));

  /* ---- closing ---- */
  style($("close-h2"), enterExit(t, 48.6, 53.2, 0.6, 22));

  /* ---- endcard: small mark (pre-drawn) + wordmark + chip, hold ---- */
  style($("end-mark"), enter(t, 54.4, 0.8, 16));
  style($("end-wordmark"), enter(t, 55.2, 0.6, 18));
  style($("end-chip"), enter(t, 56.2, 0.42, 14));

  /* ---- lottie: swap pre-cached frame markup (order-independent) ---- */
  for (const Lo of lotties) {
    const on = t >= Lo.start && t < Lo.start + Lo.dur;
    const slot = $(Lo.slot);
    slot.style.visibility = on ? "visible" : "hidden";
    slot.style.opacity = String(window01(t, Lo.start, Lo.start + Lo.dur, 0.3));
    const f = Math.round(clamp01((t - Lo.start) / Lo.dur) * (Lo.op - 1));
    const want = on ? Lo.frames[f] : "";
    if (slot.dataset.f !== String(on ? f : -1)) {
      slot.innerHTML = want;
      slot.dataset.f = String(on ? f : -1);
    }
  }

  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  return "ok";
};
