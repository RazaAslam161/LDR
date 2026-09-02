"""The expression cast, from the owner's tool to assets/presence/.

    python tool/presence_cut.py <folder-of-generated-frames>

Every delivery so far has arrived with the background baked in, framed a
little differently from frame to frame, and named by hand. So nothing here is
trusted: every frame is matted, every frame is REGISTERED to its character's
neutral (silhouette + luminance over the head, across a scale/offset grid),
one square is cut per character off the neutral, the bottom of every frame is
ramped to alpha so shoulders fade instead of ending in a hard edge, and the
result is encoded small. The face axis and the neck line are measured off the
256px neutral and printed for `presence_character.dart` — with a grid overlay
written beside them so the numbers are CONFIRMED by eye before they ship (a
centroid alone was 36px off on the female last time).

Prints the manifest lines for `PresenceArt._paths` at the end.
"""
from __future__ import annotations

import io
import os
import re
import sys

import numpy as np
from PIL import Image, ImageDraw

ART_NAMES = [
    'neutral', 'joyful', 'loving', 'cozy', 'missing_you', 'excited', 'calm',
    'playful', 'romantic', 'tired', 'anxious', 'grateful', 'sad', 'angry',
    'annoyed', 'yearning', 'flirty', 'mischief', 'kiss', 'lipstick',
]
# Hand-typed names the owner's tool produced, mapped onto the app's stems.
ALIASES = {'kissy': 'kiss', 'kissmark': 'lipstick', 'devilish': 'mischief',
           'horny': 'yearning', 'blue': 'sad'}
OUT_DIR = os.path.join('assets', 'presence')
SIZE = 256
MAX_BYTES = 16 * 1024
DIR_MAX = 1024 * 1024


def normalise(name: str) -> tuple[str, str] | None:
    stem = os.path.splitext(name)[0].lower().replace('-', '_')
    m = re.match(r'^(m|f)_(.+?)(_shut)?$', stem)
    if not m:
        return None
    prefix, expr, shut = m.group(1), m.group(2), m.group(3) or ''
    expr = ALIASES.get(expr, expr)
    if expr not in ART_NAMES:
        return None
    return prefix, expr + shut


def matte(path: str):
    from rembg import new_session, remove  # imported late: slow
    global _session
    try:
        _session
    except NameError:
        _session = None
    cache_dir = os.path.join(os.environ.get('TEMP', '.'), 'presence_cut', 'mattes')
    os.makedirs(cache_dir, exist_ok=True)
    cached = os.path.join(cache_dir, os.path.basename(path) + '.png')
    if os.path.exists(cached):
        out = Image.open(cached).convert('RGBA')
    else:
        im = Image.open(path).convert('RGB')
        # 640 is 2.5x the 256px output and ~10x cheaper to matte than the
        # 2048 the tool delivers — forty frames at 2048 ran past ten minutes,
        # at 1024 past twenty. Cached: the model is the whole cost of a run
        # and its answer for a frame never changes.
        if max(im.size) > 640:
            im = im.resize((640, int(im.height * 640 / im.width)), Image.LANCZOS)
        if _session is None:
            _session = new_session('bria-rmbg')
        out = remove(im, session=_session)
        out.save(cached)
    a = np.asarray(out)[..., 3].astype(np.float32) / 255
    mean = float(a.mean())
    flag = '' if 0.02 < mean < 0.85 else '  <-- SUSPECT matte'
    return out, mean, flag


def head_signature(rgba: Image.Image, side: int = 128):
    """Alpha silhouette + luminance of the upper 65% (the head, not the hands
    and shoulders that change with the pose), small, for registration."""
    im = rgba.resize((side, side), Image.LANCZOS)
    a = np.asarray(im)[..., 3].astype(np.float32) / 255
    lum = np.asarray(im.convert('L')).astype(np.float32) / 255 * a
    cut = int(side * 0.65)
    return a[:cut], lum[:cut]


