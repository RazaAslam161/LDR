import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:miles/core/services/session_scope.dart';
import 'package:miles/features/chat/chat_receipts.dart';
import 'package:miles/features/chat/message_preview_port.dart';
import 'package:miles/core/services/unread_tally.dart';
import 'package:miles/features/disguise/disguise_notification.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
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

/// Shows the Reach notification: a max-importance heads-up on its own channel,
/// with the distinctive buzz.
///
/// Deliberately NOT `category: call` and NOT a full-screen intent. A Reach is a
/// nudge, not a ringing call — dressing one as a call takes over the lock
/// screen, gets it ranked beside real telephony, and rides a
/// USE_FULL_SCREEN_INTENT declaration that Play grants for calls and alarms
/// only. Spending that declaration on nudges is what puts it at risk for the
/// incoming-call ring below, which genuinely needs it. `Importance.max` +
/// `Priority.max` still heads-up and still wakes the device's alerting path.
Future<void> showReachNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required String fromName,
  required String reachId,
  required String coupleId,
}) async {
  // Wear this device's disguise, not the sender's and not a hardcoded one.
  final style = await currentNotificationStyle();

  // A Reach is urgent, but urgency cannot buy plausibility. On a cover that
  // never notifies in real life, the max-importance buzz below produced a
  // heads-up banner reading "Calculator — Tap to open", with the distinctive
  // Reach vibration, on a phone whose owner is relying on that calculator to be
  // uninteresting. It shipped that way.
  //
  // So on those covers it still arrives, and still says the same words, but on
  // the low-importance channel: no sound, no vibration, no heads-up. Visible
  // when the owner looks, silent to the room. That is a real cost — a Reach on
  // a silent cover will not get anyone's attention until they pick the phone up
  // — and it is the cost that cover is chosen for.
  final quiet = style.isSilentCover;
  final android = AndroidNotificationDetails(
    quiet ? kQuietChannelId : kReachChannelId,
    quiet ? kQuietChannelName : kReachChannelName,
    channelDescription: quiet ? kQuietChannelDesc : kReachChannelDesc,
    importance: quiet ? Importance.low : Importance.max,
    priority: quiet ? Priority.low : Priority.max,
    vibrationPattern: quiet ? null : reachVibrationPattern(),
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
    // A display name containing the delimiter shifted every field after it
    // and the tap routed nowhere.
    payload: '$reachId|${fromName.replaceAll('|', ' ')}|$coupleId',
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

// ── Quiet delivery, for covers that must never make a sound ─────────────────
// On Android 8+ the CHANNEL decides whether something buzzes; importance set on
// an individual notification is only a pre-O fallback. So a silent variant is
// not a flag, it is a second channel.
const String kQuietChannelId = 'quiet_updates';
const String kQuietChannelName = 'Silent updates';
const String kQuietChannelDesc = 'Delivered without sound';

AndroidNotificationChannel buildQuietChannel() =>
    const AndroidNotificationChannel(
      kQuietChannelId,
      kQuietChannelName,
      description: kQuietChannelDesc,
      importance: Importance.low,
    );

// ── Message alerts ──────────────────────────────────────────────────────────
// The retired channel, and why. It was named 'Messages', described as 'New
// messages', while every other channel in this file was already named
// generically — 'Alerts', 'Background activity', 'Timers', 'Reminders'.
// Android lists channel names under Settings > Apps > <cover> > Notifications,
// so a "Messages / New messages" channel inside what claims to be a weather app
// was the disguise undone by someone who never even opened it. A channel cannot
// be renamed once created (see the note at the top of this file), so the only
// way out is a new id and deleting this one.
const String kLegacyMsgChannelId = 'msg_channel';

const String kMsgChannelId = 'content_updates';
const String kMsgChannelName = 'Updates';
const String kMsgChannelDesc = 'Content updates';

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
///
/// ONE notification per conversation, counting up — not one per message. The id
/// keys on the couple, not the message, which is the whole fix: this used to be
/// `messageId.hashCode`, so thirty messages over lunch produced thirty separate
/// entries. A weather app that adds thirty notifications in an hour is not a
/// weather app anyone believes.
///
/// [unreadCount] is what the body counts. Three behaviours, chosen by the
/// cover's budget rather than by what happened:
///
///   none       — nothing is posted at all. Not silently, not minimised: a
///                calculator with an entry in the shade is a calculator someone
///                picks up. The unread signal lives in the cover's own UI.
///   persistent — an ongoing, silent entry that is REWRITTEN in place, the way a
///                weather app shows current conditions all day. The number of
///                notifications on the phone never changes, so there is nothing
///                new for anyone to notice.
///   otherwise  — a normal alert, but `onlyAlertOnce` so only the FIRST message
///                of a burst makes a sound. Everything after it updates the
///                count in silence.
Future<void> showMessageNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required String messageId,
  required String coupleId,
  required int unreadCount,
  String? previewBody,
}) async {
  final profile = await currentDisguiseProfile();
  final style = notificationStyleFor(profile);
  // A COVER MEANS NO MESSAGE NOTIFICATION. Not a quieter one, not a vaguer
  // one — none.
  //
  // The budget model this replaces was built on an assumption Android does not
  // allow. Every notification carries the APP's label in its header, taken from
  // `application android:label` in the manifest, fixed at build time. The
  // activity-alias labels that rename the launcher do not touch it. So a cover
  // that says "Weather Forecast updated" arrives under the word **Miles**, and
  // the shipped result was exactly that:
  //
  //     Miles - now
  //     Weather  Forecast updated
  //     Weather  Forecast updated
  //
  // No wording, channel, importance or grouping fixes that. A disguised build
  // cannot post a notification that does not name the app, and a message
  // notification is the one kind that arrives often enough to be noticed.
  //
  // So: covers get silence, and the unread signal belongs inside the cover's
  // own UI where the OS cannot relabel it. Only the undisguised app — where the
  // header saying "Miles" is the truth and not a leak — notifies at all.
  if (profile.cover != DisguiseCover.none) return;

  final android = AndroidNotificationDetails(
    kMsgChannelId,
    kMsgChannelName,
    channelDescription: kMsgChannelDesc,
    importance: Importance.high,
    priority: Priority.high,
    // The rate limiter, and it is the platform's own: an update to an existing
    // notification never re-alerts. One sound per burst, however many arrive.
    // Kept even undisguised — thirty messages over lunch is one sound.
    onlyAlertOnce: true,
    icon: style.smallIcon,
    ticker: style.ticker,
    visibility: NotificationVisibility.secret,
  );
  await plugin.show(
    id: coupleId.hashCode & 0x7fffffff,
    title: style.title,
    // The real text when the running app could decrypt it, the count when it
    // could not. Never both, and never a name — the header already says Miles,
    // which on the undisguised app is the truth.
    body: previewBody ?? style.unreadBody(unreadCount),
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
  final profile = await currentDisguiseProfile();
  // Same rule as messages, same reason: every notification arrives under the
  // app's manifest label — "Miles" — which no cover can relabel. A covered
  // handset gets silence here too; the app shows the nudge on open.
  if (profile.cover != DisguiseCover.none) return;
  final style = notificationStyleFor(profile);
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

/// Your partner proposed a memory.
///
/// Nine proposals across two couples produced zero acceptances, and the reason
/// was not the screen: nothing anywhere told the partner one existed. This is
/// the missing half.
///
/// Deliberately on the REMINDERS channel rather than a seventh of its own.
/// Channel names are listed in Android's notification settings under whatever
/// app the launcher claims to be, so every new one is another line a stranger
/// can read on a phone that is pretending to be a news reader — and "a gentle,
/// non-urgent nudge that waits for you" is exactly what the reminders channel
/// already describes. It is emphatically not Reach: a proposal is the least
/// time-critical thing in this app, and waking the screen for one would be a
/// lie about its urgency.
///
/// Carries no name and no title, like every other notification here. The spec
/// asked for "She proposed a memory."; that would put the word *memory* on the
/// lock screen of a disguised handset, which is the same defect as the care
/// reminder that once arrived reading "News update" on a calculator.
/// A ritual arriving at the hour the couple set for it.
///
/// Wears the disguise like everything else here: the message the two of them
/// wrote is the whole point of the ritual, and putting it on a lock screen is
/// exactly what this app must not do. Opening the app shows it.
///
/// Shares the care channel — a ritual is a gentle arrival, not an alarm, and
/// giving it its own channel would put the word "ritual" in Android's own
/// notification settings, where the disguise cannot reach.
Future<void> showRitualNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required String ritualId,
  required String coupleId,
}) async {
  final profile = await currentDisguiseProfile();
  // Covers mean silence — the header would say "Miles" (see showCareNotification).
  if (profile.cover != DisguiseCover.none) return;
  final style = notificationStyleFor(profile);
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
    id: ritualId.hashCode & 0x7fffffff,
    title: style.title,
    body: style.body,
    notificationDetails: NotificationDetails(android: android),
    payload: 'ritual|$ritualId|$coupleId',
  );
}

