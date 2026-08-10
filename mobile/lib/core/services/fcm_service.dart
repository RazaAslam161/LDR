import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/services/fsi_permission.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';

/// A Reach that should surface the in-app overlay (from a foreground push or a
/// tapped notification). The AppShell listens to [pendingReach] and shows the
/// overlay, de-duping by [reachId] against its realtime listener.
class ReachTap {
  const ReachTap(this.reachId, this.fromName);
  final String reachId;
  final String fromName;
}

final ValueNotifier<ReachTap?> pendingReach = ValueNotifier<ReachTap?>(null);

/// An incoming call to ring — from a foreground push, a tapped full-screen
/// notification, or a cold start. The AppShell hands this to the CallController.
class CallTap {
  const CallTap(this.callId, this.fromName, this.video);
  final String callId;
  final String fromName;
  final bool video;
}

final ValueNotifier<CallTap?> pendingCall = ValueNotifier<CallTap?>(null);

/// Wires Firebase Messaging: permission, token lifecycle, the local-notification
/// channel, and the foreground / tapped-notification handlers.
///
/// Token storage goes through [SupabaseRepository] (never the widget layer).
class FcmService {
  FcmService._();

  static final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();

  /// Call once in main() after Firebase.initializeApp. Sets up channels +
  /// handlers. Token registration is separate (registerToken, after login).
  static Future<void> init() async {
    await _fln.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onLocalTap,
    );
    final android = _fln.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(buildReachChannel());
    await android?.createNotificationChannel(buildCareChannel());
    await android?.createNotificationChannel(buildCallChannel());

    // Cold start via a tapped Reach notification.
    final launch = await _fln.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      _routeFromPayload(launch!.notificationResponse?.payload);
    }

    FirebaseMessaging.onMessage.listen(_onForeground);
    FirebaseMessaging.onMessageOpenedApp.listen(_onOpenedApp);
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _onOpenedApp(initial);

    // Mirror the FSI permission so the background isolate can read it.
    await FsiPermission.refreshCache();
  }

  /// Android 13+/iOS notification permission prompt.
  static Future<void> requestPermission() async {
    await FirebaseMessaging.instance.requestPermission();
  }

  static bool _refreshHooked = false;

  /// After login + pairing AND on every app resume: ask permission, fetch the
  /// token (retrying if Google Play Services isn't ready yet), and re-save it.
  ///
  /// Re-saving on each foreground is the important part: the notify functions
  /// null a recipient's token server-side when FCM reports it UNREGISTERED (a
  /// stale token after a reinstall/GMS hiccup), which silently stops their
  /// pushes. Re-registering on the next launch/resume self-heals that.
  static Future<void> registerToken() async {
    await requestPermission();
    String? token;
    for (var i = 0; i < 4 && token == null; i++) {
      try {
        token = await FirebaseMessaging.instance.getToken();
      } catch (e) {
        debugPrint('FcmService getToken attempt ${i + 1} failed: $e');
      }
      if (token == null) await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (token != null) await _save(token);
    if (!_refreshHooked) {
      _refreshHooked = true;
      FirebaseMessaging.instance.onTokenRefresh.listen(_save);
    }
  }

  static Future<void> _save(String token) async {
    try {
      await SupabaseRepository.setFcmToken(token);
    } catch (e) {
      debugPrint('FcmService._save failed: $e');
    }
  }

  /// On sign-out: drop the token so this device stops getting Reach pushes.
  static Future<void> clearToken() async {
    try {
      await SupabaseRepository.setFcmToken(null);
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('FcmService.clearToken failed: $e');
    }
  }

  // ── handlers ───────────────────────────────────────────────────────────────
  static void _onForeground(RemoteMessage m) {
    final type = m.data['type'];
    if (type == 'call') {
      pendingCall.value = CallTap(
        (m.data['call_id'] as String?) ?? '',
        (m.data['from_name'] as String?) ?? 'Your partner',
        (m.data['video'] as String?) == 'true',
      );
      return;
    }
    if (type == 'care') {
      // Foreground reminder: post the (blank, secret) notification directly.
      showCareNotification(
        plugin: _fln,
        nudgeId: (m.data['nudge_id'] as String?) ?? '',
      );
      return;
    }
    if (type == 'message') {
      // This device HAD the message. Nothing below acks it, and ackDelivered
      // has one call site — the chat screen's catch-up — so a push landing
      // with chat_mounted=false and no receipt_ack_attempt after it is the
      // proof that the message arrived with no ack path at all.
      Diag.record(DiagArea.receipt, 'push_msg_received',
          corr: m.data['message_id'] as String?,
          fields: {
            'app_state': 'foreground',
            // The chat registers its live broadcast channel while mounted, so
            // this is the same fact the fast path depends on.
            'chat_mounted': ChatBroadcastService.active != null,
            'has_message_id': m.data['message_id'] != null,
          },);
      // In the foreground the chat's realtime subscription already delivers
      // the message, and the catch-up fetch covers a dropped socket — so a
      // notification here would double up on a conversation the user is
      // looking at. The push exists for the backgrounded case, handled in the
      // background isolate.
      return;
    }
    if (type != 'reach') return;
    // Foreground: surface the in-app overlay. AppShell de-dupes by reach_id so
    // this and the Supabase realtime listener never double-show.
    pendingReach.value = ReachTap(
      (m.data['reach_id'] as String?) ?? '',
      (m.data['from_name'] as String?) ?? 'Your partner',
    );
  }

  static void _onOpenedApp(RemoteMessage m) {
    final type = m.data['type'];
    if (type == 'call') {
      pendingCall.value = CallTap(
        (m.data['call_id'] as String?) ?? '',
        (m.data['from_name'] as String?) ?? 'Your partner',
        (m.data['video'] as String?) == 'true',
      );
      return;
    }
    if (type != 'reach') return;
    pendingReach.value = ReachTap(
      (m.data['reach_id'] as String?) ?? '',
      (m.data['from_name'] as String?) ?? 'Your partner',
    );
  }

  static void _onLocalTap(NotificationResponse r) =>
      _routeFromPayload(r.payload);

  static void _routeFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    final parts = payload.split('|');
    final tag = parts.isNotEmpty ? parts[0] : '';
    if (tag == 'call') {
      // call|callId|fromName|video
      pendingCall.value = CallTap(
        parts.length > 1 ? parts[1] : '',
        parts.length > 2 ? parts[2] : 'Your partner',
        !(parts.length > 3) || parts[3] == '1',
      );
      return;
    }
    if (tag == 'care') return; // care taps just open the app
    pendingReach.value = ReachTap(
      tag,
      parts.length > 1 ? parts[1] : 'Your partner',
    );
  }
}
