/* Miles film graphics inserts - the timelines. Three segments, each a pure
   function of tSec starting at t=0, applied as inline styles by
   window.seek(t); render-inserts.js steps t frame by frame. Wall clocks throw
   (the renderer installs stubs before load) so an accidental Date.now
   dependency fails loudly instead of drifting.
   Motion grammar is the app's: cubic-bezier(.215,.61,.355,1) entries (that IS
   easeOutCubic), the thread reveal on easeOutQuart, rises small, one thing
   moving at a time. */
"use strict";

/* ---------- easing + helpers ---------- */
const outCubic = p => 1 - Math.pow(1 - p, 3); /* = cubic-bezier(.215,.61,.355,1) */
const outQuart = p => 1 - Math.pow(1 - p, 4);
const clamp01  = v => Math.min(1, Math.max(0, v));
const ramp = (t, t0, t1, e = outCubic) => e(clamp01((t - t0) / (t1 - t0)));

const $ = id => document.getElementById(id);
const style = (el, s) => { for (const k in s) el.style[k] = s[k]; };

/* rise+fade entrance: returns style for an element entering at te */
function enter(t, te, dur = 0.42, rise = 26, e = outCubic) {
  const p = ramp(t, te, te + dur, e);
  return { opacity: String(p), transform: `translateY(${(1 - p) * rise}px)` };
}

const SEG_DUR = { g1_mark: 5.0, g2_icons: 5.0, g3_endcard: 8.5,
  ui_chat: 5.0, ui_picker: 4.0, ui_save: 5.0, title_card: 2.5, ui_swipe: 4.0 };
let seg = null, els = {}, g1ThreadLen = 52, ucRowH = [0, 0, 0, 0];

/* ---------- ui_* phone-screen builders (run once at boot) ----------
   Repetitive DOM (status bars, chat bubbles, keypad, icon grid) is generated
   here so every string lives exactly once. All content is static after boot;
   seek(t) only writes styles + the calculator display text. */

function buildStatusBars() {
  /* No carrier text (per direction); clock from data-clock, ink from data-ink. */
  for (const slot of document.querySelectorAll(".sbar-slot")) {
    const ink = slot.dataset.ink, clock = slot.dataset.clock;
    slot.outerHTML =
      `<div class="sbar"><span class="sclock" style="color:${ink}">${clock}</span>` +
      `<svg width="66" height="14" viewBox="0 0 66 14" aria-hidden="true">` +
      `<path d="M2 13 L12 13 L12 2 Z" fill="${ink}"/>` +
      `<path d="M30 13 L22.2 5.2 A11 11 0 0 1 37.8 5.2 Z" fill="${ink}"/>` +
      `<rect x="47" y="2.5" width="14" height="9" rx="2.5" fill="${ink}"/>` +
      `<rect x="62" y="5" width="2.2" height="4" rx="1.1" fill="${ink}"/>` +
      `</svg></div>`;
  }
}

/* Timestamps use the app's bubble format, DateFormat('h:mm a')
   (chat_screen.dart) — different night per segment, coherent with each
   status-bar clock (11:47 for ui_chat, 21:47 for ui_save). */
const CHAT_MSGS = [
  { who: "his",  text: "Eid Mubarak 🌙" },
  { who: "hers", text: "Ammi ko mithai ka hisaab dena hai 😅" },
  { who: "his",  text: "Acha suno..." },
  { who: "hers", text: "bolo" },
];

function bubbleHTML(pfx, i, m, time) {
  return `<div class="brow ${m.who}" id="${pfx}-m${i}"><div class="bub ${m.who}">` +
    `${m.text}<span class="btime">${time}</span></div></div>`;
}

