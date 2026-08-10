import 'dart:async';

import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/realtime_resume.dart';
import 'package:miles/core/supabase_service.dart';
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
        .channel(channelName)
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
                fields: {'table': table, 'event': payload.eventType.name});
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
      });
    });
  }

  /// A couple-scoped change stream (for providers / StreamBuilder). The channel
  /// is created on first listen and torn down when the last listener cancels.
  static Stream<PostgresChangePayload> coupleStream({
    required String table,
    required String coupleId,
    PostgresChangeEvent event = PostgresChangeEvent.all,
  }) {
    RealtimeChannel? channel;
    late final StreamController<PostgresChangePayload> controller;
    controller = StreamController<PostgresChangePayload>.broadcast(
      onListen: () {
        channel = coupleTable(
          channelName: 'stream:$table:$coupleId:${event.name}',
          table: table,
          coupleId: coupleId,
          event: event,
          onChange: controller.add,
        );
      },
      onCancel: () {
        final c = channel;
        channel = null;
        if (c != null) _c.removeChannel(c);
      },
    );
    return controller.stream;
  }

  /// An ephemeral broadcast channel (e.g. proximity pings, typing) — not
  /// persisted to any table.
  static RealtimeChannel broadcast(String name) => _c.channel(name);
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
///     .channel('reach:$coupleId')
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

  static ManagedSubscription start(RealtimeChannel Function() build) {
    final s = ManagedSubscription._(build);
    s._resubscribe();
    realtimeResumed.addListener(s._resubscribe);
    return s;
  }

  Future<void> _resubscribe() async {
    if (_disposed || _busy) return;
    _busy = true;
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
              fields: {'error': e.runtimeType.toString()});
        }
      }
      if (_disposed) return;
      _channel = _build();
    } finally {
      _busy = false;
    }
  }

  int _rebuilds = 0;

  /// The live channel — e.g. to send a broadcast. Null until the first subscribe
  /// resolves or while a reconnect is in flight; guard sends with `?.`.
  RealtimeChannel? get channel => _channel;

  void dispose() {
    _disposed = true;
    realtimeResumed.removeListener(_resubscribe);
    final c = _channel;
    _channel = null;
    if (c != null) SupabaseService.client.removeChannel(c);
  }
}
