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

  static const _pageSize = 200;

  /// Every visit, read in pages rather than in one open-ended request, so a
  /// couple with a long history pay a constant amount per round trip instead
  /// of one response that grows forever.
  ///
  /// Keyed on `created_at` and not on `start_date`: two visits can begin on the
  /// same day, and a cursor that is not unique steps over its own ties. The
  /// screen sorts for display, so the order here is the cursor's alone.
  static Future<List<Visit>> list(String coupleId) async {
    final out = <Visit>[];
    DateTime? cursor;
    while (true) {
      var q = _c.from('visits').select().eq('couple_id', coupleId);
      if (cursor != null) {
        q = q.lt('created_at', cursor.toUtc().toIso8601String());
      }
      final res =
          await q.order('created_at', ascending: false).limit(_pageSize);
      out.addAll(res.map(Visit.fromJson));
      if (res.length < _pageSize) return List.unmodifiable(out);
      cursor = out.last.createdAt;
    }
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
