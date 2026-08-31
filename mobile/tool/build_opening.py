"""
Builds the Opening — the cinematic a couple sees once, after they pair.

Run from the Flutter project root (mobile/):
    python tool/build_opening.py            # animatic, placeholder cast
    python tool/build_opening.py --final     # uses art_drop/opening/*.png

WHY THIS IS A SCRIPT AND NOT A CHECKED-IN MP4
A video nobody can rebuild is a dead end: the first time a shot needs retiming or a
character is re-rendered, the whole film has to be redone by hand. The plates and this
file are the source; the MP4 is output.

THE CAMERA IS THE ANIMATION
The owner can generate stills, not video, so per-frame character animation is scarce and
expensive. Almost all of the motion here is a camera moving through a still plate. A
2752x1536 plate cropped to the app's portrait aspect is 709x1536 — 0.98x of the 720x1560
target, i.e. essentially native — and leaves 3.88 screen-widths to pan across. That is
where the film's movement comes from.

Camera moves are expressed as a start and end crop rectangle in PLATE pixels, eased. A
crop that shrinks over time is a push-in; a crop that slides is a pan.
"""

from __future__ import annotations

import argparse
import math
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT.parent / "art_drop"
OUT = ROOT / "build" / "opening"

W, H = 720, 1560          # the app's portrait frame
FPS = 24
PLATE_H = 1536


def ease(t: float) -> float:
    """Slow in, slow out. A camera that starts and stops abruptly reads as a slide."""
    return t * t * (3 - 2 * t)


@dataclass
class Actor:
    """A character plate walked across the frame, feet on the ground line."""
    path: Path
    # Fractions of the OUTPUT frame: where the feet land, and how tall the figure is.
    x0: float
    x1: float
    foot_y: float
    height: float
    flip: bool = False


