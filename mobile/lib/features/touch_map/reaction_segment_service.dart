import 'dart:io';

import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'package:image/image.dart' as img;
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

  /// Remove the background from an image file.
  /// Returns a new PNG [File] with the person/hand kept and the
  /// background made transparent.
  /// Returns null if segmentation fails — caller should fall back to
  /// the original file.
  static Future<File?> removeBackground(String inputPath) async {
    try {
      final inputImage = InputImage.fromFilePath(inputPath);
      final result = await _segmenter.processImage(inputImage);

      final mask = result.foregroundBitmap;
      if (mask == null) return null;

      final originalBytes = await File(inputPath).readAsBytes();
      final original = img.decodeImage(originalBytes);
      if (original == null) return null;

      final w = original.width;
      final h = original.height;

      final output = img.Image(width: w, height: h, numChannels: 4);

      for (var py = 0; py < h; py++) {
        for (var px = 0; px < w; px++) {
          final maskIndex = py * w + px;
          final maskValue = maskIndex < mask.length ? mask[maskIndex] : 0;

          final pixel = original.getPixel(px, py);

          // Soft edge: values between 50–200 use partial transparency.
          final alpha = maskValue < 50
              ? 0
              : maskValue > 200
                  ? 255
                  : ((maskValue - 50) * 255 / 150).round();

          output.setPixelRgba(
            px,
            py,
            pixel.r.toInt(),
            pixel.g.toInt(),
            pixel.b.toInt(),
            alpha,
          );
        }
      }

      final dir = await getTemporaryDirectory();
      final outPath =
          '${dir.path}/segmented_${DateTime.now().millisecondsSinceEpoch}.png';
      final pngBytes = img.encodePng(output);
      return File(outPath)..writeAsBytesSync(pngBytes);
    } catch (_) {
      return null;
    }
  }

  static void dispose() => _segmenter.close();
}