function buildChats() {
  const uc = ["11:45 PM", "11:46 PM", "11:46 PM", "11:47 PM"];
  const us = ["9:44 PM", "9:45 PM", "9:45 PM", "9:46 PM"];
  /* ui_chat: three rows, then a fixed slot where the typing bubble hands over
     to "bolo" in place — constant layout, nothing jumps. */
  /* day header: chat_screen.dart _dayHeaderFormat, DateFormat('EEEE, MMM d') */
  let h = '<div class="chat-col" id="uc-col"><div class="day-head">Friday, Mar 20</div>';
  for (let i = 0; i < 3; i++) h += bubbleHTML("uc", i, CHAT_MSGS[i], uc[i]);
  h += '<div class="ty-slot" id="uc-slot">' +
    '<div class="brow hers" id="uc-tyrow"><div class="bub hers"><span class="ty">' +
    '<i id="uc-ty0"></i><i id="uc-ty1"></i><i id="uc-ty2"></i></span></div></div>' +
    bubbleHTML("uc", 3, CHAT_MSGS[3], uc[3]) +
    "</div></div>";
  $("uc-msgs").innerHTML = h;
  /* ui_save: the same thread, settled (no typing slot, all rows static). */
  let h2 = '<div class="chat-col"><div class="day-head">Tuesday, Aug 25</div>';
  for (let i = 0; i < 4; i++) h2 += bubbleHTML("us", i, CHAT_MSGS[i], us[i]);
  $("us-msgs").innerHTML = h2 + "</div>";
  /* ui_swipe: the settled thread once more, about to go under the shade. */
  let h3 = '<div class="chat-col"><div class="day-head">Tuesday, Aug 25</div>';
  for (let i = 0; i < 4; i++) h3 += bubbleHTML("uw", i, CHAT_MSGS[i], us[i]);
  $("uw-msgs").innerHTML = h3 + "</div>";
}

/* Picker tiles: DisguiseService.choices order (plain identity first, then
   kDisguises), labels verbatim from disguise_profile.dart. The Miles icon is
   the adaptive-icon drawable ported to SVG (same art as g2_icons);
   mipmap-xxxhdpi/ic_launcher.png IS the News cover, not Miles. */
const MIP = "/mobile/android/app/src/main/res/mipmap-xxxhdpi/";
const PICKER_TILES = [
  { label: "Miles" },
  { label: "News",       src: MIP + "ic_launcher.png" },
  { label: "Calculator", src: MIP + "ic_disguise_calculator.png", ring: true },
  { label: "Notes",      src: MIP + "ic_disguise_notes.png" },
  { label: "Weather",    src: MIP + "ic_disguise_weather.png" },
  { label: "Convert",    src: MIP + "ic_disguise_convert.png" },
  { label: "Recorder",   src: MIP + "ic_disguise_recorder.png" },
  { label: "Timer",      src: MIP + "ic_disguise_timer.png" },
  { label: "Level",      src: MIP + "ic_disguise_level.png" },
  { label: "Device Info", src: MIP + "ic_disguise_device.png" },
];
const MILES_ICON_SVG = '<svg viewBox="18 18 72 72" aria-hidden="true"><defs>' +
  '<radialGradient id="upm-bg" gradientUnits="userSpaceOnUse" cx="40" cy="70" r="86">' +
  '<stop offset="0" stop-color="#2E1418"/><stop offset="0.55" stop-color="#1C0D11"/>' +
  '<stop offset="1" stop-color="#120A0C"/></radialGradient>' +
  '<radialGradient id="upm-near" gradientUnits="userSpaceOnUse" cx="40" cy="70" r="22">' +
  '<stop offset="0" stop-color="#FF8A5E" stop-opacity="0.72"/>' +
  '<stop offset="0.35" stop-color="#E8674A" stop-opacity="0.36"/>' +
  '<stop offset="1" stop-color="#E8674A" stop-opacity="0"/></radialGradient>' +
  '<radialGradient id="upm-far" gradientUnits="userSpaceOnUse" cx="73" cy="38" r="16">' +
  '<stop offset="0" stop-color="#FF8A5E" stop-opacity="0.65"/>' +
  '<stop offset="0.35" stop-color="#E8674A" stop-opacity="0.30"/>' +
  '<stop offset="1" stop-color="#E8674A" stop-opacity="0"/></radialGradient>' +
  '<linearGradient id="upm-thread" gradientUnits="userSpaceOnUse" x1="40" y1="70" x2="73" y2="38">' +
  '<stop offset="0" stop-color="#FFA981"/><stop offset="1" stop-color="#E8674A" stop-opacity="0.8"/>' +
  '</linearGradient></defs>' +
  '<rect x="0" y="0" width="108" height="108" fill="url(#upm-bg)"/>' +
  '<circle cx="40" cy="70" r="22" fill="url(#upm-near)"/>' +
  '<circle cx="73" cy="38" r="16" fill="url(#upm-far)"/>' +
  '<path d="M 40,70 C 44,54 56,42 73,38" fill="none" stroke="url(#upm-thread)" ' +
  'stroke-width="1.7" stroke-linecap="round"/>' +
  '<circle cx="40" cy="70" r="5.4" fill="#FFF1E8"/><circle cx="73" cy="38" r="3.6" fill="#FFE4D2"/></svg>';

