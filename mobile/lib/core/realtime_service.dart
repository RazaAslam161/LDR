import 'dart:async';

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
          callback: onChange,
        )
        .subscribe();
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
      onCancel: () => channel?.unsubscribe(),
    );
    return controller.stream;
  }

  /// An ephemeral broadcast channel (e.g. proximity pings, typing) — not
  /// persisted to any table.
  static RealtimeChannel broadcast(String name) => _c.channel(name);
}
