import 'package:flutter/foundation.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_service.dart';

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
        .neq('deleted', true)
        .order('deliver_at', ascending: true);
    final out = <Ritual>[];
    for (final row in (res as List)) {
      try {
        out.add(Ritual.fromJson(row as Map<String, dynamic>));
      } catch (e) {
        // A ritual the user scheduled disappears from the list entirely when
        // this hits, so leave a trace — the row is still in Postgres and the
        // cron will still deliver it.
        debugPrint('rituals: unreadable row: $e');
      }
    }
    return out;
  }

  static Future<Ritual> create({
    required String coupleId,
    required RitualType type,
    required String message,
    required DateTime deliverAt,
  }) async {
    final res = await _c
        .from('rituals')
        .insert({
          'couple_id': coupleId,
          'type': ritualTypeToJson(type),
          'message': message,
          'deliver_at': deliverAt.toUtc().toIso8601String(),
          'delivered': false,
        })
        .select()
        .single();
    return Ritual.fromJson(res);
  }

  static Future<void> requestDelete({
    required String ritualId,
    required String requestedBy,
  }) async {
    await _c.from('rituals').update({
      'delete_requested': true,
      'delete_requested_by': requestedBy,
      'delete_requested_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', ritualId);
  }

  static Future<void> cancelDelete(String ritualId) async {
    await _c.from('rituals').update({
      'delete_requested': false,
      'delete_requested_by': null,
      'delete_requested_at': null,
    }).eq('id', ritualId);
  }

  static Future<void> hardDelete({
    required String ritualId,
    required String deletedBy,
  }) async {
    await _c.from('rituals').update({
      'deleted': true,
      'deleted_by': deletedBy,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', ritualId);
  }
}
