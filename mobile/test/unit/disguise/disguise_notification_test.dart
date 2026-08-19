import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/features/disguise/disguise_notification.dart';
import 'package:miles/features/disguise/disguise_profile.dart';

/// Words that only the real app would ever say. If any of them reach a surface
/// the recipient can see — a notification title, or a channel name listed in
/// Android's own settings — the disguise is over, whichever icon is showing.
const _tells = [
  'reach',
  'partner',
  'tethered',
  'miles',
  'couple',
  'love',
  'intimacy',
  // A news app does not place calls. These were missing, which is how the
  // channel "Voice / Incoming voice notifications" and the foreground service's
  // "Ongoing call / Shown while a call is in progress" both passed this test
  // while being listed, permanently, in the settings of the disguised app.
  'call',
  'voice',
  'ringing',
  'dial',
];

void main() {
  group('notification identity', () {
    test('every cover has a style', () {
      for (final cover in DisguiseCover.values) {
        final style = notificationStyleFor(
          DisguiseProfile(
            aliasId: 'X',
            label: 'X',
            blurb: '',
            entry: '',
            about: '',
            icon: kDefaultDisguise.icon,
            tint: kDefaultDisguise.tint,
            cover: cover,
          ),
        );
        expect(style.title, isNotEmpty);
        expect(style.body, isNotEmpty);
        expect(style.smallIcon, startsWith('@'));
      }
    });

    test('no style says anything only the real app would say', () {
      for (final d in kDisguises) {
        final s = notificationStyleFor(d);
        final text = '${s.title} ${s.body}'.toLowerCase();
        for (final tell in _tells) {
          expect(text.contains(tell), isFalse,
              reason: '${d.label} notification leaks "$tell": $text',);
        }
      }
    });

    test("a cover never wears another cover's wording", () {
      // The reported bug: a care reminder arriving on a Calculator phone
      // titled "News update".
      for (final d in kDisguises) {
        final s = notificationStyleFor(d);
        for (final other in kDisguises) {
          if (other.aliasId == d.aliasId) continue;
          expect(s.title.toLowerCase().contains(other.label.toLowerCase()),
              isFalse,
              reason: '${d.label} notification mentions ${other.label}',);
        }
      }
    });

    test('ticker always matches the title', () {
      // Two strings that can drift apart are two chances to disagree.
      for (final d in kDisguises) {
        final s = notificationStyleFor(d);
        expect(s.ticker, s.title);
      }
    });

    test('every notification icon exists as a real Android resource', () {
      // This is the bug this test exists for: the icons were renamed and the
      // Dart still named the old ones. flutter_local_notifications then threw
      // PlatformException(invalid_icon) inside the FCM background isolate and
      // posted NOTHING — invisible from Dart, invisible in analyze, and the
      // user just sees "notifications don't work".
      for (final cover in DisguiseCover.values) {
        final style = notificationStyleFor(
          DisguiseProfile(
            aliasId: 'X',
            label: 'X',
            blurb: '',
            entry: '',
            about: '',
            icon: kDefaultDisguise.icon,
            tint: kDefaultDisguise.tint,
            cover: cover,
          ),
        );
        final m = RegExp(r'^@(drawable|mipmap)/(\w+)$').firstMatch(style.smallIcon);
        expect(m, isNotNull, reason: '${style.smallIcon} is not a resource ref');

        final kind = m!.group(1)!;
        final name = m.group(2)!;
        final found = Directory('android/app/src/main/res')
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.split(RegExp(r'[\\/]')).last.startsWith(kind))
            .any((d) => d
                .listSync()
                .whereType<File>()
                .any((f) => f.uri.pathSegments.last.split('.').first == name),);
        expect(found, isTrue,
            reason: '$cover names ${style.smallIcon}, which does not exist',);
      }
    });

    test('every cover has a manifest meta-data entry for its small icon', () {
      // The call foreground service cannot take a resource name — the plugin
      // resolves its icon through a manifest <meta-data> entry. A cover with no
      // entry falls back to @mipmap/ic_launcher, which Android masks to its
      // alpha channel: a solid white square in the status bar, wearing the News
      // tile whatever cover is on. Nothing in analyze or a build catches it.
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      for (final cover in DisguiseCover.values) {
        final style = notificationStyleFor(
          DisguiseProfile(
            aliasId: 'X',
            label: 'X',
            blurb: '',
            entry: '',
            about: '',
            icon: kDefaultDisguise.icon,
            tint: kDefaultDisguise.tint,
            cover: cover,
          ),
        );
        expect(style.iconMetaData, isNot(startsWith('@')),
            reason: 'a meta-data name is not a resource reference',);
        expect(
          manifest.contains('android:name="${style.iconMetaData}"'),
          isTrue,
          reason: '$cover needs <meta-data android:name="${style.iconMetaData}" '
              'android:resource="${style.smallIcon}" /> in AndroidManifest.xml',
        );
      }
    });

    test('notification icons are protected from the resource shrinker', () {
      // They are named only from Dart, so the shrinker cannot see them.
      final keep = File('android/app/src/main/res/raw/keep.xml');
      expect(keep.existsSync(), isTrue, reason: 'res/raw/keep.xml is missing');
      expect(keep.readAsStringSync(), contains('ic_notif_'));
    });

    test('the icon matches the cover, not the default launcher', () {
      for (final d in kDisguises.where((d) => d.cover != DisguiseCover.news)) {
        final s = notificationStyleFor(d);
        expect(s.smallIcon, isNot('@mipmap/ic_launcher'),
            reason: '${d.label} would show the News icon',);
      }
    });
  });

  group('notification channels', () {
    // Channel names and descriptions are listed in Android's notification
    // settings under whatever the launcher calls this app, so they must be
    // plausible for every disguise — not just the real one.
    final channels = <String, List<String>>{
      'reach': [kReachChannelName, kReachChannelDesc],
      'call': [kCallChannelName, kCallChannelDesc],
      'care': [kCareChannelName, kCareChannelDesc],
      // The call foreground service. Its strings used to live inline in
      // call_foreground.dart, out of this test's sight, and shipped the real
      // app name into Android's notification settings.
      'background_activity': [kCallServiceChannelName, kCallServiceChannelDesc],
      // Created only by the Timer cover, but it is listed in the same place as
      // the rest once it exists.
      'timer': [kTimerChannelName, kTimerChannelDesc],
    };

    test('no channel name or description reveals the app', () {
      channels.forEach((key, strings) {
        for (final s in strings) {
          for (final tell in _tells) {
            expect(s.toLowerCase().contains(tell), isFalse,
                reason: 'the $key channel leaks "$tell": "$s"',);
          }
        }
      });
    });

    test('channel ids stay stable', () {
      // If the ids ever became disguise-specific, switching would have to
      // delete and rebuild them and any notification posted in that window
      // would be lost.
      expect(kReachChannelId, 'reach_channel');
      expect(kCallChannelId, 'call_channel');
      expect(kCareChannelId, 'care_channel');
    });

    test('the retired call-service channel is never posted to again', () {
      // flutter_foreground_task will not rename a channel it already created,
      // so 'call_service' is stuck reading "Ongoing call" forever on any
      // handset that placed a call before this was fixed. It is deleted on
      // start; recreating the id would restore that name from Android's own
      // record of the deleted channel.
      expect(kCallServiceChannelId, isNot(kLegacyCallServiceChannelId));
      expect(kLegacyCallServiceChannelId, 'call_service');
    });
  });
}
