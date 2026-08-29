import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/unlink/unlink_quotes.dart';

/// The re-link screen's words, held to the love-notes pool's rules.
void main() {
  test('the pool is big enough that a week never repeats a day', () {
    expect(unlinkQuotePool.length, greaterThanOrEqualTo(60));
  });

  test('every entry has words and a name to stand behind them', () {
    for (final q in unlinkQuotePool) {
      expect(q.text.trim(), isNotEmpty);
      expect(q.author.trim(), isNotEmpty,
          reason: 'attribution is part of the public-domain law',);
    }
  });

  test('no real names — the love-notes rule applies here too', () {
    for (final q in unlinkQuotePool) {
      for (final banned in ['Zunaira', 'Raza', 'Mrs ', 'Mr ']) {
        expect(q.text.contains(banned), isFalse, reason: q.text);
      }
    }
  });

  test('deterministic: both phones show the same words on the same day', () {
    final a = unlinkQuoteForDay(DateTime.utc(2026, 9, 1, 3));
    final b = unlinkQuoteForDay(DateTime.utc(2026, 9, 1, 22));
    expect(a, b, reason: 'two timezones, one UTC day, one quote');
    // And days actually rotate.
    final days = <String>{
      for (var d = 1; d <= 10; d++)
        unlinkQuoteForDay(DateTime.utc(2026, 9, d)).text,
    };
    expect(days.length, greaterThan(1));
  });
}
