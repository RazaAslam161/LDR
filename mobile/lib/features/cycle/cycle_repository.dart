import 'package:flutter/material.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';

class CycleSettings {
  const CycleSettings({
    this.avgCycleLength = 28,
    this.avgPeriodLength = 5,
    this.shareWithPartner = true,
    this.onPeriodNow = false,
  });
  final int avgCycleLength;
  final int avgPeriodLength;
  final bool shareWithPartner;
  final bool onPeriodNow; // simple "I'm on my period right now" hint

  factory CycleSettings.fromJson(Map<String, dynamic> j) => CycleSettings(
        avgCycleLength: JsonUtils.parseInt(j['avg_cycle_length'], fallback: 28),
        avgPeriodLength: JsonUtils.parseInt(j['avg_period_length'], fallback: 5),
        shareWithPartner: (j['share_with_partner'] as bool?) ?? true,
        onPeriodNow: (j['on_period_now'] as bool?) ?? false,
      );

  CycleSettings copyWith({
    int? cycle,
    int? period,
    bool? share,
    bool? onPeriod,
  }) =>
      CycleSettings(
        avgCycleLength: cycle ?? avgCycleLength,
        avgPeriodLength: period ?? avgPeriodLength,
        shareWithPartner: share ?? shareWithPartner,
        onPeriodNow: onPeriod ?? onPeriodNow,
      );
}

/// A computed view of where a cycle is right now.
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

  /// A gentle, supportive note for the partner (never clinical).
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

  String get phaseLabel {
    switch (phase) {
      case 'menstrual':
        return 'Period';
      case 'follicular':
        return 'Follicular';
      case 'fertile':
        return 'Fertile window';
      case 'luteal':
        return 'Luteal (pre-period)';
      default:
        return '—';
    }
  }

  static CyclePrediction compute(
      List<DateTime> starts, CycleSettings settings) {
    if (starts.isEmpty) return const CyclePrediction();
    final sorted = [...starts]..sort();
    final last = DateUtils.dateOnly(sorted.last);
    final today = DateUtils.dateOnly(DateTime.now());
    final dayOfCycle = today.difference(last).inDays + 1; // day 1 = start
    final next = last.add(Duration(days: settings.avgCycleLength));
    final daysUntilNext = DateUtils.dateOnly(next).difference(today).inDays;
    final ovulation = settings.avgCycleLength - 14;
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

  static Future<void> logPeriodStart({
    required String coupleId,
    required String userId,
    required DateTime date,
  }) async {
    final d =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    await _c.from('cycle_logs').upsert({
      'user_id': userId,
      'couple_id': coupleId,
      'period_start': d,
    }, onConflict: 'user_id,period_start');
  }

  static Future<void> deleteLog(String id) async {
    await _c.from('cycle_logs').delete().eq('id', id);
  }

  /// Period-start dates for [userId] (subject to RLS — partner sees them only
  /// if [userId] shares).
  static Future<List<DateTime>> starts(String userId) async {
    final res = await _c
        .from('cycle_logs')
        .select('period_start')
        .eq('user_id', userId)
        .order('period_start', ascending: false)
        .limit(24);
    return (res as List)
        .map((e) => JsonUtils.parseDate((e as Map)['period_start']))
        .toList(growable: false);
  }

  static Future<CycleSettings> settings(String userId) async {
    final res = await _c
        .from('cycle_settings')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    return res == null
        ? const CycleSettings()
        : CycleSettings.fromJson(res);
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
      'on_period_now': s.onPeriodNow,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}
