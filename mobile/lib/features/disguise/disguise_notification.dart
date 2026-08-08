import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/disguise_service.dart';

/// How a notification must look so it belongs to the disguise the user chose.
///
/// Everything here is decided on the **receiving** device. The sender never
/// learns which disguise their partner runs — it is not in the push payload and
/// not stored server-side — because a disguise the other side can enumerate is
/// not a disguise. Our pushes are data-only precisely so the receiving device
/// builds the visible notification itself.
class DisguiseNotificationStyle {
  const DisguiseNotificationStyle({
    required this.title,
    required this.body,
    required this.smallIcon,
  });

  /// Shown as the notification title. Reads as something the cover app would
  /// plausibly say — never the real app, never another cover's wording.
  final String title;
  final String body;

  /// Android small-icon resource, from `drawable/` — Android masks it to its
  /// alpha channel, so these are white silhouettes, not the colour launcher
  /// icons. Every value here must exist as a real resource: a name that does
  /// not resolve makes the plugin throw
  /// `PlatformException(invalid_icon, ...)` and post nothing at all, which is
  /// silent in the background isolate. `res/raw/keep.xml` stops the resource
  /// shrinker from removing them, since a name held only in a Dart string is
  /// invisible to it.
  final String smallIcon;

  /// The ticker (spoken by accessibility services, and shown on older Android).
  /// Same text as the title so the two can never disagree.
  String get ticker => title;
}

/// Copy + icon for each cover. Deliberately dull: a notification that invites
/// curiosity is a notification that gets opened by the wrong person.
DisguiseNotificationStyle notificationStyleFor(DisguiseProfile profile) {
  return switch (profile.cover) {
    DisguiseCover.news => const DisguiseNotificationStyle(
        title: 'News update',
        body: 'New stories available',
        smallIcon: '@mipmap/ic_launcher',
      ),
    DisguiseCover.calculator => const DisguiseNotificationStyle(
        title: 'Calculator',
        body: 'Tap to open',
        smallIcon: '@drawable/ic_notif_calculator',
      ),
    DisguiseCover.notes => const DisguiseNotificationStyle(
        title: 'Notes',
        body: 'You have a reminder',
        smallIcon: '@drawable/ic_notif_notes',
      ),
    DisguiseCover.weather => const DisguiseNotificationStyle(
        title: 'Weather',
        body: 'Forecast updated',
        smallIcon: '@drawable/ic_notif_weather',
      ),
  };
}

/// Resolves the style for whatever disguise this device is wearing.
///
/// Safe to call from the FCM background isolate: it reads SharedPreferences,
/// which is backed by disk and available there. Falls back to the default
/// profile if the read fails, so a notification is never shown with no identity
/// at all.
Future<DisguiseNotificationStyle> currentNotificationStyle() async {
  try {
    return notificationStyleFor(await DisguiseService.current());
  } catch (_) {
    return notificationStyleFor(kDefaultDisguise);
  }
}
