import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_service.dart';

/// Fetches and writes the couple's full visit history for the timeline.
///
/// Visits come back unsorted; the screen re-orders them as needed.
/// Adding a past visit keeps `is_upcoming = false` so it doesn't
/// hijack the countdown.
class TimelineRepository {
  TimelineRepository._();

  static final _c = SupabaseService.client;

  static Future<List<Visit>> list(String coupleId) async {
    final res = await _c
        .from('visits')
        .select()
        .eq('couple_id', coupleId)
        .order('start_date', ascending: true);
    return (res as List)
        .map((e) => Visit.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  static Future<void> addPastVisit({
    required String coupleId,
    required DateTime startDate,
    required DateTime endDate,
    String? location,
  }) async {
    await _c.from('visits').insert({
      'couple_id': coupleId,
      'start_date': startDate.toUtc().toIso8601String(),
      'end_date': endDate.toUtc().toIso8601String(),
      'location': location,
      'is_upcoming': false,
    });
  }
}
