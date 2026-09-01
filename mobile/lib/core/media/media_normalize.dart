import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:miles/core/media/thumbnails.dart' show Thumbnails;
import 'package:path_provider/path_provider.dart';

/// Turns whatever the gallery handed back into something this app can actually
/// store, render and thumbnail.
///
/// An iPhone photo copied onto an Android handset is HEIC, and a ProRAW capture
/// is DNG. Both failed three separate ways and the user just saw "unable to
/// send":
///
///  1. `couple_media` whitelists image/jpeg, png, webp and gif, so Storage
///     refused the upload outright.
///  2. [Thumbnails.forImage] decodes with the Dart `image` package, which
///     supports none of those formats — so even past Storage the tile would
///     have had nothing to paint.
///  3. Flutter's own decoders are libjpeg/libpng/libwebp. A HEIC that reached
///     the device would not render in a bubble either.
///
/// Dart cannot decode these at all, so the conversion has to go through the
/// platform: FlutterImageCompress hands the bytes to Android's own decoder
/// (HEIF from API 28, DNG where the device's codec supports it) and returns
/// JPEG.
///
/// Formats the app already handles are returned untouched. That matters — this
/// is not a blanket re-encode. A PNG keeps its alpha, a GIF keeps its
/// animation, and a JPEG the sender chose is not quietly re-compressed a second
/// time. Only what would otherwise fail is converted.
class MediaNormalize {
  MediaNormalize._();

  /// What Storage accepts, the Dart decoder can read, and Flutter can paint.
  static const _passThrough = {'jpg', 'jpeg', 'png', 'webp', 'gif'};

  /// Long edge cap for a converted file.
  ///
  /// Only applied to images being converted anyway, never to a pass-through.
  /// A 48MP ProRAW is ~60MB and would breach the bucket's 25MB limit before
  /// anything else got a chance to reject it; at 2048 it is a photograph, not
  /// a negative, and it is a couple of megabytes.
  static const _maxEdge = 2048;

  static const _quality = 88;

  static String extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  /// True when [path] is a format the rest of the pipeline can already handle.
  static bool isSupported(String path) =>
      _passThrough.contains(extensionOf(path));

  /// [file] itself when it needs nothing, a JPEG copy when it does, or null
  /// when the platform could not decode it either.
  ///
  /// Null is the honest outcome for a format this device has no codec for —
  /// some RAW variants on some handsets. The caller reports that by name rather
  /// than letting the upload fail later with nothing to say.
  static Future<File?> toSendable(File file) async {
    if (isSupported(file.path)) return file;
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final target = '${dir.path}/conv_$stamp.jpg';
      final out = await FlutterImageCompress.compressAndGetFile(
        file.absolute.path,
        target,
        quality: _quality,
        minWidth: _maxEdge,
        minHeight: _maxEdge,
      );
      if (out == null) return null;
      return File(out.path);
    } catch (e) {
      debugPrint('[normalize] ${extensionOf(file.path)} failed: ${e.runtimeType}');
      return null;
    }
  }
}