def register(frame: Image.Image, ref: Image.Image):
    """Find the scale and offset that lays `frame` over `ref`. Returns
    (scale, dx, dy, score) in the frame's own pixels.

    Searched entirely at 128px — 9 scales x 81 offsets on a 2048px frame
    would be thirty thousand full-size pastes per character — and the winner
    is mapped back up to the frame."""
    side = 128
    ra, rl = head_signature(ref, side)
    small = frame.resize((side, side), Image.LANCZOS)
    best = (1.0, 0, 0, 1e9)
    for scale in np.arange(0.92, 1.081, 0.02):
        w = max(1, int(round(side * scale)))
        scaled = small.resize((w, w), Image.LANCZOS)
        off = (side - w) // 2
        for dy in range(-12, 13, 2):
            for dx in range(-12, 13, 2):
                c = Image.new('RGBA', (side, side), (0, 0, 0, 0))
                c.paste(scaled, (off + dx, off + dy), scaled)
                fa, fl = head_signature(c, side)
                score = float(np.abs(fa - ra).mean() * 2 + np.abs(fl - rl).mean())
                if score < best[3]:
                    best = (float(scale), dx, dy, score)
    scale, dx, dy, score = best
    k = frame.width / side
    return scale, int(round(dx * k)), int(round(dy * k)), score


def apply_transform(frame: Image.Image, scale: float, dx: int, dy: int):
    w = int(round(frame.width * scale))
    scaled = frame.resize((w, w), Image.LANCZOS)
    out = Image.new('RGBA', frame.size, (0, 0, 0, 0))
    off = (frame.width - w) // 2
    out.paste(scaled, (off + dx, off + dy), scaled)
    return out


def square_from_neutral(rgba: Image.Image):
    """One crop per character: the alpha bbox of the neutral, widened 6%,
    with 3% of air above the head, square. Shoulders may run off the bottom
    — the runtime fades them; the head never may."""
    a = np.asarray(rgba)[..., 3]
    ys, xs = np.where(a > 32)
    top, bottom = ys.min(), ys.max()
    left, right = xs.min(), xs.max()
    width = right - left
    # the head is the top ~55% of the silhouette; centre the square on it
    head = a[top:top + int((bottom - top) * 0.55)]
    # Absolute columns already — `head` spans the full width. The first cut
    # added `left` to them again and shifted every male frame 174px right.
    hx = np.where(head.max(0) > 32)[0]
    hl, hr = hx.min(), hx.max()
    cx = (hl + hr) / 2
    # Sized off silhouette HEIGHT, not head width: both deliveries reach the
    # bottom of the frame at the shoulders, so height is the one measure the
    # two characters share. Width is not — her hair is twice as wide as his
    # head, and keying off it put his chin on the frame's bottom edge.
    side = int((bottom - top) * 0.95)
    H, W = a.shape
    side = min(side, W, H)
    x0 = int(min(max(0, cx - side / 2), W - side))
    y0 = int(min(max(0, top - side * 0.03), H - side))
    return (x0, y0, x0 + side, y0 + side)


def ramp_bottom(rgba: Image.Image, frac: float = 0.12):
    a = np.asarray(rgba).copy()
    h = a.shape[0]
    start = int(h * (1 - frac))
    t = np.linspace(0, 1, h - start)
    ramp = 1 - (t * t * (3 - 2 * t))
    a[start:, :, 3] = (a[start:, :, 3].astype(np.float32) * ramp[:, None]).astype(np.uint8)
    return Image.fromarray(a, 'RGBA')


def measure(rgba: Image.Image, label: str, out_png: str):
    """Pupil midpoint -> face axis; narrowest row between head and shoulders
    -> neck pivot. Printed AND drawn on a grid so it can be checked by eye."""
    a = np.asarray(rgba)[..., 3].astype(np.float32) / 255
    lum = np.asarray(rgba.convert('L')).astype(np.float32) / 255
    h, w = a.shape
    # eye band: darkest OPAQUE pixels in the upper-middle of the face. The
    # alpha mask is load-bearing: transparent pixels are black, and the first
    # cut of this found both "pupils" in the void beside the head.
    y0, y1, x0, x1 = int(h * 0.28), int(h * 0.50), int(w * 0.20), int(w * 0.80)
    band = lum[y0:y1, x0:x1]
    solid = a[y0:y1, x0:x1] > 0.9
    thresh = np.percentile(band[solid], 3)
    mask = solid & (band < thresh)
    ys, xs = np.where(mask)
    xs = xs + int(w * 0.20)
    ys = ys + int(h * 0.28)
    mid = np.median(xs)
    lx = xs[xs < mid].mean() if (xs < mid).any() else mid
    rx = xs[xs >= mid].mean() if (xs >= mid).any() else mid
    face_x = (lx + rx) / 2 / w
    eye_y = ys.mean() / h
    # neck: NOT the narrowest silhouette row — hair hides the neck on the
    # female entirely. Estimated off the eye line at this framing and DRAWN,
    # so the number that ships is the one confirmed on the grid.
    neck_y = eye_y + 0.27
    im = rgba.convert('RGB').resize((w * 3, h * 3), Image.NEAREST)
    d = ImageDraw.Draw(im)
    for f in np.arange(0, 1.001, 0.05):
        d.line([(f * w * 3, 0), (f * w * 3, h * 3)], fill=(60, 60, 60))
        d.line([(0, f * h * 3), (w * 3, f * h * 3)], fill=(60, 60, 60))
    d.line([(face_x * w * 3, 0), (face_x * w * 3, h * 3)], fill=(255, 60, 60), width=2)
    d.line([(0, neck_y * h * 3), (w * 3, neck_y * h * 3)], fill=(60, 200, 255), width=2)
    d.ellipse([lx * 3 - 4, eye_y * h * 3 - 4, lx * 3 + 4, eye_y * h * 3 + 4], outline=(255, 255, 0))
    d.ellipse([rx * 3 - 4, eye_y * h * 3 - 4, rx * 3 + 4, eye_y * h * 3 + 4], outline=(255, 255, 0))
    im.save(out_png)
    print(f'{label}: faceCentre={face_x:.3f}  pivot(neck)={neck_y:.3f}  '
          f'(eyes at y={eye_y:.3f}; grid -> {out_png})')


