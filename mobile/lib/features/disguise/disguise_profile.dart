import 'package:flutter/material.dart';

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
  /// A believable news reader (the app's original, hardcoded disguise).
  news,

  /// A working calculator. The most innocuous option and the one people expect
  /// to be boring, so nobody opens it twice.
  calculator,

  /// A plain notepad.
  notes,

  /// A local weather panel.
  weather,
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
const List<DisguiseProfile> kDisguises = [
  DisguiseProfile(
    aliasId: 'News',
    label: 'News',
    blurb: 'A headlines reader. Blends in on any home screen.',
    icon: Icons.article_outlined,
    tint: Color(0xFF1A73E8),
    cover: DisguiseCover.news,
  ),
  DisguiseProfile(
    aliasId: 'Calculator',
    label: 'Calculator',
    blurb: 'A working calculator. Nobody opens it twice.',
    icon: Icons.calculate_outlined,
    tint: Color(0xFF5F6368),
    cover: DisguiseCover.calculator,
  ),
  // Notes and Weather are NOT offered yet, on purpose. Their manifest aliases
  // and launcher icons exist, but neither has a cover screen — and a Notes icon
  // that opens a news reader is a louder tell than no disguise at all. They
  // ship the moment DisguiseCover.notes / .weather have real covers.
];

/// The identity a fresh install starts with — matches the one alias the
/// manifest ships with `android:enabled="true"`.
final DisguiseProfile kDefaultDisguise = kDisguises.first;

DisguiseProfile disguiseForAlias(String? aliasId) => kDisguises.firstWhere(
      (d) => d.aliasId == aliasId,
      orElse: () => kDefaultDisguise,
    );
