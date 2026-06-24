import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:miles/firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kReachChannelId = 'reach_channel';
const String kReachChannelName = 'Reach Alerts';
const String kReachChannelDesc = 'When your partner reaches for you';

/// The distinctive Reach buzz (also used by the in-app overlay).
Int64List reachVibrationPattern() =>
    Int64List.fromList(<int>[0, 300, 100, 500, 100, 300]);

/// The high-importance channel a Reach alert is delivered on. Importance.max +
/// sound + vibration so it heads-up even when FSI isn't granted.
AndroidNotificationChannel buildReachChannel() => AndroidNotificationChannel(
      kReachChannelId,
      kReachChannelName,
      description: kReachChannelDesc,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      vibrationPattern: reachVibrationPattern(),
    );

/// Shows the Reach notification. [fullScreen] decides whether to request a
/// full-screen intent (caller passes the live/cached permission state). When
/// false — or when the OS withholds the permission — it degrades to a
/// max-priority heads-up notification automatically.
Future<void> showReachNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required String fromName,
  required String reachId,
  required bool fullScreen,
}) async {
  final android = AndroidNotificationDetails(
    kReachChannelId,
    kReachChannelName,
    channelDescription: kReachChannelDesc,
    importance: Importance.max,
    priority: Priority.max,
    category: AndroidNotificationCategory.call, // signals urgency
    playSound: true,
    enableVibration: true,
    vibrationPattern: reachVibrationPattern(),
    fullScreenIntent: fullScreen,
    icon: '@mipmap/ic_launcher',
    ticker: 'Reach',
  );
  await plugin.show(
    id: reachId.hashCode & 0x7fffffff,
    title: '$fromName is reaching for you 💕',
    body: 'Tap to reach back',
    notificationDetails: NotificationDetails(android: android),
    payload: '$reachId|$fromName',
  );
}

/// Background + terminated FCM handler. MUST be a top-level / static function
/// annotated with @pragma('vm:entry-point') — it runs in its own isolate.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (message.data['type'] != 'reach') return;
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(buildReachChannel());

  // The background isolate has no Activity, so it can't query the FSI
  // permission live — it reads the value the foreground last cached.
  final prefs = await SharedPreferences.getInstance();
  final fullScreen = prefs.getBool('fsi_can_use') ?? false;

  await showReachNotification(
    plugin: plugin,
    fromName: (message.data['from_name'] as String?) ?? 'Your partner',
    reachId: (message.data['reach_id'] as String?) ?? '',
    fullScreen: fullScreen,
  );
}
