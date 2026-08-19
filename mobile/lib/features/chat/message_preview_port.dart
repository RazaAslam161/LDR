import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Message;
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/features/chat/chat_receipts.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// Puts the actual message text into the notification, by asking the RUNNING
/// app to do it.
///
/// The push deliberately carries no body — it holds `id, couple_id, sender_id,
/// seq` and nothing else, because the body is ciphertext and has no business
/// leaving the database for a payload that exists to transmit a sequence
/// number. So the text has to be decrypted on the device.
///
/// The background isolate cannot do that. It is a fresh Dart isolate: every
/// static is empty, `CryptoCore._sharedKey` is null, and deriving the couple
/// key there means reading the seed from the keystore AND fetching the
/// partner's public key over REST before a single character can be shown. That
/// is real work and it is not done yet — see the fallback below.
///
/// The UI isolate, when it exists, already has all of it: the key is derived,
/// the Supabase client is up, and [ChatRepository.fetchSince] returns messages
/// already decrypted. So the background handler hands the couple id across and
/// the live app rewrites its own notification in place.
///
/// Modelled on [DeliveryAckPort], which solves the same problem for receipts
/// and proves the handoff works.
class MessagePreviewPort {
  MessagePreviewPort._();

  static const name = 'miles.msg_preview';

  static ReceivePort? _port;

  /// UI isolate only. Idempotent.
  static void listen() {
    if (_port != null) return;
    final port = ReceivePort();
    // A hot restart leaves the previous engine's mapping behind, and
    // registerPortWithName refuses to replace one.
    IsolateNameServer.removePortNameMapping(name);
    if (!IsolateNameServer.registerPortWithName(port.sendPort, name)) {
      port.close();
      debugPrint('[preview] message preview port already registered');
      return;
    }
    _port = port;
    port.listen((Object? msg) {
      if (msg is! String || msg.isEmpty) return;
      unawaited(_enrich(msg));
    });
  }

  /// The running app's port, or null when this process has no UI isolate —
  /// a push that started the process from cold, which is exactly the case that
  /// cannot show content yet.
  static SendPort? get liveApp => IsolateNameServer.lookupPortByName(name);

  /// Replace the count-only notification with one carrying the real text.
  ///
  /// Same notification id as [showMessageNotification], so this REWRITES the
  /// entry rather than adding a second one — the duplicate-notification defect
  /// is the whole reason that id keys on the couple.
  static Future<void> _enrich(String coupleId) async {
    try {
      // The app lock exists to keep content off a glanced-at phone, and the
      // notification shade shows through it. Enriching would put the decrypted
      // body exactly where the lock cannot cover — the count-only entry stays.
      if (await AppLock.isEnabled()) return;

      final since = await DeliveredMark.acked(coupleId);
      // Own sends land in fetchSince too — without the filter, replying from a
      // second device would preview the user's OWN message back at them and
      // count it as unread.
      final uid = SupabaseService.currentUserId;
      final fresh = (await ChatRepository.fetchSince(coupleId, since))
          .where((m) => m.senderId != uid)
          .toList();
      if (fresh.isEmpty) return;

      // Newest wins; the body carries the count when there is more than one, so
      // nothing is lost by showing only the latest text.
      final latest = fresh.last;
      final text = _preview(latest);
      if (text == null) return;

      await showMessageNotification(
        plugin: FlutterLocalNotificationsPlugin(),
        messageId: latest.id,
        coupleId: coupleId,
        unreadCount: fresh.length,
        previewBody: fresh.length > 1 ? '$text  (+${fresh.length - 1})' : text,
      );
    } catch (e, st) {
      // The count-only notification is already on screen, so this failing costs
      // detail rather than the alert itself. Reported rather than swallowed:
      // silence here would make a broken decrypt look like a quiet partner.
      ErrorReporter.report(e, st, kind: 'notify');
    }
  }

  /// What a message reads as in one line. Media says what it is rather than
  /// leaking a file name.
  static String? _preview(Message m) {
    final body = m.body?.trim();
    if (body != null && body.isNotEmpty) return body;
    if (m.voiceDurationMs != null) return 'Voice message';
    if (m.imageUrl != null) return 'Photo';
    if (m.videoPath != null) return 'Video';
    return null;
  }
}
