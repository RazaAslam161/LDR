import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Persistent "shuffle bag": deals every prompt in a pool once before any
/// repeat, then reshuffles. Persisted per [key] so daily play doesn't repeat
/// across sessions. Both phones mark prompts seen (on draw + on receiving the
/// partner's draw) so the no-repeat is shared between them.
class NoRepeatBag {
  NoRepeatBag._();
  static final _rng = Random();

  static String _k(String key) => 'nrb_$key';

  /// Draw a random prompt from [pool] not shown recently for [key], mark it
  /// shown, and return it. Resets the cycle once the whole pool is exhausted.
  static Future<String> draw(String key, List<String> pool) async {
    if (pool.isEmpty) return '';
    final prefs = await SharedPreferences.getInstance();
    final seen = (prefs.getStringList(_k(key)) ?? const <String>[]).toSet();
    var remaining = pool.where((p) => !seen.contains(p)).toList();
    if (remaining.isEmpty) {
      seen.clear();
      remaining = List.of(pool);
    }
    final pick = remaining[_rng.nextInt(remaining.length)];
    seen.add(pick);
    await prefs.setStringList(_k(key), seen.toList());
    return pick;
  }

  /// Mark [item] shown without drawing — called when the partner draws, so the
  /// same prompt won't come up again on this device either.
  static Future<void> markSeen(String key, String item) async {
    if (item.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final seen = (prefs.getStringList(_k(key)) ?? const <String>[]).toSet();
    if (seen.add(item)) {
      await prefs.setStringList(_k(key), seen.toList());
    }
  }
}
