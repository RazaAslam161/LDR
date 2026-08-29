import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/features/unlink/unlink_repository.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The ceremony completing, in the one place both callers can reach.
///
/// It has TWO callers, and that is the point. AppShell drove this alone until
/// the ritual became a router gate — and a gate that redirects to /unlink
/// UNMOUNTS AppShell, taking `_offerUnlink`, the realtime subscription and the
/// push drain with it. A phone parked on the ritual screen at the deadline
/// would have sat there with a stale row and nothing left running to notice:
/// the takeover would have disabled its own completion.
///
/// So UnlinkScreen drives it too, and the teardown lives here rather than
/// being written twice. The order is pinned — RPC, then local teardown, then
/// reload — the same shape `_endConnection` uses with leaveCouple in the RPC's
/// seat.
///
/// `unlink_execute()` is silent rather than throwing when there is nothing to
/// do (the cron job or the other phone got there first), so the local teardown
/// still runs and this phone catches up either way.
Future<void> completeUnlink(WidgetRef ref, String coupleId) async {
  try {
    await UnlinkRepository.execute();
  } catch (e) {
    // not_yet is a clock argument the server wins; anything else is transient.
    // The next tick, resume or launch simply tries again — and past the
    // deadline the per-minute unlink-expire-due job is doing it regardless.
    debugPrint('[unlink] execute refused: ${e.runtimeType}');
    return;
  }
  UnlinkState.reset();
  final session = ref.read(sessionProvider.notifier);
  try {
    await session.endCouple(coupleId);
  } finally {
    await session.loadProfile();
  }
  // The router's needsCouple gate carries this phone to /couple.
}
