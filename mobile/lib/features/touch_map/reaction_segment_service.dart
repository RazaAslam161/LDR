import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'package:path_provider/path_provider.dart';

class ReactionSegmentService {
  static final SubjectSegmenter _segmenter = SubjectSegmenter(
    options: SubjectSegmenterOptions(
      enableForegroundBitmap: true,
      enableForegroundConfidenceMask: false,
      enableMultipleSubjects: SubjectResultOptions(
        enableConfidenceMask: false,
        enableSubjectBitmap: false,
      ),
    ),
  );

  /// The eight bytes every PNG file starts with. Checked before the result is
  /// trusted as one — see [removeBackground].
  static const _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  /// Remove the background from an image file.
  /// Returns a new PNG [File] with the person/hand kept and the
  /// background made transparent.
  /// Returns null if segmentation fails — caller falls back to the original
  /// file, which is why every failure path here returns null rather than
  /// throwing.
  ///
  /// `foregroundBitmap` IS the finished cut-out: ML Kit returns a bitmap the
  /// size of the input with the background already transparent, and the plugin
  /// hands it over PNG-ENCODED —
  /// `SubjectSegmenter.java:125` does
  /// `bitmap.compress(Bitmap.CompressFormat.PNG, 100, outputStream)`.
  /// So the only correct thing to do with those bytes is write them to a file.
  ///
  /// This method used to treat them as a flat per-pixel alpha mask
  /// (`mask[py * w + px]`) and composite them over the original by hand. A PNG
  /// byte stream's Nth byte has nothing to do with pixel N — the first eight
  /// are the signature above — so the alpha was noise. Worse, a compressed PNG
  /// is far shorter than `width * height`, so the bounds check fell through to
  /// `0` for most pixels, `0` mapped to alpha 0, and the reaction that got sent
  /// was very nearly a fully transparent image. Every Touch Map photo reaction
  /// shipped that way. Do not reintroduce a manual composite: there is nothing
  /// left to composite.
  static Future<File?> removeBackground(String inputPath) async {
    try {
      final inputImage = InputImage.fromFilePath(inputPath);
      final result = await _segmenter.processImage(inputImage);

      final foreground = result.foregroundBitmap;
      if (foreground == null) return null;

      // Guard the format rather than assume it. If the plugin ever returns raw
      // pixels instead of an encoded file, writing them under a .png name would
      // produce an image nothing can open — and the caller, seeing a File, would
      // upload it. A wrong-format result must look like failure, not success.
      if (foreground.length < _pngMagic.length ||
          !_pngMagic.asMap().entries.every((e) => foreground[e.key] == e.value)) {
        debugPrint('[segment] foregroundBitmap is not a PNG '
            '(${foreground.length} bytes) — falling back to the original');
        return null;
      }

      final dir = await getTemporaryDirectory();
      final outPath =
          '${dir.path}/segmented_${DateTime.now().millisecondsSinceEpoch}.png';
      final out = File(outPath);
      await out.writeAsBytes(foreground, flush: true);
      return out;
    } catch (e) {
      debugPrint('[segment] removeBackground failed: ${e.runtimeType}');
      return null;
    }
  }

  static void dispose() => _segmenter.close();
}
