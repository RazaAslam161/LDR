import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:video_thumbnail/video_thumbnail.dart';

/// The small sibling object a grid tile paints from.
///
/// Chat sent what the user picked and nothing else — deliberately, because
/// re-encoding a photo to send it loses quality the sender chose to keep. The
/// cost of that is paid on the READ side, by everyone, forever: a bubble the
/// size of a thumbnail was downloading a 6–12 MB original, and a pick of twenty
/// was ~150 MB on the wire before the first tile could paint.
///
/// So the original still uploads untouched. This adds a second, tiny object
/// beside it, and the grid and the chat bubble read that instead. The viewer —
/// the one place the pixels are actually wanted — still opens the original.
class Thumbnails {
  Thumbnails._();

  /// Longest edge, in pixels.
  ///
  /// The two consumers are a 2×2 album tile (~150dp) and the profile grid's
  /// 3-column tile (~120dp). At 3× that is 450px and 360px, so this covers the
  /// larger of them without paying for the pager's full-screen case, which
  /// loads the original anyway.
  static const _maxEdge = 400;

  /// Enough that a face is a face on a 2×2 tile; low enough that the object is
  /// tens of kilobytes rather than hundreds.
  static const _quality = 72;

  /// Where the thumbnail for [originalPath] lives.
  ///
  /// A `thumb/` segment inserted before the object name, so
  /// `<couple>/img_x.jpg` becomes `<couple>/thumb/img_x.jpg`. The couple id
  /// stays the FIRST segment, which is what every storage policy tests
  /// ((storage.foldername(name))[1] = couple_id) — so this needs no new policy
  /// and cannot land outside the couple's own folder.
  static String pathFor(String originalPath) {
    final cut = originalPath.lastIndexOf('/');
    if (cut < 0) return 'thumb/$originalPath';
    return '${originalPath.substring(0, cut)}/thumb/${originalPath.substring(cut + 1)}';
  }

  /// A JPEG thumbnail of an image file, or null if it could not be made.
  ///
  /// Null is a normal outcome, not an error to surface: the send proceeds with
  /// has_thumb false and the tile falls back to the original, which is exactly
  /// how every row written before this pipeline renders.
  static Future<Uint8List?> forImage(File file) async {
    try {
      final bytes = await file.readAsBytes();
      // Decoding a 12-megapixel JPEG is ~100ms of pure CPU. On the platform
      // thread that is dropped frames on the chat list while the queue works
      // through a fifty-photo pick, so it goes to an isolate.
      return compute(_resizeJpeg, (bytes: bytes, maxEdge: _maxEdge, quality: _quality));
    } catch (e) {
      debugPrint('[thumb] image failed: ${e.runtimeType}');
      return null;
    }
  }

  /// A JPEG poster frame for a video, or null.
  ///
  /// Decoded natively, which is already off the UI thread — no isolate here.
  static Future<Uint8List?> forVideo(File file) async {
    try {
      return await VideoThumbnail.thumbnailData(
        video: file.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: _maxEdge,
        quality: _quality,
      );
    } catch (e) {
      debugPrint('[thumb] video failed: ${e.runtimeType}');
      return null;
    }
  }
}

/// Longest edge of the timeline cover, in pixels.
///
/// The tile's 400px under a full-bleed 16:10 cover is a 2.16x upscale on the
/// first thing anyone sees. Raising the single shared object to 1024 instead
/// would have made every grid tile decode a 1024px frame, so the cover is its
/// own object with its own bound and the tile keeps being its own bound.
const int kMemoryCoverMaxEdge = 1024;

/// Longest edge of the shared tile — the gallery grid, the pager underlay and
/// (conditionally) the filmstrip all paint this one object.
const int kMemoryTileMaxEdge = 400;

/// Two derivatives and the capture date, from ONE decode.
class DerivedImage {
  const DerivedImage({
    required this.cover,
    required this.tile,
    this.capturedAt,
  });