Future<void> showMemoryNotification({
  required FlutterLocalNotificationsPlugin plugin,
  required String memoryId,
  required String coupleId,
}) async {
  final profile = await currentDisguiseProfile();
  // Covers mean silence — the header would say "Miles" (see showCareNotification).
  if (profile.cover != DisguiseCover.none) return;
  final style = notificationStyleFor(profile);
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
    id: memoryId.hashCode & 0x7fffffff,
    title: style.title,
    body: style.body,
    notificationDetails: NotificationDetails(android: android),
    payload: 'memory|$memoryId|$coupleId',
  );
}

/// Background + terminated FCM handler. MUST be a top-level / static function
/// annotated with @pragma('vm:entry-point') — it runs in its own isolate.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final type = message.data['type'];
  // 'message' was missing here, so message_push.sql's trigger fired, the edge
  // function sent, FCM delivered — and this isolate returned immediately. The
  // whole push path existed and did nothing for anyone. 'memory' was the same
  // omission a second time: the branch below builds the notification correctly
  // and was simply never reached.
  if (type != 'reach' &&
      type != 'care' &&
      type != 'call' &&
      type != 'message' &&
      // The DELIVERY WAKE, and the reason it is not called 'message'. The
      // trigger sends `msg_sync`, a string no shipped build knows, so build 41
      // and older fall out of this very list and return — which is deliberate:
      // reaching the 'message' branch below would post a BANNER on every
      // handset in the field, and the owner does not want message
      // notifications. A name nothing recognises is what let the server half
      // ship before the client half without notifying anybody.
      //
      // Here it must be recognised, and it must stay silent: it exists only to
      // say "this handset has it".
      type != 'msg_sync' &&
      type != 'memory' &&
      type != 'ritual') {
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

  // Both kinds, one path. 'message' is still accepted by the edge function even
  // though only the DB trigger fires today, and it sends 'msg_sync' — leaving a
  // second copy of this logic behind the other name is how the two drift until
  // one of them is the per-message flood again.
  if (type == 'msg_sync' || type == 'message') {
    // The delivery wake. Its first job is unchanged and still comes first: this
    // handset now HAS the message, so say so while the app is closed and the
    // recipient does nothing at all. That ack is what turns the sender's single
    // grey tick into two.
    //
    // Started before the notification and awaited after, so a failure drawing
    // the alert cannot cost the receipt — the ticks are the part that has been
    // working, and a new feature must not be able to break an old one.
    final ack = BackgroundReceiptAck.onMessagePush(message.data);

    // Deliberately still the 'msg_sync' kind, and not switched to 'message'.
    // Flipping the server trigger would start drawing notifications on every
    // handset ALREADY in the field, using their old per-message code — the
    // exact breakage the version gate exists to prevent. The wake already
    // arrives for every message; whether anything is drawn is decided here, by
    // this build, on this device.
    final unread = await UnreadTally.increment(coupleId ?? '');
    await androidPlugin?.createNotificationChannel(buildQuietChannel());
    await androidPlugin?.createNotificationChannel(buildMsgChannel());
    await showMessageNotification(
      plugin: plugin,
      messageId: (message.data['message_id'] as String?) ?? '',
      coupleId: coupleId ?? '',
      unreadCount: unread,
    );

    // Then ask the running app, if there is one, to rewrite that notification
    // with the actual text. It holds the couple key; this isolate does not.
    // Posting the count FIRST and enriching after means the alert is never
    // delayed by a decrypt, and never lost if one fails.
    MessagePreviewPort.liveApp?.send(coupleId ?? '');

    await ack;
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

  if (type == 'memory') {
    await androidPlugin?.createNotificationChannel(buildCareChannel());
    await showMemoryNotification(
      plugin: plugin,
      memoryId: (message.data['memory_id'] as String?) ?? '',
      coupleId: coupleId ?? '',
    );
    return;
  }

  if (type == 'ritual') {
    await androidPlugin?.createNotificationChannel(buildCareChannel());
    await showRitualNotification(
      plugin: plugin,
      ritualId: (message.data['ritual_id'] as String?) ?? '',
      coupleId: coupleId ?? '',
    );
    return;
  }

  // Everything below assumes REACH. That is not a default worth relying on —
  // a kind without its own branch above lands here and buzzes the max-importance
  // alert carrying an id that belongs to something else.
  await androidPlugin?.createNotificationChannel(buildReachChannel());
  // Both, always: which one a Reach lands on is decided per-notification by the
  // cover, and a channel that does not exist drops the notification silently.
  await androidPlugin?.createNotificationChannel(buildQuietChannel());

  await showReachNotification(
    plugin: plugin,
    fromName: (message.data['from_name'] as String?) ?? 'Your partner',
    reachId: (message.data['reach_id'] as String?) ?? '',
    coupleId: coupleId ?? '',
  );
}
