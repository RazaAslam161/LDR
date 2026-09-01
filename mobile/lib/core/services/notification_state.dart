import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// What Android actually thinks about this app's notifications.
///
/// Recovered from build 52 (docs/archive/BUILD-52-AUDIT.md). The settings screen
/// used to list seven channel rows that each opened a system page, and said
/// nothing about whether any of them could ring — so a user with notifications
/// switched off at the app level saw seven confident rows and no working
/// alerts. Android holds the truth; this asks it.
///
/// Every field is nullable-tolerant on purpose. `areNotificationsEnabled` and
/// `getNotificationChannels` are platform calls that can answer null on an OEM
/// that has not implemented them, and a screen that renders "blocked" off a
/// null has invented a fact. Null means "this phone did not say", and the copy
/// for that case says exactly that.
@immutable
class NotificationState {
  const NotificationState({this.appEnabled, this.blocked = const {}});

  /// Whether the app may post notifications at all. Null when unknown.
  final bool? appEnabled;

  /// Channel ids Android reports at importance NONE — the per-channel "off".
  final Set<String> blocked;

  bool get anyBlocked => blocked.isNotEmpty;

  /// True only when the phone actually said no. Unknown is not a no.
  bool get appBlocked => appEnabled == false;

  static Future<NotificationState> read() async {
    final android = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return const NotificationState();
    try {
      final enabled = await android.areNotificationsEnabled();
      final channels = await android.getNotificationChannels();
      return NotificationState(
        appEnabled: enabled,
        blocked: {
          for (final c in channels ?? const <AndroidNotificationChannel>[])
            if (c.importance == Importance.none) c.id,
        },
      );
    } catch (e) {
      // Never fatal to a settings screen. An OEM that throws here leaves the
      // rows saying "this phone didn't say", which is true.
      debugPrint('[notifications] state read failed: $e');
      return const NotificationState();
    }
  }
}