function buildPicker() {
  let h = "";
  PICKER_TILES.forEach((tl, i) => {
    h += `<div class="pk-tile" id="up-t${i}"><div class="pk-icon">` +
      (tl.src ? `<img src="${tl.src}" alt="">` : MILES_ICON_SVG) +
      `</div><div class="pk-label">${tl.label}</div>` +
      (tl.ring ? '<div class="pk-ring" id="up-ring"></div>' : "") + "</div>";
  });
  $("up-grid").innerHTML = h;
}

/* Keypad layout + palette verbatim from calculator_cover.dart. */
const CALC_ROWS = [["AC", "⌫", "%", "÷"], ["7", "8", "9", "×"],
  ["4", "5", "6", "−"], ["1", "2", "3", "+"], ["0", ".", "="]];
const KEY_ID = { AC: "ac", "⌫": "bs", "%": "pct", "÷": "div", "×": "mul",
  "−": "sub", "+": "add", "=": "eq", ".": "dot" };
const keyClass = k => k === "=" ? "k-eq" : "÷×−+".includes(k) ? "k-op"
  : (k === "AC" || k === "⌫" || k === "%") ? "k-fn" : "k-num";

function buildCalc() {
  let h = "";
  for (const row of CALC_ROWS) {
    h += '<div class="calc-row">';
    for (const k of row) {
      const id = KEY_ID[k] || k;
      h += `<div class="calc-key ${keyClass(k)}${k === "0" ? " wide" : ""}" id="us-k-${id}">` +
        `<i class="kov" id="us-kov-${id}"></i><span>${k}</span></div>`;
    }
    h += "</div>";
  }
  $("us-keys").innerHTML = h;
}

