import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_resume.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The ritual's own ear — because the takeover deafened it.
///
/// The router gate that brings both phones to /unlink UNMOUNTS AppShell, and
/// AppShell holds the app's only `couple_unlink` realtime subscription plus
/// the push drain. So from the moment the ritual began, every beat — the
/// note written, the acceptance, the cancel — arrived on the screen's
/// 15-second fallback poll. For calm text that was a latency wart. For a
/// scene where one phone slides a letter under a door and the other must
/// watch it emerge, it is the difference between a shared moment and two
/// phones telling the same story out of sync.
///
/// TWO rails, one authority:
///
///  * The DATABASE rail — AppShell's subscription, owned by the screen for
///    as long as the ritual holds it. Refetch-only (realtime serializes
///    bytea differently; the note would corrupt if anyone parsed a payload),
///    through ManagedSubscription (a raw channel dies silently on the first
///    reconnect). This rail decides everything.
///  * The BROADCAST rail — `unlink:scene:<coupleId>`, the screen_presence
///    pattern: ~100ms, best-effort, unordered, and allowed to do exactly one
///    thing: start the refetch early. A beat a broadcast announces is a beat
///    the next refetch would have played anyway; one that never arrives
///    costs nothing but the head start. It rides its own channel rather than
///    squatting on screen_presence, whose event grammar and rate limiter
///    belong to another feature.
///
/// The 15s poll in the screen STAYS — it is the floor under both rails.
class UnlinkSceneSync {
  /// Starts listening. [coupleId] scopes both channels; [myUid] is the
  /// self-echo guard on the broadcast rail.
  factory UnlinkSceneSync.start({
    required String coupleId,
    required String myUid,
  }) {
    // The TiltParallax.debugSource seam, for the same reason: widget tests
    // mount the ritual with no Supabase behind it, and faking a socket would
    // test the fake. The 15s poll — the floor these rails sit on — is what
    // the tests exercise instead.
    if (debugDisabled) return UnlinkSceneSync._(null, coupleId, myUid);
    final sub = ManagedSubscription.start(
      () => RealtimeService.coupleTable(
        // Distinct from AppShell's 'unlink:<id>' topic: for the first and
        // last moments of a ceremony both subscriptions are briefly alive,
        // and Supabase never dedupes channels by topic — a shared name would
        // leave one of them joined-but-dead.
        channelName: 'unlink_scene:$coupleId',
        table: 'couple_unlink',
        coupleId: coupleId,
        onChange: (_) => unawaited(UnlinkState.load()),
      ),
    );
    final sync = UnlinkSceneSync._(sub, coupleId, myUid).._openBroadcast();
    // A dozed socket comes back with every raw channel silently dead; the
    // managed rail rebuilds itself, and this rebuilds the broadcast one.
    realtimeResumed.addListener(sync._onResumed);
    return sync;
  }

  UnlinkSceneSync._(this._sub, this._coupleId, this._myUid);

  /// See [UnlinkSceneSync.start].
  @visibleForTesting
  static bool debugDisabled = false;

  final ManagedSubscription? _sub;
  final String _coupleId;
  final String _myUid;
  RealtimeChannel? _cast;
  bool _disposed = false;

  void _onResumed() {
    if (_disposed) return;
    _openBroadcast();
  }

  void _openBroadcast() {
    final old = _cast;
    _cast = null;
    if (old != null) {
      unawaited(SupabaseService.client.removeChannel(old));
    }
    final ch = RealtimeService.broadcast('unlink:scene:$_coupleId')
      ..onBroadcast(event: 'letter', callback: _onNudge)
      ..onBroadcast(event: 'agreed', callback: _onNudge)
      ..subscribe();
    _cast = ch;
  }

  /// Every broadcast means one thing: the row changed, go look. The payload
  /// is never trusted with content — the refetch is the authority, and the
  /// beat dedupe (keyed on the row's own note_updated_at) makes an early
  /// refetch and the poll's later one collapse to a single performance.
  void _onNudge(Map<String, dynamic> payload) {
    if (payload['from'] == _myUid) return; // our own echo
    unawaited(UnlinkState.load());
  }

  /// The letter left our hand — give the far phone its head start.
  void announceLetter() => _send('letter');

  /// We agreed — the far phone should see the bolt slide now, not in 15s.
  void announceAgreed() => _send('agreed');

  void _send(String event) {
    final ch = _cast;
    if (ch == null) return;
    try {
      ch.sendBroadcastMessage(event: event, payload: {'from': _myUid});
    } catch (e) {
      // Logged, never swallowed: a broadcast that dies on this side looks
      // exactly like a partner whose phone never reacted. The refetch rail
      // still carries the truth, a little slower.
      debugPrint('[unlink] $event broadcast failed: ${e.runtimeType}');
    }
  }

  void dispose() {
    _disposed = true;
    realtimeResumed.removeListener(_onResumed);
    final ch = _cast;
    _cast = null;
    if (ch != null) unawaited(SupabaseService.client.removeChannel(ch));
    _sub?.dispose();
  }
}
