import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/services/document_picker_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// How full this account's storage is, and what to say when an upload is
/// refused because of it.
///
/// A quota refusal reaches the client as `StorageException(statusCode: '403')`
/// with the generic "new row violates row-level security policy" — byte for
/// byte the same as any other RLS refusal, so the exception alone cannot be
/// worded honestly. The only discriminator is the counter itself, which is why
/// [explain] asks the server before it says anything: at quota it names the
/// cause, and otherwise it hands back the copy the caller already had.
///
/// Everything up to now said "check your connection", which sent someone to
/// their router over a full account.
class StorageQuota {
  const StorageQuota._();

  /// Bytes stored and the ceiling, or null when the account could not be
  /// asked — a number that might be wrong is worse than no number here.
  static Future<({int bytes, int quota})?> read() =>
      SupabaseRepository.storageUsage();

  /// [fallback] unless [e] is a refusal this account's storage explains.
  ///
  /// 413 is the other permanent one and needs no round trip: the file is
  /// bigger than the bucket accepts and every retry ends identically.
  static Future<String> explain(Object e, {required String fallback}) async {
    if (e is! StorageException) return fallback;
    if (e.statusCode == '413') {
      return 'That file is too large to store.';
    }
    if (e.statusCode != '403') return fallback;
    final usage = await read();
    if (usage == null || usage.bytes < usage.quota) return fallback;
    return 'Your storage is full — ${size(usage.bytes)} of '
        '${size(usage.quota)}. Delete something to make room.';
  }

  /// The app's own size formatter, so a row reads in MB while an account is
  /// small. Rendering everything in GB against a 5 GB ceiling printed "0.1 GB"
  /// for every real account here and told the owner nothing.
  static String size(int bytes) => DocumentPickerService.formatBytes(bytes);
}
