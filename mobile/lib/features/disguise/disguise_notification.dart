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

  /// The AndroidManifest `<meta-data>` name holding this cover's small icon.
  ///
  /// flutter_foreground_task cannot take a resource name the way
  /// flutter_local_notifications does — it resolves the icon through a manifest
  /// meta-data entry instead. Derived from [smallIcon] rather than listed
  /// separately so a new cover cannot arrive with one of the two set and not
  /// the other; the manifest entries are named after the drawables for the same
  /// reason.
  String get iconMetaData => smallIcon.replaceFirst('@drawable/', '');
}

/// Copy + icon for each cover. Deliberately dull: a notification that invites
/// curiosity is a notification that gets opened by the wrong person.
DisguiseNotificationStyle notificationStyleFor(DisguiseProfile profile) {
  return switch (profile.cover) {
    // No cover, so nothing to keep up: the notification says Miles because the
    // launcher already does. Dressing it as a news alert on a phone whose home
    // screen shows this app by name would be a disguise that only fools its
    // owner. The icon is the notification silhouette, not @mipmap — see below.
    DisguiseCover.none => const DisguiseNotificationStyle(
        title: 'Miles',
        body: 'You have something waiting',
        smallIcon: '@drawable/ic_notif_news',
      ),
    // Not @mipmap/ic_launcher: Android masks a small icon to its alpha
    // channel, and the launcher tile is opaque edge to edge — it arrived as a
    // solid white square in the status bar, which is a thing no shipped app
    // does and the first thing an eye catches.
    DisguiseCover.news => const DisguiseNotificationStyle(
        title: 'News update',
        body: 'New stories available',
        smallIcon: '@drawable/ic_notif_news',
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
    DisguiseCover.convert => const DisguiseNotificationStyle(
        title: 'Convert',
        body: 'Reference rates refreshed',
        smallIcon: '@drawable/ic_notif_convert',
      ),
    DisguiseCover.recorder => const DisguiseNotificationStyle(
        title: 'Recorder',
        body: 'Recording saved',
        smallIcon: '@drawable/ic_notif_recorder',
      ),
    DisguiseCover.timer => const DisguiseNotificationStyle(
        title: 'Timer finished',
        body: 'Tap to open',
        smallIcon: '@drawable/ic_notif_timer',
      ),
    DisguiseCover.level => const DisguiseNotificationStyle(
        title: 'Level',
        body: 'Calibration needed',
        smallIcon: '@drawable/ic_notif_level',
      ),
    DisguiseCover.device => const DisguiseNotificationStyle(
        title: 'Device Info',
        body: 'Storage is filling up',
        smallIcon: '@drawable/ic_notif_device',
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
