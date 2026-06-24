import 'dart:math';

import 'package:miles/core/supabase_service.dart';

/// Pre-approved category tiers for "Pick for us". Each tier carries a fixed
/// pool of result tags. The dice picks one tag from each enabled tier.
enum DiceTier {
  warm._(
    id: 'warm',
    label: 'Warm',
    emoji: '🟠',
    tags: ['slow', 'morning', 'whispered', 'tender', 'playful'],
  ),
  warmHot._(
    id: 'warm_hot',
    label: 'Warm + Hot',
    emoji: '🔥',
    tags: ['urgent', 'evening', 'adventurous', 'bold', 'lingering'],
  ),
  hot._(
    id: 'hot',
    label: 'Hot',
    emoji: '🌶️',
    tags: ['night', 'surprise', 'role', 'sensation', 'daring'],
  );

  const DiceTier._({
    required this.id,
    required this.label,
    required this.emoji,
    required this.tags,
  });

  final String id; // 'warm' | 'warm_hot' | 'hot'
  final String label;
  final String emoji;
  final List<String> tags;

  static const all = [warm, warmHot, hot];

  static DiceTier byId(String id) =>
      all.firstWhere((t) => t.id == id, orElse: () => warm);
}

/// One stored dice roll.
class DiceRoll {
  DiceRoll({
    required this.id,
    required this.tier,
    required this.tags,
    required this.rolledAt,
  });

  final String id;
  final String tier;
  final List<String> tags;
  final DateTime rolledAt;
}

/// DB access for "Pick for us" dice.
class PickForUsRepository {
  PickForUsRepository._();

  static final _c = SupabaseService.client;
  static final _rng = Random();

  /// Picks a random tag from each enabled tier. The highest enabled tier
  /// is recorded as the "tier" of the roll.
  static List<String> rollTags(List<String> enabledTierIds) {
    final tags = <String>[];
    for (final id in enabledTierIds) {
      final tier = DiceTier.byId(id);
      tags.add(tier.tags[_rng.nextInt(tier.tags.length)]);
    }
    return tags;
  }

  static Future<void> saveRoll({
    required String coupleId,
    required String tier,
    required List<String> tags,
  }) async {
    await _c.from('dice_rolls').insert({
      'couple_id': coupleId,
      'tier': tier,
      'result_tags': tags,
    });
  }

  static Future<List<DiceRoll>> fetchRecent({
    required String coupleId,
    int limit = 12,
  }) async {
    final rows = await _c
        .from('dice_rolls')
        .select('id, tier, result_tags, rolled_at')
        .eq('couple_id', coupleId)
        .order('rolled_at', ascending: false)
        .limit(limit);

    return (rows as List)
        .map((r) => DiceRoll(
              id: r['id'] as String,
              tier: r['tier'] as String,
              tags: (r['result_tags'] as List)
                  .map((e) => e.toString())
                  .toList(growable: false),
              rolledAt:
                  DateTime.parse(r['rolled_at'] as String).toLocal(),
            ),)
        .toList(growable: false);
  }

  /// Loads the consent rows for the couple. Returns a map
  /// { tierId → { userId → granted } }.
  static Future<Map<String, Map<String, bool>>> fetchConsents({
    required String coupleId,
  }) async {
    final rows = await _c
        .from('dice_tier_consents')
        .select('tier, user_id, granted')
        .eq('couple_id', coupleId);

    final out = <String, Map<String, bool>>{};
    for (final row in rows as List) {
      final tier = row['tier'] as String;
      final uid = row['user_id'] as String;
      final granted = row['granted'] as bool;
      (out[tier] ??= {})[uid] = granted;
    }
    return out;
  }

  /// Upserts my consent row for a tier. Returns the new couple-wide consent
  /// state for that tier (so the caller can tell if it just unlocked).
  static Future<Map<String, bool>> setMyConsent({
    required String coupleId,
    required String userId,
    required String partnerId,
    required String tier,
    required bool granted,
  }) async {
    await _c.from('dice_tier_consents').upsert({
      'couple_id': coupleId,
      'tier': tier,
      'user_id': userId,
      'granted': granted,
      'granted_at': granted ? DateTime.now().toUtc().toIso8601String() : null,
    });

    final consents = await fetchConsents(coupleId: coupleId);
    final tierMap = consents[tier] ?? {};
    return {
      userId: tierMap[userId] ?? false,
      partnerId: tierMap[partnerId] ?? false,
    };
  }
}
