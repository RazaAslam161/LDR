// Draws the app's spot illustrations. Run: dart run tool/generate_art.dart
//
// These were meant to be generated images. Three rounds of that produced
// baked-in text, blue butterflies, teal fringing and someone's Instagram
// screenshot — because a generator cannot be *told* not to do a thing, only
// asked. Code can be told. Every pixel below comes from MilesColors, so the
// palette is correct by construction, there is no text because nothing draws
// glyphs, and the output is byte-identical on every run.
//
// Same shape as tool/generate_icon.dart: pure Dart, package:image (already a
// direct dependency), no Flutter, geometry expressed once and rendered to
// files.
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

// ── Emberlight, from lib/core/ui/theme.dart ──────────────────────────────
final night = img.ColorRgb8(0x12, 0x0A, 0x0C);
final surface1 = img.ColorRgb8(0x22, 0x10, 0x17);
final surface2 = img.ColorRgb8(0x2F, 0x16, 0x20);
final ember = img.ColorRgb8(0xE8, 0x67, 0x4A);
final emberSoft = img.ColorRgb8(0xF2, 0x95, 0x6F);
final emberDeep = img.ColorRgb8(0xD2, 0x4A, 0x38);
final gilt = img.ColorRgb8(0xD9, 0xA8, 0x6C);
final cream = img.ColorRgb8(0xFC, 0xEF, 0xE6);
final starlight = img.ColorRgb8(0xFB, 0xEF, 0xD6);

/// A drawing surface filled with the app's night.
img.Image canvas(int size) =>
    img.Image(width: size, height: size)..clear(night);

/// A black scratch layer. Glows are drawn here, blurred, then ADDED to the
/// artwork — additive light, so overlapping glows brighten rather than
/// flatten, which is how a candle behaves and how a paint-over does not.
img.Image glowLayer(int size) =>
    img.Image(width: size, height: size)..clear(img.ColorRgb8(0, 0, 0));

void addLayer(img.Image dst, img.Image src, {double gain = 1.0}) {
  for (var y = 0; y < dst.height; y++) {
    for (var x = 0; x < dst.width; x++) {
      final s = src.getPixel(x, y);
      final d = dst.getPixel(x, y);
      dst.setPixelRgb(
        x,
        y,
        math.min(255, d.r + s.r * gain).toInt(),
        math.min(255, d.g + s.g * gain).toInt(),
        math.min(255, d.b + s.b * gain).toInt(),
      );
    }
  }
}

/// Plots a parametric curve as a chain of short antialiased segments.
void curve(
  img.Image im,
  int steps,
  math.Point<double> Function(double t) at, {
  required img.Color color,
  required num thickness,
}) {
  var prev = at(0);
  for (var i = 1; i <= steps; i++) {
    final p = at(i / steps);
    img.drawLine(
      im,
      x1: prev.x.round(),
      y1: prev.y.round(),
      x2: p.x.round(),
      y2: p.y.round(),
      color: color,
      thickness: thickness,
      antialias: true,
    );
    prev = p;
  }
}

// ── 1. thread — timeline empty state ─────────────────────────────────────
//
// A trefoil: one continuous line, crossing itself three times, tied and
// closed. It deliberately echoes the couple's wax seal (two linked loops) —
// the same idea in a lighter hand.
img.Image thread(int s) {
  final art = canvas(s);
  final glow = glowLayer(s);
  final c = s / 2;
  final scale = s * 0.115;
  math.Point<double> at(double t) {
    final a = t * 2 * math.pi;
    return math.Point(
      c + scale * (math.sin(a) + 2 * math.sin(2 * a)),
      c + scale * (math.cos(a) - 2 * math.cos(2 * a)),
    );
  }

  curve(glow, 900, at, color: emberDeep, thickness: s * 0.030);
  img.gaussianBlur(glow, radius: (s * 0.030).round());
  addLayer(art, glow, gain: 0.85);
  curve(art, 900, at, color: gilt, thickness: s * 0.011);
  curve(art, 900, at, color: cream, thickness: s * 0.004);
  return art;
}

