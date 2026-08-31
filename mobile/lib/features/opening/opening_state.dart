import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';

/// Whether the Opening has already played for THIS person, and the two writes
/// that record it.
///
/// The table takes no client writes at all — both verbs are SECURITY DEFINER
/// RPCs that derive the couple from `auth.uid()`, so a client cannot claim a
/// couple it is not in.
class OpeningRepository {
  OpeningRepository._();

  /// Stamped when the film BEGINS, not when it ends.
  ///
  /// This is the whole reason an interrupted viewing cannot re-trap anyone:
  /// once it has started even once, the automatic play is spent — whether they
  /// watched it, skipped it, backgrounded it, or the process was killed.
  static Future<void> markStarted() =>
      SupabaseService.client.rpc<void>('mark_intro_started');

  /// Only decides whether Settings says "Watch again" or "Finish watching".
  /// It never gates the automatic play.
  static Future<void> markFinished() =>
      SupabaseService.client.rpc<void>('mark_intro_finished');

  /// True when the film should play by itself, right now.
  ///
  /// FAILS CLOSED, deliberately. If the row cannot be read — offline, RLS
  /// surprise, project paused — this answers false and the film does not play.
  /// The two failure modes are not symmetrical: not playing costs a first-run
  /// flourish that Settings can still reach, while playing on a failed read
  /// costs the same film again on every launch a network is flaky, which is
  /// exactly the trap the previous intro video was deleted for.
  static Future<bool> shouldAutoPlay() async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return false;
    try {
      final row = await SupabaseService.client
          .from('couple_intro_seen')
          .select('started_at')
          .eq('user_id', uid)
          .maybeSingle();
      return row == null;
    } catch (e) {
      debugPrint('opening: could not read couple_intro_seen, not playing: $e');
      return false;
    }
  }
}
