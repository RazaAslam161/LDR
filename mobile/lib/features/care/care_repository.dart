import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CareNudge {
  CareNudge({
    required this.id,
    required this.fromUser,
    required this.kind,
    required this.message,
    required this.createdAt,
    this.acknowledgedAt,
  });

  factory CareNudge.fromJson(Map<String, dynamic> j) => CareNudge(
        id: JsonUtils.parseString(j['id']),
        fromUser: JsonUtils.parseString(j['from_user']),
        kind: JsonUtils.parseString(j['kind']),
        message: JsonUtils.parseString(j['message']),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
        acknowledgedAt:
            JsonUtils.parseDateOrNull(j['acknowledged_at'])?.toLocal(),
      );

  final String id;
  final String fromUser;
  final String kind;
  final String message;
  final DateTime createdAt;
  final DateTime? acknowledgedAt;

  bool isMine(String? uid) => fromUser == uid;
  bool get acknowledged => acknowledgedAt != null;
}

class CareRepository {
  CareRepository._();

  static final _c = SupabaseService.client;

  static Future<void> send({
    required String coupleId,
    required String fromUser,
    required String kind,
    required String message,
  }) async {
    await _c.from('care_nudges').insert({
      'couple_id': coupleId,
      'from_user': fromUser,
      'kind': kind,
      'message': message,
    });
  }

  /// Recipient marks a nudge done.
  static Future<void> acknowledge(String id) async {
    await _c.from('care_nudges').update({
      'acknowledged_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', id);
  }

  /// One page of reminders. 50 is what the screen opens on.
  static const pageSize = 50;

  /// [before] pages further back, cursored on the same column the list is
  /// ordered by. The screen showed the newest 50 and had no way to reach
  /// anything behind them — which for a couple who use this daily is under
  /// three weeks, inside the 30-day retention window, so reminders that still
  /// EXISTED were unreachable.
  static Future<List<CareNudge>> list(String coupleId,
      {DateTime? before,}) async {
    var q = _c.from('care_nudges').select().eq('couple_id', coupleId);
    if (before != null) {
      q = q.lt('created_at', before.toUtc().toIso8601String());
    }
    final res =
        await q.order('created_at', ascending: false).limit(pageSize);
    return (res as List)
        .map((e) => CareNudge.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  static RealtimeChannel subscribe(String coupleId, void Function() onChange) {
    return _c
        .channel('care_nudges:$coupleId', opts: const RealtimeChannelConfig(private: true))
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'care_nudges',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (_) => onChange(),
        )
        .subscribe();
  }
}
