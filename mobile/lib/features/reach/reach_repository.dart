import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The id of a Reach THIS handset sent that the partner just answered with
/// "I'm here". Set by the shell's reach_events UPDATE subscription; read by
/// the button that sent it. For two months the answer was written to a row
/// nobody re-read: the sender subscribed to inserts only.
final ValueNotifier<String?> reachAcknowledged = ValueNotifier<String?>(null);

class ReachEvent {
  ReachEvent({
    required this.id,
    required this.fromUser,
    required this.createdAt,
    required this.expiresAt,
    this.acknowledgedAt,
  });

  factory ReachEvent.fromJson(Map<String, dynamic> j) => ReachEvent(
        id: JsonUtils.parseString(j['id']),
        fromUser: JsonUtils.parseString(j['from_user']),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
        expiresAt: JsonUtils.parseDate(j['expires_at']).toLocal(),
        acknowledgedAt: JsonUtils.parseDateOrNull(j['acknowledged_at']),
      );

  final String id;
  final String fromUser;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? acknowledgedAt;

  bool isMine(String? uid) => fromUser == uid;
  bool get isActive => expiresAt.isAfter(DateTime.now());
}

class ReachRepository {
  ReachRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  /// Sends a Reach and returns its id, so the sender can recognise the
  /// partner's acknowledgement when it arrives over the UPDATE rail.
  static Future<String?> reach(String coupleId) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;
    final row = await _c
        .from('reach_events')
        .insert({
          'couple_id': coupleId,
          'from_user': uid,
        })
        .select('id')
        .single();
    return JsonUtils.parseString(row['id']);
  }

  /// One row, or null when it is gone. The push path asks this before it
  /// shows the overlay: a notification tapped minutes later must not open
  /// a Reach that expired at thirty seconds.
  static Future<ReachEvent?> fetch(String id) async {
    final row = await _c.from('reach_events').select().eq('id', id).maybeSingle();
    return row == null ? null : ReachEvent.fromJson(row);
  }

  /// How long the server will refuse the next Reach, in seconds; 0 when clear.
  ///
  /// The limit is a BEFORE INSERT trigger on reach_events (migration
  /// 20260601007700), so this is the only number that describes what the next
  /// insert will actually do — the widget's own countdown described nothing but
  /// itself. Seconds rather than a deadline: the countdown then needs the
  /// device's clock rate and never its absolute time.
  static Future<int> cooldownSeconds() async {
    final seconds = await _c.rpc<dynamic>('reach_cooldown_seconds');
    return JsonUtils.parseInt(seconds);
  }

  static Future<void> acknowledge(String id) async {
    await _c.from('reach_events').update(
        {'acknowledged_at': DateTime.now().toUtc().toIso8601String()},).eq('id', id);
  }

  /// Inserts ring the partner; UPDATEs carry the partner's "I'm here" back to
  /// the sender ([onAck], every row of the couple that changed — the caller
  /// keeps the ones it sent).
  static RealtimeChannel subscribe(
    String coupleId,
    void Function(ReachEvent) onReach, {
    void Function(ReachEvent)? onAck,
  }) {
    final filter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'couple_id',
      value: coupleId,
    );
    var channel = _c
        .channel('reach_events:$coupleId', opts: const RealtimeChannelConfig(private: true))
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'reach_events',
          filter: filter,
          callback: (payload) => onReach(ReachEvent.fromJson(payload.newRecord)),
        );
    if (onAck != null) {
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'reach_events',
        filter: filter,
        callback: (payload) => onAck(ReachEvent.fromJson(payload.newRecord)),
      );
    }
    return channel.subscribe();
  }
}
