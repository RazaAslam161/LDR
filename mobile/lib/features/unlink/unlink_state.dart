import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/services/server_clock.dart';

/// The unlinking ceremony, from this account's side.
///
/// Shaped like SeveranceState: a static holder, a notifier the UI can watch,
/// and `applyRow` split out so every interesting case is reachable without a
/// database. It FAILS OPEN, and open here means EMPTY — a read that did not
/// come back leaves [current] null, so nothing renders; guessing that a
/// ceremony exists would put a countdown on screen that may mean nothing.
///
/// Loaded whenever the account HAS a couple (the mirror of SeveranceState,
/// which loads only when there is none): a paired member reads the row
/// straight through RLS — `couple_id = current_user_couple_id()` — and an
/// unpaired one would be answered with nothing anyway.
class UnlinkState {
  UnlinkState._();

  /// Null when no ceremony is open — which is every couple, almost always.
  static final ValueNotifier<UnlinkRow?> current =
      ValueNotifier<UnlinkRow?>(null);

  static Future<void> load() async {
    try {
      final row = await SupabaseService.client
          .from('couple_unlink')
          .select()
          .maybeSingle()
          .timeout(const Duration(seconds: 10));
      applyRow(row);
    } catch (e) {
      // Named, not swallowed: a banner that silently fails to appear looks
      // identical to a couple with nothing going on, and the difference is a
      // seven-day clock somebody is not being shown.
      debugPrint('[unlink] state unreadable, showing nothing: '
          '${e.runtimeType}');
      applyRow(null);
    }
  }

  @visibleForTesting
  static void applyRow(Map<String, dynamic>? row) {
    UnlinkRow? parsed;
    if (row != null) {
      try {
        parsed = UnlinkRow.fromRow(row);
      } catch (e) {
        debugPrint('[unlink] bad row, showing nothing: ${e.runtimeType}');
      }
    }
    current.value = parsed;
  }

  /// Sign-out, account switch, and the couple ending by any door.
  static void reset() => current.value = null;
}

/// One open ceremony.
@immutable
class UnlinkRow {
  const UnlinkRow({
    required this.coupleId,
    required this.initiatedBy,
    required this.state,
    required this.startedAt,
    required this.coolingEndsAt,
    required this.lastLookEndsAt,
    required this.acceptedAt,
    required this.noteCipherBytea,
    required this.noteNonceBytea,
    required this.noteAuthor,
    required this.noteUpdatedAt,
  });

  factory UnlinkRow.fromRow(Map<String, dynamic> row) => UnlinkRow(
        coupleId: row['couple_id'] as String,
        initiatedBy: row['initiated_by'] as String,
        state: row['state'] as String,
        startedAt: DateTime.parse(row['started_at'] as String).toUtc(),
        coolingEndsAt:
            DateTime.parse(row['cooling_ends_at'] as String).toUtc(),
        lastLookEndsAt: row['last_look_ends_at'] == null
            ? null
            : DateTime.parse(row['last_look_ends_at'] as String).toUtc(),
        acceptedAt: row['accepted_at'] == null
            ? null
            : DateTime.parse(row['accepted_at'] as String).toUtc(),
        noteCipherBytea: row['note_cipher'] as String?,
        noteNonceBytea: row['note_nonce'] as String?,
        noteAuthor: row['note_author'] as String?,
        noteUpdatedAt: row['note_updated_at'] == null
            ? null
            : DateTime.parse(row['note_updated_at'] as String).toUtc(),
      );

  final String coupleId;
  final String initiatedBy;

  /// 'cooling' or 'last_look'.
  final String state;
  final DateTime startedAt;
  final DateTime coolingEndsAt;
  final DateTime? lastLookEndsAt;
  final DateTime? acceptedAt;

  /// The sealed note halves exactly as PostgREST hands them over (bytea wire
  /// form); decoding belongs to the repository so its byteaToBytes rules live
  /// in one place.
  final String? noteCipherBytea;
  final String? noteNonceBytea;
  final String? noteAuthor;
  final DateTime? noteUpdatedAt;

  bool get accepted => state == 'last_look';

  /// The one effective deadline: accepting clamps into the cooling window,
  /// never past it.
  DateTime get endsAt => lastLookEndsAt ?? coolingEndsAt;

  /// Against the SERVER's clock — the deadline was computed by Postgres, and
  /// a handset an hour out would otherwise execute an hour early.
  bool get due => !endsAt.isAfter(ServerClock.now());

  bool iAmInitiator(String uid) => initiatedBy == uid;

  bool get hasNote => noteCipherBytea != null && noteNonceBytea != null;
}
