# Miles intro film — deterministic local renderer

A 60s, 1920×1080\@30 kinetic-typography brand film rendered entirely on this
machine for $0. The composition (`composition/`) imports the site's own design
system; its whole timeline is a pure function `window.seek(tSec)` — wall clocks
throw, CSS animations are killed, Lottie is stepped with `goToAndStop`, and the
starfield is seeded (`mulberry32(11)`). `render.js` steps a warm Puppeteer page
frame by frame; `verify.js` re-renders five probe frames in a fresh browser and
byte-compares hashes — encoding is forbidden until it passes.

## Commands

```powershell
winget install --id Gyan.FFmpeg -e     # then open a NEW shell
npm install                             # puppeteer (pinned Chrome), lottie-web
.\prep.ps1                              # 2x lanczos plates + lottie player + emoji
node render.js --beat hero --force      # iterate on one beat (~2 min)
node render.js                          # full render, resume-aware (~10-15 min)
node verify.js                          # determinism gate — MUST pass
.\encode.ps1 master                     # out/miles-intro-master.mp4 (YouTube; not committed)
.\encode.ps1 web                        # ..\..\web\miles-intro.webm (2-pass VP9, <=10MB)
.\encode.ps1 poster                     # ..\..\web\assets\img\film-poster.jpg
```

Music later, without re-encoding the video stream:

```powershell
ffmpeg -i out/miles-intro-master.mp4 -i track.wav -map 0:v -map 1:a:0 `
  -c:v copy -c:a aac -b:a 192k `
  -af "atrim=0:60,asetpts=PTS-STARTPTS,afade=t=out:st=57:d=3" `
  -shortest -movflags +faststart out/miles-intro-music.mp4
```

## Design law carried from the app

Emberlight palette and motion tokens only; entries 420ms easeOutCubic; the two
slow reveals (thread draw, closing) on easeOutQuart; no blur, no bounce, no UI
mockups, no Closer imagery, no streaks/counters/receipts anywhere in frame.
Plates never exceed 1.15x their native pixels (pre-resampled 2x lanczos so the
browser only downscales). A seeded 4-tile grain layer at 5% overlay dithers the
plum gradients before the encoder sees them (banding defense), backed by x264
aq-mode=3.
