/* Deterministic frame renderer for the Miles intro film.
   One warm Puppeteer page; every frame is window.seek(t) + double-rAF + PNG.
   Usage:
     node render.js                 # all 1800 frames, resume-aware
     node render.js --beat talk     # just that beat's frames (use --force to redo)
     node render.js --range 660-869 # explicit frame window
     node render.js --frames 0,450  # individual stills
     node render.js --force         # overwrite existing frames in scope        */
"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");
const puppeteer = require("puppeteer");

const FPS = 30, TOTAL = 1800;
const REPO = path.resolve(__dirname, "..", "..");
const OUT = path.join(__dirname, "out", "frames");
const PAGE = "/scripts/film-render/composition/index.html";

const BEATS = {
  mark: [0, 5], hero: [5, 11], fortwo: [11, 16.5], talk: [16.5, 22],
  distance: [22, 29], rituals: [29, 35], keepsakes: [35, 41.5],
  security: [41.5, 48], closing: [48, 54], endcard: [54, 60],
};

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
  let frames = [...Array(TOTAL).keys()];
  const beat = get("--beat");
  if (beat) {
    if (!BEATS[beat]) { console.error("unknown beat: " + beat); process.exit(1); }
    const [s, e] = BEATS[beat];
    frames = frames.filter(f => f / FPS >= s && f / FPS < e);
  }
  const range = get("--range");
  if (range) { const [s, e] = range.split("-").map(Number); frames = frames.filter(f => f >= s && f <= e); }
  const list = get("--frames");
  if (list) frames = list.split(",").map(Number);
  return { frames, force: a.includes("--force") };
}

/* NOTE: an earlier version stubbed Date.now/performance.now to throw as a
   determinism tripwire. lottie-web's loader calls them internally, so the
   stub hung its DOMLoaded event and filmReady never settled. The stubs are
   gone: determinism is enforced where it is real — CSS animations killed,
   lottie autoplay off and stepped via goToAndStop, film.js pure in t, and
   verify.js's fresh-browser hash gate as the proof. */

(async () => {
  const { frames, force } = parseArgs();
  fs.mkdirSync(OUT, { recursive: true });

  const todo = force ? frames
    : frames.filter(f => {
        const p = path.join(OUT, `f${String(f).padStart(4, "0")}.png`);
        return !(fs.existsSync(p) && fs.statSync(p).size > 0);
      });
  console.log(`frames in scope: ${frames.length}, to render: ${todo.length}`);
  if (!todo.length) { console.log("nothing to do"); return; }

  const srv = await serve(REPO);
  const url = `http://127.0.0.1:${srv.address().port}${PAGE}`;

  const browser = await puppeteer.launch({
    headless: true,
    defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 },
    args: [
      "--force-color-profile=srgb", "--disable-lcd-text", "--font-render-hinting=none",
      "--disable-gpu", "--disable-accelerated-2d-canvas",
      /* Continuously-scaled layers (plate push-ins, the breathing rituals
         beat) re-raster asynchronously under checker-imaging, so a capture
         can catch the interim raster - the source of scattered frame-pair
         mismatches. Force synchronous full-tile raster. */
      "--disable-checker-imaging", "--disable-partial-raster",
      /* NOTE: --run-all-compositor-stages-before-draw deadlocks captureScreenshot
         in new headless (it expects begin-frame control); the double-rAF await in
         seek() is what actually guarantees the paint is flushed. */
      "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
      "--disable-backgrounding-occluded-windows",
      "--disable-features=Translate,BackForwardCache",
      "--hide-scrollbars", "--mute-audio",
    ],
  });
  const page = await browser.newPage();
  page.on("pageerror", e => { console.error("PAGE ERROR:", e.message); process.exitCode = 1; });
  await page.goto(url, { waitUntil: "networkidle0", timeout: 60000 });
  const ready = await page.evaluate(() => Promise.race([
    window.filmReady,
    new Promise((_, rej) => setTimeout(() =>
      rej(new Error("filmReady hung; stages: " + JSON.stringify(window.bootStage || {}))), 45000)),
  ]));
  console.log("filmReady:", ready);
  console.log("composition ready:", url);

  const t0 = process.hrtime.bigint();
  let done = 0;
  for (const f of todo) {
    await page.evaluate(t => window.seek(t), f / FPS);
    const buf = await page.screenshot({ type: "png", optimizeForSpeed: true });
    fs.writeFileSync(path.join(OUT, `f${String(f).padStart(4, "0")}.png`), buf);
    done++;
    if (done % 30 === 0 || done === todo.length) {
      const el = Number(process.hrtime.bigint() - t0) / 1e9;
      const fps = done / el;
      const eta = Math.round((todo.length - done) / fps);
      console.log(`f${String(f).padStart(4, "0")}/${TOTAL - 1}  ${fps.toFixed(1)} fps  eta ${Math.floor(eta / 60)}:${String(eta % 60).padStart(2, "0")}`);
    }
  }

  await browser.close();
  srv.close();
  console.log(`rendered ${done} frames -> ${OUT}`);
})().catch(e => { console.error(e); process.exit(1); });
