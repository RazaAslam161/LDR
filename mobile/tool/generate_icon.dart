// tool/generate_icon.dart
//
// One-time generator for the Android launcher icon.
//
// Draws a "Google-style" mark on a white rounded square:
//   - a four-colour "G" on the left (blue top / red right / yellow bottom /
//     green left, with a blue cross-bar), and
//   - three short horizontal lines on the right (blue, red, yellow).
//
// Writes ic_launcher.png at every mipmap density. The drawing is done at 4x
// resolution and then averaged down, which gives clean anti-aliased edges.
//
// Run from the Flutter project root (mobile/):
//   dart run tool/generate_icon.dart
//
// Uses the `image` package (already a dependency: image ^4.x).

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

// ── Google palette ──────────────────────────────────────────────────────────
const _blue = [0x42, 0x85, 0xF4]; // #4285F4
const _red = [0xEA, 0x43, 0x35]; // #EA4335
const _yellow = [0xFB, 0xBC, 0x05]; // #FBBC05
const _green = [0x34, 0xA8, 0x53]; // #34A853

// Target densities: folder name -> pixel size.
const _targets = <String, int>{
  'mipmap-mdpi': 48,
  'mipmap-hdpi': 72,
  'mipmap-xhdpi': 96,
  'mipmap-xxhdpi': 144,
  'mipmap-xxxhdpi': 192,
};

void main() {
  final resDir = _resolveResDir();
  stdout.writeln('Writing icons to: ${resDir.path}');

  _targets.forEach((folder, size) {
    final image = _renderIcon(size);
    final bytes = img.encodePng(image);
    final dir = Directory('${resDir.path}/$folder')..createSync(recursive: true);
    // Write BOTH the legacy icon and the adaptive-icon foreground.
    // The adaptive icon (mipmap-anydpi-v26/ic_launcher.xml) MUST point its
    // <foreground> at a DIFFERENT resource than ic_launcher — pointing it at
    // @mipmap/ic_launcher is a recursive self-reference on API 26+, which both
    // breaks the launcher icon AND crashes any foreground-service notification
    // ("Recursive reference in drawable"). So the foreground is its own file.
    for (final name in ['ic_launcher.png', 'ic_launcher_foreground.png']) {
      File('${dir.path}/$name').writeAsBytesSync(bytes);
      stdout.writeln('  ✓ $folder/$name  (${size}x$size)');
    }
  });

  stdout.writeln('Done.');
}

/// Renders the icon at [size] px by drawing at 4x and averaging down.
img.Image _renderIcon(int size) {
  const ss = 4; // supersample factor
  final n = size * ss;
  final s = n.toDouble();
  final big = img.Image(width: n, height: n, numChannels: 4);

  // ── Geometry (fractions of the supersampled canvas) ─────────────────────
  final cornerR = 0.22 * s; // rounded-square corner radius

  // The "G" lives on the left, well inside the adaptive-icon safe zone.
  final gcx = 0.40 * s;
  final gcy = 0.50 * s;
  final rOuter = 0.155 * s;
  final rInner = 0.088 * s;
  final band = rOuter - rInner;
  const mouthHalf = 0.45; // radians — half-width of the "G" opening (faces east)
  final barHalf = band * 0.55; // half-thickness of the blue cross-bar

  // Three lines on the right half.
  final lineX0 = 0.575 * s;
  final lineX1 = 0.775 * s;
  final lineThick = 0.052 * s;
  final lineR = lineThick / 2.0;
  final lines = [
    [0.42 * s, _blue],
    [0.50 * s, _red],
    [0.58 * s, _yellow],
  ];

  for (var y = 0; y < n; y++) {
    final py = y + 0.5;
    for (var x = 0; x < n; x++) {
      final px = x + 0.5;

      // 1. Outside the rounded square → transparent.
      if (!_insideRoundedSquare(px, py, s, cornerR)) {
        continue; // pixel stays (0,0,0,0)
      }

      // 2. Default: white background.
      var r = 255, g = 255, b = 255;

      // 3. The four-colour "G".
      final dx = px - gcx;
      final dy = py - gcy;
      final dist = math.sqrt(dx * dx + dy * dy);
      final ang = math.atan2(dy, dx); // 0 = east, +pi/2 = south (y is down)

      final inCrossBar = px >= gcx &&
          py >= gcy - barHalf &&
          py <= gcy + barHalf &&
          dist <= rOuter;
      final inMouth = ang > -mouthHalf && ang < mouthHalf; // east-facing gap
      final inRing = dist >= rInner && dist <= rOuter;

      List<int>? gColor;
      if (inCrossBar) {
        gColor = _blue;
      } else if (inRing && !inMouth) {
        gColor = _quadrantColor(ang);
      }
      if (gColor != null) {
        r = gColor[0];
        g = gColor[1];
        b = gColor[2];
      }

      // 4. The three lines (right half). They never overlap the "G".
      for (final line in lines) {
        final cyL = line[0] as double;
        final color = line[1] as List<int>;
        if (_inHCapsule(px, py, lineX0 + lineR, lineX1 - lineR, cyL, lineR)) {
          r = color[0];
          g = color[1];
          b = color[2];
          break;
        }
      }

      big.setPixelRgba(x, y, r, g, b, 255);
    }
  }

  // Average down to the target size for anti-aliasing.
  return img.copyResize(
    big,
    width: size,
    height: size,
    interpolation: img.Interpolation.average,
  );
}

/// Picks the arc colour for the "G" by direction:
/// top→blue, right→red, bottom→yellow, left→green.
List<int> _quadrantColor(double ang) {
  const q = math.pi / 4;
  if (ang >= -q && ang < q) return _red; // east  (right)
  if (ang >= q && ang < 3 * q) return _yellow; // south (bottom)
  if (ang >= -3 * q && ang < -q) return _blue; // north (top)
  return _green; // west (left)
}

/// True if (px,py) is inside the full-bleed rounded square [0,s] with radius cr.
bool _insideRoundedSquare(double px, double py, double s, double cr) {
  if (px >= cr && px <= s - cr) return true; // vertical band
  if (py >= cr && py <= s - cr) return true; // horizontal band
  final ccx = px < cr ? cr : s - cr; // nearest corner centre
  final ccy = py < cr ? cr : s - cr;
  final dx = px - ccx;
  final dy = py - ccy;
  return dx * dx + dy * dy <= cr * cr;
}

/// True if (px,py) is within radius [r] of the horizontal segment (ax..bx, cy).
bool _inHCapsule(double px, double py, double ax, double bx, double cy, double r) {
  final t = ((px - ax) / (bx - ax)).clamp(0.0, 1.0);
  final sx = ax + t * (bx - ax);
  final dx = px - sx;
  final dy = py - cy;
  return dx * dx + dy * dy <= r * r;
}

/// Resolves android/app/src/main/res relative to this script, with a
/// CWD-relative fallback (handles being run from the project root).
Directory _resolveResDir() {
  const rel = 'android/app/src/main/res';
  try {
    // .../mobile/lib/tools/generate_icon.dart  ->  .../mobile
    final scriptFile = File(Platform.script.toFilePath());
    final projectRoot = scriptFile.parent.parent.parent;
    final fromScript = Directory('${projectRoot.path}/$rel');
    if (Directory(projectRoot.path).existsSync()) return fromScript;
  } catch (_) {
    // fall through
  }
  return Directory(rel);
}
