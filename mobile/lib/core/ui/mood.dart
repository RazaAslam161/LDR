import 'package:flutter/material.dart';

/// A shareable mood state — emoji + label + signature color, plus a bundled
/// animated Noto-emoji (Lottie) for the cute animated rendering.
class MoodData {
  const MoodData(this.key, this.emoji, this.label, this.hex, this.desc,
      {this.intimate = false, String? asset,})
      : _asset = asset;
  final String key;
  final String emoji;
  final String label;
  final String hex; // '#RRGGBB'
  final String desc;

  /// Bold/adult moods — shown in the intimacy contexts. Never child imagery.
  final bool intimate;

  Color get color =>
      Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));

  /// Set only where the file cannot be named after the key.
  final String? _asset;

  /// The bundled animated Noto-emoji Lottie for this mood.
  ///
  /// Named off [key] by default, and deliberately overridable: [key] is the
  /// wire format — it is written to `presence.current_mood` and
  /// `messages.sender_mood`, so a build that renamed it would stop reading
  /// every mood the other phone has ever set. The FILENAME has no such
  /// constraint, and it is the half that ships in the clear: `unzip -l` on the
  /// APK lists every asset path without any tooling at all.
  String get lottieAsset => 'assets/emoji/${_asset ?? key}.json';
}

const List<MoodData> kMoods = [
  // ── Everyday expressions (cute animated faces) ──
  MoodData('joyful', '😄', 'Joyful', '#F3C77A', 'Glowing'),
  MoodData('loving', '🥰', 'Loving', '#F2A9BC', 'Adoring'),
  MoodData('cozy', '😌', 'Cozy', '#E6A765', 'Wrapped up'),
  MoodData('missing_you', '🥺', 'Missing you', '#8A6FE8', 'Longing'),
  MoodData('excited', '🤩', 'Excited', '#5FD3C4', 'Buzzing'),
  MoodData('calm', '😇', 'Calm', '#85B7EB', 'Peaceful'),
  MoodData('playful', '😜', 'Playful', '#F0997B', 'Cheeky'),
  MoodData('romantic', '😍', 'Romantic', '#D45A77', 'Enchanted'),
  MoodData('tired', '😴', 'Tired', '#B79CB0', 'Sleepy'),
  MoodData('anxious', '😰', 'Anxious', '#9FD8A0', 'Restless'),
  MoodData('grateful', '🥹', 'Grateful', '#F2A9BC', 'Thankful'),
  MoodData('sad', '😢', 'Blue', '#378ADD', 'Reflective'),
  MoodData('angry', '😠', 'Angry', '#E0564B', 'Fuming'),
  MoodData('annoyed', '😤', 'Annoyed', '#C9824A', 'Irritated'),
  // ── Bold / intimate (adult expressions — never children) ──
  MoodData('horny', '🥵', 'Turned on', '#E84A6F', 'Aching for you',
      intimate: true, asset: 'yearning',),
  MoodData('flirty', '😏', 'Flirty', '#D45A77', 'Feeling cheeky',
      intimate: true,),
  MoodData('devilish', '😈', 'Devilish', '#9B59B6', 'Up to no good',
      intimate: true, asset: 'mischief',),
  MoodData('kiss', '😘', 'Kissy', '#F2A9BC', 'Blowing a kiss', intimate: true),
  MoodData('kissmark', '💋', 'Marked you', '#E0564B', 'Left a mark',
      intimate: true, asset: 'lipstick',),
];

/// The moods a given couple may pick from.
///
/// [intimate] moods are the ones that only make sense once both partners have
/// turned Closer on. The flag existed from the start and nothing ever read it,
/// so 'Turned on / Aching for you' sat in the ordinary chat mood sheet for
/// every user — outside Closer, outside Modest Mode, outside the adult check.
/// This is the reader that was missing.
List<MoodData> moodsFor({required bool intimateAllowed}) =>
    intimateAllowed ? kMoods : [for (final m in kMoods) if (!m.intimate) m];

MoodData? moodByKey(String? key) {
  if (key == null) return null;
  for (final m in kMoods) {
    if (m.key == key) return m;
  }
  return null;
}
