import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:miles/core/data/secure_storage_options.dart';

/// Text the user has typed and not sent, kept per couple.
///
/// A draft has to outlive the input bar, because the input bar barely lives at
/// all: AppShell swaps `bodies[bodyIndex]` inside a plain Column, so changing
/// tab unmounts ChatScreen, and MilesApp.raiseCover() replaces the whole router
/// subtree with the disguise cover on every background. Both dispose the State
/// that owns the TextEditingController, and the message went with it.
///
/// Encrypted at rest rather than plain SharedPreferences. A draft IS a message
/// body, and ChatSendQueue refuses to put bodies in prefs (see its enqueueText
/// doc) for exactly the reason that applies here — prefs are the one place the
/// app's disguise cannot cover.
class ChatDraftStore {
  ChatDraftStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: kMilesKeychain,
  );

  static const _prefix = 'miles_chat_draft_';

  /// Mirrors what is on disk, so a remount inside a live process restores on
  /// the first frame instead of a beat later. That is the ordinary case: a tab
  /// change and the cover both dispose the bar without ending the process. The
  /// disk copy is only actually read after a process death.
  static final Map<String, String> _cache = {};

  static String _key(String coupleId) => '$_prefix$coupleId';

  /// The draft this process already knows, without waiting for the disk.
  static String? peek(String coupleId) => _cache[coupleId];

  /// The draft left behind by a previous process. Null when there is none.
  static Future<String?> load(String coupleId) async {
    final cached = _cache[coupleId];
    if (cached != null) return cached;
    try {
      final stored = await _storage.read(key: _key(coupleId));
      if (stored == null || stored.isEmpty) return null;
      _cache[coupleId] = stored;
      return stored;
    } catch (e) {
      debugPrint('[draft] read failed for $coupleId: $e');
      return null;
    }
  }

  static Future<void> save(String coupleId, String body) async {
    if (body.isEmpty) return clear(coupleId);
    _cache[coupleId] = body;
    try {
      await _storage.write(key: _key(coupleId), value: body);
    } catch (e) {
      debugPrint('[draft] write failed for $coupleId: $e');
    }
  }

  static Future<void> clear(String coupleId) async {
    _cache.remove(coupleId);
    try {
      await _storage.delete(key: _key(coupleId));
    } catch (e) {
      debugPrint('[draft] delete failed for $coupleId: $e');
    }
  }

  /// Drop every draft on this handset — the counterpart of
  /// `ChatSendQueue.clear`, for sign-out. Drafts are keyed by couple, so a
  /// second account on the same phone must not inherit the first one's.
  ///
  /// Filtered by prefix, never `deleteAll()`: this storage is shared with
  /// CryptoCore, whose X25519 private key lives in it and can never be
  /// regenerated. Wiping it would take every past message with it.
  static Future<void> clearAll() async {
    _cache.clear();
    try {
      final all = await _storage.readAll();
      for (final key in all.keys.where((k) => k.startsWith(_prefix))) {
        await _storage.delete(key: key);
      }
    } catch (e) {
      debugPrint('[draft] clearAll failed: $e');
    }
  }
}
