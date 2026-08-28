import 'package:miles/core/data/supabase_service.dart';

/// Today's closeness, as the SERVER decided it.
///
/// The screen used to read `desire_temps` directly and work the reveal out in
/// Dart. That put the partner's number on the device on every load and merely
/// declined to draw it — so the one promise this feature makes ("they will not
/// see your number unless you both scored high") was kept by the widget, which
/// is to say not kept at all. `get_closeness` returns
/// `case when v_revealed then v_partner else null end`: when the reveal has not
/// happened, the number never leaves the database.
///
/// The same move takes the other rules off the client, where a modified build
/// could ignore them: the 1–10 range is checked server-side (`bad_score`), the
/// row is upserted under the caller's own `auth.uid()`, and the couple is
/// resolved by `current_user_couple_id()` rather than passed in.
class Closeness {
  const Closeness({
    required this.verdict,
    this.mine,
    this.partner,
    this.revealed = false,
    this.partnerCheckedIn = false,
  });

  factory Closeness.fromJson(Map<String, dynamic> j) => Closeness(
        verdict: j['verdict'] as String? ?? 'unknown',
        mine: (j['mine'] as num?)?.toInt(),
        partner: (j['partner'] as num?)?.toInt(),
        revealed: j['revealed'] as bool? ?? false,
        partnerCheckedIn: j['partner_checked_in'] as bool? ?? false,
      );

  /// `ok`, or why not: `not_authenticated`, `no_couple`, `bad_score`.
  final String verdict;

  /// Your own number for today, or null if you have not set one.
  final int? mine;

  /// Their number — non-null ONLY when the server chose to reveal it.
  final int? partner;
  final bool revealed;

  /// They have set today's number and you have not. Deliberately a boolean:
  /// it never carries the number itself.
  final bool partnerCheckedIn;

  bool get ok => verdict == 'ok';
  bool get submitted => mine != null;
}

class ClosenessRepository {
  /// Both calls return the same shape — `set_closeness` ends with
  /// `return public.get_closeness()` — so one decoder serves both and the
  /// screen never has to re-read after a write.
  static Future<Closeness> today() => _call('get_closeness');

  static Future<Closeness> submit(int score) =>
      _call('set_closeness', {'p_score': score});

  static Future<Closeness> _call(String fn, [Map<String, dynamic>? params]) async {
    final res = await SupabaseService.client.rpc<dynamic>(fn, params: params);
    if (res is! Map) {
      throw StateError('$fn returned ${res.runtimeType}, expected a json object');
    }
    return Closeness.fromJson(Map<String, dynamic>.from(res));
  }
}
