import 'package:flutter/material.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';

/// Per-user cycle preferences. Sensitive health data — RLS-locked to the couple,
/// and the owner controls whether it's shared (`shareWithPartner`).
class CycleSettings {
  const CycleSettings({
    this.avgCycleLength = 28,
    this.avgPeriodLength = 5,
    this.shareWithPartner = true,
    this.trackingEnabled = false,
    this.onPeriodNow = false,
  }); // live "on my period" flag (mirrors latest event)

  factory CycleSettings.fromJson(Map<String, dynamic> j) => CycleSettings(
        avgCycleLength: JsonUtils.parseInt(j['avg_cycle_length'], fallback: 28),
        avgPeriodLength:
            JsonUtils.parseInt(j['avg_period_length'], fallback: 5),
        shareWithPartner: (j['share_with_partner'] as bool?) ?? true,
        trackingEnabled: (j['tracking_enabled'] as bool?) ?? false,
        onPeriodNow: (j['on_period_now'] as bool?) ?? false,
      );

  final int avgCycleLength;
  final int avgPeriodLength;
  final bool shareWithPartner;
  final bool trackingEnabled;
  final bool onPeriodNow;

  CycleSettings copyWith({
    int? cycle,
    int? period,
    bool? share,
    bool? tracking,
    bool? onPeriod,
  }) =>
      CycleSettings(
        avgCycleLength: cycle ?? avgCycleLength,
        avgPeriodLength: period ?? avgPeriodLength,
        shareWithPartner: share ?? shareWithPartner,
        trackingEnabled: tracking ?? trackingEnabled,
        onPeriodNow: onPeriod ?? onPeriodNow,
      );
}

/// A logged period boundary — 'period_start' or 'period_end'.
class CycleEvent {
  const CycleEvent({
    required this.id,
    required this.type,
    required this.eventDate,
    required this.createdAt,
  });

  factory CycleEvent.fromJson(Map<String, dynamic> j) => CycleEvent(
        id: JsonUtils.parseString(j['id']),
        type: JsonUtils.parseString(j['type'], fallback: 'period_start'),
        eventDate: JsonUtils.parseDate(j['event_date']),
        createdAt: JsonUtils.parseDate(j['created_at']),
      );

  final String id;
  final String type; // 'period_start' | 'period_end'
  final DateTime eventDate;
  final DateTime createdAt;

  bool get isStart => type == 'period_start';
}

/// A start→end period span (end is null while the period is ongoing).
class PeriodSpan {
  const PeriodSpan(this.start, this.end);
  final DateTime start;
  final DateTime? end;
}

/// A computed view of where a cycle is right now. Every figure is an ESTIMATE.
class CyclePrediction {
  const CyclePrediction({
    this.lastStart,
    this.nextPeriod,
    this.dayOfCycle,
    this.daysUntilNext,
    this.phase = 'unknown',
  });

  final DateTime? lastStart;
  final DateTime? nextPeriod;
  final int? dayOfCycle;
  final int? daysUntilNext;
  final String phase; // menstrual | follicular | fertile | luteal | unknown

  bool get hasData => lastStart != null;

  String get phaseLabel {
    switch (phase) {
      case 'menstrual':
        return 'Period';
      case 'follicular':
        return 'Follicular';
      case 'fertile':
        return 'Fertile window (estimate)';
      case 'luteal':
        return 'Luteal (pre-period)';
      default:
        return '—';
    }
  }

  String get partnerNote {
    switch (phase) {
      case 'menstrual':
        return 'Her period’s here — she may feel tired or crampy. Be extra gentle 💛';
      case 'luteal':
        return (daysUntilNext ?? 99) <= 3
            ? 'Her period’s close — PMS days. Patience and softness go far 💛'
            : 'A calm stretch — a little extra warmth is always nice 💛';
      case 'fertile':
        return 'She may feel her best and most affectionate right now 💛';
      case 'follicular':
        return 'Usually a brighter, higher-energy stretch 💛';
      default:
        return 'Be the gentle one today 💛';
    }
  }

