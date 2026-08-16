/// Truth or Dare shapes. The writing itself lives in `game_content.dart`, in
/// both English and Roman Urdu. Three levels, deepening rather than heating up:
///   • cute   – wholesome, romantic
///   • flirty – playful, teasing
///   • spicy  – the honest one: fears, regrets, the things neither of you says
///
/// The third tier once shipped app-authored instructions to send intimate
/// photos and to touch oneself, and was deleted outright. Deleting it was the
/// wrong repair twice over. It removed a feature to fix wording, and
/// [TDCard.fromJson] returns null for a tier it does not know — so a partner on
/// an older build drawing that tier left this phone showing no card at all,
/// silently. The tier is back with its wire name `spicy` unchanged, because
/// that name travels on the wire and in shipped APKs; only what it ASKS FOR
/// changed. Boldness here means saying the hard thing, not undressing.
enum TDType { truth, dare }

enum TDTier { cute, flirty, spicy }

extension TDTierMeta on TDTier {
  /// Display only. The enum NAME is the wire key — never rename it.
  String get label => switch (this) {
        TDTier.cute => 'Cute',
        TDTier.flirty => 'Playful',
        TDTier.spicy => 'Deep',
      };
  String get emoji => switch (this) {
        TDTier.cute => '🌸',
        TDTier.flirty => '😉',
        TDTier.spicy => '🌙',
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
