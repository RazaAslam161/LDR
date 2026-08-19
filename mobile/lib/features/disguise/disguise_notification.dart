import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/disguise_service.dart';

/// How much a cover can plausibly notify.
///
/// The wording of a notification was never the hard part; its EXISTENCE and its
/// FREQUENCY are. Covers are not variations on a theme, they are different
/// species: a news app alerting several times a day is unremarkable, and a
/// calculator alerting even once is the whole disguise gone. Nothing about
/// phrasing rescues a calculator that buzzes.
///
/// So the budget is the first thing decided, and everything else — which
/// channel, whether it makes a sound, whether it appears at all — derives from
/// it rather than from the kind of thing that happened.
enum NotificationBudget {
  /// The real app alerts often and unprompted. Message alerts are plausible.
  frequent,

  /// The real app alerts, but rarely and for a reason the user set up.
  occasional,

  /// The real app keeps ONE permanent, silent entry in the shade and updates it
  /// in place — a weather app showing the current conditions. The strongest
  /// cover of the three: the number of notifications never changes, so there is
  /// nothing new for anyone to notice, ever.
  persistent,

  /// The real app never notifies. Not rarely — never. Any entry in the shade is
  /// a tell, so this cover gets no system notification of any kind and the
  /// unread signal lives inside the cover's own UI instead.
  none,
}

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
    required this.budget,
    required this.unreadOne,
    required this.unreadMany,
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

  /// What this cover can plausibly get away with. See [NotificationBudget].
  final NotificationBudget budget;

  /// Wording for unread messages, in the cover's own vocabulary. Never a name,
  /// never a preview — for a disguised app there is no safe "sender only" mode,
  /// so one is not offered.
  ///
  /// A COUNT is safe and is the useful part: "3 new stories" is exactly what a
  /// news app says and exactly what the owner needs to know. `{n}` is replaced
  /// with the number.
  final String unreadOne;
  final String unreadMany;

  /// The body for [count] unread messages.
  String unreadBody(int count) => count <= 1
      ? unreadOne
      : unreadMany.replaceAll('{n}', '$count');

  /// True when this cover must never put anything in the notification shade.
  bool get isSilentCover => budget == NotificationBudget.none;

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
        budget: NotificationBudget.frequent,
        unreadOne: 'A new message',
        unreadMany: '{n} new messages',
      ),
    // Not @mipmap/ic_launcher: Android masks a small icon to its alpha
    // channel, and the launcher tile is opaque edge to edge — it arrived as a
    // solid white square in the status bar, which is a thing no shipped app
    // does and the first thing an eye catches.
    //
    // The only cover where frequent alerting is fully in character, which makes
    // it the right default for anyone who wants to be told promptly.
    DisguiseCover.news => const DisguiseNotificationStyle(
        title: 'News update',
        body: 'New stories available',
        smallIcon: '@drawable/ic_notif_news',
        budget: NotificationBudget.frequent,
        unreadOne: 'A new story is available',
        unreadMany: '{n} new stories available',
      ),
    // Calculators do not notify. Ever. No phrasing makes one plausible.
    DisguiseCover.calculator => const DisguiseNotificationStyle(
        title: 'Calculator',
        body: 'Tap to open',
        smallIcon: '@drawable/ic_notif_calculator',
        budget: NotificationBudget.none,
        unreadOne: 'Tap to open',
        unreadMany: 'Tap to open',
      ),
    DisguiseCover.notes => const DisguiseNotificationStyle(
        title: 'Notes',
        body: 'You have a reminder',
        smallIcon: '@drawable/ic_notif_notes',
        budget: NotificationBudget.occasional,
        unreadOne: 'You have a reminder',
        unreadMany: 'You have {n} reminders',
      ),
    // Weather apps keep a permanent silent entry showing current conditions and
    // rewrite it in place all day. Nothing is ever ADDED to the shade, so the
    // count a bystander could notice never changes.
    DisguiseCover.weather => const DisguiseNotificationStyle(
        title: 'Weather',
        body: 'Forecast updated',
        smallIcon: '@drawable/ic_notif_weather',
        budget: NotificationBudget.persistent,
        unreadOne: 'Forecast updated',
        unreadMany: 'Forecast updated · {n} areas',
      ),
    DisguiseCover.convert => const DisguiseNotificationStyle(
        title: 'Convert',
        body: 'Reference rates refreshed',
        smallIcon: '@drawable/ic_notif_convert',
        budget: NotificationBudget.none,
        unreadOne: 'Reference rates refreshed',
        unreadMany: 'Reference rates refreshed',
      ),
    // A recorder notifies while it is recording — which it is not.
    DisguiseCover.recorder => const DisguiseNotificationStyle(
        title: 'Recorder',
        body: 'Recording saved',
        smallIcon: '@drawable/ic_notif_recorder',
        budget: NotificationBudget.none,
        unreadOne: 'Recording saved',
        unreadMany: 'Recording saved',
      ),
    // A timer notifies when a timer the user set has finished. Plausible now
    // and then; absurd forty times a day.
    DisguiseCover.timer => const DisguiseNotificationStyle(
        title: 'Timer finished',
        body: 'Tap to open',
        smallIcon: '@drawable/ic_notif_timer',
        budget: NotificationBudget.occasional,
        unreadOne: 'Tap to open',
        unreadMany: 'Tap to open',
      ),
    DisguiseCover.level => const DisguiseNotificationStyle(
        title: 'Level',
        body: 'Calibration needed',
        smallIcon: '@drawable/ic_notif_level',
        budget: NotificationBudget.none,
        unreadOne: 'Calibration needed',
        unreadMany: 'Calibration needed',
      ),
    DisguiseCover.device => const DisguiseNotificationStyle(
        title: 'Device Info',
        body: 'Storage is filling up',
        smallIcon: '@drawable/ic_notif_device',
        budget: NotificationBudget.none,
        unreadOne: 'Storage is filling up',
        unreadMany: 'Storage is filling up',
      ),
  };
}

/// The disguise this device is wearing.
///
/// Safe to call from the FCM background isolate: it reads SharedPreferences,
/// which is backed by disk and available there.
///
/// Falls back to [kDefaultDisguise] — a COVER — rather than to the undisguised
/// profile, and that direction is deliberate. Callers use this to decide
/// whether they may post at all; failing toward "covered" costs a notification,
/// while failing toward "uncovered" posts one on a phone whose owner is relying
/// on the app to stay quiet.
Future<DisguiseProfile> currentDisguiseProfile() async {
  try {
    return await DisguiseService.current();
  } catch (_) {
    return kDefaultDisguise;
  }
}

/// Resolves the style for whatever disguise this device is wearing.
Future<DisguiseNotificationStyle> currentNotificationStyle() async =>
    notificationStyleFor(await currentDisguiseProfile());
