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
      // ritual somebody is being held inside without being shown.
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
    // A fresh ceremony clears the one-shot latch. _released() normally clears
    // it as it reads it, but it only runs while the screen is alive — a phone
    // that executed the unlink with UnlinkScreen already gone would otherwise
    // carry `endedHere` true into the NEXT couple's ceremony and play the
    // parting film over their re-link.
    if (parsed != null) endedHere = false;
    current.value = parsed;
  }

  /// Sign-out, account switch, and the couple ending by any door.
  /// True when THIS phone ran `unlink_execute()` — the couple is gone, and this
  /// device is the one that ended it.
  ///
  /// It is a FACT rather than something to infer, because inferring it raced.
  /// [reset] fires [current]'s listeners synchronously, so UnlinkScreen's
  /// `_released()` runs inside the `reset()` call — before completeUnlink's own
  /// `endCouple`/`loadProfile` have touched the session providers. Its
  /// `currentCoupleProvider` read therefore still answered "there is a couple",
  /// and the phone that had just irreversibly dissolved the relationship played
  /// the RE-LINK ending: the reunion film and the "door opens" cue, at the
  /// exact moment of the breakup.
  ///
  /// One-shot: `_released()` clears it as soon as it has read it.
  static bool endedHere = false;

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
    required this.relinkOpensAt,
    required this.partnerGateOpensAt,
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
        // Both gates default to started_at + 15 minutes when the column is
        // absent or null — which is exactly what a row written by the previous
        // server means, and what the server itself falls back to in
        // unlink_accept(). A missing gate must never read as "open now".
        relinkOpensAt: _gate(row['relink_opens_at'], row['started_at']),
        partnerGateOpensAt:
            _gate(row['partner_gate_opens_at'], row['started_at']),
        noteCipherBytea: row['note_cipher'] as String?,
        noteNonceBytea: row['note_nonce'] as String?,
        noteAuthor: row['note_author'] as String?,
        noteUpdatedAt: row['note_updated_at'] == null
            ? null
            : DateTime.parse(row['note_updated_at'] as String).toUtc(),
      );

  /// A gate, or the 15 minutes after [started] that a null one stands for.
  static DateTime _gate(Object? raw, Object? started) => raw == null
      ? DateTime.parse(started! as String).toUtc().add(_gateWait)
      : DateTime.parse(raw as String).toUtc();

  static const _gateWait = Duration(minutes: 15);

  final String coupleId;
  final String initiatedBy;

  /// 'cooling' or 'last_look'.
  final String state;
  final DateTime startedAt;
  final DateTime coolingEndsAt;
  final DateTime? lastLookEndsAt;
  final DateTime? acceptedAt;

  /// When the initiator's Re-link button appears, and when the partner may
  /// agree. Both anchored to the ceremony's own start on the SERVER clock —
  /// never to when a screen was first opened, so a partner who first looks
  /// twenty hours in does not get a fresh fifteen-minute wait.
  final DateTime relinkOpensAt;
  final DateTime partnerGateOpensAt;

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

  /// The initiator's way back is visible. The wait is a ritual and lives here,
  /// in the UI: unlink_cancel() is deliberately ungated on the server, because
  /// cancelling destroys nothing and a gated cancel would be a button that
  /// throws for the first fifteen minutes of every ceremony.
  bool get relinkOpen => !relinkOpensAt.isAfter(ServerClock.now());

  /// The partner may agree. This one IS enforced by the server, because this
  /// direction destroys.
  bool get partnerGateOpen => !partnerGateOpensAt.isAfter(ServerClock.now());

  /// Both of them chose it. Five minutes, one button.
  bool get lastCall => state == 'last_look';

  bool iAmInitiator(String uid) => initiatedBy == uid;

  bool get hasNote => noteCipherBytea != null && noteNonceBytea != null;
}
