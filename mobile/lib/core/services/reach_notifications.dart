import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:miles/core/services/session_scope.dart';
import 'package:miles/features/disguise/disguise_notification.dart';
import 'package:miles/firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Channel names and descriptions are listed in Android's own notification
// settings, under whatever app the launcher says this is. They must therefore
// be plausible for EVERY disguise, not just the real app — "Reach Alerts /
// When your partner reaches for you" announced the entire product to anyone who
// opened the settings of what looked like a calculator.
//
// Kept deliberately generic and channel IDs kept stable: disguise-specific
// names would need the channels deleted and rebuilt on every switch, and any
// notification posted in that window would be lost.
//
// Renaming one later is not uniform, which is why kCallServiceChannelId exists.
// Android updates an existing channel's name and description when it is created
// again, so the channels built here through flutter_local_notifications correct
// themselves on the next cold start. flutter_foreground_task's own channel does
// not: ForegroundService.kt guards with
// `if (nm.getNotificationChannel(channelId) == null)` and so never renames one.
// That channel can only be corrected by moving to a new id and deleting the old.
const String kReachChannelId = 'reach_channel';
const String kReachChannelName = 'Alerts';
const String kReachChannelDesc = 'Time-sensitive alerts';

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
  required String coupleId,
  required bool fullScreen,
}) async {
  // Wear this device's disguise, not the sender's and not a hardcoded one.
  final style = await currentNotificationStyle();
  final android = AndroidNotificationDetails(
    kReachChannelId,
    kReachChannelName,
    channelDescription: kReachChannelDesc,
    importance: Importance.max,
    priority: Priority.max,
    category: AndroidNotificationCategory.call, // signals urgency
    vibrationPattern: reachVibrationPattern(),
    fullScreenIntent: fullScreen,
    icon: style.smallIcon,
    ticker: style.ticker,
    // Privacy: hidden entirely on the lock screen; no preview anywhere.
    visibility: NotificationVisibility.secret,
  );
  await plugin.show(
    id: reachId.hashCode & 0x7fffffff,
    title: style.title,
    body: style.body,
    notificationDetails: NotificationDetails(android: android),
    payload: '$reachId|$fromName|$coupleId',
  );
}

// ── Incoming calls ───────────────────────────────────────────────────────────
const String kCallChannelId = 'call_channel';
const String kCallChannelName = 'Priority alerts';
const String kCallChannelDesc = 'Time-sensitive updates';

/// The foreground-service channel for a call that is already running. Lives
/// here rather than beside its only caller so the disguise guard test in
/// test/unit/disguise_notification_test.dart sees it — it was hardcoded in
/// call_foreground.dart and shipped the real app name straight into Android's
/// notification settings, under the disguised launcher label.
///
/// The id moved off 'call_service' because the name behind it was "Ongoing
/// call", described as "Shown while a call is in progress" — a calling feature,
/// announced permanently in the settings of what claims to be a news app, to
/// anyone who looked. flutter_foreground_task will not rename a channel it
/// already made (see the note at the top of this file), so the only way to
/// retire that wording on a handset that has already placed one call is a new
/// id plus [kLegacyCallServiceChannelId] being deleted.
const String kCallServiceChannelId = 'background_activity';
const String kCallServiceChannelName = 'Background activity';
const String kCallServiceChannelDesc = 'Keeps tasks running while the app works';

/// The pre-0.1.0+10 foreground-service channel, deleted on start so its
/// "Ongoing call" name stops being listed. Recreating this id would restore the
/// old name, so nothing may ever post to it again.
const String kLegacyCallServiceChannelId = 'call_service';

// ── The Timer cover's countdown ──────────────────────────────────────────────
// Created lazily by the Timer disguise itself, so a phone wearing any other
// identity never lists a channel its cover could not explain. The strings live
// here with the rest so the disguise guard test in
// test/unit/disguise/disguise_notification_test.dart sees them.
const String kTimerChannelId = 'timer_channel';
const String kTimerChannelName = 'Timers';
const String kTimerChannelDesc = 'When a countdown finishes';

AndroidNotificationChannel buildTimerChannel() =>
    const AndroidNotificationChannel(
      kTimerChannelId,
      kTimerChannelName,
      description: kTimerChannelDesc,
      importance: Importance.high,
    );

Int64List callVibrationPattern() =>
    Int64List.fromList(<int>[0, 800, 600, 800, 600, 800]);

AndroidNotificationChannel buildCallChannel() => AndroidNotificationChannel(
      kCallChannelId,
      kCallChannelName,
      description: kCallChannelDesc,
      importance: Importance.max,
      vibrationPattern: callVibrationPattern(),
    );

/// A full-screen incoming-call ring. Tapping it opens the app to the ringing
/// call screen (answer / decline happens in-app). Degrades to a max-priority
/// heads-up when the full-screen-intent permission isn't granted.
Future<void> showCallNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required String fromName,
  required String callId,
  required String coupleId,
  required bool video,
  required bool fullScreen,
}) async {
  final style = await currentNotificationStyle();
  final android = AndroidNotificationDetails(
    kCallChannelId,
    kCallChannelName,
    channelDescription: kCallChannelDesc,
    importance: Importance.max,
    priority: Priority.max,
    category: AndroidNotificationCategory.call,
    fullScreenIntent: fullScreen,
    ongoing: true,
    vibrationPattern: callVibrationPattern(),
    icon: style.smallIcon,
    ticker: style.ticker,
    visibility: NotificationVisibility.secret,
  );
  await plugin.show(
    id: callId.hashCode & 0x7fffffff,
    title: style.title,
    body: style.body,
    notificationDetails: NotificationDetails(android: android),
    payload: 'call|$callId|$fromName|${video ? 1 : 0}|$coupleId',
  );
}

