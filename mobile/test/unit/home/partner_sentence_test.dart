import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/features/home/partner_sentence.dart';

/// The rule this file exists to enforce: every line is TRUE or it does not
/// render. A map that says "asleep" while she is typing to you has not made a
/// small error.
void main() {
  setUpAll(TzHelper.ensureInit);

  Profile p({String? tz, String? wake, String? sleep}) => Profile(
        id: 'her',
        displayName: 'Sara',
        timezone: tz ?? '',
        presenceStatus: PresenceStatus.awake,
        createdAt: DateTime.utc(2026),
        wakeTime: wake,
        sleepTime: sleep,
      );

  Presence pres({DateTime? active, double? lon}) => Presence(
        userId: 'her',
        appLastActiveAt: active,
        longitude: lon,
        latitude: lon == null ? null : 0,
      );

  // 2026-08-13 18:00 UTC = 23:00 in Karachi (UTC+5)
  final t18utc = DateTime.utc(2026, 8, 13, 18);

  group('being in the app beats every inference', () {
    test('never says asleep while she is actively in the app', () {
      final s = partnerSentence(
        presence: pres(active: t18utc.subtract(const Duration(minutes: 1))),
        // A schedule that would otherwise say "asleep" at 23:00.
        partner: p(tz: 'Asia/Karachi', wake: '07:00', sleep: '22:00'),
        myTimezone: 'Asia/Karachi',
        partnerName: 'Sara',
        now: t18utc,
      );
      expect(s.text, contains('here'));
      expect(s.text.toLowerCase(), isNot(contains('asleep')));
    });

    test('an old activity stamp does not suppress the schedule', () {
      final s = partnerSentence(
        presence: pres(active: t18utc.subtract(const Duration(hours: 3))),
        partner: p(tz: 'Asia/Karachi', wake: '07:00', sleep: '22:00'),
        myTimezone: 'Asia/Karachi',
        partnerName: 'Sara',
        now: t18utc,
      );
      expect(s.text, contains('asleep'));
    });
  });

  group('the sleep window wraps midnight', () {
    test('23:00-07:00 counts 2am as asleep', () {
      // 21:00 UTC = 02:00 Karachi
      final s = partnerSentence(
        presence: pres(),
        partner: p(tz: 'Asia/Karachi', wake: '07:00', sleep: '23:00'),
        myTimezone: 'Asia/Karachi',
        partnerName: 'Sara',
        now: DateTime.utc(2026, 8, 13, 21),
      );
      expect(s.text, contains('asleep'));
    });

    test('23:00-07:00 counts 6pm as awake', () {
      // 13:00 UTC = 18:00 Karachi
      final s = partnerSentence(
        presence: pres(),
        partner: p(tz: 'Asia/Karachi', wake: '07:00', sleep: '23:00'),
        myTimezone: 'Asia/Karachi',
        partnerName: 'Sara',
        now: DateTime.utc(2026, 8, 13, 13),
      );
      expect(s.text.toLowerCase(), isNot(contains('asleep')));
    });
  });

  group('a half-schedule decides nothing', () {
    test('a wake time with no sleep time never claims asleep or awake', () {
      final s = partnerSentence(
        presence: pres(),
        partner: p(tz: 'Asia/Karachi', wake: '07:00'),
        myTimezone: 'America/Toronto',
        partnerName: 'Sara',
        now: t18utc,
      );
      expect(s.text.toLowerCase(), isNot(contains('asleep')));
      expect(s.text.toLowerCase(), isNot(contains('both awake')));
      // Falls through to the honest one: the time, and the gap.
      expect(s.text, contains("it's"));
    });
  });

  group('a stale timezone is hedged, not asserted', () {
    test('longitude far from the declared zone lowers confidence', () {
      // Declared Karachi (+5) but the shared position is in Toronto (-79 lon,
      // solar offset about -5.3h). She flew and the profile did not.
      final s = partnerSentence(
        presence: pres(lon: -79),
        partner: p(tz: 'Asia/Karachi', wake: '07:00', sleep: '23:00'),
        myTimezone: 'Asia/Karachi',
        partnerName: 'Sara',
        now: t18utc,
      );
      expect(s.confident, isFalse);
      expect(s.text, contains('around'));
      // And it must not go on to assert a sleep state built on that zone.
      expect(s.text.toLowerCase(), isNot(contains('asleep')));
    });

    test('a longitude that agrees with the zone does not hedge', () {
      final s = partnerSentence(
        presence: pres(lon: 67), // Karachi
        partner: p(tz: 'Asia/Karachi', wake: '07:00', sleep: '23:00'),
        myTimezone: 'Asia/Karachi',
        partnerName: 'Sara',
        now: t18utc,
      );
      expect(s.confident, isTrue);
    });
  });

  group('no data says so plainly', () {
    test('no timezone at all', () {
      final s = partnerSentence(
        presence: pres(),
        partner: p(),
        myTimezone: 'Asia/Karachi',
        partnerName: 'Sara',
        now: t18utc,
      );
      expect(s.text, 'Sara is somewhere');
      expect(s.confident, isFalse);
    });
  });

  group('the offset is not rounded to whole hours', () {
    test('a half-hour zone is reported as a half hour', () {
      // Karachi +5:00 to Kolkata +5:30 is thirty minutes, and the old helper
      // rounded that to "0h" or "1h" depending on the pair.
      final label = TzHelper.offsetLabel('Asia/Karachi', 'Asia/Kolkata');
      expect(label, contains('30m'));
      expect(label, contains('ahead'));
    });

    test('a whole-hour zone does not say 0m', () {
      final label = TzHelper.offsetLabel('Asia/Karachi', 'Asia/Dubai');
      expect(label, isNot(contains('0m')));
    });

    test('the same zone is same time', () {
      expect(TzHelper.offsetLabel('Asia/Karachi', 'Asia/Karachi'), 'same time');
    });
  });
}
