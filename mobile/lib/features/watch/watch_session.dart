import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:miles/features/watch/watch_source.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What the couple is watching, as the server holds it.
///
/// The screen used to keep this in widget state alone, so it died with the
/// route: leaving Watch Together for ten seconds ended the session for BOTH of
/// them, and a partner who arrived late saw an empty box because the `load`
/// broadcast had already been delivered to nobody.
///
/// A broadcast is a message to whoever is listening RIGHT NOW. A session is a
/// fact that outlives both of their attention spans, so it belongs in a row.
class WatchSession {
  const WatchSession({
    required this.source,
    required this.startedBy,
    required this.startedAt,
  });

  final WatchSource source;
  final String? startedBy;
  final DateTime startedAt;

  static WatchSession? fromJson(Map<String, dynamic> j) {
    final source = sourceFromKey(
      JsonUtils.parseString(j['source_key']),
      startAt: Duration(milliseconds: (j['start_ms'] as num?)?.toInt() ?? 0),
    );
    if (source == null) return null;
    return WatchSession(
      source: source,
      startedBy: JsonUtils.parseStringOrNull(j['started_by']),
      startedAt: JsonUtils.parseDate(j['started_at']).toUtc(),
    );
  }
}

class WatchSessionRepository {
  WatchSessionRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  /// What is open right now, or null.
  static Future<WatchSession?> current(String coupleId) async {
    try {
      final row = await _c
          .from('watch_sessions')
          .select('source_key,kind,site,start_ms,started_by,started_at')
          .eq('couple_id', coupleId)
          .maybeSingle();
      return row == null ? null : WatchSession.fromJson(JsonUtils.asMap(row));
    } catch (e) {
      debugPrint('[watch] current: ${e.runtimeType}');
      return null;
    }
  }

  /// Opens [source] for the couple, replacing whatever was open.
  ///
  /// Upsert on the couple key: picking something else already means replacing
  /// it, and two rows would be two answers to "what are we watching".
  static Future<void> open({
    required String coupleId,
    required String startedBy,
    required WatchSource source,
  }) async {
    try {
      await _c.from('watch_sessions').upsert({
        'couple_id': coupleId,
        'source_key': source.key,
        'kind': source.kind.name,
        'site': source.site,
        'start_ms': source.startAt.inMilliseconds,
        'started_by': startedBy,
        'started_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      // The session still plays locally and the broadcast still fires; losing
      // the row costs persistence, not playback.
      debugPrint('[watch] open: ${e.runtimeType}');
    }
  }

  /// Closes it for both. Deliberately NOT called from dispose — leaving the
  /// screen is the thing that used to end the session, and is exactly what must
  /// stop doing so.
  static Future<void> close(String coupleId) async {
    try {
      await _c.from('watch_sessions').delete().eq('couple_id', coupleId);
    } catch (e) {
      debugPrint('[watch] close: ${e.runtimeType}');
    }
  }
}
