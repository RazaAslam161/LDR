import 'dart:async';
import 'dart:math';

import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/realtime/realtime_resume.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Centralised realtime access for the couple's private space.
///
/// Features subscribe to their couple-scoped table changes (or ephemeral
/// broadcast channels) through here instead of hand-rolling channels, so the
/// subscription pattern + couple_id filtering lives in one place. RLS still
/// gates every delivery, so a subscriber only receives rows it may read.
class RealtimeService {
  RealtimeService._();

  static SupabaseClient get _c => SupabaseService.client;

  /// Subscribe to couple-scoped row changes on [table] (filtered by couple_id).
  /// Returns the live channel — call `.unsubscribe()` when done.
  static RealtimeChannel coupleTable({
    required String channelName,
    required String table,
    required String coupleId,
    required void Function(PostgresChangePayload payload) onChange,
    PostgresChangeEvent event = PostgresChangeEvent.all,
  }) {
    return _c
        .channel(channelName, opts: const RealtimeChannelConfig(private: true))
        .onPostgresChanges(
          event: event,
          schema: 'public',
          table: table,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (payload) {
            // Counted as well as delivered. "The partner's row changed and this
            // device was never told" and "this device was told and did nothing
            // with it" are the same symptom from the outside and completely
            // different bugs; only the arrival event separates them.
            Diag.record(DiagArea.presence, 'rt_change',
                corr: coupleId,
                fields: {'table': table, 'event': payload.eventType.name},);
            onChange(payload);
          },
        )
        // subscribe() took no callback here, so its status was discarded — for
        // EVERY couple-scoped subscription in the app, presence included. A
        // channel that lands in CHANNEL_ERROR (an RLS change, an expired token,
        // realtime not enabled for the table) then goes quiet and reports
        // nothing: the poll underneath keeps limping and the user sees a
        // partner who is permanently offline. That is the exact shape of a
        // presence report two full audits failed to reproduce.
        .subscribe((status, err) {
      Diag.record(DiagArea.presence, 'rt_subscribe', corr: coupleId, fields: {
        'table': table,
        'status': status.name,
        if (err != null) 'error': err.runtimeType.toString(),
      },);
      // Diag.record alone was this signal's ONLY sink, and Diag's ring is
      // deliberately test-only (`_capture` is false unless resetForTest turns
      // it on, and nothing in lib/ turns it on). So the callback added to stop
      // a channel failing silently in the field was itself silent in the
      // field — the exact bug it was written to close, one layer up.
      // ErrorReporter is the sink that reaches the server.
      if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        ErrorReporter.report(
          err ?? StateError('realtime $table: ${status.name}'),
          StackTrace.current,
          kind: 'realtime-subscribe',
        );
      }
    });
  }

  /// An ephemeral broadcast channel (e.g. proximity pings, typing) — not
  /// persisted to any table.
  static RealtimeChannel broadcast(String name) => _c.channel(name, opts: const RealtimeChannelConfig(private: true));
}

/// A self-healing realtime subscription — the canonical Pattern A primitive.
///
/// It subscribes once and, on every socket reconnect ([realtimeResumed]), tears
/// the channel down CLEANLY — awaiting `removeChannel(old)` BEFORE re-creating —
/// so it never leaves a duplicate-topic "joined but dead" channel. (Supabase's
/// `channel()` never dedupes by topic and `unsubscribe()` only schedules an async
/// leave, so the old `unsubscribe()` + immediate re-`channel()` pattern created
/// racing dead channels — the app-wide subscription-health bug.) Re-entrancy
/// guarded; safe to dispose mid-reconnect.
///
/// Replaces the hand-rolled `RealtimeChannel _ch; realtimeResumed.addListener(
/// _resubscribe);` boilerplate in screens/notifiers:
/// ```dart
/// _sub = ManagedSubscription.start(() => SupabaseService.client
///     .channel('reach:$coupleId', opts: RealtimeChannelConfig(private: true))
///     .onPostgresChanges(event: ..., callback: _onChange)
///     .subscribe());
/// // ... for a broadcast send: _sub.channel?.sendBroadcastMessage(...)
/// _sub.dispose(); // in State.dispose / Notifier.dispose
/// ```
class ManagedSubscription {
  ManagedSubscription._(this._build);

  /// Builds AND subscribes a fresh channel. Invoked on start + each reconnect.
  final RealtimeChannel Function() _build;
  RealtimeChannel? _channel;
  bool _busy = false;
  bool _disposed = false;

