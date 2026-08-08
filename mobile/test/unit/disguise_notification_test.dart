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
              reason: '${d.label} notification leaks "$tell": $text');
        }
      }
    });

    test('a cover never wears another cover\'s wording', () {
      // The reported bug: a care reminder arriving on a Calculator phone
      // titled "News update".
      for (final d in kDisguises) {
        final s = notificationStyleFor(d);
        for (final other in kDisguises) {
          if (other.aliasId == d.aliasId) continue;
          expect(s.title.toLowerCase().contains(other.label.toLowerCase()),
              isFalse,
              reason: '${d.label} notification mentions ${other.label}');
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

    test('the icon matches the cover, not the default launcher', () {
      for (final d in kDisguises.where((d) => d.cover != DisguiseCover.news)) {
        final s = notificationStyleFor(d);
        expect(s.smallIcon, isNot('@mipmap/ic_launcher'),
            reason: '${d.label} would show the News icon');
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
    };

    test('no channel name or description reveals the app', () {
      channels.forEach((key, strings) {
        for (final s in strings) {
          for (final tell in _tells) {
            expect(s.toLowerCase().contains(tell), isFalse,
                reason: 'the $key channel leaks "$tell": "$s"');
          }
        }
      });
    });

    test('channel ids stay stable', () {
      // A channel's name is fixed at creation. If the ids ever became
      // disguise-specific, switching would have to delete and rebuild them and
      // any notification posted in that window would be lost.
      expect(kReachChannelId, 'reach_channel');
      expect(kCallChannelId, 'call_channel');
      expect(kCareChannelId, 'care_channel');
    });
  });
}
