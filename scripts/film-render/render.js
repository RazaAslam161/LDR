/* Deterministic frame renderer for the Miles intro film.
   One warm Puppeteer page; every frame is window.seek(t) + one controlled
   BeginFrame whose synchronous draw IS the PNG.
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

  /* Capture is BeginFrame-controlled: the free-running compositor was the
     last nondeterminism source — ±1-LSB alpha-blend rounding noise across the
     whole frame with seams at the 512px raster band boundaries, cached per
     tile for a few frames (hence disjoint 12/8/7-frame gate failures that no
     composition change moved). HeadlessExperimental.beginFrame runs every
     compositor stage synchronously and returns the screenshot from that exact
     draw — no interim raster, no stale tiles. The domain lives in the old
     headless architecture, hence headless: "shell". */
  async function boot() {
    const browser = await puppeteer.launch({
      headless: "shell",
      defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 },
      args: [
        "--enable-begin-frame-control", "--run-all-compositor-stages-before-draw",
        "--disable-threaded-animation", "--disable-image-animation-resync",
        "--disable-new-content-rendering-timeout",
        /* BOTH color profiles pinned to sRGB. With only the display profile
           forced, composite sometimes ran the raster->display color conversion
           and sometimes its identity fast path — a BISTABLE ±1-LSB shift on all
           dark pixels (steep end of the sRGB curve), flipping for a few frames
           at a time. Same profile on both sides = conversion is identity in
           every path, so both attractors collapse into one. */
        "--force-color-profile=srgb", "--force-raster-color-profile=srgb",
        "--disable-lcd-text", "--font-render-hinting=none",
        "--disable-gpu", "--disable-accelerated-2d-canvas",
        "--disable-checker-imaging", "--disable-partial-raster",
        "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
        "--disable-backgrounding-occluded-windows",
        "--disable-features=Translate,BackForwardCache",
        "--hide-scrollbars", "--mute-audio",
      ],
    });
    const page = await browser.newPage();
    page.on("pageerror", e => { console.error("PAGE ERROR:", e.message); process.exitCode = 1; });
    const cdp = await page.createCDPSession();

    /* Under BeginFrame control nothing frames the page on its own, but boot
       (layout, font checks) and img.decode() inside seek() both need lifecycle
       frames. One serialized driver issues every beginFrame so the background
       pump can never overlap a capture (overlapping protocol sends error out).
       The pump runs for the whole session. */
    let bfQueue = Promise.resolve();
    const sendBF = params => {
      const op = bfQueue.then(() =>
        cdp.send("HeadlessExperimental.beginFrame", params)
          .catch(e => { if (params.screenshot) throw e; }));
      bfQueue = op.catch(() => {});
      return op;
    };
    const pump = setInterval(() => { sendBF({ noDisplayUpdates: false }); }, 100);
    await page.evaluateOnNewDocument(() => { window.__BF__ = true; });
    await page.goto(url, { waitUntil: "networkidle0", timeout: 60000 });
    const ready = await page.evaluate(() => Promise.race([
      window.filmReady,
      new Promise((_, rej) => setTimeout(() =>
        rej(new Error("filmReady hung; stages: " + JSON.stringify(window.bootStage || {}))), 45000)),
    ]));
    /* A hold frame (seek sets every style to its current value) produces no
       damage, and a damage-less beginFrame returns no screenshot. A 1px div
       parked off-viewport flips its transform each frame: guaranteed damage,
       zero visible pixels. */
    await page.evaluate(() => {
      const d = document.createElement("div");
      d.id = "__tick";
      d.style.cssText = "position:fixed;left:-8px;top:-8px;width:1px;height:1px;background:#000;";
      document.body.appendChild(d);
    });
    /* Throwaway warm-up capture: the very first composite after boot showed a
       one-frame variance once (f0480 in one of three otherwise-identical
       slice passes). No real frame gets to be the first draw. */
    await page.evaluate(t => window.seek(t), 0);
    await sendBF({ noDisplayUpdates: false, screenshot: { format: "png" } });
    return { browser, page, sendBF, pump, ready };
  }

  async function shutdown(s) {
    clearInterval(s.pump);
    try { await s.browser.close(); } catch { /* already gone */ }
  }

  const withTimeout = async (p, ms, what) => {
    p.catch(() => {});          /* abandoning it must not crash the process */
    let timer;
    try {
      return await Promise.race([p, new Promise((_, rej) => {
        timer = setTimeout(() => rej(new Error(`watchdog: ${what} still pending after ${ms}ms`)), ms);
      })]);
    } finally { clearTimeout(timer); }
  };

  let sess = await boot();
  console.log("filmReady:", sess.ready);
  console.log("composition ready:", url);

  const t0 = process.hrtime.bigint();
  let done = 0, relaunches = 0;
  for (const f of todo) {
    /* The capture loop occasionally wedges before a frame (renderer stuck in
       a lifecycle wait). Determinism is cross-boot (proven: three separate
       boots, byte-identical slices), so the watchdog relaunches the browser
       and retries the frame — once. A second wedge on the same frame is real
       and fatal. */
    for (let attempt = 0; ; attempt++) {
      try {
        await withTimeout(sess.page.evaluate((t, n) => {
          document.getElementById("__tick").style.transform = `translateX(${-(n % 2)}px)`;
          return window.seek(t);
        }, f / FPS, f), 45000, `seek f${f}`);
        const bf = await withTimeout(
          sess.sendBF({ noDisplayUpdates: false, screenshot: { format: "png" } }),
          45000, `capture f${f}`);
        if (!bf || !bf.screenshotData) throw new Error(`no screenshot at f${f} (hasDamage=${bf && bf.hasDamage})`);
        fs.writeFileSync(path.join(OUT, `f${String(f).padStart(4, "0")}.png`),
          Buffer.from(bf.screenshotData, "base64"));
        break;
      } catch (e) {
        if (attempt >= 1) { await shutdown(sess); throw e; }
        relaunches++;
        console.error(`f${f}: ${e.message} — relaunching browser, retrying frame`);
        await shutdown(sess);
        sess = await boot();
      }
    }
    done++;
    if (done % 30 === 0 || done === todo.length) {
      const el = Number(process.hrtime.bigint() - t0) / 1e9;
      const fps = done / el;
      const eta = Math.round((todo.length - done) / fps);
      console.log(`f${String(f).padStart(4, "0")}/${TOTAL - 1}  ${fps.toFixed(1)} fps  eta ${Math.floor(eta / 60)}:${String(eta % 60).padStart(2, "0")}`);
    }
  }

  await shutdown(sess);
  srv.close();
  console.log(`rendered ${done} frames -> ${OUT}${relaunches ? ` (${relaunches} browser relaunch(es))` : ""}`);
})().catch(e => { console.error(e); process.exit(1); });
