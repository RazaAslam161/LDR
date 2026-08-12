// tool/generate_icon.dart
//
// Draws every launcher icon the app can wear, at every mipmap density.
//
// Run from the Flutter project root (mobile/):
//   dart run tool/generate_icon.dart
//
// WHY THIS IS CODE AND NOT A FOLDER OF PNGS
// The app has nine launcher identities and each needs four bitmaps (legacy
// tile, adaptive background, adaptive foreground, monochrome) at five
// densities: 180 files. Hand-maintaining those guarantees drift — one icon
// gets a fix, the other eight keep the old geometry — so the geometry lives
// here once and the files are output.
//
// THE CRAFT RULES THE SPECS BELOW FOLLOW
//  * Everything is expressed in Android's 108-unit adaptive grid. 72 units are
//    guaranteed visible, 66 are guaranteed unmasked, so no mark exceeds a
//    46-48 unit box and none is centred by bounding box alone — they are
//    nudged onto their optical centre, which is what the eye reads.
//  * No icon imitates a real product's mark. Every one of these is a generic
//    category glyph — a mic, a ring, a spirit level — drawn from primitives.
//  * The set must not look like one designer's family, because nine matching
//    tiles on a home screen is itself the anomaly. So the backgrounds use four
//    different light models (linear gradient, radial highlight, flat, and a
//    circular legacy tile) and the corner radius is a fraction of the tile,
//    not a constant.
//  * Monochrome layers are authored, not derived. Android tints them by alpha,
//    so a solid silhouette turns a mic into a blob; the `cut` flag punches the
//    real holes that keep each mark readable at 48dp in one colour.

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

// ── Colour ──────────────────────────────────────────────────────────────────

class _Rgba {
  const _Rgba(this.r, this.g, this.b, [this.a = 255]);

  final int r;
  final int g;
  final int b;
  final int a;

  static const transparent = _Rgba(0, 0, 0, 0);
  static const white = _Rgba(255, 255, 255);

  _Rgba lerp(_Rgba other, double t) => _Rgba(
        (r + (other.r - r) * t).round(),
        (g + (other.g - g) * t).round(),
        (b + (other.b - b) * t).round(),
        (a + (other.a - a) * t).round(),
      );
}

