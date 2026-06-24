import 'package:flutter/material.dart';
import 'package:miles/core/mood.dart';
import 'package:miles/core/theme.dart';

/// A bottom sheet of mood chips. Returns the chosen [MoodData] (or null).
Future<MoodData?> showMoodSelector(BuildContext context, {String? currentKey}) {
  return showModalBottomSheet<MoodData>(
    context: context,
    backgroundColor: MilesColors.surface1,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How are you feeling?',
                style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            const Text('Your partner sees this with its glow.',
                style: TextStyle(color: MilesColors.taupe, fontSize: 12.5)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final m in kMoods)
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx, m),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: m.color
                            .withValues(alpha: currentKey == m.key ? 0.30 : 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: m.color.withValues(
                              alpha: currentKey == m.key ? 0.85 : 0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(m.emoji),
                          const SizedBox(width: 6),
                          Text(m.label,
                              style: const TextStyle(
                                  color: MilesColors.cream50, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
