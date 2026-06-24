import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:miles/core/services/fsi_permission.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/core/supabase_repository.dart';

/// A Reach that should surface the in-app overlay (from a foreground push or a
/// tapped notification). The AppShell listens to [pendingReach] and shows the
/// overlay, de-duping by [reachId] against its realtime listener.
class ReachTap {
  const ReachTap(this.reachId, this.fromName);
  final String reachId;
  final String fromName;
}

final ValueNotifier<ReachTap?> pendingReach = ValueNotifier<ReachTap?>(null);

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
    await _fln
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(buildReachChannel());

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

  /// After login + pairing: ask permission, store the token, keep it fresh.
  static Future<void> registerToken() async {
    await requestPermission();
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _save(token);
    FirebaseMessaging.instance.onTokenRefresh.listen(_save);
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
    if (m.data['type'] != 'reach') return;
    // Foreground: surface the in-app overlay. AppShell de-dupes by reach_id so
    // this and the Supabase realtime listener never double-show.
    pendingReach.value = ReachTap(
      (m.data['reach_id'] as String?) ?? '',
      (m.data['from_name'] as String?) ?? 'Your partner',
    );
  }

  static void _onOpenedApp(RemoteMessage m) {
    if (m.data['type'] != 'reach') return;
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
    pendingReach.value = ReachTap(
      parts.isNotEmpty ? parts[0] : '',
      parts.length > 1 ? parts[1] : 'Your partner',
    );
  }
}