window.insertsReady = (async () => {
  buildStatusBars(); buildChats(); buildPicker(); buildCalc();
  els = {
    ucSeg: $("seg-ui_chat"), ucCol: $("uc-col"),
    ucRows: [$("uc-m0"), $("uc-m1"), $("uc-m2"), $("uc-slot")],
    ucTyRow: $("uc-tyrow"),
    ucTyDots: [$("uc-ty0"), $("uc-ty1"), $("uc-ty2")],
    ucM3: $("uc-m3"),
    upHead: $("up-head"), upCaption: $("up-caption"), upFoot: $("up-foot"),
    upTiles: [...Array(10).keys()].map(i => $("up-t" + i)),
    upRing: $("up-ring"), upScrim: $("up-scrim"),
    upDialog: $("up-dialog"), upPress: $("up-press"),
    usChat: $("us-chat"), usCalc: $("us-calc"), usDisplay: $("us-display"),
    usShade: $("us-shade"), usScrim: $("us-scrim"),
    usKovs: Object.fromEntries(
      ["1", "8", "5", "0", "2", "3", "add", "eq"].map(k => [k, $("us-kov-" + k)])),
    g1: $("seg-g1_mark"), g2: $("seg-g2_icons"), g3: $("seg-g3_endcard"),
    g1Near: $("g1-near"), g1Far: $("g1-far"), g1Thread: $("g1-thread"),
    g1NearCore: $("g1-near-core"), g1FarCore: $("g1-far-core"),
    g1Wordmark: $("g1-wordmark"),
    g2Head: $("g2-head"), g2Mid: $("g2-mid"), g2Foot: $("g2-foot"),
    iMiles: $("g2-i-miles"), iCalc: $("g2-i-calc"),
    iNotes: $("g2-i-notes"), iWeather: $("g2-i-weather"),
    lMiles: $("g2-l-miles"), lCalc: $("g2-l-calc"),
    lNotes: $("g2-l-notes"), lWeather: $("g2-l-weather"),
    g3Svg: $("g3-svg"), g3Near: $("g3-near"), g3Wordmark: $("g3-wordmark"),
    g3L1: $("g3-l1"), g3L2: $("g3-l2"),
    tcGroup: $("tc-group"),
    uwShade: $("uw-shade"), uwScrim: $("uw-scrim"), uwPin: $("uw-pin"),
  };

  /* thread length needs the path renderable; segments boot display:none */
  els.g1.style.display = "block";
  g1ThreadLen = els.g1Thread.getTotalLength();
  els.g1.style.display = "";
  els.g1Thread.style.strokeDasharray = String(g1ThreadLen);
  els.g1Thread.style.strokeDashoffset = String(g1ThreadLen);

  /* fonts: load the used faces explicitly - document.fonts.ready alone
     resolves before unused faces arrive */
  await Promise.all([
    "italic 400 96px Fraunces", "400 30px Inter", "600 30px Inter",
    "400 24px Fraunces", "italic 400 22px Fraunces",
  ].map(f => document.fonts.load(f)));
  await document.fonts.ready;

  /* chat row heights need real font metrics AND a renderable box; measured
     once, used by seekUiChat to slide the thread as messages land */
  els.ucSeg.style.display = "block";
  ucRowH = els.ucRows.map(r => r.offsetHeight + 12); /* + .brow margin-top */
  els.ucSeg.style.display = "";

  /* icons decoded before frame 0 (Miles is inline SVG, nothing to decode) */
  await Promise.all([els.iCalc, els.iNotes, els.iWeather,
    ...document.querySelectorAll("#up-grid img")].map(i => i.decode()));

  return "ready";
})();

window.setSegment = function (name) {
  if (!(name in SEG_DUR)) throw new Error("unknown segment: " + name);
  seg = name;
  for (const s of document.querySelectorAll(".seg")) s.style.display = "none";
  $("seg-" + name).style.display = "block";
  return name;
};

/* ---------- g1_mark (5.0s): lights up, thread draws, wordmark rises ---------- */
function seekG1(t) {
  const nearP = ramp(t, 0.4, 1.2);
  const farP  = ramp(t, 1.2, 1.9);
  const nearS = { opacity: String(nearP), transform: `scale(${0.92 + 0.08 * nearP})` };
  const farS  = { opacity: String(farP),  transform: `scale(${0.92 + 0.08 * farP})` };
  style(els.g1Near, nearS); style(els.g1NearCore, nearS);
  style(els.g1Far, farS);   style(els.g1FarCore, farS);
  /* the reveal: thread draws over 620ms (the site's --t-reveal), easeOutQuart */
  els.g1Thread.style.strokeDashoffset =
    String(g1ThreadLen * (1 - ramp(t, 2.1, 2.72, outQuart)));
  style(els.g1Wordmark, enter(t, 3.1, 0.62, 20));
}

/* ---------- g2_icons (5.0s): one tile, five identities, four crossfades ----------
   Identity k holds, then crossfades 350ms into k+1 on the brand bezier.
   5x0.85s holds + 4x0.35s fades = 5.65s does not fit 5.0s, so holds run
   0.80s (0.35s on the final Miles) - noted deviation. */
const G2_IDS   = ["miles", "calc", "notes", "weather", "miles"];
const G2_LABEL = { miles: "Miles", calc: "Calculator", notes: "Notes", weather: "Weather" };
const G2_TS = [0.85, 2.00, 3.15, 4.30], G2_FADE = 0.35;

