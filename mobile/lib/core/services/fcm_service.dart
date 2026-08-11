import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/services/fsi_permission.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/core/services/session_scope.dart';
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

/// A tapped message notification: the AppShell selects the Chat tab. Holds the
/// message id only so a trace can tie the tap back to the push that caused it.
final ValueNotifier<String?> pendingChat = ValueNotifier<String?>(null);

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
    // Before any routing below: a cold start from a tapped notification runs
    // long before the session resolves, and the couple guard has to know which
    // account this handset was last signed in as or it would discard the very
    // tap that launched the app.
    await SessionScope.hydrate();
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

    // Cold start via a tapped notification of any kind.
    final launch = await _fln.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      routeFromPayload(launch!.notificationResponse?.payload);
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

  /// On sign-out: unbind this handset from the account leaving it.
  ///
  /// All three parts matter. The server row must stop naming this token, or
  /// reach-notify keeps pushing that couple's private signals here. The FCM
  /// token itself is deleted so the next account gets a fresh one rather than
  /// inheriting the last one. And the pending notifiers are globals that
  /// outlive a session — a Reach that arrived while the cover was up sits in
  /// [pendingReach] until a shell mounts to drain it, which after a sign-in as
  /// someone else means the next account's shell pops the previous account's
  /// overlay.
  ///
  /// Must run while still authenticated: setFcmToken writes as the current
  /// user, so calling this after signOut() silently does nothing.
  static Future<void> forgetDevice() async {
    pendingReach.value = null;
    pendingCall.value = null;
    pendingChat.value = null;
    await SessionScope.setCouple(null);
    try {
      await SupabaseRepository.setFcmToken(null);
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('FcmService.forgetDevice failed: $e');
    }
  }

  // ── handlers ───────────────────────────────────────────────────────────────
  static void _onForeground(RemoteMessage m) {
    if (!_forThisSession(m)) return;
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
        coupleId: (m.data['couple_id'] as String?) ?? '',
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
    if (!_forThisSession(m)) return;
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

  /// Whether a push belongs to the couple signed in on this handset.
  ///
  /// The token is the device's, not the account's, so FCM will happily deliver
  /// a couple's Reach to a phone that has since been signed into a different
  /// account — which is how one couple's private signal surfaced inside
  /// another's session. Nothing else in the delivery path checks this.
  static bool _forThisSession(RemoteMessage m) => SessionScope.allows(
        m.data['couple_id'] as String?,
        SessionScope.coupleId,
      );

  static void _onLocalTap(NotificationResponse r) => routeFromPayload(r.payload);

  /// Routes a tapped local notification by the payload its poster wrote in
  /// reach_notifications.dart. Both halves live on the same device, so this is
  /// the only place they have to agree — and the only place a test can reach.
  @visibleForTesting
  static void routeFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    final parts = payload.split('|');
    final tag = parts.isNotEmpty ? parts[0] : '';
    // Each payload ends with the couple it was posted for, so a notification
    // still sitting in the tray from a previous account cannot be tapped into
    // the current one. A payload without it predates this and is let through,
    // the same way a push without couple_id is.
    String? field(int i) => parts.length > i ? parts[i] : null;
    if (tag == 'call') {
      // call|callId|fromName|video|coupleId
      if (!SessionScope.allows(field(4), SessionScope.coupleId)) return;
      pendingCall.value = CallTap(
        parts.length > 1 ? parts[1] : '',
        parts.length > 2 ? parts[2] : 'Your partner',
        !(parts.length > 3) || parts[3] == '1',
      );
      return;
    }
    if (tag == 'message') {
      // message|messageId|coupleId — opens the Chat tab. Falling through to the
      // Reach branch below is what made a plain text message pop the
      // full-screen Reach overlay, on every build that posts a message
      // notification.
      if (!SessionScope.allows(field(2), SessionScope.coupleId)) return;
      pendingChat.value = parts.length > 1 ? parts[1] : '';
      return;
    }
    if (tag == 'care') return; // care taps just open the app
    // Untagged by construction: the Reach payload is 'reachId|fromName|coupleId'
    // and predates every tagged kind. So this is a default branch that ASSUMES
    // reach — any new kind must get its own branch above it, or it lands here
    // and shows the overlay with a garbage id.
    if (!SessionScope.allows(field(2), SessionScope.coupleId)) return;
    pendingReach.value = ReachTap(
      tag,
      parts.length > 1 ? parts[1] : 'Your partner',
    );
  }
}
