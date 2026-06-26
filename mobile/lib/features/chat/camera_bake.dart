import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Inputs for the off-isolate bake. All fields are primitives/Lists so the
/// object can be sent to a [compute] isolate.
class BakeRequest {
  BakeRequest({
    required this.bytes,
    required this.filterId,
    required this.matrix,
    required this.blurSigma,
    required this.overlayArgb,
    required this.overlayScreen,
    required this.hasGrain,
    required this.grainIntensity,
    this.mirror = false,
  });

  final Uint8List bytes;
  final String filterId;
  final List<double> matrix; // same 4×5 matrix used by the live preview
  final double blurSigma;
  final int? overlayArgb; // null = no overlay
  final bool overlayScreen; // true = screen blend, false = overlay blend
  final bool hasGrain;
  final double grainIntensity;
  final bool mirror; // flip horizontally (front camera, to match the preview)

  // Quality: downscale only if wider than this, and encode at high quality.
  static const int maxWidth = 1600;
  static const int jpegQuality = 92;
}

/// compute() entry point — decode → resize → apply the SAME colour matrix as the
/// preview → blur/overlay/grain → re-encode JPEG. Runs off the UI isolate so
/// capture never janks. Returns the original bytes unchanged if decoding fails.
Uint8List bakeSnap(BakeRequest req) {
  var image = img.decodeImage(req.bytes);
  if (image == null) return req.bytes;

  // Mirror to match the front-camera preview (which is flipped like a mirror),
  // so the saved selfie reads the same way the user saw it.
  if (req.mirror) {
    image = img.flipHorizontal(image);
  }

  // Resize first (fewer pixels through every subsequent loop). Only downscale.
  if (image.width > BakeRequest.maxWidth) {
    image = img.copyResize(image, width: BakeRequest.maxWidth);
  }

  if (req.filterId != 'none') {
    _applyMatrix(image, req.matrix);
    if (req.blurSigma > 0) {
      image =
          img.gaussianBlur(image, radius: req.blurSigma.round().clamp(1, 10));
    }
    if (req.overlayArgb != null) {
      _applyOverlay(image, req.overlayArgb!, req.overlayScreen);
    }
    if (req.hasGrain) {
      applyGrainBake(image, req.grainIntensity);
    }
  }

  return img.encodeJpg(image, quality: BakeRequest.jpegQuality);
}

/// Apply a 4×5 colour matrix (the preview's [ColorFilter.matrix]) per pixel.
/// The 5th column is a constant in 0..255 — identical semantics to Flutter's
/// ColorFilter, so the baked photo matches the live preview.
void _applyMatrix(img.Image image, List<double> m) {
  final r0 = m[0], r1 = m[1], r2 = m[2], rc = m[4];
  final g0 = m[5], g1 = m[6], g2 = m[7], gc = m[9];
  final b0 = m[10], b1 = m[11], b2 = m[12], bc = m[14];
  for (final p in image) {
    final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
    p.r = (r0 * r + r1 * g + r2 * b + rc).clamp(0, 255).round();
    p.g = (g0 * r + g1 * g + g2 * b + gc).clamp(0, 255).round();
    p.b = (b0 * r + b1 * g + b2 * b + bc).clamp(0, 255).round();
  }
}

/// Composite a translucent colour over the image with a screen or overlay blend
/// (matches the preview's overlay layer). [argb] alpha controls the mix weight.
void _applyOverlay(img.Image image, int argb, bool screen) {
  final oa = ((argb >> 24) & 0xFF) / 255.0;
  final or = ((argb >> 16) & 0xFF).toDouble();
  final og = ((argb >> 8) & 0xFF).toDouble();
  final ob = (argb & 0xFF).toDouble();

  double blend(double base, double src) {
    if (screen) return 255 - (255 - base) * (255 - src) / 255;
    return base < 128
        ? 2 * base * src / 255
        : 255 - 2 * (255 - base) * (255 - src) / 255;
  }

  for (final p in image) {
    final br = p.r.toDouble(), bg = p.g.toDouble(), bb = p.b.toDouble();
    p.r = (br * (1 - oa) + blend(br, or) * oa).clamp(0, 255).round();
    p.g = (bg * (1 - oa) + blend(bg, og) * oa).clamp(0, 255).round();
    p.b = (bb * (1 - oa) + blend(bb, ob) * oa).clamp(0, 255).round();
  }
}

/// Bakes reproducible (fixed seed 42) film grain into the pixels using an
/// overlay blend, weighted by [intensity]. Matches the look of the live
/// _GrainOverlay so Freesia/Retro captures keep their grain.
img.Image applyGrainBake(img.Image image, double intensity) {
  for (final p in image) {
    final v = ((p.x * 1619 + p.y * 31337 + 42 * 6301) & 0x7FFFFFFF) % 256;
    p.r = _grainChannel(p.r.toInt(), v, intensity);
    p.g = _grainChannel(p.g.toInt(), v, intensity);
    p.b = _grainChannel(p.b.toInt(), v, intensity);
  }
  return image;
}

int _grainChannel(int c, int v, double intensity) {
  final result = (c < 128)
      ? ((2 * c * v) ~/ 255).clamp(0, 255)
      : (255 - (2 * (255 - c) * (255 - v)) ~/ 255).clamp(0, 255);
  return (c + (result - c) * intensity * 0.6).round().clamp(0, 255);
}