def light_into_scene(
    fig: Image.Image,
    grade: tuple[float, float, float],
    rim: tuple[int, int, int],
    rim_from_left: bool,
    rim_gain: float,
) -> Image.Image:
    """Put a studio-lit figure inside a night scene.

    The cast was rendered on a neutral seamless, so dropped straight onto a moonlit
    street it reads as a sticker — the same defect the presence badge had. Three cheap
    passes fix it, and they are the passes a compositor would do by hand:
      * GRADE — knock the figure down toward the scene's own ambient, so it is no longer
        the brightest thing in a night frame;
      * RIM — a warm edge on the side the light is actually coming from, which is what
        separates a figure from its background;
      * (the contact shadow is drawn by the caller, under the feet, before this lands).
    """
    r, g, b, a = fig.split()
    graded = Image.merge(
        "RGBA",
        (
            r.point(lambda v: int(v * grade[0])),
            g.point(lambda v: int(v * grade[1])),
            b.point(lambda v: int(v * grade[2])),
            a,
        ),
    )

    # The rim is the figure's own silhouette, shifted away from the light and subtracted
    # from itself — what is left is the lit edge.
    # Narrow and faint. At full strength this drew a thick yellow line down each figure
    # and read as a sticker outline rather than light — the first cut shipped it.
    shift = max(1, fig.width // 200)
    dx = shift if rim_from_left else -shift
    edge = ImageChops.subtract(a, ImageChops.offset(a, dx, -shift // 2))
    edge = edge.filter(ImageFilter.GaussianBlur(max(1.0, shift * 0.8))).point(
        lambda v: min(255, int(v * rim_gain))
    )
    glow = Image.new("RGBA", fig.size, rim + (0,))
    glow.putalpha(ImageChops.multiply(edge, a))
    return Image.alpha_composite(graded, glow)


@dataclass
class Cast:
    """The generated cast for one shot, played as frames across its duration.

    Every frame is NORMALISED before compositing, because independently generated stills
    drift: measured across shot 2 the figures varied 7.6% in height and their ground line
    wandered 36px, which plays back as pumping and bobbing rather than walking. Each
    frame is cropped to its own content, scaled so that content is exactly [height] of
    the output frame, and pinned so its BOTTOM sits on [foot_y]. Drift cannot survive
    that, by construction.
    """
    frames: list[Path]
    height: float
    foot_y: float
    x: float
    x_end: float | None = None
    # 'foot' pins the bottom to the ground; 'centre' centres it — the hands have no
    # ground to stand on.
    align: str = "foot"
    # Seconds each frame is held. A walk needs ~6 poses a second to read as walking; a
    # hug wants to be held far longer.
    hold: float = 0.17
    loop: bool = True


@dataclass
class Shot:
    name: str
    plate: Path
    seconds: float
    # Crop rects in plate pixels: (left, top, width, height). Height is derived from
    # width so the aspect can never drift between the two ends of a move.
    start: tuple[float, float, float]
    end: tuple[float, float, float]
    actors: list[Actor] = field(default_factory=list)
    cast: Cast | None = None
    fade_in: bool = False
    fade_out: bool = False
    # How the scene lights whatever stands in it.
    grade: tuple[float, float, float] = (0.55, 0.58, 0.72)
    rim: tuple[int, int, int] = (255, 196, 120)
    rim_from_left: bool = True
    rim_gain: float = 0.42

    @property
    def frames(self) -> int:
        return max(1, round(self.seconds * FPS))


def crop_rect(spec: tuple[float, float, float]) -> tuple[float, float, float, float]:
    left, top, width = spec
    return left, top, width, width * H / W


def render_shot(shot: Shot, out_dir: Path, first: int) -> int:
    plate = Image.open(shot.plate).convert("RGBA")
    actors = [(a, Image.open(a.path).convert("RGBA")) for a in shot.actors]

    # Cropped to content once, here, so the per-frame loop only has to resize.
    cast_cache = []
    if shot.cast is not None:
        for fp in shot.cast.frames:
            im = Image.open(fp).convert("RGBA")
            box = im.getchannel("A").point(lambda v: 255 if v > 40 else 0).getbbox()
            cast_cache.append(im.crop(box))

    s_l, s_t, s_w, s_h = crop_rect(shot.start)
    e_l, e_t, e_w, e_h = crop_rect(shot.end)

    # PIL pads a crop that leaves the image with transparent black instead of
    # complaining, so an over-wide rect ships a black band down the frame. Both ends are
    # checked here because only one of them has to be wrong.
    for label, (l, t, cw, ch) in (
        ("start", (s_l, s_t, s_w, s_h)),
        ("end", (e_l, e_t, e_w, e_h)),
    ):
        if l < 0 or t < 0 or l + cw > plate.width or t + ch > plate.height:
            sys.exit(
                f"{shot.name}.{label}: crop {cw:.0f}x{ch:.0f}+{l:.0f}+{t:.0f} leaves "
                f"{shot.plate.name} ({plate.width}x{plate.height}). A full-height "
                f"portrait slice is the widest legal crop — keep the multiplier <= 0.99."
            )

    n = shot.frames
    for i in range(n):
        t = ease(i / max(1, n - 1))
        left = s_l + (e_l - s_l) * t
        top = s_t + (e_t - s_t) * t
        cw = s_w + (e_w - s_w) * t
        ch = s_h + (e_h - s_h) * t

        frame = plate.crop(
            (round(left), round(top), round(left + cw), round(top + ch))
        ).resize((W, H), Image.LANCZOS)

        for actor, img in actors:
            ax = actor.x0 + (actor.x1 - actor.x0) * (i / max(1, n - 1))
            fig_h = round(H * actor.height)
            fig_w = round(fig_h * img.width / img.height)
            fig = img.resize((fig_w, fig_h), Image.LANCZOS)
            if actor.flip:
                fig = fig.transpose(Image.FLIP_LEFT_RIGHT)
            fig = light_into_scene(
                fig, shot.grade, shot.rim, shot.rim_from_left, shot.rim_gain
            )

            cx = round(W * ax)
            feet = round(H * actor.foot_y)

            # Contact shadow first, or the figure floats. An ellipse pooled at the feet,
            # widest where the body meets the ground and fading out fast.
            pool = Image.new("RGBA", frame.size, (0, 0, 0, 0))
            pw, ph = round(fig_w * 0.78), max(4, round(fig_h * 0.055))
            ImageDraw.Draw(pool).ellipse(
                [cx - pw // 2, feet - ph // 2, cx + pw // 2, feet + ph // 2],
                fill=(0, 0, 0, 150),
            )
            frame.alpha_composite(pool.filter(ImageFilter.GaussianBlur(ph * 0.7)))
            frame.alpha_composite(fig, (cx - fig_w // 2, feet - fig_h))

        if shot.cast is not None:
            c = shot.cast
            k = int(i / FPS / c.hold)
            k = k % len(cast_cache) if c.loop else min(k, len(cast_cache) - 1)
            fig_h = round(H * c.height)
            fig = cast_cache[k]
            fig_w = round(fig_h * fig.width / fig.height)
            fig = light_into_scene(
                fig.resize((fig_w, fig_h), Image.LANCZOS),
                shot.grade, shot.rim, shot.rim_from_left, shot.rim_gain,
            )
            ax = c.x if c.x_end is None else c.x + (c.x_end - c.x) * (i / max(1, n - 1))
            cx = round(W * ax)
            ground = round(H * c.foot_y)
            if c.align == "foot":
                top = ground - fig_h
                pool = Image.new("RGBA", frame.size, (0, 0, 0, 0))
                pw, ph = round(fig_w * 0.80), max(4, round(fig_h * 0.05))
                ImageDraw.Draw(pool).ellipse(
                    [cx - pw // 2, ground - ph // 2, cx + pw // 2, ground + ph // 2],
                    fill=(0, 0, 0, 150),
                )
                frame.alpha_composite(pool.filter(ImageFilter.GaussianBlur(ph * 0.7)))
            else:
                top = ground - fig_h // 2
            frame.alpha_composite(fig, (cx - fig_w // 2, top))

        # Fades are done here rather than in ffmpeg so a shot is self-contained and can
        # be re-rendered alone.
        if shot.fade_in or shot.fade_out:
            k = 1.0
            edge = max(1, round(0.5 * FPS))
            if shot.fade_in and i < edge:
                k = min(k, i / edge)
            if shot.fade_out and i >= n - edge:
                k = min(k, (n - 1 - i) / edge)
            if k < 1.0:
                black = Image.new("RGBA", frame.size, (0, 0, 0, 255))
                frame = Image.blend(black, frame, k)

        frame.convert("RGB").save(out_dir / f"f{first + i:06d}.png")
    return n


def build(final: bool) -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    street, house, door, room = (
        ART / "w3.png", ART / "w1.png", ART / "w2.png", ART / "w4.png"
    )
    for p in (street, house, door, room):
        if not p.exists():
            sys.exit(f"missing plate: {p}")

    CUT = ART / "opening_cut"

    def seq(*names: str) -> list[Path]:
        out = [CUT / f"{n}.png" for n in names]
        for f in out:
            if not f.exists():
                sys.exit(f"missing cast frame: {f}")
        return out

    full = PLATE_H * W / H  # 709: a full-height portrait slice, the widest legal crop

    # THE EDIT, and why frames are missing from it.
    #
    # The cast was generated frame by frame, so continuity is not guaranteed and two
    # breaks are real: in s2_06 and s2_08 the woman stands on the LEFT while every other
    # frame of that walk puts her on the right, and s5_01/s5_02 put the man on the left
    # where s5_03-08 put him on the right. Cut in order they would teleport past each
    # other. They are dropped rather than regenerated — six poses still read as a walk,
    # and the hug is stronger starting at the reach.
    # s3_01 is dropped too: it reads as two disconnected sleeves, not hands approaching.
    shots = [
        Shot(
            "cold_open", street, 4.0,
            start=(1120, 0, full * 0.99),
            end=(760, 0, full * 0.88),
            fade_in=True,
        ),
        Shot(
            "approach", street, 4.5,
            start=(240, 0, full * 0.95),
            end=(940, 0, full * 0.95),
            cast=Cast(
                seq("s2_01", "s2_02", "s2_03", "s2_04", "s2_05", "s2_07"),
                height=0.52, foot_y=0.93, x=0.50, hold=0.17,
            ),
        ),
        Shot(
            "hands", street, 3.5,
            start=(1500, 250, full * 0.60),
            end=(1560, 300, full * 0.52),
            cast=Cast(
                seq("s3_02", "s3_03", "s3_04", "s3_05", "s3_06"),
                height=0.34, foot_y=0.52, x=0.50,
                align="centre", hold=0.70, loop=False,
            ),
        ),
        Shot(
            "house", house, 4.0,
            start=(880, 0, full * 0.99),
            end=(1010, 90, full * 0.72),
            cast=Cast(
                seq("s4_01", "s4_02", "s4_03", "s4_04"),
                height=0.40, foot_y=0.95, x=0.50, hold=0.75, loop=False,
            ),
        ),
        Shot(
            "hug", door, 5.0,
            start=(700, 0, full * 0.99),
            end=(880, 90, full * 0.74),
            cast=Cast(
                seq("s5_03", "s5_04", "s5_05", "s5_06", "s5_07", "s5_08"),
                height=0.56, foot_y=0.92, x=0.50, hold=0.80, loop=False,
            ),
        ),
        Shot(
            "inside", room, 4.5,
            start=(680, 0, full * 0.99),
            end=(1150, 40, full * 0.85),
            cast=Cast(
                seq("s6_01", "s6_02", "s6_03", "s6_04"),
                height=0.46, foot_y=0.94, x=0.46, x_end=0.54, hold=0.55, loop=False,
            ),
            grade=(0.78, 0.68, 0.58),
            rim=(255, 214, 158),
            fade_out=True,
        ),
    ]

    total = 0
    for shot in shots:
        n = render_shot(shot, OUT, total)
        total += n
        print(f"  {shot.name:<10} {shot.seconds:>4.1f}s  {n:>4} frames")

    mp4 = ROOT / "build" / "opening.mp4"
    cmd = [
        "ffmpeg", "-loglevel", "error", "-y",
        "-framerate", str(FPS),
        "-i", str(OUT / "f%06d.png"),
        "-c:v", "libx264", "-crf", "23", "-preset", "slow",
        "-pix_fmt", "yuv420p",          # anything else will not decode on Android
        "-an",                          # no audio: the score plays through MilesSound,
                                        # so the app's mute and the server sound-kill
                                        # still govern it
        str(mp4),
    ]
    subprocess.run(cmd, check=True)

    size = mp4.stat().st_size
    print(f"\n{mp4}")
    print(f"  {total} frames  {total / FPS:.1f}s  {size / 1048576:.2f} MB")
    if not final:
        print("  ANIMATIC — placeholder cast, no real character animation yet.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--final", action="store_true")
    build(ap.parse_args().final)
