import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/utils/json_utils.dart';

/// Issue 3 regression tests: a malformed row must never throw — it should fall
/// back gracefully so one bad record can't crash a whole list.
void main() {
  group('JsonUtils.parseDate', () {
    test('parses a valid ISO string', () {
      expect(JsonUtils.parseDate('2026-06-24T10:00:00Z').year, 2026);
    });
    test('passes through a DateTime', () {
      final d = DateTime(2020, 1, 2);
      expect(JsonUtils.parseDate(d), d);
    });
    test('null falls back to provided fallback', () {
      final fb = DateTime(1999);
      expect(JsonUtils.parseDate(null, fallback: fb), fb);
    });
    test('garbage falls back instead of throwing', () {
      final fb = DateTime(1999);
      expect(JsonUtils.parseDate('not-a-date', fallback: fb), fb);
    });
    test('parseDateOrNull returns null for null/garbage', () {
      expect(JsonUtils.parseDateOrNull(null), isNull);
      expect(JsonUtils.parseDateOrNull('nope'), isNull);
    });
  });

  group('JsonUtils.parseInt / parseDouble', () {
    test('int passthrough', () => expect(JsonUtils.parseInt(5), 5));
    test('numeric string (Supabase quirk)', () {
      expect(JsonUtils.parseInt('42'), 42);
      expect(JsonUtils.parseDouble('3.5'), 3.5);
    });
    test('double to int truncates', () => expect(JsonUtils.parseInt(3.9), 3));
    test('garbage falls back', () {
      expect(JsonUtils.parseInt('x', fallback: 7), 7);
      expect(JsonUtils.parseDouble(null, fallback: 1.5), 1.5);
    });
  });

  group('JsonUtils.parseString', () {
    test('null → fallback', () => expect(JsonUtils.parseString(null), ''));
    test('coerces non-strings', () => expect(JsonUtils.parseString(7), '7'));
    test('parseStringOrNull keeps null', () {
      expect(JsonUtils.parseStringOrNull(null), isNull);
    });
  });

  group('JsonUtils.parseBool', () {
    test('bool passthrough', () => expect(JsonUtils.parseBool(true), true));
    test('string forms', () {
      expect(JsonUtils.parseBool('true'), true);
      expect(JsonUtils.parseBool('f'), false);
      expect(JsonUtils.parseBool('1'), true);
    });
    test('num forms', () => expect(JsonUtils.parseBool(0), false));
    test('garbage falls back', () {
      expect(JsonUtils.parseBool('maybe', fallback: true), true);
    });
  });

  group('JsonUtils.parseList', () {
    test('skips non-map elements, never throws', () {
      final input = [
        {'v': 1},
        'oops',
        null,
        {'v': 2},
      ];
      final out = JsonUtils.parseList<int>(
          input, (m) => JsonUtils.parseInt(m['v']),);
      expect(out, [1, 2]);
    });
    test('non-list → empty', () {
      expect(JsonUtils.parseList<int>('nope', (_) => 0), isEmpty);
    });
  });

  group('JsonUtils.parseObject', () {
    test('null → null', () {
      expect(JsonUtils.parseObject<int>(null, (_) => 0), isNull);
    });
    test('map → parsed', () {
      expect(
        JsonUtils.parseObject<int>({'v': 9}, (m) => JsonUtils.parseInt(m['v'])),
        9,
      );
    });
  });
}
