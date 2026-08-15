/// Truth or Dare shapes. The writing itself lives in `game_content.dart`, in
/// both English and Roman Urdu. Two heat levels:
///   • cute   – wholesome, romantic
///   • flirty – playful, teasing
///
/// A third `spicy` tier used to sit above these. It shipped app-authored
/// instructions to send intimate photos and to touch oneself — bundled text,
/// not anything a user wrote, one drawer tap from the home screen with no gate
/// beyond the signup age check. That is content the store reads straight out of
/// the APK, so it is gone rather than reworded: the tier was named for what it
/// was, and softer wording would not have changed what it asked for.
enum TDType { truth, dare }

enum TDTier { cute, flirty }

extension TDTierMeta on TDTier {
  String get label => switch (this) {
        TDTier.cute => 'Cute',
        TDTier.flirty => 'Flirty',
      };
  String get emoji => switch (this) {
        TDTier.cute => '🌸',
        TDTier.flirty => '😏',
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
