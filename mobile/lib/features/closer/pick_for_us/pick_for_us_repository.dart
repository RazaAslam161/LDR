import 'dart:math';

import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/utils/json_utils.dart';

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
    label: 'Warm + Bold',
    emoji: '✨',
    tags: ['urgent', 'evening', 'adventurous', 'bold', 'lingering'],
  ),
  hot._(
    id: 'hot',
    label: 'Bold',
    emoji: '⚡',
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

/// Display names for the faces whose stored key reads badly on screen. The
/// keys above are what [PickForUsRepository.saveRoll] writes into
/// `dice_rolls.tags`, so every roll already in a couple's history holds them —
/// renaming the keys would only fix the dice and leave the history reading the
/// old words. Anything a partner reads goes through here instead. Same names
/// the Fantasy Jar uses for the same three faces.
const Map<String, String> _kDiceTagLabels = {
  'urgent': 'spontaneous',
  'role': 'make-believe',
  'sensation': 'senses',
};

/// The human-readable name for a dice face.
String diceTagLabel(String tag) => _kDiceTagLabels[tag] ?? tag;

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

    final out = <DiceRoll>[];
    Object? firstError;
    StackTrace? firstStack;
    for (final r in rows as List) {
      try {
        out.add(DiceRoll(
          id: JsonUtils.parseString(r['id']),
          tier: JsonUtils.parseString(r['tier']),
          tags: (r['result_tags'] as List)
              .map((e) => e.toString())
              .toList(growable: false),
          rolledAt: JsonUtils.parseDate(r['rolled_at']).toLocal(),
        ),);
      } catch (e, st) {
        // Skip a malformed row rather than blanking the whole list — but
        // counted, per the parsed-N-of-M rule: a shorter history must be
        // distinguishable from dropped rows.
        firstError ??= e;
        firstStack ??= st;
      }
    }
    if (firstError != null) {
      ErrorReporter.report(
        ParseShortfall('dice rolls',
            parsed: out.length,
            of: (rows as List).length,
            first: '${firstError.runtimeType}',),
        firstStack,
        // Its own kind, not a shared 'pick-for-us': dedup keys on kind
        // precisely so two fetches failing at the same JsonUtils frame do
        // not suppress each other.
        kind: 'pick-for-us-rolls',
      );
    }
    return out;
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
    var parsed = 0;
    Object? firstError;
    StackTrace? firstStack;
    for (final row in rows as List) {
      try {
        final tier = JsonUtils.parseString(row['tier']);
        final uid = JsonUtils.parseString(row['user_id']);
        final granted = JsonUtils.parseBool(row['granted']);
        (out[tier] ??= {})[uid] = granted;
        parsed++;
      } catch (e, st) {
        // Skip a malformed row rather than blanking the whole map — counted,
        // because a consent map missing rows fails CLOSED for the couple and
        // that must be visible somewhere.
        firstError ??= e;
        firstStack ??= st;
      }
    }
    if (firstError != null) {
      ErrorReporter.report(
        ParseShortfall('dice tier consents',
            parsed: parsed,
            of: (rows as List).length,
            first: '${firstError.runtimeType}',),
        firstStack,
        kind: 'pick-for-us-consents',
      );
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
