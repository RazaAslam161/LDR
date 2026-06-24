import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BodyTouch {
  BodyTouch({
    required this.id,
    required this.fromUser,
    required this.zone,
    required this.type,
    required this.createdAt,
  });

  factory BodyTouch.fromJson(Map<String, dynamic> j) => BodyTouch(
        id: JsonUtils.parseString(j['id']),
        fromUser: JsonUtils.parseString(j['from_user']),
        zone: JsonUtils.parseString(j['body_zone']),
        type: JsonUtils.parseString(j['touch_type'], fallback: 'glow'),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
      );

  final String id;
  final String fromUser;
  final String zone;
  final String type;
  final DateTime createdAt;

  bool isMine(String? uid) => fromUser == uid;
}

/// Ephemeral touch glows. Rows auto-expire (`expires_at`) — we never read old
/// ones; we just listen for live inserts and animate them.
class TouchMapRepository {
  TouchMapRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  static Future<void> sendTouch({
    required String coupleId,
    required String zone,
    required String type,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c.from('body_touches').insert({
      'couple_id': coupleId,
      'from_user': uid,
      'body_zone': zone,
      'touch_type': type,
    });
  }

  static RealtimeChannel subscribe(
    String coupleId,
    void Function(BodyTouch) onTouch,
  ) {
    return _c
        .channel('body_touches:$coupleId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'body_touches',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (payload) => onTouch(BodyTouch.fromJson(payload.newRecord)),
        )
        .subscribe();
  }
}
