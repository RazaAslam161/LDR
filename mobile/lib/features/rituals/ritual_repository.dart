import 'package:miles/core/models.dart';
import 'package:miles/core/supabase_service.dart';

/// CRUD wrapper around the `rituals` table.
///
/// v1 does not schedule push notifications — we only persist the
/// couple's chosen delivery time so the list can show upcoming
/// deliveries. Actual delivery arrives in a later release with
/// a cron / edge-function worker.
class RitualRepository {
  RitualRepository._();

  static final _c = SupabaseService.client;

  /// All rituals for this couple, newest first.
  static Future<List<Ritual>> list(String coupleId) async {
    final res = await _c
        .from('rituals')
        .select()
        .eq('couple_id', coupleId)
        .order('created_at', ascending: false);
    return (res as List)
        .map((e) => Ritual.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  static Future<Ritual> create({
    required String coupleId,
    required RitualType type,
    required String message,
    required DateTime deliverAt,
  }) async {
    final res = await _c.from('rituals').insert({
      'couple_id': coupleId,
      'type': ritualTypeToJson(type),
      'message': message,
      'deliver_at': deliverAt.toUtc().toIso8601String(),
      'delivered': false,
    }).select().single();
    return Ritual.fromJson(res);
  }

  static Future<void> delete(String ritualId) async {
    await _c.from('rituals').delete().eq('id', ritualId);
  }
}
