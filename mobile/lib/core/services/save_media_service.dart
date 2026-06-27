import 'dart:io';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Centralised "save media to the device" logic, shared by chat + touch.
///
/// Photos/videos go to the system gallery via [Gal] (handles its own
/// permissions + MediaStore on Android 29+). Audio isn't a gallery type, so
/// voice notes are written to the app's external files directory instead.
class SaveMediaService {
  SaveMediaService._();

  /// Save a photo from a URL (public couple_media or a signed couple_intimate
  /// URL). Returns false on any failure (no throw).
  static Future<bool> savePhotoFromUrl(String url) async {
    try {
      if (!await _ensureGalleryAccess()) return false;
      final bytes = await _download(url, const Duration(seconds: 30));
      if (bytes == null) return false;
      final file = await _writeTemp(bytes, _extFromUrl(url) ?? 'jpg');
      await Gal.putImage(file.path);
      await _safeDelete(file);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Save a video from a URL (signed couple_intimate URL). Returns false on
  /// failure (e.g. an expired signed URL → 403).
  static Future<bool> saveVideoFromUrl(String url) async {
    try {
      if (!await _ensureGalleryAccess(toAlbum: false)) return false;
      final bytes = await _download(url, const Duration(seconds: 120));
      if (bytes == null) return false;
      final file = await _writeTemp(bytes, 'mp4');
      await Gal.putVideo(file.path);
      await _safeDelete(file);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Save an audio file (voice note) to the app's external files directory.
  /// gal does not handle audio (gallery = photos/videos only).
  static Future<bool> saveAudioFromUrl(String url) async {
    try {
      final bytes = await _download(url, const Duration(seconds: 60));
      if (bytes == null) return false;
      final dir =
          await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final file = File(
          '${dir.path}/tethered_voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
      await file.writeAsBytes(bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Save a photo already on disk (e.g. just-captured camera file).
  static Future<bool> savePhotoFromPath(String path) async {
    try {
      if (!await _ensureGalleryAccess()) return false;
      await Gal.putImage(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Save a video already on disk.
  static Future<bool> saveVideoFromPath(String path) async {
    try {
      if (!await _ensureGalleryAccess(toAlbum: false)) return false;
      await Gal.putVideo(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  static Future<bool> _ensureGalleryAccess({bool toAlbum = true}) async {
    if (await Gal.hasAccess(toAlbum: toAlbum)) return true;
    return Gal.requestAccess(toAlbum: toAlbum);
  }

  static Future<List<int>?> _download(String url, Duration timeout) async {
    final res = await http.get(Uri.parse(url)).timeout(timeout);
    if (res.statusCode != 200) return null;
    return res.bodyBytes;
  }

  static Future<File> _writeTemp(List<int> bytes, String ext) async {
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/tethered_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await file.writeAsBytes(bytes);
    return file;
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static String? _extFromUrl(String url) {
    try {
      final path = Uri.parse(url).path;
      final dot = path.lastIndexOf('.');
      if (dot != -1 && dot < path.length - 1) {
        return path.substring(dot + 1).toLowerCase();
      }
    } catch (_) {}
    return null;
  }
}
