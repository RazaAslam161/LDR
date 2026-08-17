import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every notification channel the app creates gets an OS settings page, and
/// the Settings screen's Notifications section is the only in-app route to
/// them. A channel created in code but missing from that list ships per-type
/// controls the user can never find — which is exactly where all of them
/// lived before the section existed.
///
/// This scans lib/ for the channel-id constant at every creation site — the
/// AndroidNotificationChannel(...) builders and the call foreground service's
/// AndroidNotificationOptions(channelId: ...) — and requires each id to
/// appear in settings_screen.dart. AndroidNotificationDetails(...) sites are
/// deliberately not matched: posting to a channel is not creating one.
void main() {
  test('every created notification channel has a Settings row', () {
    final creations = <String>{};
    final channelCtor =
        RegExp(r'\bAndroidNotificationChannel\(\s*(k\w+ChannelId)\b');
    final serviceOpts =
        RegExp(r'\bAndroidNotificationOptions\(\s*channelId:\s*(k\w+ChannelId)\b');
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m in channelCtor.allMatches(src)) {
        creations.add(m.group(1)!);
      }
      for (final m in serviceOpts.allMatches(src)) {
        creations.add(m.group(1)!);
      }
    }

    // The scan proving it still sees anything at all: the Reach channel is the
    // one creation site this app cannot lose. An empty set would otherwise
    // make every assertion below pass vacuously.
    expect(creations, contains('kReachChannelId'),
        reason: 'the creation-site scan found $creations — the regexes no '
            'longer match how channels are built');

    // Deleted channels stay deleted. Recreating a kLegacy id would resurrect
    // its old name from Android's record of the deleted channel
    // (reach_notifications.dart explains why they can never come back).
    expect(creations.where((id) => id.startsWith('kLegacy')), isEmpty,
        reason: 'a retired legacy channel id is being created again');

    // Comments stripped first, in both directions: a comment naming an id is
    // neither a row (forward) nor a stale reference worth failing on
    // (reverse). Crude line split is enough — no string in that file carries
    // a channel constant after a '//'.
    final settingsCode = File('lib/features/settings/settings_screen.dart')
        .readAsStringSync()
        .split('\n')
        .map((l) => l.split('//').first)
        .join('\n');
    for (final id in creations) {
      expect(settingsCode.contains(id), isTrue,
          reason: '$id is created in code but has no row in the Settings '
              "screen's Notifications section — the channel ships with OS "
              'controls nobody can reach. Add a row that opens it via '
              'NotificationChannelSettings.open.');
    }

    // The reverse direction: every channel constant the rows mention must be
    // one some code actually creates. A stale id silently rides the Kotlin
    // fallback to the app-level page — the row looks like it works while
    // controlling nothing.
    final mentioned = RegExp(r'\bk[A-Z]\w*Channel\w*\b')
        .allMatches(settingsCode)
        .map((m) => m.group(0)!)
        .toSet();
    for (final id in mentioned) {
      expect(creations.contains(id), isTrue,
          reason: '$id has a Settings row but nothing creates that channel');
    }
  });
}
