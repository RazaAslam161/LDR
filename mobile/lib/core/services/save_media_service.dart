import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:http/http.dart' as http;
import 'package:miles/features/vault/vault_repository.dart';

/// Saves received/sent chat + touch media into the Private Vault — and ONLY the
/// vault. Zero bytes touch device storage: no gallery entry, no Downloads file,
/// no temp file. We store a reference (public URL, or `intimate:<path>` for the
/// private bucket) in the PIN-protected vault; the bytes stay in Supabase.
class SaveMediaService {
  SaveMediaService._();

  /// couple_media (public) photo — e.g. a chat image. URL never expires.
  static Future<bool> savePhotoToVault({
    required String url,
    required String senderName,
  }) =>
      _save(type: 'saved_photo', noun: 'Photo', senderName: senderName, publicUrl: url);

  /// couple_media (public) voice note.
  static Future<bool> saveVoiceToVault({
    required String url,
    required String senderName,
  }) =>
      _save(type: 'saved_voice', noun: 'Voice note', senderName: senderName, publicUrl: url);

  /// couple_intimate (private) video — store the path, re-sign on open.
  static Future<bool> saveVideoToVault({
    required String path,
    required String senderName,
  }) =>
      _save(type: 'saved_video', noun: 'Video', senderName: senderName, storagePath: path);

  /// couple_intimate (private) photo — e.g. a Touch body photo. Path stored.
  static Future<bool> saveIntimatePhotoToVault({
    required String path,
    required String senderName,
  }) =>
      _save(type: 'saved_photo', noun: 'Photo', senderName: senderName, storagePath: path);

  static Future<bool> _save({
    required String type,
    required String noun,
    required String senderName,
    String? publicUrl,
    String? storagePath,
  }) async {
    final label = '$noun from $senderName · ${_formatDate(DateTime.now())}';
    try {
      // Fetch the bytes and let the vault keep its OWN encrypted copy.
      //
      // Storing a pointer was the whole defect: a publicUrl is a signed link
      // that expires within a day, and a storagePath lives in the couple's
      // shared bucket where the partner can read it and delete it. Neither is
      // a private vault. Saving is worth one download.
      final url = publicUrl ??
          (storagePath == null
              ? null
              : await ChatRepository.signedVideoUrl(storagePath));
      if (url != null) {
        final res = await http.get(Uri.parse(url));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          await VaultRepository.saveMedia(
            bytes: res.bodyBytes,
            mimeType: res.headers['content-type']?.split(';').first ??
                _mimeForType(type),
            label: label,
            type: type,
          );
          return true;
        }
      }

      // The source is already gone. Recording a bookmark to it would create
      // exactly the dead row this change exists to stop making.
      ErrorReporter.report(
        StateError('vault save: source unreachable ($type)'),
        StackTrace.current,
        kind: 'vault',
      );
      return false;
    } catch (e, st) {
      ErrorReporter.report(e, st, kind: 'vault');
      return false;
    }
  }

  static String _mimeForType(String type) => switch (type) {
        'saved_video' => 'video/mp4',
        'saved_voice' => 'audio/mp4',
        _ => 'image/jpeg',
      };

  static String _formatDate(DateTime dt) =>
      '${dt.day} ${_month(dt.month)} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';

  static String _month(int m) => const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ][m - 1];
}
