import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/models.dart';

/// The parse and the serialise have to be inverses of each other.
///
/// They were not. `_parseRitualType` matched the enum identifier
/// (`weeklyHighlow`) while `ritualTypeToJson` writes the DB label
/// (`weekly_highlow`), so a "Highs & lows" ritual was stored correctly and read
/// back as [RitualType.custom]. The card then showed a type the user had never
/// chosen, with no error anywhere — the user's "not working what user set".
void main() {
  group('RitualType', () {
    test('every type survives a write/read round trip', () {
      for (final type in RitualType.values) {
        final row = {
          'id': 'r1',
          'couple_id': 'c1',
          'type': ritualTypeToJson(type),
          'delivered': false,
        };
        expect(
          Ritual.fromJson(row).type,
          type,
          reason: '${ritualTypeToJson(type)} did not read back as $type',
        );
      }
    });

    test('the DB enum labels map to the types they name', () {
      // The four labels are fixed by the ritual_type enum in Postgres. If one
      // is renamed there, this fails rather than silently falling back.
      Ritual base(String label) => Ritual.fromJson({
            'id': 'r1',
            'couple_id': 'c1',
            'type': label,
            'delivered': false,
          });

      expect(base('goodnight').type, RitualType.goodnight);
      expect(base('goodmorning').type, RitualType.goodmorning);
      expect(base('weekly_highlow').type, RitualType.weeklyHighlow);
      expect(base('custom').type, RitualType.custom);
    });

    test('an unknown label falls back to custom rather than throwing', () {
      final r = Ritual.fromJson({
        'id': 'r1',
        'couple_id': 'c1',
        'type': 'something_added_later',
        'delivered': false,
      });
      expect(r.type, RitualType.custom);
    });
  });

  group('Ritual delete window', () {
    Ritual withRequest(DateTime? at) => Ritual.fromJson({
          'id': 'r1',
          'couple_id': 'c1',
          'type': 'goodnight',
          'delivered': false,
          'delete_requested': true,
          'delete_requested_at': at?.toIso8601String(),
        });

    test('is closed while the request is fresh', () {
      final r = withRequest(
        DateTime.now().toUtc().subtract(const Duration(days: 3)),
      );
      expect(r.deleteWindowElapsed, isFalse);
    });

    test('opens once the server would accept a solo confirm', () {
      final r = withRequest(
        DateTime.now().toUtc().subtract(const Duration(days: 15)),
      );
      expect(r.deleteWindowElapsed, isTrue);
    });

    test('is closed when the server never recorded a timestamp', () {
      expect(withRequest(null).deleteWindowElapsed, isFalse);
    });
  });
}