  /// Build from logged period-start dates + settings.
  static CyclePrediction compute(
      List<DateTime> starts, CycleSettings settings,) {
    if (starts.isEmpty) return const CyclePrediction();
    final sorted = [...starts]..sort();
    final last = DateUtils.dateOnly(sorted.last);
    final today = DateUtils.dateOnly(DateTime.now());

    // Average gap between starts if we have ≥2 cycles, else the setting.
    var cycleLen = settings.avgCycleLength;
    if (sorted.length >= 2) {
      var total = 0;
      var n = 0;
      for (var i = 1; i < sorted.length; i++) {
        final gap = DateUtils.dateOnly(sorted[i])
            .difference(DateUtils.dateOnly(sorted[i - 1]))
            .inDays;
        if (gap > 10 && gap < 90) {
          total += gap;
          n++;
        }
      }
      if (n > 0) cycleLen = (total / n).round();
    }

    final dayOfCycle = today.difference(last).inDays + 1;
    final next = last.add(Duration(days: cycleLen));
    final daysUntilNext = DateUtils.dateOnly(next).difference(today).inDays;
    final ovulation = cycleLen - 14;
    String phase;
    if (dayOfCycle <= settings.avgPeriodLength) {
      phase = 'menstrual';
    } else if ((dayOfCycle - ovulation).abs() <= 2) {
      phase = 'fertile';
    } else if (dayOfCycle < ovulation) {
      phase = 'follicular';
    } else {
      phase = 'luteal';
    }
    return CyclePrediction(
      lastStart: last,
      nextPeriod: next,
      dayOfCycle: dayOfCycle,
      daysUntilNext: daysUntilNext,
      phase: phase,
    );
  }
}

class CycleRepository {
  CycleRepository._();
  static final _c = SupabaseService.client;

  // ── Settings ──────────────────────────────────────────────────────────────
  static Future<CycleSettings> settings(String userId) async {
    final res = await _c
        .from('cycle_settings')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    return res == null ? const CycleSettings() : CycleSettings.fromJson(res);
  }

  static Future<void> saveSettings({
    required String userId,
    required String coupleId,
    required CycleSettings s,
  }) async {
    await _c.from('cycle_settings').upsert({
      'user_id': userId,
      'couple_id': coupleId,
      'avg_cycle_length': s.avgCycleLength,
      'avg_period_length': s.avgPeriodLength,
      'share_with_partner': s.shareWithPartner,
      'tracking_enabled': s.trackingEnabled,
      'on_period_now': s.onPeriodNow,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  // ── Events ────────────────────────────────────────────────────────────────
  /// Period events for [userId] (RLS-gated — partner sees them only if shared).
  static Future<List<CycleEvent>> events(String userId) async {
    final res = await _c
        .from('cycle_events')
        .select()
        .eq('user_id', userId)
        .order('event_date', ascending: false)
        .order('created_at', ascending: false)
        .limit(120);
    return (res as List)
        .map((e) => CycleEvent.fromJson((e as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  static String _d(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// Toggle the period on/off: logs a start/end event AND mirrors the live
  /// `on_period_now` flag so the partner's card updates instantly.
  static Future<void> setOnPeriod({
    required String coupleId,
    required String userId,
    required bool on,
  }) async {
    await _c.from('cycle_events').insert({
      'user_id': userId,
      'couple_id': coupleId,
      'type': on ? 'period_start' : 'period_end',
      'event_date': _d(DateTime.now()),
    });
    await _c.from('cycle_settings').upsert({
      'user_id': userId,
      'couple_id': coupleId,
      'on_period_now': on,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  // ── Derivations ─────────────────────────────────────────────────────────--
  /// True if the most recent event is a start (period currently open).
  static bool onPeriod(List<CycleEvent> events) {
    if (events.isEmpty) return false;
    final sorted = [...events]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted.first.isStart;
  }

  static List<DateTime> startDates(List<CycleEvent> events) =>
      events.where((e) => e.isStart).map((e) => e.eventDate).toList();

  /// Pair each start with the next end (null while ongoing) for calendar shading.
  static List<PeriodSpan> spans(List<CycleEvent> events) {
    final sorted = [...events]
      ..sort((a, b) => a.eventDate.compareTo(b.eventDate));
    final out = <PeriodSpan>[];
    DateTime? openStart;
    for (final e in sorted) {
      if (e.isStart) {
        if (openStart != null) out.add(PeriodSpan(openStart, null));
        openStart = e.eventDate;
      } else if (openStart != null) {
        out.add(PeriodSpan(openStart, e.eventDate));
        openStart = null;
      }
    }
    if (openStart != null) out.add(PeriodSpan(openStart, null));
    return out;
  }

  /// Average period length (days) from closed spans, fallback to the setting.
  static int avgPeriodLength(List<CycleEvent> events, int fallback) {
    final closed =
        spans(events).where((s) => s.end != null).toList(growable: false);
    if (closed.isEmpty) return fallback;
    var total = 0;
    for (final s in closed) {
      total += s.end!.difference(s.start).inDays + 1;
    }
    return (total / closed.length).round().clamp(1, 14);
  }

  /// Average cycle length (days) from start-to-start gaps, fallback to setting.
  static int avgCycleLength(List<CycleEvent> events, int fallback) {
    final starts = startDates(events)..sort();
    if (starts.length < 2) return fallback;
    var total = 0;
    var n = 0;
    for (var i = 1; i < starts.length; i++) {
      final gap = starts[i].difference(starts[i - 1]).inDays;
      if (gap > 10 && gap < 90) {
        total += gap;
        n++;
      }
    }
    return n == 0 ? fallback : (total / n).round();
  }
}
