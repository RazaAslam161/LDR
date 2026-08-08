/// Truth or Dare shapes. The writing itself lives in `game_content.dart`, in
/// both English and Roman Urdu. Three heat levels so a couple can keep it sweet
/// or turn it up:
///   • cute   – wholesome, romantic
///   • flirty – playful, teasing
///   • spicy  – intimate / adult, but tasteful (it prompts *them* to express
///              desire; the photo/voice dares always add "only as far as you
///              are comfortable", so consent is baked into the game itself)
enum TDType { truth, dare }

enum TDTier { cute, flirty, spicy }

extension TDTierMeta on TDTier {
  String get label => switch (this) {
        TDTier.cute => 'Cute',
        TDTier.flirty => 'Flirty',
        TDTier.spicy => 'Spicy',
      };
  String get emoji => switch (this) {
        TDTier.cute => '🌸',
        TDTier.flirty => '😏',
        TDTier.spicy => '🔥',
      };
}

class TDCard {
  const TDCard(this.type, this.tier, this.text, this.index);

  final TDType type;
  final TDTier tier;
  final String text;

  /// Position in the pool this card was drawn from. Sent to the partner so
  /// their phone can show the same card in whichever language they read; -1
  /// when it did not come from a pool.
  final int index;

  Map<String, dynamic> toJson() =>
      {'type': type.name, 'tier': tier.name, 'text': text, 'index': index};

  static TDCard? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final type = TDType.values
        .where((t) => t.name == j['type'])
        .cast<TDType?>()
        .firstWhere((_) => true, orElse: () => null);
    final tier = TDTier.values
        .where((t) => t.name == j['tier'])
        .cast<TDTier?>()
        .firstWhere((_) => true, orElse: () => null);
    final text = j['text'] as String?;
    if (type == null || tier == null || text == null) return null;
    // Older builds send no index. -1 means "show their words verbatim".
    final index = j['index'];
    return TDCard(type, tier, text, index is int ? index : -1);
  }
}