// ── 2. lantern — wish jar empty state ────────────────────────────────────
//
// Mostly dark, with one ember just catching inside it.
img.Image lantern(int s) {
  final art = canvas(s);
  final glow = glowLayer(s);
  final cx = s ~/ 2;
  final cy = (s * 0.52).round();
  final rx = (s * 0.20).round();
  final ry = (s * 0.24).round();

  // Cap and base first, so the paper overlaps them rather than floating.
  img.fillRect(art,
      x1: cx - (rx * 0.30).round(), y1: cy - ry - (s * 0.030).round(),
      x2: cx + (rx * 0.30).round(), y2: cy - ry + (s * 0.020).round(),
      color: surface1, radius: (s * 0.008).round(),);
  img.fillRect(art,
      x1: cx - (rx * 0.26).round(), y1: cy + ry - (s * 0.020).round(),
      x2: cx + (rx * 0.26).round(), y2: cy + ry + (s * 0.026).round(),
      color: surface1, radius: (s * 0.008).round(),);

  // Paper, lit from a single point low inside it: brightness falls off with
  // distance from the ember, so the lantern glows from within instead of
  // being a flat disc with lines on it.
  final ex = cx.toDouble();
  final ey = cy + ry * 0.42;
  final reach = ry * 1.35;
  for (var y = -ry; y <= ry; y++) {
    final w = (rx * math.sqrt(1 - (y * y) / (ry * ry))).round();
    if (w <= 0) continue;
    for (var x = -w; x <= w; x++) {
      final d = math.sqrt(math.pow(cx + x - ex, 2) + math.pow(cy + y - ey, 2));
      final lit = (1 - d / reach).clamp(0.0, 1.0);
      final f = lit * lit; // falls off fast — most of the paper stays dark
      art.setPixelRgb(
        cx + x,
        cy + y,
        (surface1.r + (emberSoft.r - surface1.r) * f).toInt(),
        (surface1.g + (emberSoft.g - surface1.g) * f * 0.72).toInt(),
        (surface1.b + (emberSoft.b - surface1.b) * f * 0.58).toInt(),
      );
    }
  }
  // Ribs: a shade darker than whatever they cross, never black lines.
  for (var i = -5; i <= 5; i++) {
    final y = cy + (i * ry / 5.5).round();
    final k = (y - cy).abs() / ry;
    if (k >= 0.99) continue;
    final w = (rx * math.sqrt(1 - k * k)).round();
    for (var x = -w; x <= w; x++) {
      final p = art.getPixel(cx + x, y);
      art.setPixelRgb(
          cx + x, y, (p.r * 0.62).toInt(), (p.g * 0.62).toInt(),
          (p.b * 0.62).toInt(),);
    }
  }
  // The ember itself: a small upright flame shape, warm rather than white.
  img.fillCircle(glow,
      x: ex.round(), y: ey.round(), radius: (s * 0.030).round(),
      color: ember, antialias: true,);
  img.gaussianBlur(glow, radius: (s * 0.030).round());
  addLayer(art, glow, gain: 0.9);
  for (var i = 0; i < 7; i++) {
    final t = i / 6;
    img.fillCircle(art,
        x: ex.round(), y: (ey - t * s * 0.030).round(),
        radius: ((1 - t) * s * 0.009 + 1).round(),
        color: t > 0.55 ? starlight : gilt, antialias: true,);
  }
  return art;
}

// ── 3. chest — capsule empty state ───────────────────────────────────────
//
// Closed, with light finding the seam under the lid.
img.Image chest(int s) {
  final art = canvas(s);
  final cx = s ~/ 2;
  final w = (s * 0.30).round();
  final h = (s * 0.17).round();
  final top = (s * 0.40).round();
  final seam = top + (s * 0.075).round();

  // Lid (an arc of stacked rows) and body.
  for (var y = 0; y <= (s * 0.075).round(); y++) {
    final k = y / (s * 0.075);
    final ww = (w * math.sqrt(1 - (1 - k) * (1 - k) * 0.75)).round();
    img.drawLine(art,
        x1: cx - ww, y1: seam - y, x2: cx + ww, y2: seam - y,
        color: img.ColorRgb8(
          (surface1.r + (surface2.r - surface1.r) * k).toInt(),
          (surface1.g + (surface2.g - surface1.g) * k).toInt(),
          (surface1.b + (surface2.b - surface1.b) * k).toInt(),
        ),);
  }
  img.fillRect(art,
      x1: cx - w, y1: seam + (s * 0.010).round(), x2: cx + w, y2: seam + h,
      color: surface1, radius: (s * 0.010).round(),);
  // Gold bands and a clasp.
  for (final bx in [cx - (w * 0.62).round(), cx + (w * 0.62).round()]) {
    img.fillRect(art,
        x1: bx - (s * 0.008).round(), y1: seam - (s * 0.060).round(),
        x2: bx + (s * 0.008).round(), y2: seam + h,
        color: gilt,);
  }
  img.fillRect(art,
      x1: cx - (s * 0.018).round(), y1: seam - (s * 0.006).round(),
      x2: cx + (s * 0.018).round(), y2: seam + (s * 0.045).round(),
      color: gilt, radius: (s * 0.005).round(),);
  // The seam: the whole point of the drawing.
  final glow = glowLayer(s);
  img.drawLine(glow,
      x1: cx - w + 4, y1: seam + (s * 0.004).round(),
      x2: cx + w - 4, y2: seam + (s * 0.004).round(),
      color: ember, thickness: s * 0.012,);
  img.gaussianBlur(glow, radius: (s * 0.028).round());
  addLayer(art, glow);
  img.drawLine(art,
      x1: cx - w + 6, y1: seam + (s * 0.004).round(),
      x2: cx + w - 6, y2: seam + (s * 0.004).round(),
      color: starlight, thickness: s * 0.004,);
  return art;
}

