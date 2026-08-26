import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/services/server_clock.dart';

/// What is left of a couple that ended, from this account's side.
///
/// Shaped like ContactPause: a static holder, a notifier the UI can watch,
/// and an `applyRow` split out so the interesting cases are reachable without a
/// database. Two differences, both deliberate:
///
///   · It FAILS OPEN, and open here means EMPTY. A read that did not come back
///     leaves [held] null, so nothing renders. The alternative — guessing that
///     something is recoverable — puts a control on screen that may do nothing,
///     which is the one thing this whole design refuses to do.
///
///   · It is loaded only when there is no couple. Paired accounts never call
///     it and the server would answer null for them anyway.
///
/// Nothing here is a notification. The server answers the same null for "never
/// had a couple", "they ended it for good", "the window closed" and "you have
/// somebody new", so an ex can learn nothing from it that they did not already
/// know by being able to ask.
class SeveranceState {
  SeveranceState._();

  /// Null when there is nothing to show — which is most accounts, most of the
  /// time, and every account whose read failed.
  static final ValueNotifier<HeldHistory?> held =
      ValueNotifier<HeldHistory?>(null);

  static Future<void> load() async {
    try {
      final row = await SupabaseRepository.coupleRestoreState()
          .timeout(const Duration(seconds: 10));
      applyRow(row);
    } catch (e) {
      // Named, not swallowed. A screen that silently shows nothing looks
      // identical to a screen that correctly has nothing to show, and the
      // difference is whether somebody's history is about to be erased
      // without them being offered the choice.
      debugPrint('[severance] state unreadable, showing nothing: '
          '${e.runtimeType}');
      applyRow(null);
    }
  }

  @visibleForTesting
  static void applyRow(Map<String, dynamic>? row) {
    held.value = row == null ? null : HeldHistory.fromRow(row);
  }

  /// Sign-out and account switch. Device-scoped state that outlives an account
  /// is how one person's history ends up described to the next one.
  static void reset() => applyRow(null);
}

/// One dissolved couple, and where the two of them have got to about it.
@immutable
class HeldHistory {
  const HeldHistory({
    required this.coupleId,
    required this.purgeAt,
    required this.requestIsMine,
    required this.awaitingMe,
    required this.confirmed,
    required this.declined,
  });

  factory HeldHistory.fromRow(Map<String, dynamic> row) => HeldHistory(
        coupleId: row['couple_id'] as String,
        purgeAt: DateTime.parse(row['expires_at'] as String).toUtc(),
        requestIsMine: row['request_is_mine'] as bool?,
        awaitingMe: row['awaiting_me'] as bool?,
        confirmed: row['confirmed'] == true,
        declined: row['declined'] == true,
      );

  /// The couple the ceremony still belongs to. While unpaired this is the only
  /// place the id survives — profiles.couple_id is null on both sides and
  /// couple_members is own-rows-only, so nothing else will name it.
  final String coupleId;

  /// When the shared history is erased. Against the SERVER's clock — the
  /// expiry was computed by Postgres, and a handset an hour out would otherwise
  /// offer a way back an hour after there is one, or withdraw it an hour early.
  final DateTime purgeAt;

  /// Null when nobody has asked yet.
  final bool? requestIsMine;

  /// True only when the OTHER one asked and it is still open. This is the only
  /// field that should ever produce a prompt.
  final bool? awaitingMe;

  final bool confirmed;
  final bool declined;

  bool get expired => !purgeAt.isAfter(ServerClock.now());

  /// Nobody has asked, or the last ask was closed and this account is free to
  /// make one. The server is the authority — it refuses a second ask from
  /// somebody who was turned down — so this only decides what to draw.
  bool get canAsk {
    final mine = requestIsMine;
    return mine == null || (declined && !mine);
  }

  /// An ask of this account's own, still waiting on the other one.
  bool get waitingOnThem =>
      (requestIsMine ?? false) && !confirmed && !declined;
}
