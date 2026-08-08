import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Inputs for the off-isolate bake. All fields are primitives/Lists so the
/// object can be sent to a [compute] isolate.
class BakeRequest {
  BakeRequest({
    required this.path,
    required this.filterId,
    required this.matrix,
    required this.blurSigma,
    required this.overlayArgb,
    required this.overlayScreen,
    required this.hasGrain,
    required this.grainIntensity,
    this.mirror = false,
  });

  /// The camera's own file. compute() is Isolate.run — a Uint8List argument is
  /// COPIED, not transferred, so passing bytes meant reading megabytes on the
  /// UI isolate and then cloning them. The isolate opens the file itself.
  final String path;
  final String filterId;
  final List<double> matrix; // same 4×5 matrix used by the live preview
  final double blurSigma;
  final int? overlayArgb; // null = no overlay
  final bool overlayScreen; // true = screen blend, false = overlay blend
  final bool hasGrain;
  final double grainIntensity;
  final bool mirror; // flip horizontally (front camera, to match the preview)

  // Capture is 1080p, so this cap is never hit and copyResize never runs —
  // which is the point. It stays as a backstop for a device that negotiates
  // something larger, and it is deliberately NOT 2560: the old cap sat above
  // the old 4K capture, so every filtered shot took a resize it did not need.
  static const int maxWidth = 1920;

  // 88, not 95. The difference is invisible in a 220dp bubble and it is most of
  // the upload. Nothing here is an archival master — the sensor's own JPEG is
  // shipped untouched whenever it can be.
  static const int jpegQuality = 88;
}

/// compute() entry point. Maximises quality:
/// - Unfiltered + no mirror → returns the camera's NATIVE JPEG untouched (zero
///   recompression = true sensor quality).
/// - Otherwise decode → mirror → filter/blur/overlay/grain → re-encode at q95,
///   only downscaling if wider than [BakeRequest.maxWidth].
/// On any decode/processing failure (e.g. OOM on a huge image) it falls back to
/// the raw bytes, so a capture is never lost — just unprocessed.
/// Flips an image left-to-right by reversing each row of the pixel buffer.
///
/// img.flipHorizontal does the same thing through getPixel/setPixel, which
/// allocates a Pixel object per access — for a 1080p frame that is roughly two
/// million allocations for a selfie, and it is the one step that runs even when
/// no filter is selected. This walks the bytes instead and allocates nothing.
///
/// Falls back to the package implementation for any layout it does not own
/// (palette images, 16-bit, anything not a plain uint8 buffer).
///
/// Public only so a test can flip a known image twice and assert it is byte
/// identical — a stride or channel-count slip here silently swizzles colour.
img.Image mirrorInPlace(img.Image image) {
  final data = image.data;
  if (data is! img.ImageDataUint8) return img.flipHorizontal(image);

  final bytes = data.data;
  final channels = data.numChannels;
  final stride = data.rowStride;
  final width = image.width;
  final swap = List<int>.filled(channels, 0);

  for (var y = 0; y < image.height; y++) {
    final row = y * stride;
    for (var xl = 0, xr = width - 1; xl < xr; xl++, xr--) {
      final l = row + xl * channels;
      final r = row + xr * channels;
      for (var c = 0; c < channels; c++) {
        swap[c] = bytes[l + c];
        bytes[l + c] = bytes[r + c];
        bytes[r + c] = swap[c];
      }
    }
  }
  return image;
}

Uint8List bakeSnap(BakeRequest req) {
  final bytes = File(req.path).readAsBytesSync();
  final isNone = req.filterId == 'none';

  // Fast path: nothing to do → ship the original sensor JPEG with no quality loss.
  if (isNone && !req.mirror) return bytes;

  try {
    var image = img.decodeImage(bytes);
    if (image == null) return bytes;

    // Mirror to match the front-camera selfie (preview shows true orientation;
    // the saved photo is flipped so it reads the way the user expects).
    if (req.mirror) {
      mirrorInPlace(image);
    }

    // Only downscale if larger than the cap (never upscale — keep native res).
    if (image.width > BakeRequest.maxWidth) {
      // Explicitly averaged. copyResize defaults to Interpolation.nearest,
      // which throws away every third column with no filtering — visible
      // aliasing on hair, fabric and text, under a comment promising quality.
      image = img.copyResize(
        image,
        width: BakeRequest.maxWidth,
        interpolation: img.Interpolation.average,
      );
    }

    if (!isNone) {
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
  } catch (_) {
    return bytes; // never drop a capture — ship the raw photo on failure
  }
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
