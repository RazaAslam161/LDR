import 'package:flutter/material.dart';

/// A shareable mood state — emoji + label + signature color, plus a bundled
/// animated Noto-emoji (Lottie) for the cute animated rendering.
class MoodData {
  const MoodData(this.key, this.emoji, this.label, this.hex, this.desc,
      {this.intimate = false,});
  final String key;
  final String emoji;
  final String label;
  final String hex; // '#RRGGBB'
  final String desc;

  /// Bold/adult moods — shown in the intimacy contexts. Never child imagery.
  final bool intimate;

  Color get color =>
      Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));

  /// The bundled animated Noto-emoji Lottie for this mood.
  String get lottieAsset => 'assets/emoji/$key.json';
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
      intimate: true,),
  MoodData('flirty', '😏', 'Flirty', '#D45A77', 'Feeling cheeky',
      intimate: true,),
  MoodData('devilish', '😈', 'Devilish', '#9B59B6', 'Up to no good',
      intimate: true,),
  MoodData('kiss', '😘', 'Kissy', '#F2A9BC', 'Blowing a kiss', intimate: true),
  MoodData('kissmark', '💋', 'Marked you', '#E0564B', 'Left a mark',
      intimate: true,),
];

MoodData? moodByKey(String? key) {
  if (key == null) return null;
  for (final m in kMoods) {
    if (m.key == key) return m;
  }
  return null;
}
