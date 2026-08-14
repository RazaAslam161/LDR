import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One line on the couple's chart.
class RoutineItem {
  const RoutineItem({
    required this.id,
    required this.title,
    required this.sortMinutes,
    required this.targetCount,
    required this.isDefault,
    this.emoji,
  });

  final String id;
  final String title;
  final String? emoji;

  /// Minutes from midnight — the chart reads down the day in the order it is
  /// lived, not the order things were added.
  final int sortMinutes;

  /// 1 for a prayer, 8 for water. A target above one counts up instead of
  /// flipping, so "drink water every hour" is one line rather than eight.
  final int targetCount;

  /// Seeded rather than added by hand. Only custom lines can be removed —
  /// deleting "Fajr" for the couple would be a different feature.
  final bool isDefault;

  bool get isCounted => targetCount > 1;

  String get clock {
    final h = sortMinutes ~/ 60;
    final m = sortMinutes % 60;
    final ampm = h < 12 ? 'am' : 'pm';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${m.toString().padLeft(2, '0')}$ampm';
  }

  static RoutineItem fromJson(Map<String, dynamic> j) => RoutineItem(
        id: JsonUtils.parseString(j['id']),
        title: JsonUtils.parseString(j['title']),
        emoji: JsonUtils.parseStringOrNull(j['emoji']),
        sortMinutes: (j['sort_minutes'] as num?)?.toInt() ?? 0,
        targetCount: (j['target_count'] as num?)?.toInt() ?? 1,
        isDefault: (j['is_default'] as bool?) ?? false,
      );
}

/// Everything ticked today, by whom.
class RoutineDay {
  const RoutineDay(this.items, this.counts);

  final List<RoutineItem> items;

  /// itemId → userId → how many times.
  final Map<String, Map<String, int>> counts;

  int countFor(String itemId, String userId) =>
      counts[itemId]?[userId] ?? 0;

  bool doneBy(RoutineItem item, String userId) =>
      countFor(item.id, userId) >= item.targetCount;
}

/// The shared daily chart.
///
/// "Resets every day" needs no reset: a check is one row per (item, person,
/// date), so tomorrow simply has no rows. There is no midnight job to schedule,
/// nothing to fail overnight, and yesterday stays intact instead of being
/// wiped — which is what makes a streak possible later.
///
/// The DATE comes from the device, deliberately. These two are in different
/// timezones; a server-side "today" would roll over at a moment that is
/// midnight for neither of them.
class RoutineRepository {
  RoutineRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  /// Local calendar date as `YYYY-MM-DD`, never a UTC instant.
  static String today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  /// Idempotent server-side seed, so there is no "first run" flag to keep in
  /// sync on two handsets.
  static Future<void> ensureDefaults() async {
    try {
      await _c.rpc<void>('ensure_default_routines');
    } catch (e) {
      debugPrint('[routines] seed failed: ${e.runtimeType}');
    }
  }

  static Future<RoutineDay> fetch(String coupleId, String onDate) async {
    final rows = await _c
        .from('routine_items')
        .select('id,title,emoji,sort_minutes,target_count,is_default')
        .eq('couple_id', coupleId)
        .eq('deleted', false)
        .order('sort_minutes');
    final items = [
      for (final r in rows as List) RoutineItem.fromJson(JsonUtils.asMap(r)),
    ];

    final counts = <String, Map<String, int>>{};
    if (items.isNotEmpty) {
      final checks = await _c
          .from('routine_checks')
          .select('item_id,user_id,count')
          .eq('on_date', onDate)
          .inFilter('item_id', items.map((i) => i.id).toList());
      for (final c in checks as List) {
        final m = JsonUtils.asMap(c);
        final item = JsonUtils.parseString(m['item_id']);
        final user = JsonUtils.parseString(m['user_id']);
        counts.putIfAbsent(item, () => {})[user] =
            (m['count'] as num?)?.toInt() ?? 0;
      }
    }
    return RoutineDay(List.unmodifiable(items), counts);
  }

  /// Re-reads on any change to either table.
  ///
  /// A chart is a handful of rows, so a delta would be more machinery than the
  /// re-read costs — and this way a partner's tick and a new custom line arrive
  /// through exactly one path.
  static Stream<RoutineDay> stream(String coupleId, String onDate) {
    ManagedSubscription? items;
    ManagedSubscription? checks;
    late final StreamController<RoutineDay> controller;
    var loading = false;

    Future<void> reload() async {
      if (loading) return;
      loading = true;
      try {
        final day = await fetch(coupleId, onDate);
        if (!controller.isClosed) controller.add(day);
      } catch (e) {
        debugPrint('[routines] reload: ${e.runtimeType}');
      } finally {
        loading = false;
      }
    }

    controller = StreamController<RoutineDay>.broadcast(
      onListen: () async {
        items = ManagedSubscription.start(
          () => RealtimeService.coupleTable(
            channelName: 'routine-items:$coupleId',
            table: 'routine_items',
            coupleId: coupleId,
            onChange: (_) => unawaited(reload()),
          ),
        );
        // routine_checks has no couple_id, so it cannot use the couple-scoped
        // helper. RLS still limits delivery to this couple's items.
        checks = ManagedSubscription.start(
          () => SupabaseService.client
              .channel('routine-checks:$coupleId')
              .onPostgresChanges(
                event: PostgresChangeEvent.all,
                schema: 'public',
                table: 'routine_checks',
                callback: (_) => unawaited(reload()),
              )
              .subscribe(),
        );
        await ensureDefaults();
        await reload();
      },
      onCancel: () {
        items?.dispose();
        checks?.dispose();
        items = null;
        checks = null;
      },
    );
    return controller.stream;
  }

  /// Tick, untick, or count up one. [next] of 0 removes the row entirely, so an
  /// unticked routine leaves no trace rather than a zero that has to be read
  /// around everywhere.
  static Future<void> setCount({
    required String itemId,
    required String userId,
    required String onDate,
    required int next,
  }) async {
    if (next <= 0) {
      await _c
          .from('routine_checks')
          .delete()
          .eq('item_id', itemId)
          .eq('user_id', userId)
          .eq('on_date', onDate);
      return;
    }
    await _c.from('routine_checks').upsert({
      'item_id': itemId,
      'user_id': userId,
      'on_date': onDate,
      'count': next,
    });
  }

  static Future<void> addCustom({
    required String coupleId,
    required String createdBy,
    required String title,
    required int sortMinutes,
    int targetCount = 1,
    String? emoji,
  }) =>
      _c.from('routine_items').insert({
        'couple_id': coupleId,
        'created_by': createdBy,
        'title': title,
        'emoji': emoji,
        'sort_minutes': sortMinutes,
        'target_count': targetCount,
        'is_default': false,
      });

  /// Soft delete — the checks already written against it stay valid, and a hard
  /// delete would cascade away a partner's history for a line they were also
  /// keeping.
  static Future<void> removeCustom(String itemId) =>
      _c.from('routine_items').update({'deleted': true}).eq('id', itemId);
}