  /// One timer for both jobs — a rebuild is never wanted while a join check is
  /// pending, and vice versa.
  Timer? _timer;
  int _attempt = 0;

  static final _rand = Random();

  /// Longer than the client's 10s join timeout, so a join that is merely slow
  /// is never counted as a failure.
  static const _joinCheck = Duration(seconds: 12);
  static const _maxAttempts = 5;

  static ManagedSubscription start(RealtimeChannel Function() build) {
    final s = ManagedSubscription._(build);
    s._resubscribe();
    realtimeResumed.addListener(s._onResumed);
    return s;
  }

  /// Realtime restarts are routine, and they reconnect every client on the
  /// platform within the same second. This notifier then fans that one tick out
  /// to every subscription in the app at once, so the join rate limiter meets
  /// the whole fleet's channels together and refuses the overflow with a plain
  /// `error` reply — which schedules no rejoin anywhere in the client library.
  /// Spreading the rejoin is what stops a routine restart from leaving a slice
  /// of the fleet with dead channels until the next socket cycle.
  void _onResumed() {
    _attempt = 0;
    _schedule(Duration(milliseconds: _rand.nextInt(1200)), _resubscribe);
  }

  void _schedule(Duration d, void Function() action) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(d, action);
  }

  Future<void> _resubscribe() async {
    if (_disposed || _busy) return;
    _busy = true;
    _timer?.cancel();
    // A reconnect leaves a window in which _channel is null and every send
    // through it is dropped by the `?.` below. Counting them is how a call that
    // failed "for no reason" gets tied to a socket that was rebuilding at the
    // time — and a count that climbs is a flapping socket, which looks like
    // nothing else.
    Diag.record(DiagArea.app, 'rt_resubscribe', fields: {'n': ++_rebuilds});
    try {
      final old = _channel;
      _channel = null;
      if (old != null) {
        try {
          await SupabaseService.client.removeChannel(old);
        } catch (e) {
          Diag.record(DiagArea.app, 'rt_remove_failed',
              fields: {'error': e.runtimeType.toString()},);
        }
      }
      if (_disposed) return;
      _channel = _build();
      _schedule(_joinCheck, _verifyJoin);
    } finally {
      _busy = false;
    }
  }

  /// The channel's own view of its join, and its name.
  ///
  /// Both are marked @internal by realtime_client, and there is no public
  /// alternative: `_build` owns `.subscribe()`, and each of the two dozen call
  /// sites passes its own status handler or none at all, so the channel itself
  /// is the only thing that can answer for all of them. Same standing risk as
  /// `realtime.connect()` in AppShell — a package upgrade may remove it, and
  /// the replacement is a two-phone test, not a deletion.
  // ignore: invalid_use_of_internal_member
  bool get _joined => _channel?.isJoined ?? false;

  // ignore: invalid_use_of_internal_member
  String? get _topic => _channel?.topic;

  /// Did the join actually land?
  ///
  /// A refused join is not retried by the client library — the rate limiter
  /// answers with a plain `error` reply, which schedules nothing — and
  /// `subscribe()` throws on a second call for the same channel, so recovery
  /// has to be a fresh channel, exactly as a reconnect builds one.
  void _verifyJoin() {
    if (_disposed) return;
    if (_joined) {
      _attempt = 0;
      return;
    }
    if (_attempt >= _maxAttempts) {
      // A channel that never joined delivers nothing and looks exactly like a
      // partner who never writes. Nothing else in the app separates them.
      Diag.record(DiagArea.app, 'rt_join_dead',
          fields: {'topic': _topic, 'attempts': _attempt},);
      return;
    }
    // Equal jitter: clients that lost the same socket otherwise retry on the
    // same schedule, which reproduces the storm at every step of the backoff.
    final base = 1000 << _attempt.clamp(0, 4);
    _attempt++;
    Diag.record(DiagArea.app, 'rt_join_retry',
        fields: {'topic': _topic, 'attempt': _attempt},);
    _schedule(
      Duration(milliseconds: base ~/ 2 + _rand.nextInt(base ~/ 2)),
      _resubscribe,
    );
  }

  int _rebuilds = 0;

  /// The live channel — e.g. to send a broadcast. Null until the first subscribe
  /// resolves or while a reconnect is in flight; guard sends with `?.`.
  RealtimeChannel? get channel => _channel;

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    realtimeResumed.removeListener(_onResumed);
    final c = _channel;
    _channel = null;
    if (c != null) SupabaseService.client.removeChannel(c);
  }
}