function seekG2(t) {
  style(els.g2Head, enter(t, 0.10, 0.5, 22));
  style(els.g2Mid,  enter(t, 0.25, 0.5, 24));
  style(els.g2Foot, enter(t, 0.60, 0.5, 18));

  /* fade progress of each of the 4 transitions */
  const p = G2_TS.map(ts => ramp(t, ts, ts + G2_FADE));
  /* stage opacities: stage k = (entered) * (not yet exited) */
  const op = G2_IDS.map((_, k) => (k === 0 ? 1 : p[k - 1]) * (k === 4 ? 1 : 1 - p[k]));

  const o = {
    miles:   op[0] + op[4],
    calc:    op[1],
    notes:   op[2],
    weather: op[3],
  };
  /* incoming icon settles 0.96 -> 1; miles re-enters on the last fade */
  const s = {
    miles:   t < G2_TS[1] ? 1 : 0.96 + 0.04 * p[3],
    calc:    0.96 + 0.04 * p[0],
    notes:   0.96 + 0.04 * p[1],
    weather: 0.96 + 0.04 * p[2],
  };
  style(els.iMiles,   { opacity: String(o.miles),   transform: `scale(${s.miles})` });
  style(els.iCalc,    { opacity: String(o.calc),    transform: `scale(${s.calc})` });
  style(els.iNotes,   { opacity: String(o.notes),   transform: `scale(${s.notes})` });
  style(els.iWeather, { opacity: String(o.weather), transform: `scale(${s.weather})` });
  style(els.lMiles,   { opacity: String(o.miles) });
  style(els.lCalc,    { opacity: String(o.calc) });
  style(els.lNotes,   { opacity: String(o.notes) });
  style(els.lWeather, { opacity: String(o.weather) });
}

/* ---------- g3_endcard (6.0s): mark, wordmark, two lines, near light breathes ---------- */
function seekG3(t) {
  style(els.g3Svg, enter(t, 0.4, 0.8, 16));
  /* breathing: scale 1 -> 1.045 -> 1 on a 4s period, pure function of t */
  const b = 1 + 0.0225 * (1 - Math.cos(2 * Math.PI * t / 4));
  style(els.g3Near, { transform: `scale(${b})` });
  style(els.g3Wordmark, enter(t, 0.8, 0.6, 18));
  style(els.g3L1, enter(t, 1.2, 0.62, 20));
  style(els.g3L2, enter(t, 2.4, 0.5, 14));
}

/* ---------- ui_chat (5.0s): the thread arrives, she answers ---------- */
const UC_TE = [0.30, 1.20, 2.20, 3.00]; /* row entries; [3] is the typing slot */

function seekUiChat(t) {
  /* column sits lower by the height of every not-yet-arrived row, so each
     message pushes the thread up as it lands — the app's chat motion */
  let off = 0;
  for (let i = 0; i < 4; i++) {
    const p = ramp(t, UC_TE[i], UC_TE[i] + 0.42);
    off += ucRowH[i] * (1 - p);
    if (i < 3) style(els.ucRows[i], { opacity: String(p), transform: `translateY(${(1 - p) * 18}px)` });
  }
  els.ucCol.style.transform = `translateY(${off}px)`;
  /* typing bubble in at 3.0, out as "bolo" lands in the same slot at 4.0 */
  els.ucTyRow.style.opacity = String(ramp(t, 3.0, 3.18) * (1 - ramp(t, 3.9, 4.02)));
  els.ucTyDots.forEach((d, i) => {
    /* the app's TypingIndicator: 400ms bounce, reverse, 150ms stagger */
    d.style.transform =
      `translateY(${(-3.4 * Math.abs(Math.sin(Math.PI * (t - 0.15 * i) / 0.8))).toFixed(3)}px)`;
  });
  style(els.ucM3, enter(t, 4.0, 0.42, 14));
}