  /// 1024px longest edge, q75. What the timeline paints.
  final Uint8List cover;

  /// 400px longest edge, q72. Shared by every small surface.
  final Uint8List tile;

  /// EXIF DateTimeOriginal, when the file carried one.
  final DateTime? capturedAt;
}

/// Decode once, emit both derivatives and the capture date.
///
/// Three separate calls would be three 12-megapixel decodes at roughly 100 ms
/// each on the target handsets. The EXIF date is free here because the header
/// has already been parsed — and it is what stops a person who uploads twelve
/// Lisbon photographs in August from filing them all under August, which is
/// wrong on the timeline, wrong for "on this day" forever, and the reason visit
/// matching would otherwise never fire.
Future<DerivedImage?> deriveImage(Uint8List bytes) async {
  try {
    return await compute(_derive, bytes);
  } catch (e) {
    debugPrint('[thumb] derive failed: ${e.runtimeType}');
    return null;
  }
}

DerivedImage? _derive(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final upright = img.bakeOrientation(decoded);
  return DerivedImage(
    cover: img.encodeJpg(_fit(upright, kMemoryCoverMaxEdge), quality: 75),
    tile: img.encodeJpg(_fit(upright, kMemoryTileMaxEdge), quality: 72),
    capturedAt: _exifDate(decoded),
  );
}

/// Never upscales: a picture already smaller than the bound gains nothing but
/// bytes from being blown up to it.
img.Image _fit(img.Image src, int maxEdge) {
  final longest = src.width > src.height ? src.width : src.height;
  if (longest <= maxEdge) return src;
  return img.copyResize(
    src,
    width: src.width >= src.height ? maxEdge : null,
    height: src.height > src.width ? maxEdge : null,
    interpolation: img.Interpolation.average,
  );
}

/// EXIF DateTimeOriginal, or null.
///
/// Read from the ORIGINAL decode, before bakeOrientation — that rewrites the
/// orientation tag and there is no reason to trust what else it normalises.
/// The tag's format is 'YYYY:MM:DD HH:MM:SS', which [DateTime.parse] will not
/// take, so the two date separators are rewritten.
///
/// Treat a null as the common case rather than the exception: several Android
/// gallery providers hand out a stripped copy, and this is unverified on the
/// target handsets.
DateTime? _exifDate(img.Image image) {
  for (final tag in const ['DateTimeOriginal', 'DateTimeDigitized', 'DateTime']) {
    final raw = image.exif.imageIfd[tag]?.toString() ??
        image.exif.exifIfd[tag]?.toString();
    if (raw == null || raw.length < 19) continue;
    final normalised =
        '${raw.substring(0, 4)}-${raw.substring(5, 7)}-${raw.substring(8, 10)}'
        'T${raw.substring(11, 19)}';
    final parsed = DateTime.tryParse(normalised);
    if (parsed != null) return parsed;
  }
  return null;
}

/// Runs in an isolate. Top-level because [compute] cannot send a closure.
Uint8List? _resizeJpeg(({Uint8List bytes, int maxEdge, int quality}) job) {
  final decoded = img.decodeImage(job.bytes);
  if (decoded == null) return null;

  // Phone cameras write the sensor's orientation into EXIF rather than
  // rotating the pixels. decodeImage hands back those unrotated pixels, so
  // without this every photo taken in portrait becomes a sideways thumbnail
  // above a correctly-oriented full image — the tile and the thing it opens
  // would disagree.
  final upright = img.bakeOrientation(decoded);

  final longest = upright.width > upright.height ? upright.width : upright.height;
  // Never upscale: a picture already smaller than a tile gains nothing but
  // bytes from being blown up to 400px.
  final scaled = longest <= job.maxEdge
      ? upright
      : img.copyResize(
          upright,
          width: upright.width >= upright.height ? job.maxEdge : null,
          height: upright.height > upright.width ? job.maxEdge : null,
          interpolation: img.Interpolation.average,
        );

  return img.encodeJpg(scaled, quality: job.quality);
}