// ── 4. frame — gallery empty state ───────────────────────────────────────
img.Image frame(int s) {
  final art = canvas(s);
  final cx = s ~/ 2;
  final cy = s ~/ 2;
  final w = (s * 0.21).round();
  final h = (s * 0.26).round();

  img.fillRect(art,
      x1: cx - w, y1: cy - h, x2: cx + w, y2: cy + h,
      color: gilt, radius: (s * 0.006).round(),);
  img.fillRect(art,
      x1: cx - w + (s * 0.016).round(), y1: cy - h + (s * 0.016).round(),
      x2: cx + w - (s * 0.016).round(), y2: cy + h - (s * 0.016).round(),
      color: img.ColorRgb8(0xB4, 0x8A, 0x58),);
  img.fillRect(art,
      x1: cx - w + (s * 0.026).round(), y1: cy - h + (s * 0.026).round(),
      x2: cx + w - (s * 0.026).round(), y2: cy + h - (s * 0.026).round(),
      color: night,);

  // Two sparks adrift in the empty opening.
  final glow = glowLayer(s);
  for (final p in [
    [cx - (s * 0.045).round(), cy - (s * 0.055).round(), s * 0.016],
    [cx + (s * 0.055).round(), cy + (s * 0.070).round(), s * 0.011],
  ]) {
    img.fillCircle(glow,
        x: p[0].round(), y: p[1].round(), radius: p[2].round(),
        color: emberSoft, antialias: true,);
  }
  img.gaussianBlur(glow, radius: (s * 0.022).round());
  addLayer(art, glow);
  for (final p in [
    [cx - (s * 0.045).round(), cy - (s * 0.055).round(), s * 0.005],
    [cx + (s * 0.055).round(), cy + (s * 0.070).round(), s * 0.0035],
  ]) {
    img.fillCircle(art,
        x: p[0].round(), y: p[1].round(), radius: p[2].round(),
        color: starlight, antialias: true,);
  }
  return art;
}

/// Proves what the eye would have to be trusted for otherwise: nothing cold
/// got in, and the frame is not empty.
void report(String name, img.Image im) {
  var cold = 0;
  var lit = 0;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final p = im.getPixel(x, y);
      if (p.b > p.r + 6) cold++;
      if (p.r > 0x40) lit++;
    }
  }
  final total = im.width * im.height;
  final pct = (lit / total * 100).toStringAsFixed(1);
  stdout.writeln('$name: ${im.width}x${im.height}  lit=$pct%  '
      'cold_pixels=$cold');
  if (cold != 0) {
    stderr.writeln('  !! $name has $cold pixels bluer than red');
    exitCode = 1;
  }
  if (lit < total * 0.005) {
    stderr.writeln('  !! $name is nearly empty');
    exitCode = 1;
  }
}

void main() {
  final root = Directory('assets/art');
  root.createSync(recursive: true);
  final work = <String, img.Image>{
    'thread': thread(768),
    'lantern': lantern(768),
    'chest': chest(768),
    'frame': frame(768),
    // No 'jar' here on purpose. The wish jar ships the OWNER'S photograph,
    // not a drawing — see BRAIN §141. A jar() entry would emit assets/art/
    // jar.png, and the convert step would then overwrite jar.webp and destroy
    // a source this repo does not hold a copy of.
  };
  work.forEach((name, im) {
    report(name, im);
    File('assets/art/$name.png').writeAsBytesSync(img.encodePng(im, level: 9));
  });
  stdout.writeln('wrote ${work.length} files to assets/art/');
}