/* ---------- ui_picker (4.0s): grid, ring on Calculator, apply dialog ---------- */
function seekUiPicker(t) {
  style(els.upHead, enter(t, 0.10, 0.5, 16));
  style(els.upCaption, enter(t, 0.22, 0.5, 16));
  els.upTiles.forEach((tile, i) => style(tile, enter(t, 0.38 + i * 0.045, 0.42, 14)));
  style(els.upFoot, enter(t, 0.55, 0.5, 14));
  const rp = ramp(t, 1.30, 1.62);
  style(els.upRing, { opacity: String(rp), transform: `scale(${1.18 - 0.18 * rp})` });
  const dp = ramp(t, 2.20, 2.46);
  els.upScrim.style.opacity = String(0.55 * dp);
  style(els.upDialog, {
    opacity: String(dp),
    transform: `translateY(calc(-50% + ${((1 - dp) * 16).toFixed(3)}px)) scale(${0.96 + 0.04 * dp})`,
  });
  /* "Change it" takes the press near the end and holds it */
  els.upPress.style.opacity = String(ramp(t, 3.50, 3.62));
}

/* ---------- ui_save (5.0s): chat, instant lock to Calculator, shade ---------- */
const CALC_PRESSES = [
  [1.45, "1"], [1.60, "8"], [1.75, "5"], [1.90, "0"],
  [2.15, "add"],
  [2.35, "2"], [2.50, "3"], [2.65, "0"], [2.80, "0"],
  [2.95, "eq"],
];

/* CalculatorCover semantics: "+" shows the accumulator, the next digit starts
   a fresh entry, "=" resolves — so 1850, +, 2300, = reads 4150. */
function calcDisplay(t) {
  if (t < 1.45) return "0";
  if (t < 1.60) return "1";
  if (t < 1.75) return "18";
  if (t < 1.90) return "185";
  if (t < 2.35) return "1850";
  if (t < 2.50) return "2";
  if (t < 2.65) return "23";
  if (t < 2.80) return "230";
  if (t < 2.95) return "2300";
  return "4150";
}

function seekUiSave(t) {
  /* the emergency lock is instant: a hard cut, no transition */
  const onChat = t < 1.2;
  els.usChat.style.opacity = onChat ? "1" : "0";
  els.usCalc.style.opacity = onChat ? "0" : "1";
  els.usDisplay.textContent = calcDisplay(t);
  /* key washes: 70ms in, 220ms out after each press */
  const kOp = {};
  for (const [tp, id] of CALC_PRESSES) {
    const x = t - tp;
    const v = x <= 0 ? 0 : x < 0.07 ? x / 0.07 : Math.max(0, 1 - (x - 0.07) / 0.22);
    if (!(kOp[id] >= v)) kOp[id] = v;
  }
  for (const id in els.usKovs) els.usKovs[id].style.opacity = String(kOp[id] || 0);
  /* shade: down over the top third 3.0-3.42, back up 3.98-4.4 */
  const sp = ramp(t, 3.0, 3.42) - ramp(t, 3.98, 4.4);
  els.usShade.style.transform = `translateY(${(-(1 - sp) * 400).toFixed(3)}px)`;
  els.usShade.style.opacity = String(Math.min(1, sp * 6));
  els.usScrim.style.opacity = String(0.30 * sp);
}

/* ---------- title_card (2.5s): both lines fade up as one, hold ---------- */
function seekTitleCard(t) {
  style(els.tcGroup, enter(t, 0.3));
}

/* ---------- ui_swipe (4.0s): the shade pulls down over the chat, holds ---------- */
function seekUiSwipe(t) {
  /* travel = shade height 1006 + the shadow's 62px reach (18px offset + 44px
     blur), so the parked shade casts nothing onto the calm chat before 0.8.
     The pin counter-translates by the exact same offset: clock + rows hold
     still in screen space and the descending edge reveals them. */
  const p = ramp(t, 0.8, 1.45);
  const off = ((1 - p) * 1068).toFixed(3);
  els.uwShade.style.transform = `translateY(-${off}px)`;
  els.uwPin.style.transform = `translateY(${off}px)`;
  els.uwScrim.style.opacity = String(0.30 * p);
}

const SEEK = { g1_mark: seekG1, g2_icons: seekG2, g3_endcard: seekG3,
  ui_chat: seekUiChat, ui_picker: seekUiPicker, ui_save: seekUiSave,
  title_card: seekTitleCard, ui_swipe: seekUiSwipe };

window.seek = async function (tSec) {
  if (!seg) throw new Error("setSegment() must run before seek()");
  SEEK[seg](tSec);
  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  return "ok";
};
