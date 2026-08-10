import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  static Future<void> reach(String coupleId) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c.from('reach_events').insert({
      'couple_id': coupleId,
      'from_user': uid,
    });
  }

  static Future<void> acknowledge(String id) async {
    await _c.from('reach_events').update(
        {'acknowledged_at': DateTime.now().toUtc().toIso8601String()},).eq('id', id);
  }

  static RealtimeChannel subscribe(
    String coupleId,
    void Function(ReachEvent) onReach,
  ) {
    return _c
        .channel('reach_events:$coupleId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'reach_events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (payload) => onReach(ReachEvent.fromJson(payload.newRecord)),
        )
        .subscribe();
  }
}