def main(folder: str):
    files = sorted(f for f in os.listdir(folder) if f.lower().endswith(('.png', '.jpg', '.jpeg', '.webp')))
    wanted: dict[str, str] = {}
    for f in files:
        key = normalise(f)
        if key is None:
            print(f'IGNORED (not a cast name): {f}')
            continue
        k = f'{key[0]}_{key[1]}'
        if k in wanted:
            print(f'DUPLICATE {k}: {f} and {wanted[k]} -- keeping the first')
            continue
        wanted[k] = os.path.join(folder, f)
    for p in 'mf':
        missing = [n for n in ART_NAMES if f'{p}_{n}' not in wanted]
        if missing:
            print(f'MISSING for {p}: {missing}')

    os.makedirs(OUT_DIR, exist_ok=True)
    scratch = os.path.join(os.environ.get('TEMP', '.'), 'presence_cut')
    os.makedirs(scratch, exist_ok=True)

    manifest = []
    for p in 'mf':
        neutral_key = f'{p}_neutral'
        if neutral_key not in wanted:
            print(f'no neutral for {p}; cannot register -- skipping character')
            continue
        print(f'\n== {p} ==')
        ref, mean, flag = matte(wanted[neutral_key])
        print(f'matte {neutral_key}: alpha_mean={mean:.3f}{flag}')
        box = square_from_neutral(ref)
        print(f'crop square for {p}: {box}')
        cut_ref = ramp_bottom(ref.crop(box).resize((SIZE, SIZE), Image.LANCZOS))
        measure(cut_ref, neutral_key, os.path.join(scratch, f'{neutral_key}_grid.png'))
        frames = {neutral_key: cut_ref}
        for k, path in sorted(wanted.items()):
            if not k.startswith(p + '_') or k == neutral_key:
                continue
            rgba, mean, flag = matte(path)
            scale, dx, dy, score = register(rgba, ref)
            reg = apply_transform(rgba, scale, dx, dy)
            print(f'{k:16s} alpha_mean={mean:.3f}{flag}  register: scale={scale:.2f} '
                  f'dx={dx:+d} dy={dy:+d} score={score:.4f}'
                  + ('  <-- OUTLIER' if score > 0.12 else ''))
            frames[k] = ramp_bottom(reg.crop(box).resize((SIZE, SIZE), Image.LANCZOS))
        for k, im in frames.items():
            out = os.path.join(OUT_DIR, f'{k}.webp')
            buf = io.BytesIO()
            im.save(buf, 'WEBP', quality=80, alpha_quality=90, method=6)
            data = buf.getvalue()
            if len(data) > MAX_BYTES:
                print(f'  {k}: {len(data)} bytes > {MAX_BYTES} -- re-encoding at q70')
                buf = io.BytesIO()
                im.save(buf, 'WEBP', quality=70, alpha_quality=85, method=6)
                data = buf.getvalue()
            with open(out, 'wb') as fh:
                fh.write(data)
            manifest.append((k, f'assets/presence/{k}.webp', len(data)))

    total = sum(b for _, _, b in manifest)
    print(f'\nwrote {len(manifest)} frames, {total / 1024:.0f}KB total (dir ceiling {DIR_MAX // 1024}KB)')
    assert total <= DIR_MAX, 'over the presence directory ceiling'
    print('\n--- PresenceArt._paths ---')
    for k, path, b in manifest:
        print(f"    '{k}': '{path}',  // {b // 1024}KB")


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'art_drop/presence')
