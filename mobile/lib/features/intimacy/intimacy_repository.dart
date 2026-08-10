import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The tender, non-explicit set of "In the Mood" states. Copy stays warm and
/// tasteful — flirtation and closeness, never graphic.
class MoodState {
  const MoodState(this.key, this.label, this.emoji);
  final String key;
  final String label;
  final String emoji;
}

const moodStates = <MoodState>[
  MoodState('thinking_of_you', 'Thinking of you', '💭'),
  MoodState('feeling_close', 'Feeling close', '🤍'),
  MoodState('missing_touch', 'Missing your touch', '🌙'),
  MoodState('feeling_flirty', 'Feeling a little flirty', '✨'),
  MoodState('wish_here', 'Wishing you were here', '💫'),
];

MoodState moodFor(String key) =>
    moodStates.firstWhere((m) => m.key == key,
        orElse: () => const MoodState('feeling_close', 'Feeling close', '🤍'),);

class IntimacyPrefs {
  const IntimacyPrefs({this.receivingEnabled = false, this.signalingEnabled = false});

  factory IntimacyPrefs.fromJson(Map<String, dynamic> j) => IntimacyPrefs(
        receivingEnabled: JsonUtils.parseBool(j['receiving_enabled']),
        signalingEnabled: JsonUtils.parseBool(j['signaling_enabled']),
      );

  final bool receivingEnabled;
  final bool signalingEnabled;

  /// Opted into the layer at all?
  bool get optedIn => receivingEnabled || signalingEnabled;
}

class IntimacySignal {
  IntimacySignal({
    required this.id,
    required this.userId,
    required this.state,
    required this.windowExpiresAt,
  });

  factory IntimacySignal.fromJson(Map<String, dynamic> j) => IntimacySignal(
        id: JsonUtils.parseString(j['id']),
        userId: JsonUtils.parseString(j['user_id']),
        state: JsonUtils.parseString(j['state']),
        windowExpiresAt: JsonUtils.parseDate(j['window_expires_at']).toLocal(),
      );

  final String id;
  final String userId;
  final String state;
  final DateTime windowExpiresAt;

  bool get isActive => windowExpiresAt.isAfter(DateTime.now());
}

class IntimacyRepository {
  IntimacyRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  static Future<IntimacyPrefs> getPrefs() async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return const IntimacyPrefs();
    final res = await _c
        .from('intimacy_prefs')
        .select()
        .eq('user_id', uid)
        .maybeSingle();
    return res == null
        ? const IntimacyPrefs()
        : IntimacyPrefs.fromJson(res);
  }

  static Future<void> setPrefs({
    required bool receiving,
    required bool signaling,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c.from('intimacy_prefs').upsert({
      'user_id': uid,
      'receiving_enabled': receiving,
      'signaling_enabled': signaling,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> sendSignal({
    required String coupleId,
    required String state,
    Duration window = const Duration(hours: 6),
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    // Replace any prior active signal so the latest mood stands.
    await clearMine();
    await _c.from('intimacy_signals').insert({
      'couple_id': coupleId,
      'user_id': uid,
      'state': state,
      'window_expires_at':
          DateTime.now().toUtc().add(window).toIso8601String(),
    });
  }

  /// Active signals the caller is allowed to see. RLS guarantees you only see
  /// your partner's signal if YOU also have an active one (the mutual gate).
  static Future<List<IntimacySignal>> activeSignals(String coupleId) async {
    final res = await _c
        .from('intimacy_signals')
        .select()
        .eq('couple_id', coupleId)
        .gt('window_expires_at', DateTime.now().toUtc().toIso8601String());
    return (res as List)
        .map((e) => IntimacySignal.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// "Not tonight" / retract — frictionless, no trace left.
  static Future<void> clearMine() async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c.from('intimacy_signals').delete().eq('user_id', uid);
  }

  static RealtimeChannel subscribe(String coupleId, void Function() onChange) {
    return _c
        .channel('intimacy:$coupleId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'intimacy_signals',
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