/// Relative luminance, so a contrast claim in a spec comment can be checked
/// rather than asserted. Used by [_assertContrast].
double _luminance(_Rgba c) {
  double channel(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(_Rgba a, _Rgba b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

// ── Backgrounds ─────────────────────────────────────────────────────────────

enum _BgKind { flat, linear, radial }

class _Bg {
  const _Bg.flat(this.from)
      : to = from,
        angleDeg = 0,
        kind = _BgKind.flat;

  /// Two stops along [angleDeg] (0 = left to right, positive = clockwise).
  const _Bg.linear(this.from, this.to, this.angleDeg) : kind = _BgKind.linear;

  /// An off-centre highlight in the top-left, the way an OEM icon set fakes a
  /// light source. Deliberately a different light model from the gradients.
  const _Bg.radial(this.from, this.to)
      : angleDeg = 0,
        kind = _BgKind.radial;

  final _Rgba from;
  final _Rgba to;
  final double angleDeg;
  final _BgKind kind;

  _Rgba at(double x, double y) {
    switch (kind) {
      case _BgKind.flat:
        return from;
      case _BgKind.linear:
        final a = angleDeg * math.pi / 180;
        final dx = math.cos(a);
        final dy = math.sin(a);
        // Normalised over the projected extent of the 108 grid, so the two
        // stops always land on opposite edges whatever the angle.
        final extent = 108 * (dx.abs() + dy.abs()) / 2;
        final t = (((x - 54) * dx + (y - 54) * dy) / (2 * extent) + 0.5)
            .clamp(0.0, 1.0);
        return from.lerp(to, t);
      case _BgKind.radial:
        final dx = x - 0.30 * 108;
        final dy = y - 0.30 * 108;
        final t = (math.sqrt(dx * dx + dy * dy) / (0.85 * 108)).clamp(0.0, 1.0);
        return to.lerp(from, t);
    }
  }
}

// ── Shapes ──────────────────────────────────────────────────────────────────

/// One primitive in the 108-unit grid.
///
/// [cut] shapes are negative space: they punch a hole through the mark instead
/// of painting. That is what gives the monochrome layer real holes, and on the
/// colour layers it lets the background show through — an outlined mic rather
/// than a white lozenge.
abstract class _Shape {
  const _Shape({
    required this.color,
    this.cut = false,
    this.rotDeg = 0,
  });

  final _Rgba color;
  final bool cut;

  /// Rotation about the grid centre. Several marks are deliberately a few
  /// degrees off axis — perfect symmetry is what makes a generated icon look
  /// generated.
  final double rotDeg;

  bool hit(double x, double y);

  bool contains(double x, double y) {
    if (rotDeg == 0) return hit(x, y);
    const px = 54.0;
    const py = 54.0;
    final a = -rotDeg * math.pi / 180;
    final dx = x - px;
    final dy = y - py;
    return hit(
      px + dx * math.cos(a) - dy * math.sin(a),
      py + dx * math.sin(a) + dy * math.cos(a),
    );
  }
}

class _Circle extends _Shape {
  const _Circle(this.cx, this.cy, this.r, {required super.color});

  final double cx;
  final double cy;
  final double r;

  @override
  bool hit(double x, double y) {
    final dx = x - cx;
    final dy = y - cy;
    return dx * dx + dy * dy <= r * r;
  }
}

class _RRect extends _Shape {
  const _RRect(this.x, this.y, this.w, this.h, this.r,
      {required super.color, super.cut,});

  final double x;
  final double y;
  final double w;
  final double h;
  final double r;

  @override
  bool hit(double qx, double qy) {
    if (qx < x || qx > x + w || qy < y || qy > y + h) return false;
    final ix = qx.clamp(x + r, x + w - r);
    final iy = qy.clamp(y + r, y + h - r);
    final dx = qx - ix;
    final dy = qy - iy;
    return dx * dx + dy * dy <= r * r;
  }
}

/// A stroke with round caps, from (x1,y1) to (x2,y2). Every bar, rule and hand
/// in the set is one of these.
class _Cap extends _Shape {
  const _Cap(this.x1, this.y1, this.x2, this.y2, this.r,
      {required super.color, super.cut,});

  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double r;

  @override
  bool hit(double x, double y) {
    final vx = x2 - x1;
    final vy = y2 - y1;
    final len2 = vx * vx + vy * vy;
    final t = len2 == 0 ? 0.0 : (((x - x1) * vx + (y - y1) * vy) / len2).clamp(0.0, 1.0);
    final dx = x - (x1 + t * vx);
    final dy = y - (y1 + t * vy);
    return dx * dx + dy * dy <= r * r;
  }
}

/// A thick arc. Angles in degrees, 0 = east, increasing clockwise (y is down).
class _Arc extends _Shape {
  const _Arc(this.cx, this.cy, this.r, this.thick, this.fromDeg, this.toDeg,
      {required super.color, super.rotDeg,});

  final double cx;
  final double cy;
  final double r;
  final double thick;
  final double fromDeg;
  final double toDeg;

  @override
  bool hit(double x, double y) {
    final dx = x - cx;
    final dy = y - cy;
    final d = math.sqrt(dx * dx + dy * dy);
    if ((d - r).abs() > thick / 2) return false;
    var ang = math.atan2(dy, dx) * 180 / math.pi;
    while (ang < fromDeg) {
      ang += 360;
    }
    return ang <= toDeg;
  }
}

class _Tri extends _Shape {
  const _Tri(this.ax, this.ay, this.bx, this.by, this.cx, this.cy,
      {required super.color, super.cut, super.rotDeg,});

  final double ax;
  final double ay;
  final double bx;
  final double by;
  final double cx;
  final double cy;

  static double _side(double x, double y, double x1, double y1, double x2, double y2) =>
      (x - x2) * (y1 - y2) - (x1 - x2) * (y - y2);

  @override
  bool hit(double x, double y) {
    final d1 = _side(x, y, ax, ay, bx, by);
    final d2 = _side(x, y, bx, by, cx, cy);
    final d3 = _side(x, y, cx, cy, ax, ay);
    final neg = d1 < 0 || d2 < 0 || d3 < 0;
    final pos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(neg && pos);
  }
}

// ── Icon specs ──────────────────────────────────────────────────────────────

class _IconSpec {
  const _IconSpec({
    required this.base,
    required this.bg,
    required this.mark,
    this.circularTile = false,
    this.shadow = true,
  });

  /// Resource base name: `{base}.png`, `{base}_bg.png`, `{base}_fg.png`,
  /// `{base}_mono.png`.
  final String base;
  final _Bg bg;
  final List<_Shape> mark;

  /// Legacy (pre-API-26) tile shape. One icon in the set uses a circular badge
  /// so the corner language is not uniform across the launcher.
  final bool circularTile;

  /// A 1.5-unit offset copy of the mark at 18% black underneath it. There is no
  /// blur available here, so the stacked offset is what buys depth.
  final bool shadow;
}

const _white = _Rgba.white;

final List<_IconSpec> _icons = [
  // ── News — the default identity ───────────────────────────────────────────
  // Replaces a mark that was a pixel-for-pixel copy of a real company's logo,
  // in that company's exact brand hexes. That is a trademark liability, and it
  // is also a worse disguise: a counterfeit of a famous icon is more likely to
  // be noticed than an unremarkable one nobody recognises.
  //
  // An article card — a photo block and rules of text. Reads as "a thing to
  // read" at 48dp without borrowing anyone's identity.
  _IconSpec(
    base: 'ic_launcher',
    bg: _Bg.linear(_Rgba(0xB3, 0x26, 0x1E), _Rgba(0x8C, 0x1D, 0x18), 20),
    mark: [
      _RRect(31, 31, 21, 21, 3, color: _white),
      _Cap(58, 36, 77, 36, 3, color: _white),
      _Cap(58, 47, 72, 47, 3, color: _white),
      _Cap(31, 62, 77, 62, 3, color: _white),
      _Cap(31, 73, 68, 73, 3, color: _white),
    ],
  ),

  // ── Calculator ────────────────────────────────────────────────────────────
  // The previous mark drew a calculator-shaped slab with a screen and keys —
  // device chrome, which is the single most common amateur-icon mistake and
  // turns to mud at 48dp. This is the four operators instead: unmistakable as
  // a category, legible at any size, and nothing to render but strokes.
  _IconSpec(
    base: 'ic_disguise_calculator',
    bg: _Bg.linear(_Rgba(0x3C, 0x40, 0x43), _Rgba(0x1F, 0x22, 0x24), 15),
    mark: [
      // +
      _Cap(42, 35, 42, 49, 3.4, color: _Rgba(0xFF, 0xC2, 0x4B)),
      _Cap(35, 42, 49, 42, 3.4, color: _Rgba(0xFF, 0xC2, 0x4B)),
      // −
      _Cap(59, 42, 73, 42, 3.4, color: _white),
      // ×
      _Cap(37, 61, 47, 71, 3.4, color: _white),
      _Cap(47, 61, 37, 71, 3.4, color: _white),
      // ÷
      _Cap(59, 66, 73, 66, 3.4, color: _white),
      _Circle(66, 58, 3.4, color: _white),
      _Circle(66, 74, 3.4, color: _white),
    ],
  ),

  // ── Notes ─────────────────────────────────────────────────────────────────
  // A page with a folded corner. The rules are cuts, not grey strokes, so the
  // monochrome layer keeps real holes instead of collapsing to a white slab.
  _IconSpec(
    base: 'ic_disguise_notes',
    bg: _Bg.linear(_Rgba(0xE6, 0x51, 0x00), _Rgba(0xEF, 0x6C, 0x00), 25),
    mark: [
      _RRect(34, 28, 40, 52, 4, color: _white),
      _Tri(74, 64, 74, 80, 58, 80, color: _white, cut: true),
      _Cap(42, 42, 66, 42, 2, color: _white, cut: true),
      _Cap(42, 53, 66, 53, 2, color: _white, cut: true),
      _Cap(42, 64, 56, 64, 2, color: _white, cut: true),
    ],
  ),

  // ── Weather ───────────────────────────────────────────────────────────────
  // Sun and cloud, deliberately not touching: overlapped they merge into one
  // silhouette the moment Android tints the monochrome layer.
  _IconSpec(
    base: 'ic_disguise_weather',
    bg: _Bg.linear(_Rgba(0x1E, 0x88, 0xE5), _Rgba(0x0D, 0x47, 0xA1), 20),
    mark: [
      _Circle(71, 33, 11, color: _Rgba(0xFF, 0xCA, 0x28)),
      _Circle(43, 58, 14, color: _white),
      _Circle(60, 61, 11, color: _white),
      _RRect(38, 58, 32, 14, 7, color: _white),
    ],
  ),

  // ── Convert ───────────────────────────────────────────────────────────────
  // Two arcs chasing each other, 12° off the vertical so the glyph is not
  // machine-symmetric. Single-hue teal: a converter is a tool, not a brand.
  _IconSpec(
    base: 'ic_disguise_convert',
    bg: _Bg.linear(_Rgba(0x0F, 0x76, 0x6E), _Rgba(0x11, 0x5E, 0x59), 22),
    mark: [
      _Arc(54, 54, 20, 6, 200, 355, color: _white, rotDeg: 12),
      _Tri(66, 47, 82, 47, 74, 62, color: _white, rotDeg: 12),
      _Arc(54, 54, 20, 6, 20, 175, color: _white, rotDeg: 12),
      _Tri(42, 61, 26, 61, 34, 46, color: _white, rotDeg: 12),
    ],
  ),

  // ── Recorder ──────────────────────────────────────────────────────────────
  // A radial highlight instead of a gradient, so this tile and Convert do not
  // read as the same hand. The mic is an outline — the inner cut is what keeps
  // it a mic and not a capsule once it is one flat colour.
  _IconSpec(
    base: 'ic_disguise_recorder',
    bg: _Bg.radial(_Rgba(0x1C, 0x1B, 0x1F), _Rgba(0x39, 0x36, 0x40)),
    mark: [
      _Cap(54, 38, 54, 54, 9, color: _white),
      _Cap(54, 41, 54, 51, 4.6, color: _white, cut: true),
      _Circle(54, 47, 3.2, color: _Rgba(0xE6, 0x4A, 0x19)),
      _Arc(54, 51, 16, 3.4, 15, 165, color: _white),
      _Cap(54, 67, 54, 74, 2, color: _white),
      _Cap(45, 77, 63, 77, 2, color: _white),
    ],
    shadow: false,
  ),

  // ── Timer ─────────────────────────────────────────────────────────────────
  // A circular badge rather than a squircle — a third corner language. No
  // numerals and no tick marks: both turn to noise at 48dp. The hand sits 40°
  // off vertical, which is the asymmetry that stops it looking generated.
  //
  // Green rather than the obvious stopwatch vermilion, because News is already
  // red and Notes already orange: nine icons on one home screen have to be
  // told apart by hue before shape, at a glance, in a grid.
  _IconSpec(
    base: 'ic_disguise_timer',
    bg: _Bg.linear(_Rgba(0x2E, 0x7D, 0x32), _Rgba(0x43, 0xA0, 0x47), 200),
    circularTile: true,
    mark: [
      _Arc(54, 57, 24, 6, -75, 255, color: _white),
      _RRect(48, 27, 12, 5, 2, color: _white),
      _Cap(54, 57, 62, 47, 2.6, color: _white),
    ],
  ),

  // ── Level ─────────────────────────────────────────────────────────────────
  // Flat, no gradient at all — a fourth craft signature. The bubble sits off
  // centre because that is what a spirit level actually looks like, so the
  // asymmetry is earned rather than decorative.
  _IconSpec(
    base: 'ic_disguise_level',
    bg: _Bg.flat(_Rgba(0xF3, 0xE9, 0xD2)),
    mark: [
      _RRect(24, 43, 60, 22, 11, color: _Rgba(0xB0, 0x6A, 0x12)),
      _RRect(27.5, 46.5, 53, 15, 7.5, color: _white, cut: true),
      _Cap(45, 46, 45, 62, 1.2, color: _Rgba(0x6B, 0x3F, 0x08)),
      _Cap(63, 46, 63, 62, 1.2, color: _Rgba(0x6B, 0x3F, 0x08)),
      _Circle(57.5, 54, 7, color: _Rgba(0x2E, 0x7D, 0x57)),
    ],
    shadow: false,
  ),

  // ── Device info ───────────────────────────────────────────────────────────
  // Bars, not a drawing of a phone. The tallest bar is a lighter tint so there
  // is tonal separation inside the mark and not only against the background.
  _IconSpec(
    base: 'ic_disguise_device',
    bg: _Bg.linear(_Rgba(0x31, 0x2E, 0x81), _Rgba(0x37, 0x30, 0xA3), 14),
    mark: [
      _RRect(31, 58, 10, 18, 5, color: _white),
      _RRect(49, 46, 10, 30, 5, color: _white),
      _RRect(67, 34, 10, 42, 5, color: _Rgba(0xC7, 0xD2, 0xFE)),
    ],
  ),
];

// ── Output ──────────────────────────────────────────────────────────────────

enum _Layer { legacy, background, foreground, monochrome }

/// Legacy launcher bitmaps: 48dp at each density.
const _legacySizes = <String, int>{
  'mipmap-mdpi': 48,
  'mipmap-hdpi': 72,
  'mipmap-xhdpi': 96,
  'mipmap-xxhdpi': 144,
  'mipmap-xxxhdpi': 192,
};

/// Adaptive layers are the 108dp grid, so every density is 2.25x the legacy one.
const _adaptiveSizes = <String, int>{
  'mipmap-mdpi': 108,
  'mipmap-hdpi': 162,
  'mipmap-xhdpi': 216,
  'mipmap-xxhdpi': 324,
  'mipmap-xxxhdpi': 432,
};

void main() {
  _assertContrast();

  final resDir = _resolveResDir();
  stdout.writeln('Writing icons to: ${resDir.path}');

  var written = 0;
  for (final spec in _icons) {
    for (final entry in _legacySizes.entries) {
      final dir = Directory('${resDir.path}/${entry.key}')
        ..createSync(recursive: true);
      void write(String suffix, _Layer layer, int size) {
        File('${dir.path}/${spec.base}$suffix.png')
            .writeAsBytesSync(img.encodePng(_render(spec, layer, size)));
        written++;
      }

      write('', _Layer.legacy, entry.value);
      final adaptive = _adaptiveSizes[entry.key]!;
      write('_bg', _Layer.background, adaptive);
      write('_fg', _Layer.foreground, adaptive);
      write('_mono', _Layer.monochrome, adaptive);
    }
    stdout.writeln('  ✓ ${spec.base}');
  }

  stdout.writeln('Done — $written files.');
}

/// The one number in a spec that is a claim rather than a taste: a mark has to
/// clear its background or it disappears at 48dp. Level is the tight one —
/// ochre on sand — and it was 1.9:1 before the vial was darkened.
void _assertContrast() {
  const min = 3.0;
  for (final spec in _icons) {
    final bg = spec.bg.at(54, 54);
    for (final shape in spec.mark) {
      if (shape.cut) continue;
      final ratio = _contrast(shape.color, bg);
      if (ratio < min) {
        throw StateError('${spec.base}: a mark colour is only '
            '${ratio.toStringAsFixed(2)}:1 against its background '
            '(needs $min:1 to survive 48dp)');
      }
    }
  }
}

img.Image _render(_IconSpec spec, _Layer layer, int size) {
  const ss = 4; // supersample factor; averaged down for clean edges
  final n = size * ss;
  final big = img.Image(width: n, height: n, numChannels: 4);
  final legacy = layer == _Layer.legacy;

  // The legacy tile shows the middle 88 units of the 108 grid, which puts the
  // 66-unit safe mark at ~75% of the tile — where a launcher icon's mark sits.
  double toGrid(int p) =>
      legacy ? 10 + (p + 0.5) / n * 88 : (p + 0.5) / n * 108;

  for (var y = 0; y < n; y++) {
    final gy = toGrid(y);
    for (var x = 0; x < n; x++) {
      final gx = toGrid(x);

      if (legacy && !_insideTile(gx, gy, spec.circularTile)) continue;

      final bg = legacy ? spec.bg.at(gx, gy) : _Rgba.transparent;
      var r = bg.r.toDouble();
      var g = bg.g.toDouble();
      var b = bg.b.toDouble();
      var a = bg.a.toDouble();

      void blend(_Rgba c, double alpha) {
        r = r * (1 - alpha) + c.r * alpha;
        g = g * (1 - alpha) + c.g * alpha;
        b = b * (1 - alpha) + c.b * alpha;
        a = a * (1 - alpha) + 255 * alpha;
      }

      if (layer == _Layer.background) {
        final c = spec.bg.at(gx, gy);
        r = c.r.toDouble();
        g = c.g.toDouble();
        b = c.b.toDouble();
        a = 255;
      } else {
        if (spec.shadow && layer != _Layer.monochrome) {
          final shadowed = spec.mark
              .any((s) => !s.cut && s.contains(gx - 1.5, gy - 1.5));
          if (shadowed) blend(const _Rgba(0, 0, 0), 0.18);
        }
        for (final shape in spec.mark) {
          if (!shape.contains(gx, gy)) continue;
          if (shape.cut) {
            // Negative space: on the legacy tile the background is behind the
            // mark, everywhere else there is nothing behind it at all.
            final under = legacy ? spec.bg.at(gx, gy) : _Rgba.transparent;
            r = under.r.toDouble();
            g = under.g.toDouble();
            b = under.b.toDouble();
            a = under.a.toDouble();
          } else {
            blend(layer == _Layer.monochrome ? _Rgba.white : shape.color, 1);
          }
        }
      }

      big.setPixelRgba(x, y, r.round(), g.round(), b.round(), a.round());
    }
  }

  return _downsample(big, size, ss);
}

/// Box-averages [src] down by [ss], **premultiplying alpha**.
///
/// A straight average is wrong for anything with transparency: the RGB of a
/// fully transparent pixel is (0,0,0), so averaging it with a white mark edge
/// produces grey. Three of the four layers here are transparent outside the
/// mark, which is exactly where a dark fringe would show — a halo around every
/// glyph on every adaptive icon.
img.Image _downsample(img.Image src, int size, int ss) {
  final out = img.Image(width: size, height: size, numChannels: 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var sa = 0.0;
      var sr = 0.0;
      var sg = 0.0;
      var sb = 0.0;
      for (var dy = 0; dy < ss; dy++) {
        for (var dx = 0; dx < ss; dx++) {
          final p = src.getPixel(x * ss + dx, y * ss + dy);
          final a = p.a.toDouble();
          sa += a;
          sr += p.r * a;
          sg += p.g * a;
          sb += p.b * a;
        }
      }
      final n = ss * ss;
      if (sa == 0) {
        out.setPixelRgba(x, y, 0, 0, 0, 0);
      } else {
        out.setPixelRgba(x, y, (sr / sa).round(), (sg / sa).round(),
            (sb / sa).round(), (sa / n).round(),);
      }
    }
  }
  return out;
}

/// The legacy tile silhouette, in grid units over the visible 10..98 band.
bool _insideTile(double x, double y, bool circular) {
  const lo = 10.0;
  const hi = 98.0;
  if (circular) {
    final dx = x - 54;
    final dy = y - 54;
    return dx * dx + dy * dy <= 44 * 44;
  }
  // Radius as a fraction of the tile, not a constant — 0.18 x 88.
  const cr = 0.18 * 88;
  if (x < lo || x > hi || y < lo || y > hi) return false;
  final ix = x.clamp(lo + cr, hi - cr);
  final iy = y.clamp(lo + cr, hi - cr);
  final dx = x - ix;
  final dy = y - iy;
  return dx * dx + dy * dy <= cr * cr;
}

/// Resolves android/app/src/main/res relative to this script, with a
/// CWD-relative fallback (handles being run from the project root).
Directory _resolveResDir() {
  const rel = 'android/app/src/main/res';
  final fromCwd = Directory(rel);
  if (fromCwd.existsSync()) return fromCwd;
  // .../mobile/tool/generate_icon.dart -> .../mobile
  final projectRoot = File(Platform.script.toFilePath()).parent.parent;
  return Directory('${projectRoot.path}/$rel');
}
