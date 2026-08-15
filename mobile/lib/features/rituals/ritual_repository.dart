import 'package:flutter/foundation.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_service.dart';

/// CRUD wrapper around the `rituals` table.
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
        // this hits, so leave a trace — the row is still in Postgres.
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

  /// Confirms a delete that was already requested.
  ///
  /// Only `deleted` is sent: a BEFORE UPDATE trigger on the table stamps
  /// `deleted_by` and `deleted_at` from `auth.uid()` itself, and it rejects the
  /// write outright (42501) unless a request is standing and the confirmer is
  /// not the requester — or the 14-day window has run out. Sending our own
  /// values here claimed an authority the client does not have.
  static Future<void> confirmDelete(String ritualId) async {
    await _c.from('rituals').update({'deleted': true}).eq('id', ritualId);
  }
}
