import 'package:flutter/material.dart';

/// A shareable mood state — emoji + label + signature color.
class MoodData {
  const MoodData(this.key, this.emoji, this.label, this.hex, this.desc);
  final String key;
  final String emoji;
  final String label;
  final String hex; // '#RRGGBB'
  final String desc;

  Color get color =>
      Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));
}

const List<MoodData> kMoods = [
  MoodData('joyful', '✨', 'Joyful', '#F3C77A', 'Glowing'),
  MoodData('loving', '💕', 'Loving', '#F2A9BC', 'Adoring'),
  MoodData('cozy', '🕯️', 'Cozy', '#E6A765', 'Wrapped up'),
  MoodData('missing_you', '🌙', 'Missing you', '#8A6FE8', 'Longing'),
  MoodData('excited', '🌟', 'Excited', '#5FD3C4', 'Buzzing'),
  MoodData('calm', '🌊', 'Calm', '#85B7EB', 'Peaceful'),
  MoodData('playful', '🎲', 'Playful', '#F0997B', 'Cheeky'),
  MoodData('romantic', '🌹', 'Romantic', '#D45A77', 'Enchanted'),
  MoodData('tired', '🌛', 'Tired', '#B79CB0', 'Sleepy'),
  MoodData('anxious', '🌀', 'Anxious', '#9FD8A0', 'Restless'),
  MoodData('grateful', '🙏', 'Grateful', '#F2A9BC', 'Thankful'),
  MoodData('sad', '💧', 'Blue', '#378ADD', 'Reflective'),
];

MoodData? moodByKey(String? key) {
  if (key == null) return null;
  for (final m in kMoods) {
    if (m.key == key) return m;
  }
  return null;
}
