import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:miles/core/data/secure_storage_options.dart';
import 'package:miles/core/diag/diag.dart';

/// Message bodies the user has sent that the server has not accepted yet.
///
/// [ChatSendQueue] persists media sends in SharedPreferences — a path, a kind,
/// two ids, nothing the disguise has to hide. A BODY is different, and that is
/// why text sends were deliberately left in memory only: a process death during
/// the send took the message with it, and that was judged the smaller harm.
///
/// It is not the smaller harm. Android kills this app while it is backgrounded,
/// and backgrounding is when the cover goes up — so the kill is the ordinary
/// case here, not a rare one. A message typed and sent as the phone went into a
/// pocket was gone: no row, no bubble, no copy anywhere, and nothing said.
///
/// So the body is kept, in the store the DRAFT of that same message already
/// uses: encrypted at rest, prefix-filtered, never SharedPreferences. A draft
/// and an unsent send are the same text one keystroke apart.
class ChatTextOutbox {
  ChatTextOutbox._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: kMilesKeychain,
  );

  /// One key per send, not one key holding the list. A list would be
  /// read-modify-written on every landing, and two sends resolving at once then
  /// resurrect each other.
  static const _prefix = 'miles_chat_outbox_';

  static Future<void> put(String id, Map<String, Object?> row) async {
    try {
      await _storage.write(key: '$_prefix$id', value: jsonEncode(row));
    } catch (e) {
      debugPrint('[outbox] write failed for $id: ${e.runtimeType}');
    }
  }

  static Future<void> remove(String id) async {
    try {
      await _storage.delete(key: '$_prefix$id');
    } catch (e) {
      debugPrint('[outbox] delete failed for $id: ${e.runtimeType}');
    }
  }

  /// Everything a previous process left unsent, for [uid] alone — or null when
  /// the store could not be read.
  ///
  /// Null rather than an empty list, and the difference is the whole point: an
  /// empty outbox and a keystore that threw once are the same answer otherwise,
  /// and the caller latches on a successful restore. One transient read failure
  /// then meant the bodies were never restored again for the life of the
  /// process — and a sign-out later in that same session deletes them.
  ///
  ///
  /// Scoped by user id for the reason ChatReactionOutbox is: two accounts share
  /// one handset, and a queue keyed only by device would hand the second
  /// account the first's unsent messages. A foreign row is SKIPPED, never
  /// deleted — it is that person's message, and it is still theirs when they
  /// sign back in.
  static Future<List<Map<String, dynamic>>?> restore(String uid) async {
    final Map<String, String> all;
    try {
      all = await _storage.readAll();
    } catch (e) {
      debugPrint('[outbox] restore failed: ${e.runtimeType}');
      ErrorReporter.report(e, StackTrace.current, kind: 'chat-outbox-read');
      return null;
    }
    final out = <Map<String, dynamic>>[];
    for (final e in all.entries.where((e) => e.key.startsWith(_prefix))) {
      // Per row, so one unparseable entry does not discard every other body
      // in the store.
      try {
        final j = jsonDecode(e.value);
        if (j is! Map<String, dynamic> || j['u'] != uid) continue;
        out.add(j);
      } catch (_) {
        debugPrint('[outbox] unreadable row ${e.key}');
      }
    }
    return out;
  }

  /// Drop every body on this handset.
  ///
  /// Called when the COUPLE ends, however it ended — which is why this is not
  /// the reaction outbox's "keep the disk copy" rule. A message typed during
  /// the argument and left unsent must not be resurrected and delivered to a
  /// couple the user has walked away from; that is the exact leak
  /// `SessionNotifier.endCouple` exists to close.
  ///
  /// Filtered by prefix, never `deleteAll()`: this storage also holds
  /// CryptoCore's X25519 private key, which can never be regenerated. Wiping it
  /// would take every past message with it.
  static Future<void> clearAll() async {
    try {
      final all = await _storage.readAll();
      for (final key in all.keys.where((k) => k.startsWith(_prefix))) {
        await _storage.delete(key: key);
      }
    } catch (e) {
      debugPrint('[outbox] clearAll failed: ${e.runtimeType}');
    }
  }
}
