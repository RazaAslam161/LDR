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

// ── Incoming calls ───────────────────────────────────────────────────────────
const String kCallChannelId = 'call_channel';
const String kCallChannelName = 'Incoming Calls';
const String kCallChannelDesc = 'Ringing when your partner calls you';

Int64List callVibrationPattern() =>
    Int64List.fromList(<int>[0, 800, 600, 800, 600, 800]);

AndroidNotificationChannel buildCallChannel() => AndroidNotificationChannel(
      kCallChannelId,
      kCallChannelName,
      description: kCallChannelDesc,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      vibrationPattern: callVibrationPattern(),
    );

/// A full-screen incoming-call ring. Tapping it opens the app to the ringing
/// call screen (answer / decline happens in-app). Degrades to a max-priority
/// heads-up when the full-screen-intent permission isn't granted.
Future<void> showCallNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required String fromName,
  required String callId,
  required bool video,
  required bool fullScreen,
}) async {
  final android = AndroidNotificationDetails(
    kCallChannelId,
    kCallChannelName,
    channelDescription: kCallChannelDesc,
    importance: Importance.max,
    priority: Priority.max,
    category: AndroidNotificationCategory.call,
    fullScreenIntent: fullScreen,
    ongoing: true,
    playSound: true,
    enableVibration: true,
    vibrationPattern: callVibrationPattern(),
    icon: '@mipmap/ic_launcher',
    ticker: 'Incoming call',
  );
  await plugin.show(
    id: callId.hashCode & 0x7fffffff,
    title: video ? '$fromName is video calling 📹' : '$fromName is calling 📞',
    body: 'Tap to answer',
    notificationDetails: NotificationDetails(android: android),
    payload: 'call|$callId|$fromName|${video ? 1 : 0}',
  );
}

// ── Care Nudges ──────────────────────────────────────────────────────────────
const String kCareChannelId = 'care_channel';
const String kCareChannelName = 'Care Reminders';
const String kCareChannelDesc = 'Gentle reminders from your partner';

AndroidNotificationChannel buildCareChannel() =>
    const AndroidNotificationChannel(
      kCareChannelId,
      kCareChannelName,
      description: kCareChannelDesc,
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

/// A gentle reminder notification ("eat lunch", "take your medicine"…).
Future<void> showCareNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required String title,
  required String body,
  required String nudgeId,
}) async {
  const android = AndroidNotificationDetails(
    kCareChannelId,
    kCareChannelName,
    channelDescription: kCareChannelDesc,
    importance: Importance.high,
    priority: Priority.high,
    icon: '@mipmap/ic_launcher',
    ticker: 'Reminder',
  );
  await plugin.show(
    id: nudgeId.hashCode & 0x7fffffff,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(android: android),
    payload: 'care|$nudgeId',
  );
}

/// Background + terminated FCM handler. MUST be a top-level / static function
/// annotated with @pragma('vm:entry-point') — it runs in its own isolate.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final type = message.data['type'];
  if (type != 'reach' && type != 'care' && type != 'call') return;
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  final androidPlugin = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();

  if (type == 'call') {
    await androidPlugin?.createNotificationChannel(buildCallChannel());
    final prefs = await SharedPreferences.getInstance();
    final fullScreen = prefs.getBool('fsi_can_use') ?? false;
    await showCallNotification(
      plugin: plugin,
      fromName: (message.data['from_name'] as String?) ?? 'Your partner',
      callId: (message.data['call_id'] as String?) ?? '',
      video: (message.data['video'] as String?) == 'true',
      fullScreen: fullScreen,
    );
    return;
  }

  if (type == 'care') {
    await androidPlugin?.createNotificationChannel(buildCareChannel());
    await showCareNotification(
      plugin: plugin,
      title: (message.data['title'] as String?) ?? 'A reminder 💛',
      body: (message.data['body'] as String?) ?? '',
      nudgeId: (message.data['nudge_id'] as String?) ?? '',
    );
    return;
  }

  await androidPlugin?.createNotificationChannel(buildReachChannel());

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
