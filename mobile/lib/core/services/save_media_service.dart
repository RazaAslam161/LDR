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
    try {
      final label = '$noun from $senderName · ${_formatDate(DateTime.now())}';
      await VaultRepository.saveMediaToVault(
        type: type,
        label: label,
        publicUrl: publicUrl,
        storagePath: storagePath,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _formatDate(DateTime dt) =>
      '${dt.day} ${_month(dt.month)} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';

  static String _month(int m) => const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ][m - 1];
}