// ── Care Nudges ──────────────────────────────────────────────────────────────
const String kMsgChannelId = 'msg_channel';
const String kMsgChannelName = 'Messages';
const String kMsgChannelDesc = 'New messages';

const String kCareChannelId = 'care_channel';
const String kCareChannelName = 'Reminders';
const String kCareChannelDesc = 'Scheduled reminders';

AndroidNotificationChannel buildCareChannel() =>
    const AndroidNotificationChannel(
      kCareChannelId,
      kCareChannelName,
      description: kCareChannelDesc,
      importance: Importance.high,
    );

AndroidNotificationChannel buildMsgChannel() =>
    const AndroidNotificationChannel(
      kMsgChannelId,
      kMsgChannelName,
      description: kMsgChannelDesc,
      importance: Importance.high,
    );

/// A new chat message arrived while the app was backgrounded or killed.
///
/// Carries no sender name and no message text on purpose: the launcher is
/// disguised, so the notification wears the same cover as every other one.
/// Whoever picks up the phone sees a generic alert; the content is behind the
/// app lock.
Future<void> showMessageNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required String messageId,
  required String coupleId,
}) async {
  final style = await currentNotificationStyle();
  final android = AndroidNotificationDetails(
    kMsgChannelId,
    kMsgChannelName,
    channelDescription: kMsgChannelDesc,
    importance: Importance.high,
    priority: Priority.high,
    icon: style.smallIcon,
    ticker: style.ticker,
    visibility: NotificationVisibility.secret,
  );
  await plugin.show(
    id: messageId.hashCode & 0x7fffffff,
    title: style.title,
    body: style.body,
    notificationDetails: NotificationDetails(android: android),
    payload: 'message|$messageId|$coupleId',
  );
}

/// A gentle reminder notification ("eat lunch", "take your medicine"…).
Future<void> showCareNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required String nudgeId,
  required String coupleId,
}) async {
  // The reported bug lived here: a care reminder sent to a partner running the
  // Calculator disguise arrived as a "News update".
  final style = await currentNotificationStyle();
  final android = AndroidNotificationDetails(
    kCareChannelId,
    kCareChannelName,
    channelDescription: kCareChannelDesc,
    importance: Importance.high,
    priority: Priority.high,
    icon: style.smallIcon,
    ticker: style.ticker,
    visibility: NotificationVisibility.secret,
  );
  await plugin.show(
    id: nudgeId.hashCode & 0x7fffffff,
    title: style.title,
    body: style.body,
    notificationDetails: NotificationDetails(android: android),
    payload: 'care|$nudgeId|$coupleId',
  );
}

/// Background + terminated FCM handler. MUST be a top-level / static function
/// annotated with @pragma('vm:entry-point') — it runs in its own isolate.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final type = message.data['type'];
  // 'message' was missing here, so message_push.sql's trigger fired, the edge
  // function sent, FCM delivered — and this isolate returned immediately. The
  // whole push path existed and did nothing for anyone.
  if (type != 'reach' && type != 'care' && type != 'call' && type != 'message') {
    return;
  }

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // A push is addressed to a device token, so nothing above this line knows
  // whether it belongs to the account currently signed in. A handset that had
  // been signed into two accounts received the second couple's Reach inside the
  // first couple's session. Drop it before it is ever drawn: an unwanted
  // notification for a stranger's couple is the leak, not the tap that follows.
  //
  // Read here rather than first thing, so this isolate touches a plugin channel
  // in the same order it already does for 'fsi_can_use' below — an unproven
  // ordering that threw would take out every notification for everyone, which
  // is a worse failure than the one being fixed.
  final coupleId = message.data['couple_id'] as String?;
  if (!SessionScope.allows(coupleId, await SessionScope.readCouple())) return;

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    // Init-time DEFAULT only — every notification we post overrides this with
    // the active disguise's icon. Anything that forgets to would show the News
    // icon on a Calculator phone, so pass style.smallIcon when adding one.
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
      coupleId: coupleId ?? '',
      video: (message.data['video'] as String?) == 'true',
      fullScreen: fullScreen,
    );
    return;
  }

  if (type == 'message') {
    await androidPlugin?.createNotificationChannel(buildMsgChannel());
    await showMessageNotification(
      plugin: plugin,
      messageId: (message.data['message_id'] as String?) ?? '',
      coupleId: coupleId ?? '',
    );
    return;
  }

  if (type == 'care') {
    await androidPlugin?.createNotificationChannel(buildCareChannel());
    await showCareNotification(
      plugin: plugin,
      nudgeId: (message.data['nudge_id'] as String?) ?? '',
      coupleId: coupleId ?? '',
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
    coupleId: coupleId ?? '',
    fullScreen: fullScreen,
  );
}
