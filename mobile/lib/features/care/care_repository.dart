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

  static Future<List<CareNudge>> list(String coupleId) async {
    final res = await _c
        .from('care_nudges')
        .select()
        .eq('couple_id', coupleId)
        .order('created_at', ascending: false)
        .limit(50);
    return (res as List)
        .map((e) => CareNudge.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  static RealtimeChannel subscribe(String coupleId, void Function() onChange) {
    return _c
        .channel('care_nudges:$coupleId', opts: RealtimeChannelConfig(private: true))
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
