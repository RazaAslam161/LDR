import 'package:flutter/material.dart';
import 'package:miles/features/disguise/disguise_service.dart' show DisguiseService;

/// What the app pretends to be on the user's phone.
///
/// Each profile maps 1:1 to an `<activity-alias>` in AndroidManifest.xml —
/// [aliasId] is the alias's short name, and Android reads the launcher label and
/// icon from the manifest, not from here. The Dart-side [label] and [icon] exist
/// so the picker and the cover screen can describe the same identity without a
/// second round trip to the platform.
///
/// Adding a profile means adding BOTH an entry here and a matching
/// `<activity-alias android:name=".Alias<Id>">` — see [DisguiseService].
enum DisguiseCover {
  /// No cover at all — the app opens straight into itself.
  ///
  /// The plain identity used to carry `news` here, because every profile had to
  /// name a cover and news was the old default. The launcher then said Miles
  /// and the first screen said News, which is the one combination that reads as
  /// a bug rather than a disguise.
  none,

  /// A believable news reader (the app's original, hardcoded disguise).
  news,

  /// A working calculator. The most innocuous option and the one people expect
  /// to be boring, so nobody opens it twice.
  calculator,

  /// A plain notepad.
  notes,

  /// A local weather panel.
  weather,

  /// A unit and currency converter. Output-only: there is no list, no history
  /// and nothing that could belong to a person.
  convert,

  /// A voice recorder with an empty library.
  recorder,

  /// A stopwatch and countdown timer. No content at all, not even an empty
  /// list.
  timer,

  /// A bubble level and compass, driven by the device's own sensors.
  level,

  /// A read-only wall of device and storage statistics.
  device,
}

@immutable
class DisguiseProfile {
  const DisguiseProfile({
    required this.aliasId,
    required this.label,
    required this.blurb,
    required this.icon,
    required this.tint,
    required this.cover,
  });

  /// Matches `<activity-alias android:name=".Alias$aliasId">` in the manifest.
  final String aliasId;

  /// The launcher name the manifest declares for this alias. Kept in sync by
  /// hand — Android cannot report a disabled alias's label back to us.
  final String label;

  /// One line shown in the picker.
  final String blurb;

  /// Picker-only preview glyph; the real launcher icon lives in res/.
  final IconData icon;
  final Color tint;

  /// Which fake app the cover screen renders once the disguise is active.
  final DisguiseCover cover;
}

/// Every disguise the app ships. Order is the order shown in the picker.
///
/// `news` stays first and is the default so that existing installs — which are
/// already running the News alias — keep the identity they were installed with.
///
/// No profile names a way in. The app ships no entry gesture for any cover:
/// the owner records their own on the cover they chose (see cover_gate.dart),
/// and every string that once described a door here was a door everyone could
/// read.
const List<DisguiseProfile> kDisguises = [
  DisguiseProfile(
    aliasId: 'News',
    label: 'News',
    blurb: 'A headlines reader. Blends in on any home screen.',
    icon: Icons.article_outlined,
    tint: Color(0xFFB3261E),
    cover: DisguiseCover.news,
  ),
  DisguiseProfile(
    aliasId: 'Calculator',
    label: 'Calculator',
    blurb: 'A working calculator. Nobody opens it twice.',
    icon: Icons.calculate_outlined,
    tint: Color(0xFF3C4043),
    cover: DisguiseCover.calculator,
  ),
  DisguiseProfile(
    aliasId: 'Notes',
    label: 'Notes',
    blurb: 'A notepad that really keeps notes.',
    icon: Icons.sticky_note_2_outlined,
    tint: Color(0xFFE65100),
    cover: DisguiseCover.notes,
  ),
  DisguiseProfile(
    aliasId: 'Weather',
    label: 'Weather',
    blurb: 'A local forecast, stable through the day.',
    icon: Icons.wb_sunny_outlined,
    tint: Color(0xFF1565C0),
    cover: DisguiseCover.weather,
  ),
  DisguiseProfile(
    aliasId: 'Convert',
    label: 'Convert',
    blurb: 'Units and currency. Output only — nothing to browse.',
    icon: Icons.swap_horiz_rounded,
    tint: Color(0xFF0F766E),
    cover: DisguiseCover.convert,
  ),
  DisguiseProfile(
    aliasId: 'Recorder',
    label: 'Recorder',
    blurb: 'A voice recorder. An empty one raises no questions.',
    icon: Icons.mic_none_rounded,
    tint: Color(0xFF2A2830),
    cover: DisguiseCover.recorder,
  ),
  DisguiseProfile(
    aliasId: 'Timer',
    label: 'Timer',
    blurb: 'A stopwatch and countdown. No content whatsoever.',
    icon: Icons.timer_outlined,
    tint: Color(0xFF2E7D32),
    cover: DisguiseCover.timer,
  ),
  DisguiseProfile(
    aliasId: 'Level',
    label: 'Level',
    blurb: 'A spirit level and compass. Alive the moment you tilt it.',
    icon: Icons.straighten_rounded,
    tint: Color(0xFFB06A12),
    cover: DisguiseCover.level,
  ),
  DisguiseProfile(
    aliasId: 'Device',
    label: 'Device Info',
    blurb: "The phone's own numbers. Boring is the product.",
    icon: Icons.bar_chart_rounded,
    tint: Color(0xFF3730A3),
    cover: DisguiseCover.device,
  ),
];

/// The identity a fresh install starts with — matches the one alias the
/// manifest ships with `android:enabled="true"`.
/// The app as itself: its own name, its own icon, no cover behind it.
///
/// Deliberately NOT in [kDisguises] — it is the absence of a disguise, and
/// every test and picker that walks that list is asking "which covers exist",
/// which this is not an answer to. It has an alias of its own all the same,
/// because a launcher identity you cannot switch back TO is a one-way door.
/// Both channels declare `.AliasMiles` and ship it enabled. It also carries the
/// share target, so under a cover the app is absent from the share sheet.
const DisguiseProfile kPlainProfile = DisguiseProfile(
  aliasId: 'Miles',
  label: 'Miles',
  blurb: 'The app as itself. No cover, its own name and icon.',
  icon: Icons.favorite_outline,
  tint: Color(0xFFE0785A),
  cover: DisguiseCover.none,
);

final DisguiseProfile kDefaultDisguise = kDisguises.first;

DisguiseProfile disguiseForAlias(String? aliasId) => aliasId ==
        kPlainProfile.aliasId
    ? kPlainProfile
    : kDisguises.firstWhere(
      (d) => d.aliasId == aliasId,
      orElse: () => kDefaultDisguise,
    );
