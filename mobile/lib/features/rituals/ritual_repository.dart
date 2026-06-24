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

  /// All rituals for this couple, soonest delivery first. (The table has no
  /// created_at column — ordering by it was the cause of the Rituals error.)
  static Future<List<Ritual>> list(String coupleId) async {
    final res = await _c
        .from('rituals')
        .select()
        .eq('couple_id', coupleId)
        .order('deliver_at', ascending: true);
    final out = <Ritual>[];
    for (final row in (res as List)) {
      try {
        out.add(Ritual.fromJson(row as Map<String, dynamic>));
      } catch (_) {}
    }
    return out;
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
