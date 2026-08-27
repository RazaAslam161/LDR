/* Deterministic frame renderer for the Miles film graphics inserts.
   Adapted from scripts/film-render/render.js: one warm Puppeteer page; every
   frame is window.seek(t) + double-rAF + PNG. Each segment is its own timeline
   starting at t=0, so frames number from f0000 per segment.
   Usage:
     node render-inserts.js --segment g1_mark                  # all frames @24
     node render-inserts.js --segment g2_icons --fps 24 --out ../film-shoot/graphics/frames/g2_icons
     node render-inserts.js --segment g3_endcard --frames 0,30,60
     node render-inserts.js --segment g1_mark --range 0-59 --force            */
"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");
const puppeteer = require(path.join(__dirname, "..", "film-render", "node_modules", "puppeteer"));

const REPO = path.resolve(__dirname, "..", "..");
const PAGE = "/scripts/film-shoot/inserts/index.html";
const SEGMENTS = { g1_mark: 5.0, g2_icons: 5.0, g3_endcard: 8.5,
  ui_chat: 5.0, ui_picker: 4.0, ui_save: 5.0, title_card: 2.5, ui_swipe: 4.0 };

const MIME = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript",
  ".json": "application/json", ".png": "image/png", ".webp": "image/webp",
  ".woff2": "font/woff2", ".svg": "image/svg+xml" };

function serve(root) {
  return new Promise(res => {
    const srv = http.createServer((req, rsp) => {
      const p = path.join(root, decodeURIComponent(req.url.split("?")[0]));
      if (!p.startsWith(root) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) {
        rsp.writeHead(404); rsp.end(); return;
      }
      rsp.writeHead(200, { "content-type": MIME[path.extname(p)] || "application/octet-stream" });
      fs.createReadStream(p).pipe(rsp);
    });
    srv.listen(0, "127.0.0.1", () => res(srv));
  });
}

function parseArgs() {
  const a = process.argv.slice(2);
  const get = f => { const i = a.indexOf(f); return i >= 0 ? a[i + 1] : null; };
  const segment = get("--segment");
  if (!segment || !SEGMENTS[segment]) {
    console.error("usage: node render-inserts.js --segment <" +
      Object.keys(SEGMENTS).join("|") + "> [--fps N] [--out DIR] [--frames a,b] [--range a-b] [--force]");
    process.exit(1);
  }
  const fps = Number(get("--fps") || 24);
  const total = Math.round(SEGMENTS[segment] * fps);
  const out = path.resolve(__dirname, get("--out") || path.join("graphics", "frames", segment));
  let frames = [...Array(total).keys()];
  const range = get("--range");
  if (range) { const [s, e] = range.split("-").map(Number); frames = frames.filter(f => f >= s && f <= e); }
  const list = get("--frames");
  if (list) frames = list.split(",").map(Number).filter(f => f >= 0 && f < total);
  return { segment, fps, total, out, frames, force: a.includes("--force") };
}

/* Installed before any composition script runs: wall clocks THROW so an
   accidental time dependency fails loudly instead of drifting. rAF still
   works (the flush mechanism), driven by the real compositor. */
const CLOCK_STUB = `
  const boom = name => () => { throw new Error(name + " is banned in the film composition"); };
  Date.now = boom("Date.now");
  performance.now = boom("performance.now");
  const OD = Date;
  window.Date = class extends OD { constructor(...a) { if (!a.length) boom("new Date()")(); super(...a); } };
  window.Date.now = boom("Date.now");
`;

(async () => {
  const { segment, fps, total, out, frames, force } = parseArgs();
  fs.mkdirSync(out, { recursive: true });

  const todo = force ? frames
    : frames.filter(f => {
        const p = path.join(out, `f${String(f).padStart(4, "0")}.png`);
        return !(fs.existsSync(p) && fs.statSync(p).size > 0);
      });
  console.log(`segment ${segment} @ ${fps}fps: ${total} frames total, in scope: ${frames.length}, to render: ${todo.length}`);
  if (!todo.length) { console.log("nothing to do"); return; }

  const srv = await serve(REPO);
  const url = `http://127.0.0.1:${srv.address().port}${PAGE}`;

  const browser = await puppeteer.launch({
    headless: true,
    protocolTimeout: 25000,
    defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 },
    args: [
      "--force-color-profile=srgb", "--disable-lcd-text", "--font-render-hinting=none",
      "--disable-gpu", "--disable-accelerated-2d-canvas",
      /* render.js also passes --run-all-compositor-stages-before-draw and
         --disable-new-content-rendering-timeout; on this machine that pair
         intermittently deadlocks the first captureScreenshot (compositor
         waits for a draw an idle page never schedules), so they are dropped
         here and determinism is proven by double-render hash comparison. */
      "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
      "--disable-backgrounding-occluded-windows",
      "--disable-features=Translate,BackForwardCache",
      "--hide-scrollbars", "--mute-audio",
    ],
  });
  const page = await browser.newPage();
  page.on("pageerror", e => { console.error("PAGE ERROR:", e.message); process.exitCode = 1; });
  await page.evaluateOnNewDocument(CLOCK_STUB);
  await page.goto(url, { waitUntil: "networkidle0", timeout: 60000 });
  await page.evaluate(() => window.insertsReady);
  await page.evaluate(s => window.setSegment(s), segment);
  console.log("composition ready:", url, "segment:", segment);

  /* Headless Chrome's first captureScreenshot can deadlock waiting for a
     compositor commit under --run-all-compositor-stages-before-draw (startup
     race; seen intermittently on this machine). Re-seeking dirties the style
     tree and forces a fresh commit, so retry seek+shot as a unit, loudly. */
  async function shoot(t) {
    for (let attempt = 1; ; attempt++) {
      try {
        await page.evaluate(s => window.seek(s), t);
        return await page.screenshot({ type: "png", optimizeForSpeed: true });
      } catch (e) {
        if (attempt >= 3) throw e;
        console.error(`screenshot attempt ${attempt} failed at t=${t}: ${e.message}; retrying`);
      }
    }
  }
  await shoot(todo[0] / fps); /* warm-up: absorb the startup race before the loop */

  const t0 = process.hrtime.bigint();
  let done = 0;
  for (const f of todo) {
    const buf = await shoot(f / fps);
    fs.writeFileSync(path.join(out, `f${String(f).padStart(4, "0")}.png`), buf);
    done++;
    if (done % 24 === 0 || done === todo.length) {
      const el = Number(process.hrtime.bigint() - t0) / 1e9;
      const rate = done / el;
      const eta = Math.round((todo.length - done) / rate);
      console.log(`f${String(f).padStart(4, "0")}/${total - 1}  ${rate.toFixed(1)} fps  eta ${Math.floor(eta / 60)}:${String(eta % 60).padStart(2, "0")}`);
    }
  }

  await browser.close();
  srv.close();
  console.log(`rendered ${done} frames -> ${out}`);
})().catch(e => { console.error(e); process.exit(1); });
